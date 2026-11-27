//
//  EntitlementsComposer.swift
//  PlayCoverSandbox
//

import Foundation
import PlayCoverCore
import Security

public enum EntitlementsComposer {
    public static let criticalDenyPaths: [String] = [
        "/Developer",
        "/Library/Application Support/MacOver",
        "/Library/Application Support/PlayCover",
        "/Library/Frameworks/PlayTools.framework",
        "/bin/bash",
        "/usr/sbin/sshd",
        "/usr/libexec/ssh-keysign",
        "/bin/sh",
        "/etc/ssh/sshd_config",
        "/usr/libexec/sftp-server",
        "/usr/bin/ssh",
        "/Applications/MacOver.app",
        "/System/Volumes/Data/Applications/MacOver.app",
        "/Applications/PlayCover.app",
        "/System/Volumes/Data/Applications/PlayCover.app",
        "${HomeDirectory}/Library/Application Support/MacOver",
        "${HomeDirectory}/Library/Preferences/app.makedie.MacOver.plist",
        "${HomeDirectory}/Library/Containers/app.makedie.MacOver/CACHE",
        "${HomeDirectory}/Library/Containers/app.makedie.MacOver/VERSION",
        "${HomeDirectory}/Library/Containers/app.makedie.MacOver/Sources.plist",
        "${HomeDirectory}/Library/Application Support/PlayCover",
        "${HomeDirectory}/Library/Frameworks/PlayTools.framework",
        "${HomeDirectory}/Library/Preferences/io.playcover.PlayCover.plist",
        "${HomeDirectory}/Library/Containers/io.playcover.PlayCover/CACHE",
        "${HomeDirectory}/Library/Containers/io.playcover.PlayCover/VERSION",
        "${HomeDirectory}/Library/Containers/io.playcover.PlayCover/Sources.plist"
    ]

    public static let tccServices: [String] = [
        "kTCCService",
        "kTCCServiceAll",
        "kTCCServiceAddressBook",
        "kTCCServiceCalendar",
        "kTCCServiceReminders",
        "kTCCServiceLiverpool",
        "kTCCServiceUbiquity",
        "kTCCServiceShareKit",
        "kTCCServicePhotos",
        "kTCCServicePhotosAdd",
        "kTCCServiceMicrophone",
        "kTCCServiceCamera",
        "kTCCServiceMediaLibrary",
        "kTCCServiceSiri",
        "kTCCServiceAppleEvents",
        "kTCCServiceAccessibility",
        "kTCCServicePostEvent",
        "kTCCServiceLocation",
        "kTCCServiceSystemPolicyAllFiles",
        "kTCCServiceSystemPolicySysAdminFiles",
        "kTCCServiceSystemPolicyDeveloperFile",
        "kTCCServiceSystemPolicyDocumentsFolder"
    ]

    public static let protectedAncestorRoots: Set<String> = [
        "/",
        "/System",
        "/System/Volumes",
        "/System/Volumes/Data",
        "/System/Volumes/Data/Users",
        "/System/Volumes/Data/Library",
        "/private",
        "/Library",
        "/Users",
        "/usr",
        "/bin",
        "/sbin"
    ]

    public static func mergeRuleLists(_ base: [String]?, _ extra: [String]?) -> [String]? {
        guard let extra, !extra.isEmpty else { return base }
        guard let base, !base.isEmpty else { return extra }
        var seen = Set(base)
        var merged = base
        for item in extra where seen.insert(item).inserted {
            merged.append(item)
        }
        return merged
    }

