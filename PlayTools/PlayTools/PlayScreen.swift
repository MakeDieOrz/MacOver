//
//  ScreenController.swift
//  PlayTools
//
import Foundation
import UIKit

let screen = PlayScreen.shared
var isInvertFixEnabled: Bool {
    if #available(iOS 16.3, *) {
        return false
    }
    return PlaySettings.shared.inverseScreenValues && PlaySettings.shared.adaptiveDisplay
}
var mainScreenWidth: CGFloat {
    !isInvertFixEnabled ? PlaySettings.shared.windowSizeWidth : PlaySettings.shared.windowSizeHeight
}
var mainScreenHeight: CGFloat {
    !isInvertFixEnabled ? PlaySettings.shared.windowSizeHeight : PlaySettings.shared.windowSizeWidth
}
var customScaler: CGFloat {
    PlaySettings.shared.customScaler
}

extension CGSize {
    func aspectRatio() -> CGFloat {
        let ratio = PTCoordinateMath.aspectRatio(width: width, height: height)
        if ratio > 0 {
            return ratio
        }
        return PTCoordinateMath.aspectRatio(width: mainScreenWidth, height: mainScreenHeight)
    }

    func toAspectRatio() -> CGSize {
        if #available(iOS 16.3, *) {
            return CGSize(width: mainScreenWidth, height: mainScreenHeight)
        } else {
            return CGSize(width: mainScreenHeight, height: mainScreenWidth)
        }
    }

    func toAspectRatioInternal() -> CGSize {
        return CGSize(width: mainScreenHeight, height: mainScreenWidth)
    }
    func toAspectRatioDefault() -> CGSize {
        if #available(iOS 16.3, *) {
            return CGSize(width: mainScreenWidth, height: mainScreenHeight)
        } else {
            return CGSize(width: mainScreenHeight, height: mainScreenWidth)
        }
    }
    func toAspectRatioInternalDefault() -> CGSize {
        return CGSize(width: mainScreenWidth, height: mainScreenHeight)
    }
}

extension CGRect {
    func aspectRatio() -> CGFloat {
        let ratio = PTCoordinateMath.aspectRatio(width: width, height: height)
        if ratio > 0 {
            return ratio
        }
        return PTCoordinateMath.aspectRatio(width: mainScreenWidth, height: mainScreenHeight)
    }

    func toAspectRatio(_ multiplier: CGFloat = 1) -> CGRect {
        return CGRect(x: minX, y: minY, width: mainScreenWidth * multiplier, height: mainScreenHeight * multiplier)
    }

    func toAspectRatioReversed() -> CGRect {
        return CGRect(x: minX, y: minY, width: mainScreenHeight, height: mainScreenWidth)
    }
    func toAspectRatioDefault(_ multiplier: CGFloat = 1) -> CGRect {
        return CGRect(x: minX, y: minY, width: mainScreenWidth * multiplier, height: mainScreenHeight * multiplier)
    }
    func toAspectRatioReversedDefault() -> CGRect {
        return CGRect(x: minX, y: minY, width: mainScreenHeight, height: mainScreenWidth)
    }
}

extension UIScreen {
    private static var cachedAspectRatio: CGFloat?
    private static let aspectRatioLock = PTUnfairLock()

    static func invalidateCachedAspectRatio() {
        aspectRatioLock.withLock {
            cachedAspectRatio = nil
        }
    }

    static var aspectRatio: CGFloat {
        if let cached = aspectRatioLock.withLock({ cachedAspectRatio }) {
            return cached
        }

        let computed: CGFloat
        let count = AKInterface.shared?.screenCount ?? 1
        if PlaySettings.shared.notch && (count == 1 || (AKInterface.shared?.isMainScreenEqualToFirst ?? true)) {
            computed = mainScreenWidth / mainScreenHeight
        } else if let frame = AKInterface.shared?.mainScreenFrame {
            computed = frame.aspectRatio()
        } else {
            computed = mainScreenWidth / mainScreenHeight
        }

        aspectRatioLock.withLock {
            cachedAspectRatio = computed
        }
        return computed
    }
}

public class PlayScreen: NSObject {
    @objc public static let shared = PlayScreen()

    private static let boundsLock = PTUnfairLock()
    private static weak var cachedWindow: UIWindow?
    private static var lastKnownWindowBounds: CGRect = .zero
    private static var lastMainKnownBounds: CGRect = .zero
    private static var cachedMainScreenRect: CGRect = .zero

