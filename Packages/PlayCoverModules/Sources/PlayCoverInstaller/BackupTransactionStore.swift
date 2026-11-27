//
//  BackupTransactionStore.swift
//  PlayCoverInstaller
//

import Darwin
import Foundation
import PlayCoverCore
import PlayCoverMachO

public struct AppBackupManifest: Codable, Equatable, Sendable {
    public static let installGenerationInfoKey = "PCInstallGeneration"
    public static let backupManifestFileName = "manifest.plist"

    private enum CodingKeys: String, CodingKey {
        case bundleIdentifier = "CFBundleIdentifier"
        case shortVersionString = "CFBundleShortVersionString"
        case bundleVersion = "CFBundleVersion"
        case installGeneration = "PCInstallGeneration"
    }

    public let bundleIdentifier: String
    public let shortVersionString: String
    public let bundleVersion: String
    public let installGeneration: String

    public init(
        bundleIdentifier: String,
        shortVersionString: String,
        bundleVersion: String,
        installGeneration: String
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.shortVersionString = shortVersionString
        self.bundleVersion = bundleVersion
        self.installGeneration = installGeneration
    }

    public init?(appInfo: AppInfo) {
        let bundleID = appInfo.bundleIdentifier
        let generation = appInfo[string: Self.installGenerationInfoKey] ?? ""
        guard !bundleID.isEmpty, !generation.isEmpty else {
            return nil
        }
        self.bundleIdentifier = bundleID
        self.shortVersionString = appInfo[string: "CFBundleShortVersionString"] ?? ""
        self.bundleVersion = appInfo[string: "CFBundleVersion"] ?? ""
        self.installGeneration = generation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        self.shortVersionString = try container.decode(String.self, forKey: .shortVersionString)
        self.bundleVersion = try container.decode(String.self, forKey: .bundleVersion)
        self.installGeneration = try container.decode(String.self, forKey: .installGeneration)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(shortVersionString, forKey: .shortVersionString)
        try container.encode(bundleVersion, forKey: .bundleVersion)
        try container.encode(installGeneration, forKey: .installGeneration)
    }
}

public enum AppBackupStagingResult: Equatable, Sendable {
    case staged(URL)
    case noneApplicable
    case failed
}

public enum AppBackupCommitOutcome: Equatable, Sendable {
    case committed
    case noneApplicable
    case degradedWithoutBackups
}

public enum PathPresence: Equatable, Sendable {
    case present
    case absent
    case queryFailed(Int32)
}

public enum BackupTransactionStore {
    public static func restoreRollbackFile(
        at url: URL,
        existedBefore: Bool,
        previousData: Data?,
        label: String
    ) {
        if let previousData {
            try? previousData.write(to: url, options: .atomic)
        } else if !existedBefore {
            try? FileManager.default.removeItem(at: url)
        } else {
            PlayCoverDiagnostics.log(
                "Preserving pre-existing unreadable \(label) file at \(url.path) during install rollback",
                isError: true
            )
        }
    }

    private static func isRegularFileNoFollow(at url: URL) -> Bool {
        var st = stat()
        guard Darwin.lstat(url.path, &st) == 0 else {
            return false
        }
        return (st.st_mode & S_IFMT) == S_IFREG
    }

    private static func checkBackupSourceRegularFile(at url: URL, label: String) -> Bool {
        if isRegularFileNoFollow(at: url) {
            return true
        }
        if case .present = probePathPresence(at: url) {
            PlayCoverDiagnostics.log(
                "Refusing non-regular \(label) during AppBackups staging: \(url.lastPathComponent)",
                isError: true
            )
        }
        return false
    }

    private static func copyRegularFileNoFollow(from src: URL, to dst: URL) throws {
        let srcFD = Darwin.open(src.path, O_RDONLY | O_NOFOLLOW)
        guard srcFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(srcFD) }

        var st = stat()
        guard Darwin.fstat(srcFD, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }

