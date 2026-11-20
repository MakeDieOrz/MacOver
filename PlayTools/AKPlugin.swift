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

// Add a lightweight struct so we can decode only the flag we care about
private struct AKAppSettingsData: Codable {
    var hideTitleBar: Bool?
    var floatingWindow: Bool?
    var resolution: Int?
    var resizableAspectRatioWidth: Int?
    var resizableAspectRatioHeight: Int?
}

class AKPlugin: NSObject, Plugin {
    private var isApplyingProgrammaticGeometry = false
    private var geometryObservers: [NSObjectProtocol] = []

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

    private func configureWindow(_ window: NSWindow) {
        window.styleMask.insert([.resizable])
        window.collectionBehavior = [.fullScreenPrimary, .managed, .participatesInCycle]
        window.isMovable = true
        window.isMovableByWindowBackground = true

        if self.hideTitleBarSetting {
            window.styleMask.insert([.fullSizeContentView])
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.toolbar = nil
            window.title = ""
        }

        if self.floatingWindowSetting {
            window.level = .floating
        }

        if let aspectRatio = self.aspectRatioSetting {
            window.contentAspectRatio = aspectRatio
        }
    }

    required override init() {
        super.init()
        if let window = activeWindow {
            configureWindow(window)
            NSWindow.allowsAutomaticWindowTabbing = true
        }

        // Apply the same appearance rules to any subsequent windows that may be created
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main) { [weak self] notif in
                guard let self,
                      let win = notif.object as? NSWindow,
                      Self.isPrimaryHostWindow(win) else { return }
                self.configureWindow(win)
        }
    }

    var screenCount: Int {
        NSScreen.screens.count
    }

    var mousePoint: CGPoint {
        activeWindow?.mouseLocationOutsideOfEventStream ?? CGPoint()
    }

    var windowFrame: CGRect {
        activeWindow?.frame ?? CGRect()
    }

    var isMainScreenEqualToFirst: Bool {
        return NSScreen.main == NSScreen.screens.first
    }

    var mainScreenFrame: CGRect {
        return (NSScreen.main ?? NSScreen.screens.first)?.frame ?? CGRect()
    }

    var isFullscreen: Bool {
        activeWindow?.styleMask.contains(.fullScreen) ?? false
    }

    var isSequoiaOrNewer: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
    }

    func setWindowContentSize(_ size: CGSize) {
        let apply = { [weak self] in
            guard let self, let window = self.activeWindow else { return }
            guard !window.styleMask.contains(.fullScreen) else { return }
            let visibleFrame = (window.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
            let clamped = PTWindowGeometryMath.clampedContentSize(
                requested: size,
                visibleScreenFrame: visibleFrame
            )
            guard clamped.width > 0, clamped.height > 0 else { return }
            let titleHeight = max(0, window.frame.height - window.contentLayoutRect.height)
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
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func setWindowAspectRatio(_ ratio: CGSize) {
        let apply = { [weak self] in
            guard let self, let window = self.activeWindow else { return }
            guard ratio.width.isFinite, ratio.height.isFinite, ratio.width > 0, ratio.height > 0 else { return }
            window.contentAspectRatio = NSSize(width: ratio.width, height: ratio.height)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func clearWindowAspectRatio() {
        let apply = { [weak self] in
            guard let self, let window = self.activeWindow else { return }
            window.resizeIncrements = NSSize(width: 1, height: 1)
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func setWindowOrientation(portrait: Bool, targetSize: CGSize) {
        let apply = { [weak self] in
            guard let self else { return }
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
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    func setupWindowGeometryChanged(_ callback: @escaping (CGRect) -> Void) {
        let register = { [weak self] in
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
                    guard let self, !self.isApplyingProgrammaticGeometry else { return }
                    if let notifiedWin = notification.object as? NSWindow,
                       !Self.isPrimaryHostWindow(notifiedWin) {
                        return
                    }
                    guard let win = (notification.object as? NSWindow) ?? self.activeWindow,
                          Self.isPrimaryHostWindow(win) else { return }
                    callback(win.frame)
                }
                self.geometryObservers.append(observer)
            }
        }
        if Thread.isMainThread {
            register()
        } else {
            DispatchQueue.main.async(execute: register)
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
        guard let firstScreen = NSScreen.screens.first else {return}
        let frame = windowFrame
        // Convert from NS coordinates to CG coordinates
        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: firstScreen.frame.height - frame.midY))
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
        NSApplication.shared.terminate(self)
    }

    private var modifierFlag: UInt = 0

    // swiftlint:disable:next function_body_length
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

    func setupMouseButton(left: Bool, right: Bool, _ consumed: @escaping (Int, Bool) -> Bool) {
        let downType: NSEvent.EventTypeMask = left ? .leftMouseDown : right ? .rightMouseDown : .otherMouseDown
        let upType: NSEvent.EventTypeMask = left ? .leftMouseUp : right ? .rightMouseUp : .otherMouseUp

        // Helper to detect whether the event is inside any of the window "traffic-light" buttons
        func isInTrafficLightArea(_ event: NSEvent) -> Bool {
            if self.hideTitleBarSetting == false {
                return false
            }
            guard let win = event.window else { return false }
            let pointInWindow = event.locationInWindow
            let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton, .fullScreenButton]
            for type in buttonTypes {
                if let button = win.standardWindowButton(type) {
                    let localPoint = button.convert(pointInWindow, from: nil) // convert from window coords
                    if button.bounds.contains(localPoint) {
                        return true
                    }
                }
            }
            return false
        }

        NSEvent.addLocalMonitorForEvents(matching: downType, handler: { event in
            // Always allow clicks on the window traffic-light buttons to pass through
            if isInTrafficLightArea(event) {
                return event
            }

            // Detect double-clicks on the title-bar area (respecting system preference)

            if left && event.clickCount == 2, self.hideTitleBarSetting, let win = event.window {
                let contentRect = win.contentLayoutRect
                // Title-bar area is the region above contentLayoutRect
                if event.locationInWindow.y > contentRect.maxY {
                    win.performZoom(nil)
                    return nil
                }
            }

            // Bypass auxiliary panels / IME windows and mismatched host windows
            if let eventWin = event.window, !Self.isPrimaryHostWindow(eventWin) {
                return event
            }
            if let targetWin = self.activeWindow, let eventWin = event.window, eventWin != targetWin {
                return event
            }
            if consumed(event.buttonNumber, true) {
                return nil
            }
            return event
        })
        NSEvent.addLocalMonitorForEvents(matching: upType, handler: { event in
            if let eventWin = event.window, !Self.isPrimaryHostWindow(eventWin) {
                return event
            }
            // Always allow releases on the traffic-light buttons to pass through
            if isInTrafficLightArea(event) {
                _ = consumed(event.buttonNumber, false)
                return event
            }
            if consumed(event.buttonNumber, false) {
                return nil
            }
            return event
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

    /// Convenience instance property that exposes the cached static preference.
    private var hideTitleBarSetting: Bool { Self.akAppSettingsData?.hideTitleBar ?? false }
    private var floatingWindowSetting: Bool { Self.akAppSettingsData?.floatingWindow ?? false }
    private var aspectRatioSetting: NSSize? {
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
        if let rawEnv, let envStr = String(validatingUTF8: rawEnv), envStr.hasPrefix("/") {
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
           let overridePath = String(validatingUTF8: overridePtr),
           overridePath.hasPrefix("/") {
            return URL(fileURLWithPath: overridePath)
        }
        let settingsDir = URL(fileURLWithPath: resolveHostUserRoot())
            .appendingPathComponent("Library/Containers/io.playcover.PlayCover")
            .appendingPathComponent("App Settings")
        if !bundleIdentifier.isEmpty {
            let primary = settingsDir.appendingPathComponent("\(bundleIdentifier).plist")
            if FileManager.default.fileExists(atPath: primary.path) {
                return primary
            }
            if let cfHomePtr = getenv("CFFIXED_USER_HOME"),
               let cfHome = String(validatingUTF8: cfHomePtr),
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
           let cfHome = String(validatingUTF8: cfHomePtr),
           let marker = cfHome.range(of: "/Library/Containers/") {
            let tail = cfHome[marker.upperBound...]
            let cid = tail.prefix(while: { $0 != "/" })
            if !cid.isEmpty {
                return settingsDir.appendingPathComponent("\(cid).plist")
            }
        }
        return settingsDir.appendingPathComponent("\(bundleIdentifier).plist")
    }

    fileprivate static var akAppSettingsData: AKAppSettingsData? = {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        let settingsURL = resolveSettingsURL(bundleIdentifier: bundleIdentifier)
        guard let data = try? Data(contentsOf: settingsURL),
              let decoded = try? PropertyListDecoder().decode(AKAppSettingsData.self, from: data) else {
            return nil
        }
        return decoded
    }()
}
