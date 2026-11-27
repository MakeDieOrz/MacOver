//
//  ScreenController.swift
//  PlayTools
//
import Foundation
import ObjectiveC.runtime
import Synchronization
import UIKit

let screen = PlayScreen.shared
var mainScreenWidth: CGFloat {
    PlaySettings.shared.windowSizeWidth
}
var mainScreenHeight: CGFloat {
    PlaySettings.shared.windowSizeHeight
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
        return CGSize(width: mainScreenWidth, height: mainScreenHeight)
    }

    func toAspectRatioInternal() -> CGSize {
        return CGSize(width: mainScreenHeight, height: mainScreenWidth)
    }
    func toAspectRatioDefault() -> CGSize {
        return CGSize(width: mainScreenWidth, height: mainScreenHeight)
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

    func toAspectRatioDefault(_ multiplier: CGFloat = 1) -> CGRect {
        return CGRect(x: minX, y: minY, width: mainScreenWidth * multiplier, height: mainScreenHeight * multiplier)
    }
    func toAspectRatioReversedDefault() -> CGRect {
        return CGRect(x: minX, y: minY, width: mainScreenHeight, height: mainScreenWidth)
    }
}

extension UIScreen {
    nonisolated private static let aspectRatioLock = PTUnfairLock()
    nonisolated(unsafe) private static var cachedAspectRatio: CGFloat?

    nonisolated static func invalidateCachedAspectRatio() {
        aspectRatioLock.withLock {
            cachedAspectRatio = nil
        }
    }

