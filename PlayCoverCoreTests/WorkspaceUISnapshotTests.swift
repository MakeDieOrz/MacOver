import AppKit
import Foundation
import PlayCoverCore
import PlayCoverUI
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import PlayCover

private struct DemoAppSpec {
    let slug, displayName, bundleID, version, symbol: String
    let startColor: NSColor
    let endColor: NSColor
}

private struct CaptureSpec {
    let name: String
    let windowTitle: String
    let size: NSSize
    let appearance: NSAppearance.Name
    let toolbarStyle: NSWindow.ToolbarStyle
    let delay: TimeInterval
}

private struct CaptureResult {
    let width, height, uniqueColors: Int
    let attachment: XCTAttachment?
}

private struct ConfigTarget {
    let name, windowTitle: String
    let app: PlayApp
    let pane: ConfigPane
}

private struct DemoContext {
    let deps: PlayCoverDependencies
    let navState: AppNavigationState
    let updaterVM: UpdaterViewModel
    let starlight, chrono, aether, retro: PlayApp

    var apps: [PlayApp] { [starlight, chrono, aether, retro] }
}

@MainActor
final class WorkspaceUISnapshotTests: XCTestCase {
    private static let suiteName = "app.makedie.MacOverCoreTests.WorkspaceUISnapshots"

