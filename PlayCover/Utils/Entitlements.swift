//
//  Entitlements.swift
//  PlayCover
//

import Darwin
import Foundation
import Security
import Yams

class Entitlements {
    static var critical = [
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

    private struct RulesCacheKey: Equatable {
        let path: String
        let mtimeSec: Int
        let mtimeNSec: Int
        let fileSize: UInt64
    }

    private struct CompositeRulesCacheKey: Equatable {
        let bundled: RulesCacheKey?
        let custom: RulesCacheKey?
    }

    private static let rulesCacheLock = NSLock()
    private static var cachedDefaultRulesKey: CompositeRulesCacheKey?
    private static var cachedDefaultRules: PlayRules?

    private static func mergeRuleLists(_ base: [String]?, _ extra: [String]?) -> [String]? {
        guard let extra, !extra.isEmpty else { return base }
        guard let base, !base.isEmpty else { return extra }
        var seen = Set(base)
        var merged = base
        for item in extra where seen.insert(item).inserted {
            merged.append(item)
        }
        return merged
    }

    static var playCoverEntitlementsDir: URL {
        let entFolder = PlayTools.playCoverContainer.appendingPathComponent("Entitlements")
        if !FileManager.default.fileExists(atPath: entFolder.path) {
            do {
                try FileManager.default.createDirectory(at: entFolder,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
        }
        return entFolder
    }

    static func signingInfo(for url: URL) -> (isSigned: Bool, infoPlistSealed: Bool)? {
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

    static func dumpEntitlements(exec: URL) throws -> [String: Any] {
        var staticCode: SecStaticCode?
        if SecStaticCodeCreateWithPath(exec as CFURL, [], &staticCode) == errSecSuccess,
           let code = staticCode {
            var infoCF: CFDictionary?
            let status = SecCodeCopySigningInformation(
                code,
                SecCSFlags(rawValue: kSecCSSigningInformation),
                &infoCF
            )
            if status == errSecCSUnsigned {
                return [:]
            }
            if status == errSecSuccess, let info = infoCF as? [String: Any] {
                return info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
            }
        }
        let result = try [String: Any].read(try copyEntitlements(exec: exec))
        return result ?? [:]
    }

    static func areEntitlementsValid(app: PlayApp) throws -> Bool {
        guard let old = try dumpEntitlements(exec: app.executable) as? [String: AnyHashable] else { return false }
        guard let new = try composeEntitlements(app) as? [String: AnyHashable] else { return false }
        return (new as NSDictionary).isEqual(to: old)
    }

    private static func setBaseEntitlements(_ base: inout [String: Any]) {
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

    private static func declaredApplicationGroups(from entitlementsURL: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: entitlementsURL.path),
              let dict = try? [String: Any].read(entitlementsURL),
              let raw = dict["com.apple.security.application-groups"] else {
            return []
        }
        if let arr = raw as? [String] {
            return arr
        }
        if let single = raw as? String {
            return [single]
        }
        return []
    }

    private static func escapeSBPLRegex(_ raw: String) -> String? {
        guard !raw.contains("\0"), !raw.contains("\n"), !raw.contains("\r") else {
            return nil
        }
        let escapedRegex = NSRegularExpression.escapedPattern(for: raw)
        return escapeSBPLPath(escapedRegex)
    }

    private static func discordIPCSBPLRules() -> [String] {
        var candidates = Set<String>()
        let rawTmp = FileManager.default.temporaryDirectory.path
        for raw in [rawTmp, URL(fileURLWithPath: rawTmp).resolvingSymlinksInPath().path] {
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

    private static func normalizedSelfBundlePaths(
        for app: PlayApp,
        targetBundleURL: URL? = nil
    ) -> (ordered: [String], lookup: Set<String>) {
        var ordered = [String]()
        var lookup = Set<String>()
        let effectiveURL = targetBundleURL ?? app.url
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

    static func composeEntitlements(_ app: PlayApp, targetBundleURL: URL? = nil) throws -> [String: Any] {
        var base = [String: Any]()
        let bundleID = app.info.bundleIdentifier
        if !bundleID.elementsEqual("com.devsisters.ck") {
            base["com.apple.security.app-sandbox"] = true
        }

        setBaseEntitlements(&base)

        if SystemConfig.isPlaySignActive {
            base["com.apple.private.tcc.allow"] = TCC.split(whereSeparator: \.isNewline).map(String.init)
            if let specific = try [String: Any].read(app.entitlements) {
                for key in specific.keys {
                    base[key] = specific[key]
                }
            }
        }

        var sandboxProfile = [String]()

        var rules = try getDefaultRules()
        if let bundleRules = try getBundleRules(bundleID) {
            rules.allow = mergeRuleLists(rules.allow, bundleRules.allow)
            rules.bypass = mergeRuleLists(rules.bypass, bundleRules.bypass)
            if !(bundleRules.blocklist?.isEmpty ?? true) {
                rules.blocklist = bundleRules.blocklist
            }
            if !(bundleRules.greenlist?.isEmpty ?? true) {
                rules.greenlist = bundleRules.greenlist
            }
        }

        sandboxProfile.append(contentsOf: PlayRules.buildRules(rules: rules.allow ?? [], bundleID: bundleID))
        if app.settings.settings.discordActivity.enable {
            sandboxProfile.append(contentsOf: discordIPCSBPLRules())
        }

        let escapedGroups = declaredApplicationGroups(from: app.entitlements).compactMap { groupID -> String? in
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

        var deniedPaths = PlayRules.buildRules(rules: Entitlements.critical, bundleID: bundleID)

        if app.settings.settings.bypass {
            sandboxProfile.append("(deny process-fork)")
            sandboxProfile.append(
                "(deny file-read-data (with errno ENOENT) (with no-report) " +
                "(literal \"/Users\") (literal \"/System/Volumes/Data/Users\"))"
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

        let selfBundle = normalizedSelfBundlePaths(for: app, targetBundleURL: targetBundleURL)
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

    private static let protectedAncestorRoots: Set<String> = [
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

    private static func escapeSBPLPath(_ rawPath: String) -> String? {
        if rawPath.contains("\0") || rawPath.contains("\n") || rawPath.contains("\r") {
            return nil
        }
        return rawPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func expandSandboxDenyAliases(_ path: String) -> [String] {
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

    private static func buildDenySBPLRules(from rawPaths: [String]) -> [String] {
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

    private static func copyEntitlements(exec: URL) throws -> String {
        var entitlements = try excludeEntitlements(exec: exec)
        if !entitlements.contains("DOCTYPE plist PUBLIC") {
            entitlements = Entitlements.entitlements_template
        }
        return entitlements
    }

    private static func excludeEntitlements(exec: URL) throws -> String {
        let from = try PlayTools.fetchEntitlements(exec)
        if let range: Range<String.Index> = from.range(of: "<?xml") {
            return String(from[range.lowerBound...])
        } else {
            return Entitlements.entitlements_template
        }
    }

    private static let TCC =
        """
        kTCCService
        kTCCServiceAll
        kTCCServiceAddressBook
        kTCCServiceCalendar
        kTCCServiceReminders
        kTCCServiceLiverpool
        kTCCServiceUbiquity
        kTCCServiceShareKit
        kTCCServicePhotos
        kTCCServicePhotosAdd
        kTCCServiceMicrophone
        kTCCServiceCamera
        kTCCServiceMediaLibrary
        kTCCServiceSiri
        kTCCServiceAppleEvents
        kTCCServiceAccessibility
        kTCCServicePostEvent
        kTCCServiceLocation
        kTCCServiceSystemPolicyAllFiles
        kTCCServiceSystemPolicySysAdminFiles
        kTCCServiceSystemPolicyDeveloperFile
        kTCCServiceSystemPolicyDocumentsFolder
        """

    private static func cacheKey(for url: URL) -> RulesCacheKey? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return RulesCacheKey(
            path: url.path,
            mtimeSec: Int(st.st_mtimespec.tv_sec),
            mtimeNSec: Int(st.st_mtimespec.tv_nsec),
            fileSize: UInt64(st.st_size)
        )
    }

    private static func decodeRulesFile(at url: URL) throws -> PlayRules {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try YAMLDecoder().decode(PlayRules.self, from: data)
    }

    public static func getDefaultRules() throws -> PlayRules {
        let bundledURL = Bundle.main.path(forResource: "default", ofType: "yaml")
            .map { URL(fileURLWithPath: $0) }
        let customURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("PlayCover")
            .appendingPathComponent("default")
            .appendingPathExtension("yaml")
        let customExists = FileManager.default.fileExists(atPath: customURL.path)

        if bundledURL == nil && !customExists {
            throw PlayCoverError.entitlementsError("Default config not found: default.yaml")
        }

        let compositeKey = CompositeRulesCacheKey(
            bundled: bundledURL.flatMap { cacheKey(for: $0) },
            custom: customExists ? cacheKey(for: customURL) : nil
        )
        rulesCacheLock.lock()
        let cached = (cachedDefaultRulesKey == compositeKey) ? cachedDefaultRules : nil
        rulesCacheLock.unlock()
        if let cached {
            return cached
        }

        var merged: PlayRules
        if let bundledURL {
            do {
                merged = try decodeRulesFile(at: bundledURL)
            } catch {
                print("failed to get default rules at \(bundledURL): \(error)")
                throw PlayCoverError.entitlementsError("failed to get default rules at \(bundledURL): \(error)")
            }
            if customExists {
                do {
                    let custom = try decodeRulesFile(at: customURL)
                    merged.allow = mergeRuleLists(merged.allow, custom.allow)
                    merged.bypass = mergeRuleLists(merged.bypass, custom.bypass)
                    merged.greenlist = mergeRuleLists(merged.greenlist, custom.greenlist)
                    merged.blocklist = mergeRuleLists(merged.blocklist, custom.blocklist)
                } catch {
                    print("failed to get default rules at \(customURL): \(error)")
                    throw PlayCoverError.entitlementsError("failed to get default rules at \(customURL): \(error)")
                }
            }
        } else {
            do {
                merged = try decodeRulesFile(at: customURL)
            } catch {
                print("failed to get default rules at \(customURL): \(error)")
                throw PlayCoverError.entitlementsError("failed to get default rules at \(customURL): \(error)")
            }
        }

        rulesCacheLock.lock()
        cachedDefaultRulesKey = compositeKey
        cachedDefaultRules = merged
        rulesCacheLock.unlock()
        return merged
    }

    public static func getBundleRules(_ bundleID: String) throws -> PlayRules? {
        var path: URL
        let yamlURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config")
            .appendingPathComponent("PlayCover")
            .appendingPathComponent(bundleID)
            .appendingPathExtension("yaml")
        if FileManager.default.fileExists(atPath: yamlURL.path) {
            path = yamlURL
        } else if let bpath = Bundle.main.path(forResource: bundleID, ofType: "yaml") {
            path = URL(fileURLWithPath: bpath)
        } else {
            return nil
        }

        do {
            let data = try Data(contentsOf: path, options: .mappedIfSafe)
            let decoder = YAMLDecoder()
            let decoded: PlayRules = try decoder.decode(PlayRules.self, from: data)
            return decoded
        } catch {
            print("failed to get bundle rules at \(path): \(error)")
            throw error
        }
    }

    public static func isAppRequireUnsandbox(_ app: BaseApp) -> Bool {
        unsandboxedApps.contains(app.info.bundleIdentifier)
    }

    private static let unsandboxedApps = ["com.devsisters.ck"]

    static let entitlements_template = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        </dict>
        </plist>
        """
}

public func == <K, L: Hashable, R: Hashable>(lhs: [K: L], rhs: [K: R]) -> Bool {
    (lhs as NSDictionary).isEqual(to: rhs)
}

extension Dictionary {
    func store(_ toUrl: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: self, format: .xml, options: 0)
        try data.write(to: toUrl, options: .atomic)
    }

    static func read(_ from: URL) throws -> Dictionary? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        if let data = FileManager.default.contents(atPath: from.path) {
            return try PropertyListSerialization.propertyList(
                from: data,
                options: .mutableContainersAndLeaves,
                format: &format) as? Dictionary
        }
        return nil
    }

    static func read(_ from: String) throws -> Dictionary? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        if let data = from.data(using: .utf8) {
            return try PropertyListSerialization.propertyList(
                from: data,
                options: .mutableContainersAndLeaves,
                format: &format) as? Dictionary
        }
        return nil
    }
}
