//
//  UpdateScheme.swift
//  PlayCover
//
//  Created by TheMoonThatRises on 7/6/24.
//

nonisolated class UpdateScheme {
    public static let versionsFile = PlayTools.playCoverContainer.appendingPathComponent("VERSION")
    public static var currentVersion: String {
        if let raw = try? String(contentsOf: UpdateScheme.versionsFile, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return inferVersionWithoutMarker(
            containerRoot: PlayTools.playCoverContainer,
            keymappingRoot: Keymapping.keymappingDir
        )
    }

    static func inferVersionWithoutMarker(containerRoot: URL, keymappingRoot: URL) -> String {
        let fm = FileManager.default
        if let rootItems = try? fm.contentsOfDirectory(
            at: containerRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let hasRootV2Apps = rootItems.contains { item in
                item.pathExtension == "app"
                    && fm.fileExists(atPath: item.appendingPathComponent("Info.plist").path)
            }
            if hasRootV2Apps {
                return "2"
            }
        }
        if let kmItems = try? fm.contentsOfDirectory(
            at: keymappingRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            let hasFlatV3Keymaps = kmItems.contains { item in
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return !isDir && item.pathExtension == "plist"
            }
            if hasFlatV3Keymaps {
                return "3"
            }
        }
        return "3.1"
    }
    struct Version: Hashable {
        let components: [Int]
        init(_ string: String) {
            var comps = string.split(separator: ".").compactMap { Int($0) }
            while comps.last == 0 && comps.count > 1 {
                comps.removeLast()
            }
            self.components = comps
        }
    }

    struct Migration: Sendable {
        let fromVersion: String
        let toVersion: String
        let action: @Sendable () throws -> Void
    }

    private static let migrations: [Version: Migration] = [
        Version("2"): Migration(
            fromVersion: "2",
            toVersion: "3",
            action: updateFromV2ToV3
        ),
        Version("3"): Migration(
            fromVersion: "3",
            toVersion: "3.1",
            action: updateFromV3ToV3p1
        )
    ]

    public static func checkForUpdate() {
        guard !ProcessInfo.isRunningUnitTests else { return }
        let maxSteps = migrations.count
        var steps = 0

        while steps < maxSteps {
            let currentVer = Version(currentVersion.trimmingCharacters(in: .whitespacesAndNewlines))

            guard let migration = migrations[currentVer] else {
                print("No more migrations needed")
                return
            }

            do {
                print("Migrating \(migration.fromVersion) → \(migration.toVersion)")
                try migration.action()
            } catch {
                PlayCoverDiagnostics.reportError(error)
                return
            }

            steps += 1
        }
    }

    private static func updateFromV2ToV3() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: AppsVM.appDirectory, withIntermediateDirectories: true)

        let directoryContents = try fm.contentsOfDirectory(
            at: PlayTools.playCoverContainer,
            includingPropertiesForKeys: nil,
            options: []
        )

        let subdirs = directoryContents.filter { $0.hasDirectoryPath }

        for sub in subdirs {
            if sub.pathExtension == "app" &&
                fm.fileExists(atPath: sub.appendingPathComponent("Info").appendingPathExtension("plist").path) {
                let app = PlayApp(appUrl: sub)
                let bundleID = app.info.bundleIdentifier
                guard Shell.isValidBundleIdentifier(bundleID) else {
                    continue
                }
                let targetURL = AppsVM.appDirectory
                    .appendingPathComponent(bundleID)
                    .appendingPathExtension("app")
                app.removeAlias()
                // Idempotent/merge-safe: skip if already migrated rather than aborting mid-migration.
                if fm.fileExists(atPath: targetURL.path) {
                    continue
                }
                try fm.moveItem(at: app.url, to: targetURL)
            }
        }

        try "3".write(to: UpdateScheme.versionsFile, atomically: true, encoding: .utf8)
    }

    private static func updateFromV3ToV3p1() throws {
        let fm = FileManager.default
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml

        let directoryContents = try fm.contentsOfDirectory(
            at: Keymapping.keymappingDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        for file in directoryContents where file.pathExtension == "plist" {
            let isDir = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir { continue }
            let bundleId = file.deletingPathExtension().lastPathComponent
            guard Shell.isValidBundleIdentifier(bundleId) else {
                continue
            }
            let appKeymapDir = Keymapping.keymappingDir.appendingPathComponent(bundleId, isDirectory: true)
            let keymapFileURL = appKeymapDir
                .appendingPathComponent("default")
                .appendingPathExtension("plist")

            try fm.createDirectory(at: appKeymapDir, withIntermediateDirectories: true)

            if !fm.fileExists(atPath: keymapFileURL.path) {
                try fm.moveItem(at: file, to: keymapFileURL)
            } else {
                try? fm.removeItem(at: file)
            }

            let configURL = appKeymapDir.appendingPathComponent(".config").appendingPathExtension("plist")
            if !fm.fileExists(atPath: configURL.path) {
                do {
                    let data = try encoder.encode(KeymapConfig(defaultKm: keymapFileURL, keymapOrder: [keymapFileURL]))
                    try data.write(to: configURL, options: [.atomic])
                } catch {
                    print(error)
                }
            }
        }

        try "3.1".write(to: UpdateScheme.versionsFile, atomically: true, encoding: .utf8)
    }

}