    public static func setBaseEntitlements(_ base: inout [String: Any]) {
        base["com.apple.security.assets.movies.read-write"] = true
        base["com.apple.security.assets.music.read-write"] = true
        base["com.apple.security.assets.pictures.read-write"] = true
        base["com.apple.security.device.audio-input"] = true
        base["com.apple.security.device.bluetooth"] = true
        base["com.apple.security.device.camera"] = true
        base["com.apple.security.device.microphone"] = true
        base["com.apple.security.files.downloads.read-write"] = true
        base["com.apple.security.files.user-selected.read-write"] = true
        base["com.apple.security.network.client"] = true
        base["com.apple.security.network.server"] = true
        base["com.apple.security.personal-information.addressbook"] = true
        base["com.apple.security.personal-information.calendars"] = true
        base["com.apple.security.personal-information.location"] = true
        base["com.apple.security.print"] = true
    }

    public static func declaredApplicationGroups(from dict: [String: Any]) -> [String] {
        guard let raw = dict["com.apple.security.application-groups"] else {
            return []
        }
        if let arr = raw as? [String] {
            return arr
        }
        if let str = raw as? String {
            return [str]
        }
        if let arr = raw as? [Any] {
            return arr.compactMap { $0 as? String }
        }
        return []
    }

    public static func escapeSBPLPath(_ rawPath: String) -> String? {
        if rawPath.contains("\0") || rawPath.contains("\n") || rawPath.contains("\r") {
            return nil
        }
        return rawPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func escapeSBPLRegex(_ raw: String) -> String? {
        guard !raw.contains("\0"), !raw.contains("\n"), !raw.contains("\r") else {
            return nil
        }
        let escapedRegex = NSRegularExpression.escapedPattern(for: raw)
        return escapeSBPLPath(escapedRegex)
    }

    public static func expandSandboxDenyAliases(_ path: String) -> [String] {
        var variants = [path]
        let symlinkPairs: [(String, String)] = [
            ("/etc", "/private/etc"),
            ("/var", "/private/var"),
            ("/tmp", "/private/tmp")
        ]
        for (shortRoot, realRoot) in symlinkPairs {
            if path == shortRoot || path.hasPrefix(shortRoot + "/") {
                variants.append(realRoot + path.dropFirst(shortRoot.count))
            } else if path == realRoot || path.hasPrefix(realRoot + "/") {
                variants.append(shortRoot + path.dropFirst(realRoot.count))
            }
        }
        let firmlinkRoots = ["/Applications", "/Library", "/opt", "/usr/local", "/Users"]
        for root in firmlinkRoots {
            let dataPrefix = "/System/Volumes/Data" + root
            if path == root || path.hasPrefix(root + "/") {
                variants.append("/System/Volumes/Data" + path)
            } else if path == dataPrefix || path.hasPrefix(dataPrefix + "/") {
                variants.append(String(path.dropFirst("/System/Volumes/Data".count)))
            }
        }
        return variants
    }

    public static func buildDenySBPLRules(from rawPaths: [String]) -> [String] {
        var seen = Set<String>()
        var filters = [String]()

        for raw in rawPaths {
            var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.count > 1 && trimmed.hasSuffix("/") {
                trimmed.removeLast()
            }
            guard trimmed.hasPrefix("/"),
                  !protectedAncestorRoots.contains(trimmed),
                  escapeSBPLPath(trimmed) != nil else {
                continue
            }
            for candidate in expandSandboxDenyAliases(trimmed) where seen.insert(candidate).inserted {
                if !protectedAncestorRoots.contains(candidate),
                   let escaped = escapeSBPLPath(candidate) {
                    filters.append("    (subpath \"\(escaped)\")")
                }
            }
        }

        guard !filters.isEmpty else { return [] }
        let rule = "(deny file* file-read* file-test-existence process-exec (with errno ENOENT) (with no-report)\n"
            + filters.joined(separator: "\n") + ")"
        return [rule]
    }

    public static func discordIPCSBPLRules(
        temporaryDirectoryPath: String = FileManager.default.temporaryDirectory.path
    ) -> [String] {
        var candidates = Set<String>()
        let resolved = URL(fileURLWithPath: temporaryDirectoryPath).resolvingSymlinksInPath().path
        for raw in [temporaryDirectoryPath, resolved] {
            var clean = raw
            while clean.count > 1 && clean.hasSuffix("/") {
                clean.removeLast()
            }
            if !clean.isEmpty {
                candidates.insert(clean)
                if clean.hasPrefix("/var/") {
                    candidates.insert("/private" + clean)
                }
            }
        }
        candidates.insert("/private/tmp")

        let filters = candidates.sorted().compactMap { dir -> String? in
            guard let pattern = escapeSBPLRegex(dir) else { return nil }
            return "#\"^\(pattern)/discord-ipc-[0-9]+$\""
        }
        guard !filters.isEmpty else { return [] }
        let regexArgs = filters.map { "(regex \($0))" }.joined(separator: " ")
        return ["(allow network-outbound \(regexArgs))"]
    }

    public static func normalizedSelfBundlePaths(
        bundleURL: URL,
        targetBundleURL: URL? = nil
    ) -> (ordered: [String], lookup: Set<String>) {
        var ordered = [String]()
        var lookup = Set<String>()
        let effectiveURL = targetBundleURL ?? bundleURL
        let resolvedParentURL = effectiveURL
            .deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .appendingPathComponent(effectiveURL.lastPathComponent)
        let rawPaths = [
            effectiveURL.path,
            effectiveURL.resolvingSymlinksInPath().path,
            resolvedParentURL.path
        ]

        for rawPath in rawPaths {
            var clean = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            while clean.count > 1 && clean.hasSuffix("/") {
                clean.removeLast()
            }
            guard !clean.isEmpty else { continue }

            var forms = [clean]
            if clean.hasPrefix("/System/Volumes/Data/") {
                forms.append(String(clean.dropFirst("/System/Volumes/Data".count)))
            }
            for form in forms {
                for alias in expandSandboxDenyAliases(form) {
                    guard !protectedAncestorRoots.contains(alias),
                          alias != "/Applications",
                          alias != "/System/Volumes/Data/Applications" else {
                        continue
                    }
                    if lookup.insert(alias).inserted {
                        ordered.append(alias)
                    }
                }
            }
        }
        return (ordered, lookup)
    }

    public static func signingInfo(for url: URL) -> (isSigned: Bool, infoPlistSealed: Bool)? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            return nil
        }
        var infoCF: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF
        )
        if status == errSecCSUnsigned {
            return (false, false)
        }
        guard status == errSecSuccess, let info = infoCF as? [String: Any] else {
            return nil
        }
        let hasPlist = info[kSecCodeInfoPList as String] != nil
        return (true, hasPlist)
    }

    public static func compose(
        bundleID: String,
        bundleURL: URL,
        targetBundleURL: URL? = nil,
        settings: AppSettingsData,
        rules: PlayRules,
        isPlaySignActive: Bool,
        specificEntitlements: [String: Any]? = nil,
        declaredGroups: [String] = [],
        temporaryDirectoryPath: String = FileManager.default.temporaryDirectory.path
    ) -> [String: Any] {
        var base = [String: Any]()
        if !bundleID.elementsEqual("com.devsisters.ck") {
            base["com.apple.security.app-sandbox"] = true
        }

        setBaseEntitlements(&base)

        if isPlaySignActive {
            base["com.apple.private.tcc.allow"] = tccServices
            if let specific = specificEntitlements {
                for (key, value) in specific {
                    base[key] = value
                }
            }
        }

        var sandboxProfile = [String]()
        sandboxProfile.append(contentsOf: PlayRules.buildRules(rules: rules.allow ?? [], bundleID: bundleID))
        if settings.discordActivity.enable {
            sandboxProfile.append(contentsOf: discordIPCSBPLRules(temporaryDirectoryPath: temporaryDirectoryPath))
        }

        let escapedGroups = declaredGroups.compactMap { groupID -> String? in
            let trimmed = groupID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.contains("/"),
                  !trimmed.contains(".."),
                  let escapedGroup = escapeSBPLPath(trimmed) else {
                return nil
            }
            return escapedGroup
        }
        if !escapedGroups.isEmpty {
            let groupDirs = escapedGroups.map {
                "(subpath \"${HomeDirectory}/Library/Group Containers/\($0)\")"
            }
            let groupRule = "(allow file* file-read* file-read-metadata file-ioctl \(groupDirs.joined(separator: " ")))"
            sandboxProfile.append(contentsOf: PlayRules.buildRules(rules: [groupRule], bundleID: bundleID))
            for escapedGroup in escapedGroups {
                sandboxProfile.append(
                    "(allow user-preference-read user-preference-write (preference-domain \"\(escapedGroup)\"))"
                )
            }
        }

        var deniedPaths = PlayRules.buildRules(rules: criticalDenyPaths, bundleID: bundleID)

        if settings.effectiveBypass {
            sandboxProfile.append("(deny process-fork)")
            sandboxProfile.append(
                "(deny file-read-data (with errno ENOENT) (with no-report) " +
                "(literal \"/Users\") (literal \"/System/Volumes/Data/Users\"))"
            )
            sandboxProfile.append(
                "(deny file-read-data (with errno ENOENT) (with no-report) " +
                "(literal \"/Library/Application Support\") " +
                "(literal \"/System/Volumes/Data/Library/Application Support\"))"
            )
            sandboxProfile.append(
                "(deny sysctl-read (with errno ENOENT) (with no-report) " +
                "(sysctl-name \"kern.bootargs\" \"kern.wakereason\" \"kern.hibernatefile\" " +
                "\"kern.hv_support\" \"vm.swapusage\" \"hw.use_kernelmanagerd\" " +
                "\"security.mac.amfi.developer_mode_status\" " +
                "\"kern.proc.all\" \"kern.proc.uid\" " +
                "\"kern.proc.ruid\" \"kern.proc.tty\" \"kern.proc.pgrp\"))"
            )

            for file in PlayRules.buildRules(rules: rules.greenlist ?? [], bundleID: bundleID) {
                if let escapedFile = escapeSBPLPath(file) {
                    sandboxProfile.append(
                        """
                         (allow file* file-read* file-read-metadata file-ioctl (literal "\(escapedFile)"))
                        """)
                }
            }

            sandboxProfile.append(contentsOf: PlayRules.buildRules(rules: rules.bypass ?? [], bundleID: bundleID))
            deniedPaths.append(contentsOf: PlayRules.buildRules(rules: rules.blocklist ?? [], bundleID: bundleID))
        }

        let selfBundle = normalizedSelfBundlePaths(bundleURL: bundleURL, targetBundleURL: targetBundleURL)
        deniedPaths.removeAll { raw in
            var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            while trimmed.count > 1 && trimmed.hasSuffix("/") {
                trimmed.removeLast()
            }
            if selfBundle.lookup.contains(trimmed) {
                return true
            }
            if trimmed.hasPrefix("/System/Volumes/Data/") {
                let stripped = String(trimmed.dropFirst("/System/Volumes/Data".count))
                return selfBundle.lookup.contains(stripped)
            }
            return false
        }

        sandboxProfile.append(contentsOf: buildDenySBPLRules(from: deniedPaths))

        let selfBundleSubpaths = selfBundle.ordered.compactMap { path -> String? in
            guard let escaped = escapeSBPLPath(path) else { return nil }
            return "(subpath \"\(escaped)\")"
        }
        if !selfBundleSubpaths.isEmpty {
            let allowOps = "file-read* file-read-metadata file-test-existence file-ioctl " +
                "file-map-executable process-exec"
            sandboxProfile.append("(allow \(allowOps) \(selfBundleSubpaths.joined(separator: " ")))")
        }

        base["com.apple.security.temporary-exception.sbpl"] = sandboxProfile
        return base
    }
}