    private var tempDir: URL?
    private var createdBundleIDs: [String] = []
    private var isolatedDefaults: UserDefaults?
    private var savedLayoutRaw: String?
    private var savedLegacyList: Any?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedLayoutRaw = UserDefaults.standard.string(forKey: "AppLibraryLayoutMode")
        savedLegacyList = UserDefaults.standard.object(forKey: "AppLibraryView")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacOverWorkspaceUISnapshots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        let defaults = UserDefaults(suiteName: Self.suiteName)
        defaults?.removePersistentDomain(forName: Self.suiteName)
        isolatedDefaults = defaults
    }

    override func tearDownWithError() throws {
        restoreUserDefaults()
        for bundleID in createdBundleIDs {
            let settingsURL = AppSettings.appSettingsDir
                .appendingPathComponent(bundleID).appendingPathExtension("plist")
            try? FileManager.default.removeItem(at: settingsURL)
            try? FileManager.default.removeItem(at: Keymapping.keymappingDir.appendingPathComponent(bundleID))
        }
        createdBundleIDs.removeAll()
        if let dir = tempDir { try? FileManager.default.removeItem(at: dir) }
        tempDir = nil
        isolatedDefaults?.removePersistentDomain(forName: Self.suiteName)
        isolatedDefaults = nil
        try super.tearDownWithError()
    }

    func testCaptureRealMacOS26UIScreenshots() throws {
        let context = try makeDemoContext()
        defer { context.apps.forEach { $0.settings.flush() } }
        captureLibraryScreens(context: context)
        captureConfigScreens(context: context)
        captureAuxiliaryScreens(context: context)
    }

    private func captureLibraryScreens(context: DemoContext) {
        context.navState.configTargetID = nil
        context.navState.sidebarDestination = .library
        context.navState.showInspector = true
        context.navState.libraryLayout = .grid
        context.navState.selectedAppID = context.starlight.id
        captureMainWindow("01_library_grid_light", "PlayCover — 应用库", .aqua, context, delay: 0.9)
        captureMainWindow("02_library_grid_dark", "PlayCover — 应用库", .darkAqua, context, delay: 0.7)
        context.navState.libraryLayout = .table
        context.navState.selectedAppID = context.aether.id
        captureMainWindow("03_library_table_light", "PlayCover — 应用库", .aqua, context, delay: 0.8)
    }

    private func captureConfigScreens(context: DemoContext) {
        context.navState.libraryLayout = .grid
        context.navState.showInspector = true
        let configs = [
            ConfigTarget(name: "04_config_overview_restart_banner", windowTitle: "Starlight Odyssey — 概览",
                         app: context.starlight, pane: .overview),
            ConfigTarget(name: "05_config_display_budget_over", windowTitle: "Aether Tactics — 显示与帧率",
                         app: context.aether, pane: .display),
            ConfigTarget(name: "06_config_device_legacy_warning", windowTitle: "Retro Runner — 机型与系统",
                         app: context.retro, pane: .device),
            ConfigTarget(name: "07_config_network_rules", windowTitle: "Starlight Odyssey — 网络规则",
                         app: context.starlight, pane: .network)
        ]
        for target in configs {
            context.navState.configTargetID = target.app.id
            context.navState.activeConfigPane = target.pane
            captureMainWindow(target.name, target.windowTitle, .aqua, context, delay: 0.8)
        }
    }

    private func captureAuxiliaryScreens(context: DemoContext) {
        captureWindow(
            SigningGuideView(isSigningSetupShown: .constant(true)),
            spec: CaptureSpec(
                name: "08_signing_guide_sheet", windowTitle: "签名与钥匙串模式",
                size: NSSize(width: 640, height: 540), appearance: .aqua, toolbarStyle: .unified, delay: 0.9
            )
        )
        context.deps.downloadVM.storeAppData = SourceAppsData(
            bundleID: context.starlight.info.bundleIdentifier,
            name: context.starlight.name, version: "1.0.0", itunesLookup: "", link: "", checksum: nil
        )
        context.deps.downloadVM.next(.downloading, 0.0, 0.7)
        context.deps.downloadVM.updateProgress(0.64)
        context.deps.installVM.inProgress = true
        context.deps.installVM.next(.playtools, 0.52, 0.72)
        let activityView = ActivityCenterView()
            .environmentObject(context.deps.installVM)
            .environmentObject(context.deps.downloadVM)
            .environmentObject(context.deps)
        captureWindow(
            activityView,
            spec: CaptureSpec(
                name: "09_activity_center_popover", windowTitle: "活动中心",
                size: NSSize(width: 380, height: 320), appearance: .aqua, toolbarStyle: .unified, delay: 0.6
            )
        )
        let settingsRoot = PlayCoverSettingsView(updaterViewModel: context.updaterVM)
        captureWindow(
            withDependencies(settingsRoot, context: context),
            spec: CaptureSpec(
                name: "10_settings_window", windowTitle: "MacOver 设置",
                size: NSSize(width: 680, height: 420), appearance: .aqua, toolbarStyle: .preference, delay: 0.7
            )
        )
    }

    private func captureMainWindow(
        _ name: String, _ title: String, _ appearance: NSAppearance.Name, _ context: DemoContext, delay: TimeInterval
    ) {
        let rootView = withDependencies(RootSplitView(autoFetchOnAppear: false), context: context)
        let spec = CaptureSpec(
            name: name, windowTitle: title, size: NSSize(width: 1280, height: 800),
            appearance: appearance, toolbarStyle: .unified, delay: delay
        )
        captureWindow(rootView, spec: spec)
    }

    private func withDependencies<Content: View>(_ content: Content, context: DemoContext) -> some View {
        let deps = context.deps
        return content
            .environmentObject(deps).environmentObject(deps.installVM)
            .environmentObject(deps.downloadVM).environmentObject(deps.appsVM)
            .environmentObject(deps.storeVM).environmentObject(deps.toastVM)
            .environmentObject(deps.appIntegrity).environmentObject(deps.alertPresenter)
            .environmentObject(deps.startupAlerts).environmentObject(deps.keyCoverObservable)
            .environmentObject(deps.keyCoverPreferences).environmentObject(deps.installPreferences)
            .environmentObject(deps.uninstallPreferences).environmentObject(deps.urlObservable)
            .environmentObject(deps.modifierKeyObserver).environmentObject(context.navState)
    }

    private func captureWindow<Content: View>(_ rootView: Content, spec: CaptureSpec) {
        let result = SnapshotSupport.renderAndSave(rootView: rootView, spec: spec)
        XCTAssertGreaterThan(result.width, 0, "Zero width bitmap for \(spec.name)")
        XCTAssertGreaterThan(result.height, 0, "Zero height bitmap for \(spec.name)")
        XCTAssertGreaterThan(result.uniqueColors, 15, "Snapshot \(spec.name) appears blank")
        if let attachment = result.attachment {
            add(attachment)
        } else {
            XCTFail("Failed to capture PNG for \(spec.name)")
        }
    }

    private func makeDemoContext() throws -> DemoContext {
        let defaults = try XCTUnwrap(isolatedDefaults)
        let deps = PlayCoverDependencies(userDefaults: defaults, loadInitialData: false, configureDiagnostics: false)
        deps.appIntegrity.integrityOff = false
        deps.startupAlerts.activeAlert = nil
        deps.keyCoverObservable.isKeyCoverUnlockingPromptShown = false
        deps.toastVM.isShown = false
        let dir = try XCTUnwrap(tempDir)
        let apps = try SnapshotSupport.demoSpecs().map { spec in
            createdBundleIDs.append(spec.bundleID)
            return try SnapshotSupport.makeDemoApp(spec: spec, in: dir, deps: deps)
        }
        SnapshotSupport.configureDemoApps(apps)
        deps.appsVM.updatingApps = false
        deps.appsVM.apps = apps
        deps.appsVM.applyFilter()
        return DemoContext(
            deps: deps, navState: AppNavigationState(), updaterVM: UpdaterViewModel(startUpdater: false),
            starlight: apps[0], chrono: apps[1], aether: apps[2], retro: apps[3]
        )
    }

    private func restoreUserDefaults() {
        if let savedLayoutRaw {
            UserDefaults.standard.set(savedLayoutRaw, forKey: "AppLibraryLayoutMode")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppLibraryLayoutMode")
        }
        if let savedLegacyList {
            UserDefaults.standard.set(savedLegacyList, forKey: "AppLibraryView")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppLibraryView")
        }
    }
}