    func initialize() {
        if Thread.isMainThread {
            Self.updateCachedScreenRect(UIScreen.main.bounds)
        }
        AKInterface.shared?.setupWindowGeometryChanged? { _ in
            UIScreen.invalidateCachedAspectRatio()
            Self.updateCachedScreenRect(UIScreen.main.bounds)
        }
        NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            UIScreen.invalidateCachedAspectRatio()
            if let window = notification.object as? UIWindow,
               !window.isHidden,
               !Self.isAuxiliaryKeyboardWindow(window),
               Self.isValidWindowBounds(window) {
                Self.cachedWindow = window
                if self.resizable, let windowScene = window.windowScene {
                    windowScene.sizeRestrictions?.minimumSize = CGSize(width: 0, height: 0)
                    windowScene.sizeRestrictions?.maximumSize = CGSize(width: .max, height: .max)
                }
                if !PTSafeMode.isActive,
                   let ak = AKInterface.shared,
                   ak.isSequoiaOrNewer == true,
                   !self.fullscreen,
                   PlaySettings.shared.adaptiveDisplay {
                    let targetSize = CGSize(width: mainScreenWidth, height: mainScreenHeight)
                    if targetSize.width > 0, targetSize.height > 0 {
                        ak.setWindowContentSize?(targetSize)
                        let settingsData = PlaySettings.shared.settingsData
                        if self.resizable,
                           settingsData.resizableAspectRatioWidth > 0,
                           settingsData.resizableAspectRatioHeight > 0 {
                            ak.setWindowAspectRatio?(
                                CGSize(
                                    width: CGFloat(settingsData.resizableAspectRatioWidth),
                                    height: CGFloat(settingsData.resizableAspectRatioHeight)
                                )
                            )
                        }
                    }
                }
            }
            Self.updateCachedScreenRect(UIScreen.main.bounds)
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("NSWindowDidEndLiveResizeNotification"),
            object: nil,
            queue: .main
        ) { _ in
            UIScreen.invalidateCachedAspectRatio()
            Self.updateCachedScreenRect(UIScreen.main.bounds)
        }
    }

    private static func updateCachedScreenRect(_ rect: CGRect) {
        guard rect.width > 1, rect.height > 1 else { return }
        boundsLock.withLock {
            cachedMainScreenRect = rect
        }
    }

    @objc public static func frame(_ rect: CGRect) -> CGRect {
        if #available(iOS 16.3, *) {
            return rect.toAspectRatio()
        }
        return rect.toAspectRatioReversed()
    }

    @objc public static func bounds(_ rect: CGRect) -> CGRect {
        return rect.toAspectRatio()
    }

    /// Backing-framebuffer `nativeBounds` for UIKit/Catalyst system callers and when `bypass`
    /// is disabled (`windowSize * customScaler`), keeping Mac window resizing and render scaling
    /// intact. App-level `UIScreen.nativeBounds` queries under `bypass` are intercepted in
    /// `NSObject+Swizzle.m` (`pt_hook_screen_nativeBounds`) to report the active device profile's
    /// physical portrait resolution (e.g. 1242x2688 on iPhone12,5).
    @objc public static func nativeBounds(_ rect: CGRect) -> CGRect {
        return rect.toAspectRatio(CGFloat((customScaler)))
    }

    @objc public static func width(_ size: Int) -> Int {
        return size
    }

    @objc public static func height(_ size: Int) -> Int {
        let ratio = UIScreen.aspectRatio
        guard ratio > 0 else { return size }
        return Int(CGFloat(size) / ratio)
    }

    @objc public static func sizeAspectRatio(_ size: CGSize) -> CGSize {
        return size.toAspectRatio()
    }

    var fullscreen: Bool {
        return AKInterface.shared?.isFullscreen ?? false
    }

    var resizable: Bool {
        return PlaySettings.shared.resizableWindow
    }

    @objc public var screenRect: CGRect {
        if Thread.isMainThread {
            let b = UIScreen.main.bounds
            Self.updateCachedScreenRect(b)
            return b
        }
        let (cached, fallbackWin) = Self.boundsLock.withLock {
            (Self.cachedMainScreenRect, Self.lastKnownWindowBounds)
        }
        if cached.width > 1, cached.height > 1 {
            return cached
        }
        if fallbackWin.width > 1, fallbackWin.height > 1 {
            return fallbackWin
        }
        return CGRect(x: 0, y: 0, width: mainScreenWidth, height: mainScreenHeight)
    }

    var width: CGFloat {
        screenRect.width
    }

    var height: CGFloat {
        screenRect.height
    }

    var max: CGFloat {
        let rect = screenRect
        return Swift.max(rect.width, rect.height)
    }

    var percent: CGFloat {
        PTCoordinateMath.screenPercent(for: screenRect.size)
    }

    var keyWindow: UIWindow? {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for win in windowScene.windows where win.isKeyWindow
                && !win.isHidden
                && !Self.isAuxiliaryKeyboardWindow(win)
                && Self.isValidWindowBounds(win) {
                return win
            }
        }
        return primaryWindow
    }

    var windowScene: UIWindowScene? {
        window?.windowScene
    }

    var window: UIWindow? {
        for scene in UIApplication.shared.connectedScenes where scene.activationState == .foregroundActive {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for win in windowScene.windows where win.isKeyWindow
                && !win.isHidden
                && !Self.isAuxiliaryKeyboardWindow(win)
                && Self.isValidWindowBounds(win) {
                return win
            }
        }
        return primaryWindow
    }

    var nsWindow: NSObject? {
        window?.nsWindow
    }

    func switchDock(_ visible: Bool) {
        AKInterface.shared?.setMenuBarVisible(visible)
    }

    // Default calculation
    @objc public static func frameReversedDefault(_ rect: CGRect) -> CGRect {
        return rect.toAspectRatioReversedDefault()
    }
    @objc public static func frameDefault(_ rect: CGRect) -> CGRect {
        return rect.toAspectRatioDefault()
    }
    @objc public static func boundsDefault(_ rect: CGRect) -> CGRect {
        return rect.toAspectRatioDefault()
    }

    /// Default-mode backing-framebuffer `nativeBounds` for system/non-bypass callers; see `nativeBounds(_:)`.
    @objc public static func nativeBoundsDefault(_ rect: CGRect) -> CGRect {
        return rect.toAspectRatioDefault(CGFloat((customScaler)))
    }

    @objc public static func sizeAspectRatioDefault(_ size: CGSize) -> CGSize {
        return size.toAspectRatioDefault()
    }
    @objc public static func frameInternalDefault(_ rect: CGRect) -> CGRect {
            return rect.toAspectRatioDefault()
    }

    private static func isValidWindowBounds(_ window: UIWindow) -> Bool {
        let b = window.bounds
        return b.width > 1 && b.height > 1
    }

    private static func isAuxiliaryKeyboardWindow(_ window: UIWindow) -> Bool {
        PTWindowGeometryMath.isAuxiliaryUIWindow(className: NSStringFromClass(type(of: window)))
    }

    var primaryWindow: UIWindow? {
        var bestNormalApp: UIWindow?
        var bestKeyValidApp: UIWindow?
        var bestNormalAnyApp: UIWindow?
        var bestVisibleValidApp: UIWindow?
        var fallbackApp: UIWindow?

        var bestKeyNormalOther: UIWindow?
        var bestNormalOther: UIWindow?
        var fallbackOther: UIWindow?

        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            let isAppRole = (ws.session.role == .windowApplication)
            for w in ws.windows {
                let isAux = Self.isAuxiliaryKeyboardWindow(w)
                if isAppRole {
                    if fallbackApp == nil && !isAux { fallbackApp = w }
                    if w.isHidden || isAux { continue }
                    let valid = Self.isValidWindowBounds(w)
                    let normal = (w.windowLevel == .normal)
                    if w.isKeyWindow && normal && valid { return w }
                    if bestNormalApp == nil && normal && valid { bestNormalApp = w }
                    if bestKeyValidApp == nil && w.isKeyWindow && valid { bestKeyValidApp = w }
                    if bestNormalAnyApp == nil && normal { bestNormalAnyApp = w }
                    if bestVisibleValidApp == nil && valid { bestVisibleValidApp = w }
                } else {
                    if fallbackOther == nil && !isAux { fallbackOther = w }
                    if w.isHidden || isAux { continue }
                    let valid = Self.isValidWindowBounds(w)
                    let normal = (w.windowLevel == .normal)
                    if bestKeyNormalOther == nil && w.isKeyWindow && normal && valid { bestKeyNormalOther = w }
                    if bestNormalOther == nil && normal && valid { bestNormalOther = w }
                }
            }
        }
        return bestNormalApp ?? bestKeyValidApp ?? bestNormalAnyApp
            ?? bestVisibleValidApp ?? fallbackApp ?? bestKeyNormalOther ?? bestNormalOther ?? fallbackOther
    }

    @objc public func activeTouchWindow() -> UIWindow? {
        return keyWindow ?? primaryWindow
    }

    @objc(activeTouchWindowAtPoint:)
    public func activeTouchWindow(at point: CGPoint) -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let orderedScenes = scenes.sorted { lhs, rhs in
            let lhsScore = (lhs.activationState == .foregroundActive ? 2 : 0)
                + (lhs.session.role == .windowApplication ? 1 : 0)
            let rhsScore = (rhs.activationState == .foregroundActive ? 2 : 0)
                + (rhs.session.role == .windowApplication ? 1 : 0)
            return lhsScore > rhsScore
        }

        for ws in orderedScenes {
            let windows = ws.windows
            let candidates = windows.map { win in
                PTWindowGeometryMath.TouchWindowCandidate(
                    isHidden: win.isHidden,
                    alpha: win.alpha,
                    isUserInteractionEnabled: win.isUserInteractionEnabled,
                    boundsSize: win.bounds.size,
                    windowLevel: win.windowLevel.rawValue
                )
            }
            for idx in PTWindowGeometryMath.orderedTouchCandidateIndices(candidates) {
                let win = windows[idx]
                let localPoint = PTWindowGeometryMath.pointInWindow(
                    scenePoint: point,
                    windowOrigin: win.frame.origin
                )
                if win.bounds.contains(localPoint), win.hitTest(localPoint, with: nil) != nil {
                    return win
                }
            }
        }
        return activeTouchWindow()
    }

    public func isPointInsideActiveTextInput(_ point: CGPoint) -> Bool {
        guard Thread.isMainThread, let win = activeTouchWindow(at: point) else {
            return false
        }
        let localPoint = PTWindowGeometryMath.pointInWindow(
            scenePoint: point,
            windowOrigin: win.frame.origin
        )
        var current = win.hitTest(localPoint, with: nil)
        while let view = current {
            if view is UITextInput && view.isFirstResponder {
                return true
            }
            current = view.superview
        }
        return false
    }

    @objc public static func boundsResizable(_ rect: CGRect) -> CGRect {
        if Thread.isMainThread {
            if let cw = cachedWindow,
               !cw.isHidden,
               cw.isKeyWindow,
               cw.windowScene?.session.role == .windowApplication {
                let winBounds = cw.bounds
                if winBounds.width > 1, winBounds.height > 1 {
                    if winBounds != lastMainKnownBounds {
                        lastMainKnownBounds = winBounds
                        boundsLock.withLock {
                            lastKnownWindowBounds = winBounds
                            cachedMainScreenRect = winBounds
                        }
                    }
                    return winBounds
                }
            }

            if let resolved = PlayScreen.shared.primaryWindow {
                cachedWindow = resolved
                let winBounds = resolved.bounds
                if winBounds.width > 1, winBounds.height > 1 {
                    if winBounds != lastMainKnownBounds {
                        lastMainKnownBounds = winBounds
                        boundsLock.withLock {
                            lastKnownWindowBounds = winBounds
                            cachedMainScreenRect = winBounds
                        }
                    }
                    return winBounds
                }
            }

            if lastMainKnownBounds.width > 1, lastMainKnownBounds.height > 1 {
                return lastMainKnownBounds
            }
        } else {
            let cached = boundsLock.withLock { lastKnownWindowBounds }
            if cached.width > 1, cached.height > 1 {
                return cached
            }
        }
        if (!PlaySettings.shared.adaptiveDisplay || PlaySettings.shared.resizableWindow),
           rect.width > 1, rect.height > 1 {
            return rect
        }
        return rect.toAspectRatio()
    }
}

extension CGFloat {
    var relativeY: CGFloat {
        PTCoordinateMath.relativeY(self, screenHeight: screen.height)
    }

    var relativeX: CGFloat {
        PTCoordinateMath.relativeX(self, screenWidth: screen.width)
    }

    var relativeSize: CGFloat {
        PTCoordinateMath.relativeSize(self, screenSize: screen.screenRect.size)
    }

    var absoluteSize: CGFloat {
        PTCoordinateMath.absoluteSize(self, screenSize: screen.screenRect.size)
    }

    var absoluteX: CGFloat {
        PTCoordinateMath.absoluteX(self, screenWidth: screen.width)
    }

    var absoluteY: CGFloat {
        PTCoordinateMath.absoluteY(self, screenHeight: screen.height)
    }
}

extension UIWindow {
    var nsWindow: NSObject? {
        guard let nsWindows = NSClassFromString("NSApplication")?
            .value(forKeyPath: "sharedApplication.windows") as? [AnyObject] else { return nil }
        for nsWindow in nsWindows {
            let uiWindows = nsWindow.value(forKeyPath: "uiWindows") as? [UIWindow] ?? []
            if uiWindows.contains(self) {
                return nsWindow as? NSObject
            }
        }
        return nil
    }
}
