import Darwin
import Foundation
import PlayCoverCore
import Security

public struct VerifiedXPCClientIdentity: Equatable, Sendable {
    public let pid: pid_t
    public let uid: uid_t
    public let gid: gid_t
    public let homeDirectory: String

    public init(pid: pid_t, uid: uid_t, gid: gid_t, homeDirectory: String) {
        self.pid = pid
        self.uid = uid
        self.gid = gid
        self.homeDirectory = homeDirectory
    }
}

public enum HelperSecurityValidator {
    public static let expectedClientBundleID = "app.makedie.MacOver"
    public static let maxRepairDepth = 64

    public static let reservedBundleIdentifierPrefixes: [String] = [
        "com.apple.",
        "app.makedie.",
        "io.playcover."
    ]

    public static let reservedBundleIdentifiers: Set<String> = [
        "com.apple",
        "app.makedie",
        "io.playcover"
    ]

    private static let developerIDRequirementString =
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ " +
        "and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */"

    public static func validateBundleIdentifier(_ bundleID: String) -> Bool {
        Shell.isValidBundleIdentifier(bundleID)
    }

    public static func isReservedBundleIdentifier(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        if reservedBundleIdentifiers.contains(lower) {
            return true
        }
        return reservedBundleIdentifierPrefixes.contains { lower.hasPrefix($0) }
    }

    public static func validateGuestBundleIdentifier(_ bundleID: String) -> Bool {
        validateBundleIdentifier(bundleID) && !isReservedBundleIdentifier(bundleID)
    }

    private static func readBundleIdentifierFromAppDirectory(_ appURL: URL) -> String? {
        var dirStat = Darwin.stat()
        guard Darwin.lstat(appURL.path, &dirStat) == 0,
              (dirStat.st_mode & S_IFMT) == S_IFDIR else {
            return nil
        }
        let plistURL = appURL.appendingPathComponent("Info.plist")
        let fd = Darwin.open(plistURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            return nil
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }

        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_size > 0,
              st.st_size <= 2 * 1024 * 1024 else {
            return nil
        }
        guard let data = try? handle.read(upToCount: Int(st.st_size)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let bundleID = dict["CFBundleIdentifier"] as? String else {
            return nil
        }
        return bundleID
    }

    public static func isManagedAppBundleID(_ bundleID: String, in managedAppsDirectory: URL) -> Bool {
        guard validateGuestBundleIdentifier(bundleID) else {
            return false
        }
        var appsDirStat = Darwin.stat()
        guard Darwin.lstat(managedAppsDirectory.path, &appsDirStat) == 0,
              (appsDirStat.st_mode & S_IFMT) == S_IFDIR else {
            return false
        }

        let directAppURL = managedAppsDirectory.appendingPathComponent("\(bundleID).app", isDirectory: true)
        if readBundleIdentifierFromAppDirectory(directAppURL) == bundleID {
            return true
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: managedAppsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }
        for entry in entries where entry.pathExtension == "app" {
            if readBundleIdentifierFromAppDirectory(entry) == bundleID {
                return true
            }
        }
        return false
    }

    public static func homeDirectory(forUID uid: uid_t) -> String? {
        guard uid != 0 else { return nil }
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var bufferSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        if bufferSize <= 0 {
            bufferSize = 16_384
        }
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let rc = getpwuid_r(uid, &pwd, &buffer, buffer.count, &result)
        guard rc == 0, let entry = result, let dirPtr = entry.pointee.pw_dir else {
            return nil
        }
        let home = String(cString: dirPtr)
        guard home.hasPrefix("/Users/"),
              !home.contains(".."),
              !home.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }
        return URL(fileURLWithPath: home).standardizedFileURL.path
    }

    public static func validateContainerPath(
        _ path: String,
        userHomeRoot: String? = nil,
        requireExisting: Bool = false,
        managedAppsDirectory: URL? = nil
    ) -> String? {
        guard !path.isEmpty, path.hasPrefix("/") else {
            return nil
        }
        if path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return nil
        }