private enum SnapshotSupport {
    static func demoSpecs() -> [DemoAppSpec] {
        [
            DemoAppSpec(
                slug: "starlight", displayName: "Starlight Odyssey", bundleID: "app.makedie.uitest.starlight",
                version: "1.0.0", symbol: "sparkles", startColor: .systemIndigo, endColor: .systemCyan
            ),
            DemoAppSpec(
                slug: "chrono", displayName: "Chrono Arena", bundleID: "app.makedie.uitest.chrono",
                version: "2.4.1", symbol: "gamecontroller.fill", startColor: .systemOrange, endColor: .systemPink
            ),
            DemoAppSpec(
                slug: "aether", displayName: "Aether Tactics", bundleID: "app.makedie.uitest.aether",
                version: "3.0.2", symbol: "bolt.shield.fill", startColor: .systemTeal, endColor: .systemBlue
            ),
            DemoAppSpec(
                slug: "retro", displayName: "Retro Runner", bundleID: "app.makedie.uitest.retro",
                version: "1.8.0", symbol: "arcade.stick.console.fill", startColor: .systemPurple, endColor: .systemRed
            )
        ]
    }

    static func configureDemoApps(_ apps: [PlayApp]) {
        apps[0].settings.update { data in
            data.resolution = 2; data.aspectRatio = 1
            data.windowWidth = 1920; data.windowHeight = 1080
            data.customScaler = 1.5; data.iosDeviceModel = "iPad16,6"
            data.frameRateTargetMode = .fixed60; data.enableNetworkRules = true
            data.networkBlockMock200 = true
            data.blockedURLPatterns = [
                "||ads.example.com^", "@@||auth.example.com^",
                "\(NetworkRuleParser.disabledPrefix)||disabled.example.com^", "telemetry.example.net"
            ]
            data.metalHUD = true
        }
        apps[0].launchSnapshot = apps[0].settings.settings
        apps[0].isRunning = true
        apps[0].settings.update { data in
            data.iosDeviceModel = "iPad17,3"
            data.frameRateTargetMode = .fixed120
        }
        apps[1].settings.update { PlayAppSettingsPreset.balanced.apply(to: &$0) }
        apps[2].settings.update { data in
            data.resolution = 4; data.aspectRatio = 1
            data.windowWidth = 3840; data.windowHeight = 2160; data.customScaler = 2.0
            data.frameRateTargetMode = .fixed120; data.windowCompatibility = .invertedMetrics
            data.iosDeviceModel = "iPad17,3"
        }
        apps[3].settings.update { data in
            data.resolution = 2; data.aspectRatio = 1
            data.windowWidth = 1920; data.windowHeight = 1080; data.customScaler = 1.0
            data.frameRateTargetMode = .fixed60; data.iosDeviceModel = "iPad6,7"
        }
    }