    nonisolated static var aspectRatio: CGFloat {
        if let cached = aspectRatioLock.withLock({ cachedAspectRatio }) {
            return cached
        }

        let computed: CGFloat
        let count = AKInterface.shared?.screenCount ?? 1
        if PlaySettings.shared.strictEmulationMode {
            computed = mainScreenHeight > 0 ? (mainScreenWidth / mainScreenHeight) : 1.0
        } else if PlaySettings.shared.notch && (count == 1 || (AKInterface.shared?.isMainScreenEqualToFirst ?? true)) {
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

public final class PlayScreen: NSObject, @unchecked Sendable {
    @objc public static let shared = PlayScreen()

    private struct BoundsState: Sendable {
        weak var cachedWindow: UIWindow?
        var lastKnownWindowBounds: CGRect = .zero
        var lastMainKnownBounds: CGRect = .zero
        var cachedMainScreenRect: CGRect = .zero
        var lastAppliedStrictFitViewportKey: PTStrictViewportFocusKey?
    }

    private static let boundsState = Mutex(BoundsState())

    @MainActor
    private static func resolveActiveScreenBounds(preferredWindow: UIWindow? = nil) -> CGRect {
        if let bounds = preferredWindow?.windowScene?.screen.bounds,
           bounds.width > 1,
           bounds.height > 1 {
            return bounds
        }
        if let bounds = PlayScreen.shared.windowScene?.screen.bounds,
           bounds.width > 1,
           bounds.height > 1 {
            return bounds
        }
        var fallbackSceneBounds: CGRect?
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            let bounds = windowScene.screen.bounds
            guard bounds.width > 1, bounds.height > 1 else { continue }
            if windowScene.activationState == .foregroundActive {
                return bounds
            }
            if fallbackSceneBounds == nil {
                fallbackSceneBounds = bounds
            }
        }
        if let fallbackSceneBounds {
            return fallbackSceneBounds
        }
        let cached = boundsState.withLock { $0.cachedMainScreenRect }
        if cached.width > 1, cached.height > 1 {
            return cached
        }
        if mainScreenWidth > 1, mainScreenHeight > 1 {
            return CGRect(x: 0, y: 0, width: mainScreenWidth, height: mainScreenHeight)
        }
        if let akFrame = AKInterface.shared?.mainScreenFrame,
           akFrame.width > 1,
           akFrame.height > 1 {
            return akFrame
        }
        return CGRect(x: 0, y: 0, width: mainScreenWidth, height: mainScreenHeight)
    }

    func initialize() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                Self.updateCachedScreenRect(Self.resolveActiveScreenBounds())
            }
        }
        AKInterface.shared?.setupWindowGeometryChanged? { _ in
            UIScreen.invalidateCachedAspectRatio()
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    Self.updateCachedScreenRect(Self.resolveActiveScreenBounds())
                }
            }
        }
        NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            nonisolated(unsafe) let unsafeNotification = notification
            MainActor.assumeIsolated {
                self?.handleWindowDidBecomeKey(unsafeNotification)
            }
        }
        NotificationCenter.default.addObserver(
            forName: Notification.Name("NSWindowDidEndLiveResizeNotification"),
            object: nil,
            queue: .main
        ) { _ in
            UIScreen.invalidateCachedAspectRatio()
            MainActor.assumeIsolated {
                Self.updateCachedScreenRect(Self.resolveActiveScreenBounds())
            }
        }
    }

    @MainActor
    private func handleWindowDidBecomeKey(_ notification: Notification) {
        UIScreen.invalidateCachedAspectRatio()
        let notificationWindow = notification.object as? UIWindow
        defer { Self.updateCachedScreenRect(Self.resolveActiveScreenBounds(preferredWindow: notificationWindow)) }
        guard let window = notificationWindow,
              !window.isHidden,
              !Self.isAuxiliaryKeyboardWindow(window),
              Self.isValidWindowBounds(window) else {
            return
        }
        Self.boundsState.withLock {
            $0.cachedWindow = window
        }
        let isStrict = PlaySettings.shared.strictEmulationMode
        if self.resizable || isStrict, let windowScene = window.windowScene {
            windowScene.sizeRestrictions?.minimumSize = CGSize(width: 0, height: 0)
            windowScene.sizeRestrictions?.maximumSize = CGSize(width: .max, height: .max)
        }
        guard !PTSafeMode.isActive,
              let akInterface = AKInterface.shared,
              isStrict || akInterface.isSequoiaOrNewer == true,
              !self.fullscreen,
              PlaySettings.shared.adaptiveDisplay else {
            return
        }
        let targetSize = CGSize(width: mainScreenWidth, height: mainScreenHeight)
        guard targetSize.width > 0, targetSize.height > 0 else { return }
        if isStrict {
            akInterface.setWindowAspectRatio?(targetSize)
        }
        let currentKey = PTStrictViewportFocusKey(
            sceneID: window.windowScene.map { ObjectIdentifier($0) },
            deviceModel: PlaySettings.shared.deviceModel as String,
            scaleMode: PlaySettings.shared.strictViewportScaleMode as String,
            targetSize: targetSize,
            screenFrame: akInterface.mainScreenFrame
        )
        let shouldApplySize = Self.boundsState.withLock { state in
            let decision = PTStrictViewportFocusPolicy.shouldApplyContentSizeOnFocus(
                isStrictEmulationMode: isStrict,
                lastAppliedFitScreenKey: state.lastAppliedStrictFitViewportKey,
                currentKey: currentKey
            )
            state.lastAppliedStrictFitViewportKey = decision.nextAppliedFitScreenKey
            return decision.shouldApply
        }
        if shouldApplySize {
            akInterface.setWindowContentSize?(targetSize)
        }
        let settingsData = PlaySettings.shared.settingsData
        if !isStrict,
           self.resizable,
           settingsData.resizableAspectRatioWidth > 0,
           settingsData.resizableAspectRatioHeight > 0 {
            akInterface.setWindowAspectRatio?(CGSize(
                width: CGFloat(settingsData.resizableAspectRatioWidth),
                height: CGFloat(settingsData.resizableAspectRatioHeight)
            ))
        }
    }

    private static func updateCachedScreenRect(_ rect: CGRect) {
        guard rect.width > 1, rect.height > 1 else { return }
        boundsState.withLock {
            $0.cachedMainScreenRect = rect
        }
    }

    @objc public static func frame(_ rect: CGRect) -> CGRect {
        return rect.toAspectRatio()
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
        if PlaySettings.shared.strictEmulationMode {
            return CGRect(x: 0, y: 0, width: mainScreenWidth, height: mainScreenHeight)
        }
        if Thread.isMainThread {
            let b = MainActor.assumeIsolated { Self.resolveActiveScreenBounds() }
            Self.updateCachedScreenRect(b)
            return b
        }
        let (cached, fallbackWin) = Self.boundsState.withLock {
            ($0.cachedMainScreenRect, $0.lastKnownWindowBounds)
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

    @MainActor
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

    @MainActor
    var windowScene: UIWindowScene? {
        window?.windowScene
    }

    @MainActor
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

    @MainActor
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

    @MainActor
    private static func isValidWindowBounds(_ window: UIWindow) -> Bool {
        let b = window.bounds
        return b.width > 1 && b.height > 1
    }

    @MainActor
    private static func isAuxiliaryKeyboardWindow(_ window: UIWindow) -> Bool {
        PTWindowGeometryMath.isAuxiliaryUIWindow(className: NSStringFromClass(type(of: window)))
    }

    @MainActor
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

    @MainActor
    @objc public func activeTouchWindow() -> UIWindow? {
        return keyWindow ?? primaryWindow
    }

    @MainActor
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
        guard Thread.isMainThread else {
            return false
        }
        return MainActor.assumeIsolated {
            guard let win = activeTouchWindow(at: point) else {
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
    }

    @objc public static func boundsResizable(_ rect: CGRect) -> CGRect {
        if PlaySettings.shared.strictEmulationMode {
            return CGRect(x: 0, y: 0, width: mainScreenWidth, height: mainScreenHeight)
        }
        if Thread.isMainThread {
            if let winBounds = MainActor.assumeIsolated({ () -> CGRect? in
                let cachedWin = boundsState.withLock { $0.cachedWindow }
                if let cw = cachedWin,
                   !cw.isHidden,
                   cw.isKeyWindow,
                   cw.windowScene?.session.role == .windowApplication {
                    let b = cw.bounds
                    if b.width > 1, b.height > 1 {
                        return b
                    }
                }
                if let resolved = PlayScreen.shared.primaryWindow {
                    boundsState.withLock { $0.cachedWindow = resolved }
                    let b = resolved.bounds
                    if b.width > 1, b.height > 1 {
                        return b
                    }
                }
                return nil
            }) {
                boundsState.withLock { state in
                    if winBounds != state.lastMainKnownBounds {
                        state.lastMainKnownBounds = winBounds
                        state.lastKnownWindowBounds = winBounds
                        state.cachedMainScreenRect = winBounds
                    }
                }
                return winBounds
            }

            let lastMain = boundsState.withLock { $0.lastMainKnownBounds }
            if lastMain.width > 1, lastMain.height > 1 {
                return lastMain
            }
        } else {
            let cached = boundsState.withLock { $0.lastKnownWindowBounds }
            if cached.width > 1, cached.height > 1 {
                return cached
            }
        }
        let preservesManualBounds = !PlaySettings.shared.adaptiveDisplay || PlaySettings.shared.resizableWindow
        if preservesManualBounds,
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
        let sharedAppSel = NSSelectorFromString("sharedApplication")
        let windowsSel = NSSelectorFromString("windows")
        let uiWindowsSel = NSSelectorFromString("uiWindows")
        guard let nsAppClass: AnyClass = NSClassFromString("NSApplication"),
              let sharedMethod = class_getClassMethod(nsAppClass, sharedAppSel) else {
            return nil
        }
        typealias SharedAppIMP = @convention(c) (AnyClass, Selector) -> AnyObject?
        let sharedIMP = unsafeBitCast(method_getImplementation(sharedMethod), to: SharedAppIMP.self)
        guard let sharedApp = sharedIMP(nsAppClass, sharedAppSel) as? NSObject,
              sharedApp.responds(to: windowsSel),
              let nsWindows = sharedApp.perform(windowsSel)?.takeUnretainedValue() as? [NSObject] else {
            return nil
        }
        for candidate in nsWindows {
            guard candidate.responds(to: uiWindowsSel),
                  let uiWindows = candidate.perform(uiWindowsSel)?.takeUnretainedValue() as? [UIWindow] else {
                continue
            }
            if uiWindows.contains(self) {
                return candidate
            }
        }
        return nil
    }
}