        let rawURL = URL(fileURLWithPath: path)
        if rawURL.pathComponents.contains("..") || rawURL.pathComponents.contains(".") {
            return nil
        }

        let standardized = rawURL.standardizedFileURL.path
        let components = URL(fileURLWithPath: standardized).pathComponents
        // Expected shape: ["/", "Users", "<username>", "Library", "Containers", "<bundleID>", ...]
        guard components.count >= 6,
              components[0] == "/",
              components[1] == "Users",
              !components[2].isEmpty,
              components[2] != "." && components[2] != "..",
              components[3] == "Library",
              components[4] == "Containers" else {
            return nil
        }

        let containerID = components[5]
        guard validateGuestBundleIdentifier(containerID) else {
            return nil
        }
        if let managedAppsDirectory {
            guard isManagedAppBundleID(containerID, in: managedAppsDirectory) else {
                return nil
            }
        }

        if let userHomeRoot {
            let expectedHome = URL(fileURLWithPath: userHomeRoot).standardizedFileURL.path
            guard !expectedHome.isEmpty, expectedHome.hasPrefix("/Users/") else {
                return nil
            }
            let expectedPrefix = URL(fileURLWithPath: expectedHome)
                .appendingPathComponent("Library/Containers", isDirectory: true)
                .standardizedFileURL
                .path
            guard standardized.hasPrefix(expectedPrefix + "/") else {
                return nil
            }
        }

        // Reject any symlink on existing path components (and require existence when requested).
        var current = ""
        for idx in 1..<components.count {
            current += "/" + components[idx]
            var st = Darwin.stat()
            if Darwin.lstat(current, &st) == 0 {
                let fileType = st.st_mode & S_IFMT
                if fileType == S_IFLNK {
                    return nil
                }
                let isLast = (idx == components.count - 1)
                if !isLast && fileType != S_IFDIR {
                    return nil
                }
                if isLast && requireExisting && fileType != S_IFDIR {
                    return nil
                }
            } else {
                if requireExisting {
                    return nil
                }
                if errno != ENOENT {
                    return nil
                }
                break
            }
        }

