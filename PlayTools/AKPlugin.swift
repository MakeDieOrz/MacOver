//
//  MacPlugin.swift
//  AKInterface
//
//  Created by Isaac Marovitz on 13/09/2022.
//

import AppKit
import CoreGraphics
import Darwin
import Foundation
import ObjectiveC

private struct AKUncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

final class AKPlugin: NSObject, Plugin, @unchecked Sendable {
    private var isApplyingProgrammaticGeometry = false
    @MainActor private var isTrackingWindowChromeClick = false
    private var geometryObservers: [NSObjectProtocol] = []

    private static func onMainSync<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(body)
        }
    }

    @MainActor
    private static func isPrimaryHostWindow(_ window: NSWindow) -> Bool {
        let className = NSStringFromClass(type(of: window))
        let delegateClassName = window.delegate.map { NSStringFromClass(type(of: $0)) }
        let hasTitleOrFullScreen = window.styleMask.contains(.titled) || window.styleMask.contains(.fullScreen)
        return !PTWindowGeometryMath.isAuxiliaryHostWindow(
            className: className,
            delegateClassName: delegateClassName,
            isPanel: window is NSPanel,
            hasTitleOrFullScreenStyle: hasTitleOrFullScreen,
            frameSize: window.frame.size
        )
    }

    @MainActor
    private var activeWindow: NSWindow? {
        if let key = NSApplication.shared.keyWindow, Self.isPrimaryHostWindow(key) {
            return key
        }
        if let main = NSApplication.shared.mainWindow, Self.isPrimaryHostWindow(main) {
            return main
        }
        if let visiblePrimary = NSApplication.shared.windows.first(where: {
            $0.isVisible && Self.isPrimaryHostWindow($0)
        }) {
            return visiblePrimary
        }
        return NSApplication.shared.windows.first(where: { Self.isPrimaryHostWindow($0) })
    }

    @MainActor
    private static func titleBarHeight(for window: NSWindow) -> CGFloat {
        max(0, window.frame.height - window.contentRect(forFrameRect: window.frame).height)
    }

    @MainActor
    private func applyHideTitleBarAppearance(to window: NSWindow) {
        if !window.styleMask.contains(.fullScreen) {
            window.styleMask.insert([.fullSizeContentView])
        }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = nil
        window.title = ""
    }

    @MainActor
    private func configureWindow(_ window: NSWindow) {
        if !window.styleMask.contains(.fullScreen) {
            if let plan = strictWindowPlan(for: window) {
                if plan.allowsUserResize {
                    window.styleMask.insert([.resizable])
                } else {
                    window.styleMask.remove(.resizable)
                }
                window.contentMinSize = NSSize(
                    width: min(100, max(1, plan.windowContentSize.width)),
                    height: min(100, max(1, plan.windowContentSize.height))
                )
                window.contentAspectRatio = NSSize(
                    width: plan.lockedAspectRatio.width,
                    height: plan.lockedAspectRatio.height
                )
            } else {
                window.styleMask.insert([.resizable])
                if let aspectRatio = self.aspectRatioSetting {
                    window.contentAspectRatio = aspectRatio
                }
            }
        }
        window.collectionBehavior = [.fullScreenPrimary, .managed, .participatesInCycle]
        window.isMovable = true
        window.isMovableByWindowBackground = true

        if self.hideTitleBarSetting {
            applyHideTitleBarAppearance(to: window)
        }

        if self.floatingWindowSetting {
            window.level = .floating
        }
    }

    required override init() {
        super.init()
        Self.onMainSync {
            if let window = self.activeWindow {
                self.configureWindow(window)
                NSWindow.allowsAutomaticWindowTabbing = true
            }
        }

        // Apply the same appearance rules to any subsequent windows that may be created
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main) { [weak self] notif in
                guard let self else { return }
                let winBox = AKUncheckedSendableBox(value: notif.object as? NSWindow)
                MainActor.assumeIsolated {
                    guard let win = winBox.value,
                          Self.isPrimaryHostWindow(win) else { return }
                    self.configureWindow(win)
                }
        }
    }

    var screenCount: Int {
        Self.onMainSync { NSScreen.screens.count }
    }

    var mousePoint: CGPoint {
        Self.onMainSync { activeWindow?.mouseLocationOutsideOfEventStream ?? CGPoint() }
    }

    var windowFrame: CGRect {
        Self.onMainSync { activeWindow?.frame ?? CGRect() }
    }

    var isMainScreenEqualToFirst: Bool {
        Self.onMainSync { NSScreen.main == NSScreen.screens.first }
    }

    var mainScreenFrame: CGRect {
        Self.onMainSync { (NSScreen.main ?? NSScreen.screens.first)?.frame ?? CGRect() }
    }

    var isFullscreen: Bool {
        Self.onMainSync { activeWindow?.styleMask.contains(.fullScreen) ?? false }
    }

    var isSequoiaOrNewer: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
    }

    func setWindowContentSize(_ size: CGSize) {
        let apply = { @MainActor [weak self] in
            guard let self, let window = self.activeWindow else { return }
            guard !window.styleMask.contains(.fullScreen) else { return }
            if self.hideTitleBarSetting && !window.styleMask.contains(.fullSizeContentView) {
                self.applyHideTitleBarAppearance(to: window)
            }
            let visibleFrame = (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            let titleHeight = Self.titleBarHeight(for: window)
            let clamped: CGSize
            if let plan = self.strictWindowPlan(for: window, visibleFrame: visibleFrame, titleHeight: titleHeight) {
                clamped = plan.windowContentSize
                if plan.allowsUserResize {
                    window.styleMask.insert([.resizable])
                } else {
                    window.styleMask.remove(.resizable)
                }
                window.contentMinSize = NSSize(
                    width: min(100, max(1, clamped.width)),
                    height: min(100, max(1, clamped.height))
                )
                window.contentAspectRatio = NSSize(
                    width: plan.lockedAspectRatio.width,
                    height: plan.lockedAspectRatio.height
                )
            } else {
                clamped = PTWindowGeometryMath.clampedContentSize(
                    requested: size,
                    visibleScreenFrame: visibleFrame,
                    titleBarHeight: titleHeight
                )
            }
            guard clamped.width > 0, clamped.height > 0 else { return }
            let nextFrame = PTWindowGeometryMath.centeredFrame(
                forContentSize: clamped,
                currentFrame: window.frame,
                visibleScreenFrame: visibleFrame,
                titleBarHeight: titleHeight
            )
            self.isApplyingProgrammaticGeometry = true
            defer { self.isApplyingProgrammaticGeometry = false }
            window.setFrame(nextFrame, display: true, animate: false)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(apply)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(apply)
            }
        }
    }

    func setWindowAspectRatio(_ ratio: CGSize) {
        let apply = { @MainActor [weak self] in
            guard let self,
                  let window = self.activeWindow,
                  !window.styleMask.contains(.fullScreen) else { return }
            let effectiveRatio = self.strictDeviceLogicalSize ?? ratio
            guard effectiveRatio.width.isFinite,
                  effectiveRatio.height.isFinite,
                  effectiveRatio.width > 0,
                  effectiveRatio.height > 0 else { return }
            window.contentAspectRatio = NSSize(width: effectiveRatio.width, height: effectiveRatio.height)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(apply)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(apply)
            }
        }
    }

    func clearWindowAspectRatio() {
        let apply = { @MainActor [weak self] in
            guard let self, !self.isStrictEmulationActive, let window = self.activeWindow else { return }
            window.resizeIncrements = NSSize(width: 1, height: 1)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(apply)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(apply)
            }
        }
    }

    func setWindowOrientation(portrait: Bool, targetSize: CGSize) {
        let apply = { @MainActor [weak self] in
            guard let self else { return }
            if let strictSize = self.strictDeviceLogicalSize {
                self.setWindowAspectRatio(strictSize)
                self.setWindowContentSize(strictSize)
                return
            }
            let fallback = self.activeWindow?.contentLayoutRect.size ?? CGSize(width: 1920, height: 1080)
            let base = (targetSize.width > 0 && targetSize.height > 0) ? targetSize : fallback
            let oriented = PTWindowGeometryMath.orientedSize(baseSize: base, portrait: portrait)
            guard oriented.width > 0, oriented.height > 0 else { return }
            if self.aspectRatioSetting != nil {
                self.setWindowAspectRatio(oriented)
            }
            self.setWindowContentSize(oriented)
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(apply)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(apply)
            }
        }
    }

    func setupWindowGeometryChanged(_ callback: @escaping (CGRect) -> Void) {
        let callbackBox = AKUncheckedSendableBox(value: callback)
        let register = { @MainActor [weak self] in
            guard let self else { return }
            for obs in self.geometryObservers {
                NotificationCenter.default.removeObserver(obs)
            }
            self.geometryObservers.removeAll()

            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didChangeBackingPropertiesNotification,
                NSWindow.didBecomeKeyNotification
            ]
            for name in names {
                let observer = NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] notification in
                    guard let self else { return }
                    let notifBox = AKUncheckedSendableBox(value: notification.object as? NSWindow)
                    MainActor.assumeIsolated {
                        guard !self.isApplyingProgrammaticGeometry else { return }
                        if let notifiedWin = notifBox.value,
                           !Self.isPrimaryHostWindow(notifiedWin) {
                            return
                        }
                        guard let win = notifBox.value ?? self.activeWindow,
                              Self.isPrimaryHostWindow(win) else { return }
                        callbackBox.value(win.frame)
                    }
                }
                self.geometryObservers.append(observer)
            }
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(register)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(register)
            }
        }
    }

    var cmdPressed: Bool = false
    var cursorHideLevel = 0
    func hideCursor() {
        NSCursor.hide()
        cursorHideLevel += 1
        CGAssociateMouseAndMouseCursorPosition(0)
        warpCursor()
    }

    func hideCursorMove() {
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func warpCursor() {
        Self.onMainSync {
            guard let firstScreen = NSScreen.screens.first else { return }
            let frame = windowFrame
            // Convert from NS coordinates to CG coordinates
            CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: firstScreen.frame.height - frame.midY))
        }
    }

    func unhideCursor() {
        guard cursorHideLevel > 0 else {
            CGAssociateMouseAndMouseCursorPosition(1)
            return
        }
        NSCursor.unhide()
        cursorHideLevel -= 1
        if cursorHideLevel <= 0 {
            cursorHideLevel = 0
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    func terminateApplication() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func shouldTerminateOnWindowClose(_ window: NSObject) -> Bool {
        guard let closingWindow = window as? NSWindow else { return false }
        let windowBox = AKUncheckedSendableBox(value: closingWindow)
        return Self.onMainSync {
            let targetWindow = windowBox.value
            let isPrimary = Self.isPrimaryHostWindow(targetWindow)
            let otherVisiblePrimaryCount = NSApplication.shared.windows.reduce(into: 0) { count, candidate in
                if candidate !== targetWindow
                    && candidate.isVisible
                    && Self.isPrimaryHostWindow(candidate) {
                    count += 1
                }
            }
            return PTWindowGeometryMath.shouldTerminateOnWindowClose(
                isClosingWindowPrimary: isPrimary,
                otherVisiblePrimaryWindowCount: otherVisiblePrimaryCount
            )
        }
    }

    private var modifierFlag: UInt = 0

    func setupKeyboard(keyboard: @escaping (UInt16, Bool, Bool, Bool) -> Bool,
                       swapMode: @escaping () -> Bool) {
        func checkCmd(modifier: NSEvent.ModifierFlags) -> Bool {
            if modifier.contains(.command) {
                self.cmdPressed = true
                return true
            } else if self.cmdPressed {
                self.cmdPressed = false
            }
            return false
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { event in
            if checkCmd(modifier: event.modifierFlags) {
                return event
            }
            let consumed = keyboard(event.keyCode, true, event.isARepeat,
                                    event.modifierFlags.contains(.control))
            if consumed {
                return nil
            }
            return event
        })
        NSEvent.addLocalMonitorForEvents(matching: .keyUp, handler: { event in
            if checkCmd(modifier: event.modifierFlags) {
                return event
            }
            let consumed = keyboard(event.keyCode, false, false,
                                    event.modifierFlags.contains(.control))
            if consumed {
                return nil
            }
            return event
        })
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { event in
            if checkCmd(modifier: event.modifierFlags) {
                return event
            }
            let pressed = self.modifierFlag < event.modifierFlags.rawValue
            let changed = self.modifierFlag ^ event.modifierFlags.rawValue
            self.modifierFlag = event.modifierFlags.rawValue
            let changedFlags = NSEvent.ModifierFlags(rawValue: changed)
            if pressed && changedFlags.contains(.option) {
                if swapMode() {
                    return nil
                }
                return event
            }
            let consumed = keyboard(event.keyCode, pressed, false,
                                    event.modifierFlags.contains(.control))
            if consumed {
                return nil
            }
            return event
        })
    }

    func setupMouseMoved(_ mouseMoved: @escaping (CGFloat, CGFloat) -> Bool) {
        let mask: NSEvent.EventTypeMask = [.leftMouseDragged, .otherMouseDragged, .rightMouseDragged]
        NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            if event.type == .leftMouseDragged {
                let eventBox = AKUncheckedSendableBox(value: event)
                let bypass = MainActor.assumeIsolated {
                    let ev = eventBox.value
                    if let eventWin = ev.window, !Self.isPrimaryHostWindow(eventWin) {
                        return true
                    }
                    return self.isTrackingWindowChromeClick || self.isInWindowChromeOrTrafficLights(ev)
                }
                if bypass {
                    return event
                }
            }
            let consumed = mouseMoved(event.deltaX, event.deltaY)
            if consumed {
                return nil
            }
            return event
        })
        // transpass mouse moved event when no button pressed, for traffic light button to light up
        NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            _ = mouseMoved(event.deltaX, event.deltaY)
            return event
        })
    }

    @MainActor
    private func isInWindowChromeOrTrafficLights(_ event: NSEvent) -> Bool {
        guard let win = event.window else { return false }
        let pointInWindow = event.locationInWindow
        let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttonTypes {
            if let button = win.standardWindowButton(type),
               button.window === win,
               !button.isHiddenOrHasHiddenAncestor {
                let localPoint = button.convert(pointInWindow, from: nil)
                if button.bounds.contains(localPoint) {
                    return true
                }
            }
        }
        if !self.hideTitleBarSetting && !win.styleMask.contains(.fullScreen) {
            return PTWindowGeometryMath.isPointInTitleBar(
                pointInWindow: pointInWindow,
                contentLayoutRect: win.contentLayoutRect
            )
        }
        return false
    }

    func setupMouseButton(left: Bool, right: Bool, _ consumed: @escaping (Int, Bool) -> Bool) {
        let downType: NSEvent.EventTypeMask = left ? .leftMouseDown : right ? .rightMouseDown : .otherMouseDown
        let upType: NSEvent.EventTypeMask = left ? .leftMouseUp : right ? .rightMouseUp : .otherMouseUp
        let consumedBox = AKUncheckedSendableBox(value: consumed)

        NSEvent.addLocalMonitorForEvents(matching: downType, handler: { event in
            let eventBox = AKUncheckedSendableBox(value: event)
            let dropEvent = MainActor.assumeIsolated {
                let event = eventBox.value
                // Always allow clicks on the window traffic-light buttons or native title bar to pass through
                if self.isInWindowChromeOrTrafficLights(event) {
                    if left {
                        self.isTrackingWindowChromeClick = true
                    }
                    return false
                }
                if left {
                    // Clear stale chrome tracking if AppKit modal titlebar drag or button tracking consumed mouseUp.
                    self.isTrackingWindowChromeClick = false
                }

                // Detect double-clicks on the title-bar area (respecting system preference)
                if left && event.clickCount == 2, self.hideTitleBarSetting, let win = event.window {
                    let contentRect = win.contentLayoutRect
                    // Title-bar area is the region above contentLayoutRect
                    if event.locationInWindow.y > contentRect.maxY {
                        win.performZoom(nil)
                        return true
                    }
                }

                // Bypass auxiliary panels / IME windows and mismatched host windows
                if let eventWin = event.window, !Self.isPrimaryHostWindow(eventWin) {
                    return false
                }
                if let targetWin = self.activeWindow, let eventWin = event.window, eventWin != targetWin {
                    return false
                }
                return consumedBox.value(event.buttonNumber, true)
            }
            return dropEvent ? nil : event
        })
        NSEvent.addLocalMonitorForEvents(matching: upType, handler: { event in
            let eventBox = AKUncheckedSendableBox(value: event)
            let dropEvent = MainActor.assumeIsolated {
                let event = eventBox.value
                let wasTrackingChrome = left && self.isTrackingWindowChromeClick
                if wasTrackingChrome {
                    self.isTrackingWindowChromeClick = false
                }
                if let eventWin = event.window, !Self.isPrimaryHostWindow(eventWin) {
                    return false
                }
                // Always allow releases on the traffic-light buttons or title bar to pass through
                if wasTrackingChrome || self.isInWindowChromeOrTrafficLights(event) {
                    _ = consumedBox.value(event.buttonNumber, false)
                    return false
                }
                return consumedBox.value(event.buttonNumber, false)
            }
            return dropEvent ? nil : event
        })
    }

    func setupScrollWheel(_ onMoved: @escaping (CGFloat, CGFloat) -> Bool) {
        NSEvent.addLocalMonitorForEvents(matching: NSEvent.EventTypeMask.scrollWheel, handler: { event in
            var deltaX = event.scrollingDeltaX, deltaY = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas {
                deltaX *= 16
                deltaY *= 16
            }
            let consumed = onMoved(deltaX, deltaY)
            if consumed {
                return nil
            }
            return event
        })
    }

    func urlForApplicationWithBundleIdentifier(_ value: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: value)
    }

    func setMenuBarVisible(_ visible: Bool) {
        NSMenu.setMenuBarVisible(visible)
    }

    private static func parseSafeModeEnvFlag(_ raw: String?) -> Bool? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "1" || normalized == "true" || normalized == "yes" {
            return true
        }
        if normalized == "0" || normalized == "false" || normalized == "no" {
            return false
        }
        return nil
    }

    private static func resolvePTSafeModeIsActive() -> Bool? {
        let candidateNames = [
            "PTSafeMode",
            "_TtC9PlayTools10PTSafeMode",
            "_TtC14PlayToolsTests10PTSafeMode"
        ]
        let selector = NSSelectorFromString("isActive")
        for name in candidateNames {
            guard let cls = NSClassFromString(name),
                  let method = class_getClassMethod(cls, selector) else {
                continue
            }
            typealias IsActiveFn = @convention(c) (AnyClass, Selector) -> Bool
            let isActiveImp = unsafeBitCast(method_getImplementation(method), to: IsActiveFn.self)
            return isActiveImp(cls, selector)
        }
        return nil
    }

    private static var isSafeModeActive: Bool {
        let envRaw = getenv("PLAYTOOLS_SAFE_MODE").map { String(cString: $0) }
        if let explicitFlag = parseSafeModeEnvFlag(envRaw) {
            return explicitFlag
        }
        return resolvePTSafeModeIsActive() ?? false
    }

    private var isStrictEmulationActive: Bool {
        !Self.isSafeModeActive && (Self.akAppSettingsData?.strictEmulationMode == true)
    }

    private var strictDeviceLogicalSize: CGSize? {
        guard isStrictEmulationActive, let settings = Self.akAppSettingsData else {
            return nil
        }
        let logical = settings.strictDeviceDisplaySpec.logicalSize(
            orientation: settings.strictViewportOrientation
        )
        return CGSize(width: logical.width, height: logical.height)
    }

    @MainActor
    private func strictWindowPlan(
        for window: NSWindow,
        visibleFrame: CGRect? = nil,
        titleHeight: CGFloat? = nil
    ) -> PTWindowGeometryMath.StrictViewportWindowPlan? {
        guard let logicalSize = strictDeviceLogicalSize else {
            return nil
        }
        let targetFrame = visibleFrame
            ?? (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? .zero
        let resolvedTitleHeight = titleHeight ?? Self.titleBarHeight(for: window)
        return PTWindowGeometryMath.strictViewportWindowPlan(
            logicalSceneSize: logicalSize,
            scaleMode: Self.akAppSettingsData?.strictViewportScaleMode.rawValue,
            visibleScreenFrame: targetFrame,
            titleBarHeight: resolvedTitleHeight
        )
    }

    /// Convenience instance property that exposes the cached static preference.
    private var hideTitleBarSetting: Bool { Self.akAppSettingsData?.hideTitleBar ?? false }
    private var floatingWindowSetting: Bool { Self.akAppSettingsData?.floatingWindow ?? false }
    private var aspectRatioSetting: NSSize? {
        if let strictSize = strictDeviceLogicalSize {
            return NSSize(width: strictSize.width, height: strictSize.height)
        }
        guard Self.akAppSettingsData?.resolution == 6 else {
            return nil
        }
        let width = Self.akAppSettingsData?.resizableAspectRatioWidth ?? 0
        let height = Self.akAppSettingsData?.resizableAspectRatioHeight ?? 0
        guard width > 0 && height > 0 else {
            return nil
        }
        return NSSize(width: width, height: height)
    }

    private static func resolveHostUserRoot() -> String {
        let rawEnv = getenv("CFFIXED_USER_HOME") ?? getenv("HOME")
        if let rawEnv, let envStr = String(validatingCString: rawEnv), envStr.hasPrefix("/") {
            var path = envStr
            if path.hasPrefix("/System/Volumes/Data/") {
                path.removeFirst("/System/Volumes/Data".count)
            }
            if let range = path.range(of: "/Library/Containers/"), range.lowerBound > path.startIndex {
                return String(path[..<range.lowerBound])
            }
            if path.hasPrefix("/Users/") {
                let afterUsers = path.index(path.startIndex, offsetBy: "/Users/".count)
                if let slash = path[afterUsers...].firstIndex(of: "/") {
                    return String(path[..<slash])
                }
                if afterUsers < path.endIndex {
                    return path
                }
            }
        }
        if let passwdEntry = getpwuid(getuid()), let dirPtr = passwdEntry.pointee.pw_dir {
            let dir = String(cString: dirPtr)
            if dir.hasPrefix("/") {
                return dir
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    private static func resolveSettingsURL(bundleIdentifier: String) -> URL {
        if let overridePtr = getenv("PLAYTOOLS_SETTINGS_PLIST"),
           let overridePath = String(validatingCString: overridePtr),
           overridePath.hasPrefix("/") {
            return URL(fileURLWithPath: overridePath)
        }
        let settingsDir = URL(fileURLWithPath: resolveHostUserRoot())
            .appendingPathComponent("Library/Containers/app.makedie.MacOver")
            .appendingPathComponent("App Settings")
        if !bundleIdentifier.isEmpty {
            let primary = settingsDir.appendingPathComponent("\(bundleIdentifier).plist")
            if FileManager.default.fileExists(atPath: primary.path) {
                return primary
            }
            if let cfHomePtr = getenv("CFFIXED_USER_HOME"),
               let cfHome = String(validatingCString: cfHomePtr),
               let marker = cfHome.range(of: "/Library/Containers/") {
                let tail = cfHome[marker.upperBound...]
                let cid = tail.prefix(while: { $0 != "/" })
                if !cid.isEmpty {
                    let alt = settingsDir.appendingPathComponent("\(cid).plist")
                    if FileManager.default.fileExists(atPath: alt.path) {
                        return alt
                    }
                }
            }
            return primary
        }
        if let cfHomePtr = getenv("CFFIXED_USER_HOME"),
           let cfHome = String(validatingCString: cfHomePtr),
           let marker = cfHome.range(of: "/Library/Containers/") {
            let tail = cfHome[marker.upperBound...]
            let cid = tail.prefix(while: { $0 != "/" })
            if !cid.isEmpty {
                return settingsDir.appendingPathComponent("\(cid).plist")
            }
        }
        return settingsDir.appendingPathComponent("\(bundleIdentifier).plist")
    }

    fileprivate static let akAppSettingsData: AppSettingsData? = {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        let settingsURL = resolveSettingsURL(bundleIdentifier: bundleIdentifier)
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? PropertyListDecoder().decode(AppSettingsData.self, from: data) else {
            return nil
        }
        return decoded
    }()
}
