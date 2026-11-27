//
//  LaunchEnvironmentPatcher.swift
//  PlayCoverInstaller
//

import Foundation

public enum LaunchEnvironmentPatcher {
    public static let introspectionLibraryPath = "/usr/lib/system/introspection"
    public static let iosFrameworksLibraryPath = "/System/iOSSupport/System/Library/Frameworks"

    public struct StrictLaunchEnvPatchResult: Equatable, Sendable {
        public let env: [String: String]
        public let changed: Bool
        public let discoveredIntrospection: Bool
        public let discoveredIosFrameworks: Bool

        public init(
            env: [String: String],
            changed: Bool,
            discoveredIntrospection: Bool,
            discoveredIosFrameworks: Bool
        ) {
            self.env = env
            self.changed = changed
            self.discoveredIntrospection = discoveredIntrospection
            self.discoveredIosFrameworks = discoveredIosFrameworks
        }
    }

    public static func updatedLSEnvironment(
        _ env: [String: String],
        including entry: String,
        enabled: Bool
    ) -> (env: [String: String], changed: Bool) {
        var nextEnv = env
        var entries = (nextEnv["DYLD_LIBRARY_PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        let contains = entries.contains(entry)
        if enabled {
            guard !contains else { return (env, false) }
            entries.append(entry)
        } else {
            guard contains else { return (env, false) }
            entries.removeAll { $0 == entry }
        }
        if entries.isEmpty {
            nextEnv.removeValue(forKey: "DYLD_LIBRARY_PATH")
        } else {
            nextEnv["DYLD_LIBRARY_PATH"] = entries.joined(separator: ":")
        }
        return (nextEnv, true)
    }

    public static func containsLibraryPath(_ path: String, in env: [String: String]) -> Bool {
        let entries = (env["DYLD_LIBRARY_PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
        return entries.contains(path)
    }

    public static func sanitizedLSEnvironment(_ env: [String: String]) -> [String: String] {
        var filtered = env
        if let dyldPath = filtered["DYLD_LIBRARY_PATH"], dyldPath.isEmpty {
            filtered.removeValue(forKey: "DYLD_LIBRARY_PATH")
        }
        return filtered
    }

    public static func stripForStrictLaunch(env: [String: String]) -> StrictLaunchEnvPatchResult {
        var nextEnv = env
        var changed = false

        let introResult = updatedLSEnvironment(
            nextEnv,
            including: introspectionLibraryPath,
            enabled: false
        )
        if introResult.changed {
            nextEnv = introResult.env
            changed = true
        }

        let iosFwResult = updatedLSEnvironment(
            nextEnv,
            including: iosFrameworksLibraryPath,
            enabled: false
        )
        if iosFwResult.changed {
            nextEnv = iosFwResult.env
            changed = true
        }

        return StrictLaunchEnvPatchResult(
            env: nextEnv,
            changed: changed,
            discoveredIntrospection: introResult.changed,
            discoveredIosFrameworks: iosFwResult.changed
        )
    }

    public static func restoreForNonStrictLaunch(
        env: [String: String],
        storedHasIntrospection: Bool,
        storedHasIosFrameworks: Bool
    ) -> (env: [String: String], changed: Bool) {
        var nextEnv = env
        var changed = false

        if storedHasIntrospection {
            let introResult = updatedLSEnvironment(
                nextEnv,
                including: introspectionLibraryPath,
                enabled: true
            )
            if introResult.changed {
                nextEnv = introResult.env
                changed = true
            }
        }

        if storedHasIosFrameworks {
            let iosFwResult = updatedLSEnvironment(
                nextEnv,
                including: iosFrameworksLibraryPath,
                enabled: true
            )
            if iosFwResult.changed {
                nextEnv = iosFwResult.env
                changed = true
            }
        }

        return (nextEnv, changed)
    }
}
