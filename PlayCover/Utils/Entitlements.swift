//
//  Entitlements.swift
//  PlayCover
//

import Darwin
import Foundation
import Security
import Synchronization
import Yams

nonisolated class Entitlements {
    static var critical: [String] {
        EntitlementsComposer.criticalDenyPaths
    }

    private struct RulesCacheKey: Equatable, Sendable {
        let path: String
        let mtimeSec: Int
        let mtimeNSec: Int
        let fileSize: UInt64
    }

    private struct CompositeRulesCacheKey: Equatable, Sendable {
        let bundled: RulesCacheKey?
        let custom: RulesCacheKey?
    }

    private struct CachedDefaultRules: Sendable {
        var key: CompositeRulesCacheKey?
        var rules: PlayRules?
    }

    private static let cachedDefaultRulesState = Mutex(CachedDefaultRules())

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
        EntitlementsComposer.signingInfo(for: url)
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

    private static func declaredApplicationGroups(from entitlementsURL: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: entitlementsURL.path),
              let dict = try? [String: Any].read(entitlementsURL) else {
            return []
        }
        return EntitlementsComposer.declaredApplicationGroups(from: dict)
    }

    static func composeEntitlements(_ app: PlayApp, targetBundleURL: URL? = nil) throws -> [String: Any] {
        let bundleID = app.info.bundleIdentifier
        var rules = try getDefaultRules()
        if let bundleRules = try getBundleRules(bundleID) {
            rules.allow = EntitlementsComposer.mergeRuleLists(rules.allow, bundleRules.allow)
            rules.bypass = EntitlementsComposer.mergeRuleLists(rules.bypass, bundleRules.bypass)
            if !(bundleRules.blocklist?.isEmpty ?? true) {
                rules.blocklist = bundleRules.blocklist
            }
            if !(bundleRules.greenlist?.isEmpty ?? true) {
                rules.greenlist = bundleRules.greenlist
            }
        }

        let isPlaySignActive = SystemConfig.isPlaySignActive
        let specificEntitlements = isPlaySignActive ? (try [String: Any].read(app.entitlements)) : nil
        let declaredGroups = declaredApplicationGroups(from: app.entitlements)

        return EntitlementsComposer.compose(
            bundleID: bundleID,
            bundleURL: app.url,
            targetBundleURL: targetBundleURL,
            settings: app.settings.settings,
            rules: rules,
            isPlaySignActive: isPlaySignActive,
            specificEntitlements: specificEntitlements,
            declaredGroups: declaredGroups
        )
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
        let cached = cachedDefaultRulesState.withLock { state -> PlayRules? in
            (state.key == compositeKey) ? state.rules : nil
        }
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
                    merged.allow = EntitlementsComposer.mergeRuleLists(merged.allow, custom.allow)
                    merged.bypass = EntitlementsComposer.mergeRuleLists(merged.bypass, custom.bypass)
                    merged.greenlist = EntitlementsComposer.mergeRuleLists(merged.greenlist, custom.greenlist)
                    merged.blocklist = EntitlementsComposer.mergeRuleLists(merged.blocklist, custom.blocklist)
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

        cachedDefaultRulesState.withLock { state in
            state.key = compositeKey
            state.rules = merged
        }
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

nonisolated public func == <K, L: Hashable, R: Hashable>(lhs: [K: L], rhs: [K: R]) -> Bool {
    (lhs as NSDictionary).isEqual(to: rhs)
}

nonisolated extension Dictionary {
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
