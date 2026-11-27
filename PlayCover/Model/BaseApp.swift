//
//  BaseApp.swift
//  PlayCover
//

import Foundation

nonisolated public class BaseApp {
    /// All mach-o binaries within the app, including the executable itself.
    /// Call resolveValidMachOs to ensure a non-nil value.
    public var validMachOs: [URL]?

    public let info: AppInfo
    public var url: URL

    public var executable: URL {
        url.appendingEscapedPathComponent(info.executableName)
    }

    public var entitlements: URL {
        Entitlements.playCoverEntitlementsDir
            .appendingPathComponent(info.bundleIdentifier)
            .appendingPathExtension("plist")
    }

    public static var appBackupsRoot: URL {
        PlayTools.playCoverContainer.appendingPathComponent("AppBackups")
    }

    public static var svcPatchesRoot: URL {
        PlayTools.playCoverContainer.appendingPathComponent("SVCPatches")
    }

    public static func svcPatchManifestURL(forBundleIdentifier bundleIdentifier: String) -> URL {
        svcPatchesRoot.appendingPathComponent("\(bundleIdentifier).json")
    }

    public var appBackupsDir: URL {
        Self.appBackupsRoot.appendingPathComponent(info.bundleIdentifier)
    }

    public var svcPatchManifestURL: URL {
        Self.svcPatchManifestURL(forBundleIdentifier: info.bundleIdentifier)
    }

    public var provisioningProfileBackup: URL {
        appBackupsDir.appendingPathComponent("embedded.mobileprovision")
    }

    public var originalExecutableBackup: URL {
        appBackupsDir.appendingPathComponent("executable")
    }

    public var infoPlistBackup: URL {
        appBackupsDir.appendingPathComponent("Info.plist")
    }

    init(appUrl: URL) {
        url = appUrl
        info = AppInfo(contentsOf: url.appendingPathComponent("Info")
                                      .appendingPathExtension("plist"))
    }

    init(appUrl: URL, info: AppInfo) {
        self.url = appUrl
        self.info = info
    }
}