    @MainActor
    static func renderAndSave<Content: View>(rootView: Content, spec: CaptureSpec) -> CaptureResult {
        let colorScheme: ColorScheme = spec.appearance == .darkAqua ? .dark : .light
        let controller = NSHostingController(rootView: rootView.preferredColorScheme(colorScheme))
        let window = NSWindow(contentViewController: controller)
        window.title = spec.windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = spec.toolbarStyle
        window.setContentSize(spec.size)
        window.appearance = NSAppearance(named: spec.appearance)
        window.backgroundColor = .windowBackgroundColor
        window.orderBack(nil)
        defer { window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(spec.delay))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        guard let captureTarget = window.contentView?.superview ?? window.contentView,
              let bitmap = captureTarget.bitmapImageRepForCachingDisplay(in: captureTarget.bounds) else {
            return CaptureResult(width: 0, height: 0, uniqueColors: 0, attachment: nil)
        }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            captureTarget.cacheDisplay(in: captureTarget.bounds, to: bitmap)
        }
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return CaptureResult(width: bitmap.pixelsWide, height: bitmap.pixelsHigh, uniqueColors: 0, attachment: nil)
        }
        if let outputPath = ProcessInfo.processInfo.environment["PLAYCOVER_UI_SNAPSHOT_DIR"], !outputPath.isEmpty {
            let outputDir = URL(fileURLWithPath: outputPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
            try? pngData.write(to: outputDir.appendingPathComponent("\(spec.name).png"), options: .atomic)
        }
        let attachment = XCTAttachment(data: pngData, uniformTypeIdentifier: UTType.png.identifier)
        attachment.name = "\(spec.name).png"
        attachment.lifetime = .keepAlways
        return CaptureResult(
            width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
            uniqueColors: sampledColorCount(in: bitmap), attachment: attachment
        )
    }

    private static func sampledColorCount(in bitmap: NSBitmapImageRep) -> Int {
        var colors = Set<UInt32>()
        let stepX = max(1, bitmap.pixelsWide / 40)
        let stepY = max(1, bitmap.pixelsHigh / 40)
        for posY in stride(from: 0, to: bitmap.pixelsHigh, by: stepY) {
            for posX in stride(from: 0, to: bitmap.pixelsWide, by: stepX) {
                if let color = bitmap.colorAt(x: posX, y: posY)?.usingColorSpace(.sRGB) {
                    let red = UInt32(min(max(color.redComponent, 0), 1) * 255)
                    let green = UInt32(min(max(color.greenComponent, 0), 1) * 255)
                    let blue = UInt32(min(max(color.blueComponent, 0), 1) * 255)
                    colors.insert((red << 16) | (green << 8) | blue)
                }
            }
        }
        return colors.count
    }

    static func makeDemoApp(spec: DemoAppSpec, in dir: URL, deps: PlayCoverDependencies) throws -> PlayApp {
        let appURL = dir.appendingPathComponent("\(spec.slug).app", isDirectory: true)
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let infoPlist: [String: Any] = [
            "CFBundleDisplayName": spec.displayName, "CFBundleName": spec.displayName,
            "CFBundleIdentifier": spec.bundleID, "CFBundleShortVersionString": spec.version,
            "CFBundleExecutable": spec.slug, "MinimumOSVersion": "17.0", "CFBundleIconName": "AppIcon"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .binary, options: 0)
        try plistData.write(to: appURL.appendingPathComponent("Info.plist"))
        let iconData = try makeAppIconPNG(symbol: spec.symbol, startColor: spec.startColor, endColor: spec.endColor)
        try iconData.write(to: appURL.appendingPathComponent("AppIcon.png"))
        return PlayApp(appUrl: appURL, dependencies: deps)
    }

    private static func makeAppIconPNG(symbol: String, startColor: NSColor, endColor: NSColor) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw NSError(domain: "WorkspaceUISnapshotTests", code: 1)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        let bounds = NSRect(x: 0, y: 0, width: 256, height: 256)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 56, yRadius: 56)
        if let gradient = NSGradient(starting: startColor, ending: endColor) { gradient.draw(in: path, angle: -45) }
        if let baseSymbol = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 108, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            let configured = baseSymbol.withSymbolConfiguration(symbolConfig) ?? baseSymbol
            let size = configured.size
            let rect = NSRect(
                x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                width: size.width, height: size.height
            )
            configured.draw(in: rect)
        }
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