        return standardized
    }

    /// Descriptor-pinned permission and ownership repair under a validated container path.
    /// Never follows symlinks and never crosses filesystem device boundaries.
    public static func repairContainerPermissionsSecurely(
        at path: String,
        userHomeRoot: String,
        ownerUID: uid_t? = nil,
        ownerGID: gid_t? = nil,
        managedAppsDirectory: URL? = nil
    ) throws {
        guard let validatedPath = validateContainerPath(
            path,
            userHomeRoot: userHomeRoot,
            requireExisting: true,
            managedAppsDirectory: managedAppsDirectory
        ) else {
            throw PlayCoverError.privilegeEscalationFailed("Rejected invalid container path for permission repair.")
        }

        let rootFD = try openDirectoryComponentByComponent(validatedPath)
        defer { _ = Darwin.close(rootFD) }

        var rootStat = Darwin.stat()
        guard Darwin.fstat(rootFD, &rootStat) == 0,
              (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw PlayCoverError.privilegeEscalationFailed("Target container path is not a directory.")
        }

        let context = RepairContext(
            rootDevice: rootStat.st_dev,
            ownerUID: ownerUID,
            ownerGID: ownerGID
        )
        try repairDirectoryTree(
            dirFD: rootFD,
            dirStat: rootStat,
            context: context,
            depth: 0
        )
    }

    private struct RepairContext {
        let rootDevice: dev_t
        let ownerUID: uid_t?
        let ownerGID: gid_t?
    }

    private static func openDirectoryComponentByComponent(_ absolutePath: String) throws -> Int32 {
        let components = URL(fileURLWithPath: absolutePath).pathComponents.dropFirst()
        var currentFD = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard currentFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }
        for component in components {
            let nextFD = Darwin.openat(
                currentFD,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            _ = Darwin.close(currentFD)
            guard nextFD >= 0 else {
                let err = errno
                if err == ELOOP || err == ENOTDIR {
                    throw PlayCoverError.privilegeEscalationFailed(
                        "Rejected symlink or non-directory component during permission repair."
                    )
                }
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EACCES)
            }
            currentFD = nextFD
        }
        return currentFD
    }

    private static func normalizedRepairedMode(existingMode: mode_t, isDirectory: Bool) -> mode_t {
        var mode = existingMode & 0o0777 // strip SUID/SGID/sticky escalation bits
        mode |= mode_t(S_IRUSR | S_IWUSR)
        if isDirectory || (existingMode & 0o111) != 0 {
            mode |= mode_t(S_IXUSR)
        }
        return mode
    }

    private static func repairDirectoryTree(
        dirFD: Int32,
        dirStat: Darwin.stat,
        context: RepairContext,
        depth: Int
    ) throws {
        guard depth <= maxRepairDepth else {
            throw PlayCoverError.privilegeEscalationFailed("Container directory depth exceeds safety limit.")
        }

        if let uid = context.ownerUID, let gid = context.ownerGID {
            if Darwin.fchown(dirFD, uid, gid) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
            }
        }
        let dirMode = normalizedRepairedMode(existingMode: dirStat.st_mode, isDirectory: true)
        if Darwin.fchmod(dirFD, dirMode) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }

        var subdirectories: [String] = []
        do {
            let dupFD = Darwin.dup(dirFD)
            guard dupFD >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EMFILE)
            }
            guard let dirStream = Darwin.fdopendir(dupFD) else {
                let err = errno
                _ = Darwin.close(dupFD)
                throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EACCES)
            }
            defer { _ = Darwin.closedir(dirStream) }

            while let entry = Darwin.readdir(dirStream) {
                let name = withUnsafePointer(to: &entry.pointee.d_name) { ptr in
                    ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { cStr in
                        String(cString: cStr)
                    }
                }
                if name == "." || name == ".." {
                    continue
                }

                var childStat = Darwin.stat()
                guard Darwin.fstatat(dirFD, name, &childStat, AT_SYMLINK_NOFOLLOW) == 0 else {
                    continue
                }
                let fileType = childStat.st_mode & S_IFMT
                if fileType == S_IFLNK {
                    // Never follow or modify symlinks inside an untrusted container tree.
                    continue
                }
                if childStat.st_dev != context.rootDevice {
                    continue
                }

                if fileType == S_IFDIR {
                    subdirectories.append(name)
                } else if fileType == S_IFREG {
                    guard childStat.st_nlink == 1 else {
                        throw PlayCoverError.privilegeEscalationFailed(
                            "Rejected hardlinked file during container permission repair."
                        )
                    }
                    let fileFD = Darwin.openat(dirFD, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fileFD >= 0 else {
                        let err = errno
                        if err == ENOENT || err == ELOOP {
                            continue
                        }
                        throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EPERM)
                    }
                    defer { _ = Darwin.close(fileFD) }

                    var openedStat = Darwin.stat()
                    guard Darwin.fstat(fileFD, &openedStat) == 0,
                          (openedStat.st_mode & S_IFMT) == S_IFREG,
                          openedStat.st_dev == context.rootDevice else {
                        continue
                    }
                    guard openedStat.st_nlink == 1 else {
                        throw PlayCoverError.privilegeEscalationFailed(
                            "Rejected hardlinked file during container permission repair."
                        )
                    }

                    if let uid = context.ownerUID, let gid = context.ownerGID {
                        if Darwin.fchown(fileFD, uid, gid) != 0 {
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
                        }
                    }
                    let fileMode = normalizedRepairedMode(existingMode: openedStat.st_mode, isDirectory: false)
                    if Darwin.fchmod(fileFD, fileMode) != 0 {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
                    }
                }
            }
        }

        // dirStream is closed before recursing to avoid EMFILE on deep trees.
        for name in subdirectories {
            let childFD = Darwin.openat(
                dirFD,
                name,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard childFD >= 0 else { continue }
            defer { _ = Darwin.close(childFD) }
            var openedStat = Darwin.stat()
            guard Darwin.fstat(childFD, &openedStat) == 0,
                  (openedStat.st_mode & S_IFMT) == S_IFDIR,
                  openedStat.st_dev == context.rootDevice else {
                continue
            }
            try repairDirectoryTree(
                dirFD: childFD,
                dirStat: openedStat,
                context: context,
                depth: depth + 1
            )
        }
    }

    public static func isValidTeamIdentifier(_ teamID: String) -> Bool {
        guard !teamID.isEmpty, teamID.count <= 32 else {
            return false
        }
        return teamID.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A)
        }
    }

    public static func clientCodeSigningRequirement(teamID: String? = currentProcessTeamIdentifier()) -> String? {
        guard let teamID, isValidTeamIdentifier(teamID) else {
            return nil
        }
        return "identifier \"\(expectedClientBundleID)\" and \(developerIDRequirementString) " +
            "and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    public static func extractAuditToken(from connection: NSXPCConnection) -> audit_token_t? {
        let selector = Selector(("auditToken"))
        guard connection.responds(to: selector),
              let rawValue = connection.value(forKey: "auditToken") as? NSValue else {
            return nil
        }
        var token = audit_token_t()
        rawValue.getValue(&token, size: MemoryLayout<audit_token_t>.size)
        return token
    }

    public static func verifyIncomingConnectionIdentity(
        _ connection: NSXPCConnection
    ) -> VerifiedXPCClientIdentity? {
        guard let ownTeamID = currentProcessTeamIdentifier(),
              let requirementString = clientCodeSigningRequirement(teamID: ownTeamID) else {
            return nil
        }

        connection.setCodeSigningRequirement(requirementString)

        guard var token = extractAuditToken(from: connection) else {
            return nil
        }
        let pid = pid_t(bitPattern: token.val.5)
        let euid = uid_t(token.val.1)
        let egid = gid_t(token.val.2)
        guard pid > 0, euid != 0,
              let homeDir = homeDirectory(forUID: euid) else {
            return nil
        }

        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        let attributes: [String: Any] = [
            kSecGuestAttributeAudit as String: tokenData as CFData
        ]

        var guestCode: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, SecCSFlags(), &guestCode)
        guard status == errSecSuccess,
              let code = guestCode else {
            return nil
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementString as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let devIDRequirement = requirement else {
            return nil
        }

        // Dynamic code validity check on the live process represented by the audit token.
        guard SecCodeCheckValidity(code, SecCSFlags(), devIDRequirement) == errSecSuccess else {
            return nil
        }

        var guestStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &guestStatic) == errSecSuccess,
              let staticClient = guestStatic else {
            return nil
        }

        guard SecStaticCodeCheckValidity(staticClient, SecCSFlags(), devIDRequirement) == errSecSuccess else {
            return nil
        }

        var clientInfoCF: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticClient,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &clientInfoCF
        ) == errSecSuccess,
        let clientInfo = clientInfoCF as? [String: Any],
        let clientIdentifier = clientInfo[kSecCodeInfoIdentifier as String] as? String,
        let clientTeamID = clientInfo[kSecCodeInfoTeamIdentifier as String] as? String,
        clientIdentifier == expectedClientBundleID,
        clientTeamID == ownTeamID else {
            return nil
        }

        return VerifiedXPCClientIdentity(
            pid: pid,
            uid: euid,
            gid: egid,
            homeDirectory: homeDir
        )
    }

    public static func verifyIncomingConnection(_ connection: NSXPCConnection) -> Bool {
        verifyIncomingConnectionIdentity(connection) != nil
    }

    public static func currentProcessTeamIdentifier() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess, let code = selfCode else {
            return nil
        }
        var selfStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &selfStatic) == errSecSuccess,
              let staticSelf = selfStatic else {
            return nil
        }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticSelf,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF
        ) == errSecSuccess,
        let info = infoCF as? [String: Any] else {
            return nil
        }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