        let dstFD = Darwin.open(dst.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o644))
        guard dstFD >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var closedDst = false
        defer {
            if !closedDst {
                Darwin.close(dstFD)
            }
        }

        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { ptr in
                Darwin.read(srcFD, ptr.baseAddress, ptr.count)
            }
            if bytesRead == 0 {
                break
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            var written = 0
            while written < bytesRead {
                let res = buffer.withUnsafeBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return -1 }
                    return Darwin.write(dstFD, base.advanced(by: written), bytesRead - written)
                }
                if res < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                written += res
            }
        }
        if Darwin.close(dstFD) != 0 {
            closedDst = true
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        closedDst = true
    }

    private static func cloneOrCopyRegularFileNoFollow(from src: URL, to dst: URL) throws {
        if Darwin.clonefile(src.path, dst.path, UInt32(CLONE_NOFOLLOW)) == 0 {
            return
        }
        let cloneErr = errno
        if cloneErr == ELOOP || cloneErr == EISDIR {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(cloneErr))
        }
        try copyRegularFileNoFollow(from: src, to: dst)
    }

    public static func stageAppBackups(
        bundleURL: URL,
        executableURL: URL,
        in stagingDir: URL
    ) -> AppBackupStagingResult {
        let fm = FileManager.default
        if fm.fileExists(atPath: stagingDir.path) {
            try? fm.removeItem(at: stagingDir)
        }

        let provisionURL = bundleURL.appendingPathComponent("embedded.mobileprovision")
        let hasProvision = checkBackupSourceRegularFile(at: provisionURL, label: "embedded.mobileprovision")

        let infoPlistURL = bundleURL.appendingPathComponent("Info.plist")
        let hasInfoPlist = checkBackupSourceRegularFile(at: infoPlistURL, label: "Info.plist")

        let codeResourcesURL = bundleURL
            .appendingPathComponent("_CodeSignature")
            .appendingPathComponent("CodeResources")
        let hasCodeResources = checkBackupSourceRegularFile(
            at: codeResourcesURL,
            label: "_CodeSignature/CodeResources"
        )

        let executableSliceContext: Macho.SliceContext?
        if checkBackupSourceRegularFile(at: executableURL, label: "executable") {
            do {
                executableSliceContext = try Macho.inspectArm64Slice(at: executableURL)
            } catch {
                PlayCoverDiagnostics.log(
                    "Failed to inspect executable for AppBackups staging: \(error)",
                    isError: true
                )
                return .failed
            }
        } else {
            executableSliceContext = nil
        }

        guard hasProvision || executableSliceContext != nil || hasInfoPlist || hasCodeResources else {
            return .noneApplicable
        }

        do {
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            PlayCoverDiagnostics.log("Failed to create AppBackups staging dir: \(error)", isError: true)
            return .failed
        }

        if hasCodeResources {
            do {
                try cloneOrCopyRegularFileNoFollow(
                    from: codeResourcesURL,
                    to: stagingDir.appendingPathComponent("CodeResources")
                )
            } catch {
                PlayCoverDiagnostics.log("Failed to stage CodeResources backup: \(error)", isError: true)
                try? fm.removeItem(at: stagingDir)
                return .failed
            }
        }

        if hasInfoPlist {
            do {
                try cloneOrCopyRegularFileNoFollow(
                    from: infoPlistURL,
                    to: stagingDir.appendingPathComponent("Info.plist")
                )
            } catch {
                PlayCoverDiagnostics.log("Failed to stage Info.plist backup: \(error)", isError: true)
                try? fm.removeItem(at: stagingDir)
                return .failed
            }
        }

        if hasProvision {
            do {
                try cloneOrCopyRegularFileNoFollow(
                    from: provisionURL,
                    to: stagingDir.appendingPathComponent("embedded.mobileprovision")
                )
            } catch {
                PlayCoverDiagnostics.log("Failed to stage embedded.mobileprovision backup: \(error)", isError: true)
                try? fm.removeItem(at: stagingDir)
                return .failed
            }
        }

        if let ctx = executableSliceContext {
            let stagedExec = stagingDir.appendingPathComponent("executable")
            do {
                if !ctx.isFat {
                    try cloneOrCopyRegularFileNoFollow(from: executableURL, to: stagedExec)
                } else {
                    let srcHandle = try FileHandle(forReadingFrom: executableURL)
                    defer { try? srcHandle.close() }
                    guard fm.createFile(
                        atPath: stagedExec.path,
                        contents: nil,
                        attributes: [.posixPermissions: NSNumber(value: 0o755)]
                    ) else {
                        throw PlayCoverError.failedToStripBinary
                    }
                    let outHandle = try FileHandle(forWritingTo: stagedExec)
                    do {
                        try srcHandle.seek(toOffset: ctx.sliceOffset)
                        var remaining = ctx.sliceSize
                        let chunkSize = 4 * 1024 * 1024
                        while remaining > 0 {
                            let step = Int(min(remaining, UInt64(chunkSize)))
                            let written: Int = try autoreleasepool {
                                guard let chunk = try srcHandle.read(upToCount: step), !chunk.isEmpty else {
                                    throw PlayCoverError.appCorrupted
                                }
                                try outHandle.write(contentsOf: chunk)
                                return chunk.count
                            }
                            remaining -= UInt64(written)
                        }
                        try outHandle.close()
                    } catch {
                        try? outHandle.close()
                        throw error
                    }
                }
                try? stagedExec.setBinaryPosixPermissions(0o755)
            } catch {
                PlayCoverDiagnostics.log("Failed to stage executable backup: \(error)", isError: true)
                try? fm.removeItem(at: stagingDir)
                return .failed
            }
        }

        return .staged(stagingDir)
    }

    private static func canonicalFilePath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    public static func isSubpath(_ candidate: URL, of directory: URL) -> Bool {
        let stdDir = directory.standardizedFileURL.path
        let stdCand = candidate.standardizedFileURL.path
        let stdPrefix = stdDir.hasSuffix("/") ? stdDir : (stdDir + "/")
        if stdCand.hasPrefix(stdPrefix) {
            return true
        }
        let realDir = canonicalFilePath(directory)
        let realCand = canonicalFilePath(candidate)
        let realPrefix = realDir.hasSuffix("/") ? realDir : (realDir + "/")
        return realCand.hasPrefix(realPrefix)
    }

    public static func probePathPresence(at targetURL: URL) -> PathPresence {
        var st = stat()
        if Darwin.lstat(targetURL.path, &st) == 0 {
            return .present
        }
        let err = errno
        if err == ENOENT {
            return .absent
        }
        return .queryFailed(err)
    }

    public static func isSafeBundleIdentifierForStorage(_ bundleIdentifier: String) -> Bool {
        guard !bundleIdentifier.isEmpty,
              bundleIdentifier != ".",
              bundleIdentifier != "..",
              !bundleIdentifier.hasPrefix("."),
              !bundleIdentifier.contains("/"),
              !bundleIdentifier.contains("\\"),
              !bundleIdentifier.contains("\0") else {
            return false
        }
        return true
    }

    private static func isValidatedBackupTarget(_ targetDir: URL, bundleIdentifier: String) -> Bool {
        guard isSafeBundleIdentifierForStorage(bundleIdentifier),
              targetDir.lastPathComponent == bundleIdentifier else {
            return false
        }
        let parentDir = targetDir.deletingLastPathComponent()
        let expectedPath = parentDir.appendingPathComponent(bundleIdentifier).standardizedFileURL.path
        guard targetDir.standardizedFileURL.path == expectedPath else {
            return false
        }
        return isSubpath(targetDir, of: parentDir)
    }

    private static func invalidatedBackupPrefix(for directoryName: String) -> String {
        ".\(directoryName).invalidated-"
    }

    public static func quarantineAppBackups(at targetDir: URL, bundleIdentifier: String) throws -> URL? {
        guard isValidatedBackupTarget(targetDir, bundleIdentifier: bundleIdentifier) else {
            throw PlayCoverError.playToolsError(
                "Refusing to quarantine AppBackups outside expected container for \(bundleIdentifier)"
            )
        }
        switch probePathPresence(at: targetDir) {
        case .absent:
            return nil
        case .queryFailed(let err):
            let msg = String(cString: strerror(err))
            PlayCoverDiagnostics.log(
                "Failed to query AppBackups before quarantine for \(bundleIdentifier): \(msg) (errno=\(err))",
                isError: true
            )
            throw PlayCoverError.playToolsError(
                "Failed to query AppBackups for \(bundleIdentifier): \(msg) (errno=\(err))"
            )
        case .present:
            break
        }
        let invalidatedDir = targetDir.deletingLastPathComponent().appendingPathComponent(
            "\(invalidatedBackupPrefix(for: targetDir.lastPathComponent))\(UUID().uuidString)"
        )
        if Darwin.rename(targetDir.path, invalidatedDir.path) == 0 {
            return invalidatedDir
        }
        let renameErr = errno
        PlayCoverDiagnostics.log(
            "Atomic rename failed quarantining AppBackups for \(bundleIdentifier): " +
                "\(String(cString: strerror(renameErr)))",
            isError: true
        )
        try FileManager.default.moveItem(at: targetDir, to: invalidatedDir)
        return invalidatedDir
    }

    @discardableResult
    public static func restoreQuarantinedAppBackups(
        _ quarantinedDir: URL,
        to targetDir: URL,
        bundleIdentifier: String
    ) -> Bool {
        let parentDir = targetDir.deletingLastPathComponent()
        let prefix = invalidatedBackupPrefix(for: bundleIdentifier)
        guard isValidatedBackupTarget(targetDir, bundleIdentifier: bundleIdentifier),
              isSubpath(quarantinedDir, of: parentDir),
              quarantinedDir.lastPathComponent.hasPrefix(prefix) else {
            PlayCoverDiagnostics.log(
                "Refusing to restore quarantined AppBackups outside expected container for \(bundleIdentifier)",
                isError: true
            )
            return false
        }
        switch probePathPresence(at: quarantinedDir) {
        case .present:
            break
        case .absent:
            return false
        case .queryFailed(let err):
            PlayCoverDiagnostics.log(
                "Failed to query quarantined AppBackups for \(bundleIdentifier): " +
                    "\(String(cString: strerror(err))) (errno=\(err))",
                isError: true
            )
            return false
        }
        switch probePathPresence(at: targetDir) {
        case .absent:
            break
        case .present:
            PlayCoverDiagnostics.log(
                "Cannot restore quarantined AppBackups for \(bundleIdentifier): " +
                    "active path \(targetDir.path) is still occupied",
                isError: true
            )
            return false
        case .queryFailed(let err):
            PlayCoverDiagnostics.log(
                "Cannot restore quarantined AppBackups for \(bundleIdentifier): " +
                    "failed to query active path \(targetDir.path): \(String(cString: strerror(err))) (errno=\(err))",
                isError: true
            )
            return false
        }
        if Darwin.rename(quarantinedDir.path, targetDir.path) == 0 {
            return true
        }
        let renameErr = errno
        do {
            try FileManager.default.moveItem(at: quarantinedDir, to: targetDir)
            return true
        } catch {
            PlayCoverDiagnostics.log(
                "Failed to restore quarantined AppBackups for \(bundleIdentifier) " +
                    "(rename errno=\(renameErr)): \(error)",
                isError: true
            )
            return false
        }
    }

    public static func cleanupInvalidatedAppBackups(
        primary: URL?,
        in parentDir: URL,
        bundleIdentifier: String,
        excluding excludedURLs: Set<URL> = []
    ) {
        guard isSafeBundleIdentifierForStorage(bundleIdentifier) else {
            PlayCoverDiagnostics.log(
                "Refusing cleanupInvalidatedAppBackups for invalid bundle identifier: \(bundleIdentifier)",
                isError: true
            )
            return
        }
        let fm = FileManager.default
        let prefix = invalidatedBackupPrefix(for: bundleIdentifier)
        let excludedStdPaths = Set(excludedURLs.map { $0.standardizedFileURL.path })
        let excludedRealPaths = Set(excludedURLs.map { canonicalFilePath($0) })
        let isExcluded: (URL) -> Bool = { candidate in
            excludedStdPaths.contains(candidate.standardizedFileURL.path) ||
                excludedRealPaths.contains(canonicalFilePath(candidate))
        }

        if let primary,
           !isExcluded(primary),
           isSubpath(primary, of: parentDir),
           primary.lastPathComponent.hasPrefix(prefix) {
            var st = stat()
            if Darwin.lstat(primary.path, &st) == 0 {
                do {
                    try fm.removeItem(at: primary)
                } catch {
                    PlayCoverDiagnostics.log(
                        "Failed to remove invalidated AppBackups \(primary.lastPathComponent) " +
                            "for \(bundleIdentifier): \(error)",
                        isError: true
                    )
                }
            }
        }
        if let entries = try? fm.contentsOfDirectory(
            at: parentDir,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
                if isExcluded(entry) {
                    continue
                }
                do {
                    try fm.removeItem(at: entry)
                } catch {
                    PlayCoverDiagnostics.log(
                        "Failed to clean up leftover invalidated AppBackups \(entry.lastPathComponent) " +
                            "for \(bundleIdentifier): \(error)",
                        isError: true
                    )
                }
            }
        }
    }

    public static func invalidateAppBackups(at targetDir: URL, bundleIdentifier: String) -> Bool {
        guard isValidatedBackupTarget(targetDir, bundleIdentifier: bundleIdentifier) else {
            PlayCoverDiagnostics.log(
                "Refusing to invalidate AppBackups outside expected container for \(bundleIdentifier)",
                isError: true
            )
            return false
        }
        let fm = FileManager.default
        switch probePathPresence(at: targetDir) {
        case .absent:
            return true
        case .queryFailed(let err):
            PlayCoverDiagnostics.log(
                "Failed to query AppBackups for invalidation at \(targetDir.path) (\(bundleIdentifier)): " +
                    "\(String(cString: strerror(err))) (errno=\(err))",
                isError: true
            )
            return false
        case .present:
            break
        }
        let invalidatedDir = targetDir.deletingLastPathComponent().appendingPathComponent(
            "\(invalidatedBackupPrefix(for: targetDir.lastPathComponent))\(UUID().uuidString)"
        )
        if Darwin.rename(targetDir.path, invalidatedDir.path) == 0 {
            do {
                try fm.removeItem(at: invalidatedDir)
            } catch {
                PlayCoverDiagnostics.log(
                    "Evicted stale AppBackups for \(bundleIdentifier) to \(invalidatedDir.lastPathComponent), " +
                        "but removal failed: \(error)",
                    isError: true
                )
            }
            return true
        }

        let renameErr = errno
        let renameMessage = String(cString: strerror(renameErr))
        do {
            try fm.removeItem(at: targetDir)
            return true
        } catch let removeError {
            PlayCoverDiagnostics.log(
                "Failed to evict stale AppBackups for \(bundleIdentifier) " +
                    "(rename: \(renameMessage), remove: \(removeError))",
                isError: true
            )
            var orderedNames: [String] = [
                AppBackupManifest.backupManifestFileName,
                "Info.plist",
                "CodeResources",
                "executable",
                "embedded.mobileprovision"
            ]
            if let listed = try? fm.contentsOfDirectory(atPath: targetDir.path) {
                for item in listed where !orderedNames.contains(item) {
                    orderedNames.append(item)
                }
            }
            for name in orderedNames {
                let itemURL = targetDir.appendingPathComponent(name)
                if Darwin.unlink(itemURL.path) != 0 {
                    let unlinkErr = errno
                    if unlinkErr != ENOENT {
                        PlayCoverDiagnostics.log(
                            "Failed to unlink \(name) in stale AppBackups for \(bundleIdentifier): " +
                                "\(String(cString: strerror(unlinkErr)))",
                            isError: true
                        )
                    }
                }
            }
            if Darwin.rmdir(targetDir.path) == 0 {
                return true
            }
            if Darwin.rename(targetDir.path, invalidatedDir.path) == 0 {
                do {
                    try fm.removeItem(at: invalidatedDir)
                } catch {
                    PlayCoverDiagnostics.log(
                        "Failed to remove evicted AppBackups \(invalidatedDir.lastPathComponent) " +
                            "for \(bundleIdentifier): \(error)",
                        isError: true
                    )
                }
                return true
            }
            PlayCoverDiagnostics.log(
                "Critical: stale AppBackups directory remains at active path for \(bundleIdentifier)",
                isError: true
            )
            return false
        }
    }

    public static func verifyAppBackupManifest(in backupDir: URL, for appInfo: AppInfo) -> Bool {
        guard let expected = AppBackupManifest(appInfo: appInfo) else {
            return false
        }
        let manifestURL = backupDir.appendingPathComponent(AppBackupManifest.backupManifestFileName)
        guard let data = try? Data(contentsOf: manifestURL),
              let actual = try? PropertyListDecoder().decode(AppBackupManifest.self, from: data) else {
            return false
        }
        return actual == expected
    }

    public static func validateOrInvalidateAppBackupsForLaunch(
        at backupDir: URL,
        for appInfo: AppInfo
    ) throws {
        let bundleID = appInfo.bundleIdentifier
        guard !bundleID.isEmpty else {
            return
        }
        switch probePathPresence(at: backupDir) {
        case .absent:
            return
        case .queryFailed(let err):
            let msg = String(cString: strerror(err))
            PlayCoverDiagnostics.log(
                "Failed to query AppBackups before launch for \(bundleID): \(msg) (errno=\(err))",
                isError: true
            )
            throw PlayCoverError.playToolsError(
                "Failed to inspect AppBackups for \(bundleID): \(msg) (errno=\(err))"
            )
        case .present:
            if !verifyAppBackupManifest(in: backupDir, for: appInfo) {
                guard invalidateAppBackups(at: backupDir, bundleIdentifier: bundleID) else {
                    throw PlayCoverError.playToolsError(
                        "Failed to evict stale AppBackups for \(bundleID)"
                    )
                }
            }
        }
    }

    @discardableResult
    public static func finalizeAppBackupsAfterSwap(
        _ stagingResult: AppBackupStagingResult,
        to targetDir: URL,
        bundleIdentifier: String,
        manifest: AppBackupManifest?,
        quarantinedDir: URL?
    ) throws -> AppBackupCommitOutcome {
        let outcome = try commitAppBackups(
            stagingResult,
            to: targetDir,
            bundleIdentifier: bundleIdentifier,
            manifest: manifest
        )
        switch outcome {
        case .committed, .noneApplicable:
            cleanupInvalidatedAppBackups(
                primary: quarantinedDir,
                in: targetDir.deletingLastPathComponent(),
                bundleIdentifier: bundleIdentifier
            )
        case .degradedWithoutBackups:
            if let quarantinedDir {
                PlayCoverDiagnostics.log(
                    "AppBackups staging or validation failed for \(bundleIdentifier); " +
                        "preserving quarantined previous AppBackups at \(quarantinedDir.path)",
                    isError: true
                )
            } else {
                PlayCoverDiagnostics.log(
                    "AppBackups staging or validation failed for \(bundleIdentifier); " +
                        "continuing installation without AppBackups",
                    isError: true
                )
            }
        }
        return outcome
    }

    public static func replaceBackupDirectoryAtomically(
        incomingDir: URL,
        targetDir: URL,
        parentDir: URL,
        bundleIdentifier: String,
        allowRenameSwap: Bool = true
    ) throws {
        guard isValidatedBackupTarget(targetDir, bundleIdentifier: bundleIdentifier),
              isSubpath(incomingDir, of: parentDir),
              canonicalFilePath(targetDir.deletingLastPathComponent()) == canonicalFilePath(parentDir) else {
            throw PlayCoverError.playToolsError(
                "Refusing AppBackups replacement outside expected container for \(bundleIdentifier)"
            )
        }
        let fm = FileManager.default
        switch probePathPresence(at: targetDir) {
        case .present:
            if allowRenameSwap && Darwin.renamex_np(incomingDir.path, targetDir.path, UInt32(RENAME_SWAP)) == 0 {
                try? fm.removeItem(at: incomingDir)
                return
            }
            let previousDir = parentDir.appendingPathComponent(
                ".\(targetDir.lastPathComponent).previous-\(UUID().uuidString)"
            )
            try fm.moveItem(at: targetDir, to: previousDir)
            do {
                try fm.moveItem(at: incomingDir, to: targetDir)
                try? fm.removeItem(at: previousDir)
            } catch {
                if Darwin.rename(previousDir.path, targetDir.path) != 0 {
                    do {
                        try fm.moveItem(at: previousDir, to: targetDir)
                    } catch let restoreError {
                        PlayCoverDiagnostics.log(
                            "Critical: failed to restore previous AppBackups for \(bundleIdentifier) " +
                                "from \(previousDir.path) to \(targetDir.path): \(restoreError)",
                            isError: true
                        )
                    }
                }
                throw error
            }
        case .absent:
            try fm.moveItem(at: incomingDir, to: targetDir)
        case .queryFailed(let err):
            let msg = String(cString: strerror(err))
            throw PlayCoverError.playToolsError(
                "Failed to query target AppBackups for \(bundleIdentifier): \(msg) (errno=\(err))"
            )
        }
    }

    @discardableResult
    public static func commitAppBackups(
        _ stagingResult: AppBackupStagingResult,
        to targetDir: URL,
        bundleIdentifier: String,
        manifest: AppBackupManifest?
    ) throws -> AppBackupCommitOutcome {
        guard isValidatedBackupTarget(targetDir, bundleIdentifier: bundleIdentifier) else {
            throw PlayCoverError.playToolsError(
                "Refusing to commit AppBackups outside expected container for \(bundleIdentifier)"
            )
        }
        let fm = FileManager.default

        let stagingDir: URL
        switch stagingResult {
        case .staged(let url):
            stagingDir = url
        case .noneApplicable:
            guard invalidateAppBackups(at: targetDir, bundleIdentifier: bundleIdentifier) else {
                throw PlayCoverError.playToolsError(
                    "Failed to evict stale AppBackups for \(bundleIdentifier)"
                )
            }
            return .noneApplicable
        case .failed:
            guard invalidateAppBackups(at: targetDir, bundleIdentifier: bundleIdentifier) else {
                throw PlayCoverError.playToolsError(
                    "Failed to evict stale AppBackups for \(bundleIdentifier)"
                )
            }
            return .degradedWithoutBackups
        }

        guard let manifest,
              !manifest.installGeneration.isEmpty,
              manifest.bundleIdentifier == bundleIdentifier,
              fm.fileExists(atPath: stagingDir.path),
              let entries = try? fm.contentsOfDirectory(atPath: stagingDir.path),
              !entries.isEmpty else {
            if fm.fileExists(atPath: stagingDir.path) {
                try? fm.removeItem(at: stagingDir)
            }
            guard invalidateAppBackups(at: targetDir, bundleIdentifier: bundleIdentifier) else {
                throw PlayCoverError.playToolsError(
                    "Failed to evict unbound AppBackups for \(bundleIdentifier)"
                )
            }
            return .degradedWithoutBackups
        }

        let parentDir = targetDir.deletingLastPathComponent()
        let incomingDir = parentDir.appendingPathComponent(
            ".\(targetDir.lastPathComponent).staging-\(UUID().uuidString)"
        )

        do {
            try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try fm.moveItem(at: stagingDir, to: incomingDir)

            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            let manifestData = try encoder.encode(manifest)
            let manifestURL = incomingDir.appendingPathComponent(AppBackupManifest.backupManifestFileName)
            try manifestData.write(to: manifestURL, options: .atomic)

            try replaceBackupDirectoryAtomically(
                incomingDir: incomingDir,
                targetDir: targetDir,
                parentDir: parentDir,
                bundleIdentifier: bundleIdentifier
            )
            var committedStat = stat()
            guard Darwin.lstat(targetDir.path, &committedStat) == 0,
                  Darwin.lstat(
                      targetDir.appendingPathComponent(AppBackupManifest.backupManifestFileName).path,
                      &committedStat
                  ) == 0 else {
                throw PlayCoverError.playToolsError(
                    "Committed AppBackups verification failed at \(targetDir.path)"
                )
            }
            return .committed
        } catch {
            var incomingStat = stat()
            if Darwin.lstat(incomingDir.path, &incomingStat) == 0 {
                try? fm.removeItem(at: incomingDir)
            }
            PlayCoverDiagnostics.log(
                "Failed to commit AppBackups for \(bundleIdentifier): \(error)",
                isError: true
            )
            throw PlayCoverError.playToolsError(
                "Failed to commit AppBackups for \(bundleIdentifier): \(error.localizedDescription)"
            )
        }
    }
}
