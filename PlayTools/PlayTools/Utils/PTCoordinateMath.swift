//
//  PTCoordinateMath.swift
//  PlayTools
//

import CoreGraphics
import Foundation

public enum PTCoordinateMath {
    public static func cursorPosition(
        mousePoint: CGPoint,
        windowFrame: CGRect,
        viewRect: CGRect,
        resizable: Bool,
        fullscreen: Bool,
        edgeMargin: CGFloat = 10
    ) -> CGPoint? {
        guard mousePoint.x.isFinite,
              mousePoint.y.isFinite,
              windowFrame.origin.x.isFinite,
              windowFrame.origin.y.isFinite,
              windowFrame.size.width.isFinite,
              windowFrame.size.height.isFinite,
              viewRect.origin.x.isFinite,
              viewRect.origin.y.isFinite,
              viewRect.size.width.isFinite,
              viewRect.size.height.isFinite,
              edgeMargin.isFinite,
              windowFrame.size.width >= 1,
              windowFrame.size.height >= 1,
              viewRect.size.width > 0,
              viewRect.size.height > 0 else {
            return nil
        }

        var point = mousePoint
        if resizable && !fullscreen {
            if point.x < edgeMargin || point.x > windowFrame.width - edgeMargin ||
                point.y < edgeMargin || point.y > windowFrame.height - edgeMargin {
                return nil
            }
        }

        let widthRate = viewRect.width / windowFrame.width
        let heightRate = viewRect.height / windowFrame.height
        let rate = max(widthRate, heightRate)
        guard rate.isFinite, rate > 0 else {
            return nil
        }

        if fullscreen {
            point.y -= (windowFrame.height - viewRect.height / rate) / 2
        }
        point.y *= rate
        point.y = viewRect.height - point.y
        if !point.y.isFinite || point.y < 0 {
            return nil
        }
        point.x -= (windowFrame.width - viewRect.width / rate) / 2
        point.x *= rate
        guard point.x.isFinite, point.y.isFinite else {
            return nil
        }
        return point
    }

    public static func aspectRatio(width: CGFloat, height: CGFloat) -> CGFloat {
        guard width.isFinite, height.isFinite, width > 0, height > 0 else { return 0 }
        let ratio = width > height ? (width / height) : (height / width)
        return ratio.isFinite ? ratio : 0
    }

    public static func screenPercent(for size: CGSize) -> CGFloat {
        guard size.width.isFinite, size.height.isFinite else { return 0 }
        let pct = max(0, max(size.width, size.height)) / 100.0
        return pct.isFinite ? pct : 0
    }

    public static func relativeX(_ x: CGFloat, screenWidth: CGFloat) -> CGFloat {
        guard x.isFinite, screenWidth.isFinite, screenWidth > 0 else { return 0 }
        let value = x / screenWidth
        return value.isFinite ? value : 0
    }

    public static func relativeY(_ y: CGFloat, screenHeight: CGFloat) -> CGFloat {
        guard y.isFinite, screenHeight.isFinite, screenHeight > 0 else { return 0 }
        let value = y / screenHeight
        return value.isFinite ? value : 0
    }

    public static func relativeSize(_ size: CGFloat, screenSize: CGSize) -> CGFloat {
        guard size.isFinite else { return 0 }
        let pct = screenPercent(for: screenSize)
        guard pct > 0 else { return 0 }
        let value = size / pct
        return value.isFinite ? value : 0
    }

    public static func absoluteX(_ relativeX: CGFloat, screenWidth: CGFloat) -> CGFloat {
        guard relativeX.isFinite, screenWidth.isFinite else { return 0 }
        let value = relativeX * screenWidth
        return value.isFinite ? value : 0
    }

    public static func absoluteY(_ relativeY: CGFloat, screenHeight: CGFloat) -> CGFloat {
        guard relativeY.isFinite, screenHeight.isFinite else { return 0 }
        let value = relativeY * screenHeight
        return value.isFinite ? value : 0
    }

    public static func absoluteSize(_ relativeSize: CGFloat, screenSize: CGSize) -> CGFloat {
        guard relativeSize.isFinite else { return 0 }
        let value = relativeSize * screenPercent(for: screenSize)
        return value.isFinite ? value : 0
    }

    public static func isPointOutOfBounds(_ point: CGPoint, boundsSize: CGSize) -> Bool {
        guard point.x.isFinite,
              point.y.isFinite,
              boundsSize.width.isFinite,
              boundsSize.height.isFinite,
              boundsSize.width >= 0,
              boundsSize.height >= 0 else {
            return true
        }
        return point.x < 0 || point.y < 0 || point.x > boundsSize.width || point.y > boundsSize.height
    }

    public static func velocityScaler(
        predicted: CGPoint,
        current: CGPoint,
        boundsSize: CGSize
    ) -> CGFloat {
        guard predicted.x.isFinite,
              predicted.y.isFinite,
              current.x.isFinite,
              current.y.isFinite,
              boundsSize.width.isFinite,
              boundsSize.height.isFinite,
              boundsSize.width > 0,
              boundsSize.height > 0,
              !isPointOutOfBounds(current, boundsSize: boundsSize) else {
            return 0
        }
        var scaler: CGFloat = 1.0
        let dx = predicted.x - current.x
        if dx != 0 {
            if predicted.x < 0 {
                scaler = min(scaler, (0 - current.x) / dx)
            } else if predicted.x > boundsSize.width {
                scaler = min(scaler, (boundsSize.width - current.x) / dx)
            }
        }
        let dy = predicted.y - current.y
        if dy != 0 {
            if predicted.y < 0 {
                scaler = min(scaler, (0 - current.y) / dy)
            } else if predicted.y > boundsSize.height {
                scaler = min(scaler, (boundsSize.height - current.y) / dy)
            }
        }
        return scaler.isFinite ? max(0, scaler) : 0
    }

    public static func applySwipeDelta(
        _ location: CGPoint,
        deltaX: CGFloat,
        deltaY: CGFloat
    ) -> CGPoint {
        guard location.x.isFinite, location.y.isFinite else {
            return .zero
        }
        guard deltaX.isFinite, deltaY.isFinite else {
            return location
        }
        let nextX = location.x + deltaX
        let nextY = location.y - deltaY
        guard nextX.isFinite, nextY.isFinite else {
            return location
        }
        return CGPoint(x: nextX, y: nextY)
    }

    public static func scaledCameraDelta(
        deltaX: CGFloat,
        deltaY: CGFloat,
        sensitivity: Float
    ) -> CGVector {
        guard deltaX.isFinite, deltaY.isFinite, sensitivity.isFinite else {
            return .zero
        }
        let sensy = CGFloat(sensitivity * 0.6)
        let dx = deltaX * sensy
        let dy = -deltaY * sensy
        guard sensy.isFinite, dx.isFinite, dy.isFinite else {
            return .zero
        }
        return CGVector(dx: dx, dy: dy)
    }

    public static func clampPoint(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        guard point.x.isFinite,
              point.y.isFinite,
              !bounds.isNull,
              !bounds.isInfinite,
              bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.size.width.isFinite,
              bounds.size.height.isFinite,
              bounds.size.width >= 0,
              bounds.size.height >= 0 else {
            return .zero
        }
        return CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    public static func isWithinDeadZone(
        from previous: CGPoint,
        to current: CGPoint,
        deadZone: CGFloat
    ) -> Bool {
        guard previous.x.isFinite,
              previous.y.isFinite,
              current.x.isFinite,
              current.y.isFinite,
              deadZone.isFinite,
              deadZone >= 0 else {
            return false
        }
        return hypot(current.x - previous.x, current.y - previous.y) <= deadZone
    }
}

public struct PTMouseMoveCoalescer {
    public let minIntervalNanoseconds: UInt64
    public let deadZone: CGFloat
    private var lastFlushNanoseconds: UInt64
    public private(set) var accumulatedDelta: CGVector = .zero

    public init(
        maxPollingRate: Int,
        deadZone: CGFloat = 0,
        initialTimestampNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        let clampedRate = max(1, maxPollingRate)
        self.minIntervalNanoseconds = UInt64(1_000_000_000 / clampedRate)
        self.deadZone = (deadZone.isFinite && deadZone >= 0) ? deadZone : 0
        self.lastFlushNanoseconds = initialTimestampNanoseconds
    }

    public mutating func ingest(
        deltaX: CGFloat,
        deltaY: CGFloat,
        timestampNanoseconds: UInt64
    ) -> CGVector? {
        guard deltaX.isFinite, deltaY.isFinite else {
            return nil
        }
        accumulatedDelta.dx += deltaX
        accumulatedDelta.dy += deltaY

        let nextAllowed = lastFlushNanoseconds &+ minIntervalNanoseconds
        guard timestampNanoseconds >= nextAllowed else {
            return nil
        }

        let magnitude = hypot(accumulatedDelta.dx, accumulatedDelta.dy)
        guard magnitude.isFinite else {
            accumulatedDelta = .zero
            return nil
        }
        if deadZone > 0 && magnitude <= deadZone {
            return nil
        }

        lastFlushNanoseconds = timestampNanoseconds
        let output = accumulatedDelta
        accumulatedDelta = .zero
        return output
    }

    public mutating func reset(timestampNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        accumulatedDelta = .zero
        lastFlushNanoseconds = timestampNanoseconds
    }
}

public enum PTWindowGeometryMath {
    public static func clampedContentSize(
        requested: CGSize,
        visibleScreenFrame: CGRect,
        aspectRatio: CGSize? = nil,
        titleBarHeight: CGFloat = 0
    ) -> CGSize {
        guard requested.width.isFinite,
              requested.height.isFinite,
              requested.width > 0,
              requested.height > 0 else {
            return .zero
        }

        let safeTitleHeight = (titleBarHeight.isFinite && titleBarHeight > 0) ? titleBarHeight : 0
        let hasValidWidth = visibleScreenFrame.width.isFinite && visibleScreenFrame.width > 0
        let hasValidHeight = visibleScreenFrame.height.isFinite && visibleScreenFrame.height > 0
        let rawMaxW = hasValidWidth ? visibleScreenFrame.width : requested.width
        let rawMaxH = hasValidHeight ? max(1.0, visibleScreenFrame.height - safeTitleHeight) : requested.height
        let maxW = (hasValidWidth && rawMaxW >= 1.0) ? floor(rawMaxW) : rawMaxW
        let maxH = (hasValidHeight && rawMaxH >= 1.0) ? floor(rawMaxH) : rawMaxH

        let targetW = requested.width
        var targetH = requested.height
        if let ratio = aspectRatio,
           ratio.width.isFinite,
           ratio.height.isFinite,
           ratio.width > 0,
           ratio.height > 0 {
            targetH = targetW * (ratio.height / ratio.width)
        }

        let scale = min(1.0, min(maxW / max(1.0, targetW), maxH / max(1.0, targetH)))
        var finalW = max(1.0, (targetW * scale).rounded())
        var finalH = max(1.0, (targetH * scale).rounded())
        if (hasValidWidth && finalW > maxW) || (hasValidHeight && finalH > maxH) {
            finalW = max(1.0, floor(targetW * scale))
            finalH = max(1.0, floor(targetH * scale))
        }
        guard finalW.isFinite, finalH.isFinite else {
            return .zero
        }
        return CGSize(width: finalW, height: finalH)
    }

    public struct StrictDeviceDisplaySpec: Equatable, Sendable {
        public let model: String
        public let nativePixelWidth: Int
        public let nativePixelHeight: Int
        public let nativeScale: Double
        public let isIPad: Bool

        public var portraitLogicalSize: CGSize {
            let shortPx = Double(min(nativePixelWidth, nativePixelHeight))
            let longPx = Double(max(nativePixelWidth, nativePixelHeight))
            return CGSize(
                width: (shortPx / nativeScale).rounded(),
                height: (longPx / nativeScale).rounded()
            )
        }

        public func logicalSize(orientation: String) -> CGSize {
            orientedSize(baseSize: portraitLogicalSize, portrait: isPortrait(orientation))
        }

        private func isPortrait(_ orientation: String) -> Bool {
            orientation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "portrait"
        }

        private func orientedSize(baseSize: CGSize, portrait: Bool) -> CGSize {
            PTWindowGeometryMath.orientedSize(baseSize: baseSize, portrait: portrait)
        }

        private static let table: [String: StrictDeviceDisplaySpec] = [
            "iPad6,7": StrictDeviceDisplaySpec(
                model: "iPad6,7", nativePixelWidth: 2048, nativePixelHeight: 2732, nativeScale: 2.0, isIPad: true
            ),
            "iPad8,6": StrictDeviceDisplaySpec(
                model: "iPad8,6", nativePixelWidth: 2048, nativePixelHeight: 2732, nativeScale: 2.0, isIPad: true
            ),
            "iPad13,8": StrictDeviceDisplaySpec(
                model: "iPad13,8", nativePixelWidth: 2048, nativePixelHeight: 2732, nativeScale: 2.0, isIPad: true
            ),
            "iPad14,5": StrictDeviceDisplaySpec(
                model: "iPad14,5", nativePixelWidth: 2048, nativePixelHeight: 2732, nativeScale: 2.0, isIPad: true
            ),
            "iPad16,6": StrictDeviceDisplaySpec(
                model: "iPad16,6", nativePixelWidth: 2064, nativePixelHeight: 2752, nativeScale: 2.0, isIPad: true
            ),
            "iPad17,3": StrictDeviceDisplaySpec(
                model: "iPad17,3", nativePixelWidth: 2064, nativePixelHeight: 2752, nativeScale: 2.0, isIPad: true
            ),
            "iPhone12,5": StrictDeviceDisplaySpec(
                model: "iPhone12,5", nativePixelWidth: 1242, nativePixelHeight: 2688, nativeScale: 3.0, isIPad: false
            ),
            "iPhone14,3": StrictDeviceDisplaySpec(
                model: "iPhone14,3", nativePixelWidth: 1284, nativePixelHeight: 2778, nativeScale: 3.0, isIPad: false
            ),
            "iPhone15,3": StrictDeviceDisplaySpec(
                model: "iPhone15,3", nativePixelWidth: 1290, nativePixelHeight: 2796, nativeScale: 3.0, isIPad: false
            ),
            "iPhone16,2": StrictDeviceDisplaySpec(
                model: "iPhone16,2", nativePixelWidth: 1290, nativePixelHeight: 2796, nativeScale: 3.0, isIPad: false
            ),
            "iPhone17,2": StrictDeviceDisplaySpec(
                model: "iPhone17,2", nativePixelWidth: 1320, nativePixelHeight: 2868, nativeScale: 3.0, isIPad: false
            ),
            "iPhone18,2": StrictDeviceDisplaySpec(
                model: "iPhone18,2", nativePixelWidth: 1320, nativePixelHeight: 2868, nativeScale: 3.0, isIPad: false
            )
        ]

        private static let ios13CompatibleModels: Set<String> = ["iPad6,7", "iPad8,6", "iPhone12,5"]

        public static func normalizedReportedIOSVersion(_ raw: String?) -> String {
            switch (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "followhost", "follow_host", "host":
                return "followHost"
            case "compat18_3", "18.3", "ios18_3":
                return "compat18_3"
            case "compat13_7", "13.7", "ios13_7":
                return "compat13_7"
            default:
                return "automatic"
            }
        }

        public static func effectiveModel(
            for rawModel: String,
            normalizedReportedIOSVersion: String
        ) -> String {
            let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            let base = trimmed.isEmpty ? "iPad13,8" : trimmed
            guard normalizedReportedIOSVersion == "compat13_7", !ios13CompatibleModels.contains(base) else {
                return base
            }
            return base.hasPrefix("iPhone") ? "iPhone12,5" : "iPad8,6"
        }

        public static func resolve(forModel rawModel: String) -> StrictDeviceDisplaySpec {
            let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            if let exact = table[trimmed] {
                return exact
            }
            if trimmed.hasPrefix("iPhone"), let fallbackPhone = table["iPhone17,2"] {
                return fallbackPhone
            }
            return table["iPad13,8"] ?? StrictDeviceDisplaySpec(
                model: "iPad13,8", nativePixelWidth: 2048, nativePixelHeight: 2732, nativeScale: 2.0, isIPad: true
            )
        }
    }

    public struct StrictViewportWindowPlan: Equatable {
        public let logicalSceneSize: CGSize
        public let windowContentSize: CGSize
        public let lockedAspectRatio: CGSize
        public let allowsUserResize: Bool
    }

    public static func normalizedStrictOrientation(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "portrait" ? "portrait" : "landscape"
    }

    public static func normalizedStrictScaleMode(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "native1x" ? "native1x" : "fitScreen"
    }

    public static func strictViewportWindowPlan(
        logicalSceneSize: CGSize,
        scaleMode: String?,
        visibleScreenFrame: CGRect,
        titleBarHeight: CGFloat
    ) -> StrictViewportWindowPlan {
        let normalizedScale = normalizedStrictScaleMode(scaleMode)
        let clamped = clampedContentSize(
            requested: logicalSceneSize,
            visibleScreenFrame: visibleScreenFrame,
            titleBarHeight: titleBarHeight
        )
        let allowsResize = (normalizedScale == "fitScreen")
        return StrictViewportWindowPlan(
            logicalSceneSize: logicalSceneSize,
            windowContentSize: clamped,
            lockedAspectRatio: logicalSceneSize,
            allowsUserResize: allowsResize
        )
    }

    public static func orientedSize(baseSize: CGSize, portrait: Bool) -> CGSize {
        guard baseSize.width.isFinite,
              baseSize.height.isFinite,
              baseSize.width > 0,
              baseSize.height > 0 else {
            return .zero
        }
        let shortSide = min(baseSize.width, baseSize.height)
        let longSide = max(baseSize.width, baseSize.height)
        return portrait
            ? CGSize(width: shortSide, height: longSide)
            : CGSize(width: longSide, height: shortSide)
    }

    public static func centeredFrame(
        forContentSize contentSize: CGSize,
        currentFrame: CGRect,
        visibleScreenFrame: CGRect,
        titleBarHeight: CGFloat = 0
    ) -> CGRect {
        guard contentSize.width.isFinite,
              contentSize.height.isFinite,
              contentSize.width > 0,
              contentSize.height > 0 else {
            return currentFrame
        }
        let safeTitleHeight = (titleBarHeight.isFinite && titleBarHeight >= 0) ? titleBarHeight : 0
        let totalWidth = contentSize.width
        let totalHeight = contentSize.height + safeTitleHeight

        let centerX = currentFrame.width > 0 ? currentFrame.midX : visibleScreenFrame.midX
        let centerY = currentFrame.height > 0 ? currentFrame.midY : visibleScreenFrame.midY

        var originX = (centerX - totalWidth / 2.0).rounded()
        var originY = (centerY - totalHeight / 2.0).rounded()

        if visibleScreenFrame.width >= totalWidth && visibleScreenFrame.height >= totalHeight {
            originX = min(max(originX, visibleScreenFrame.minX), visibleScreenFrame.maxX - totalWidth)
            originY = min(max(originY, visibleScreenFrame.minY), visibleScreenFrame.maxY - totalHeight)
        }

        return CGRect(x: originX, y: originY, width: totalWidth, height: totalHeight)
    }

    public static func isAuxiliaryHostWindow(
        className: String,
        delegateClassName: String?,
        isPanel: Bool,
        hasTitleOrFullScreenStyle: Bool,
        frameSize: CGSize
    ) -> Bool {
        if isPanel {
            return true
        }
        if className.hasPrefix("TUINS")
            || className.contains("ToolbarFullScreen")
            || className.contains("FullScreenTransition")
            || className.contains("PopoverWindow")
            || className.contains("StatusBarWindow")
            || className.contains("MenuWindow") {
            return true
        }
        if delegateClassName?.contains("UINSSceneWindowController") == true
            || className.contains("UINSWindow") {
            return false
        }
        if !hasTitleOrFullScreenStyle {
            guard frameSize.width.isFinite,
                  frameSize.height.isFinite,
                  frameSize.width >= 120,
                  frameSize.height >= 120 else {
                return true
            }
        }
        return false
    }

    public static func isAuxiliaryUIWindow(className: String) -> Bool {
        className.contains("TextEffectsWindow")
            || className.contains("RemoteKeyboardWindow")
            || className.contains("InputWindow")
    }

    public static func isPointInTitleBar(
        pointInWindow: CGPoint,
        contentLayoutRect: CGRect
    ) -> Bool {
        guard pointInWindow.x.isFinite,
              pointInWindow.y.isFinite,
              contentLayoutRect.origin.x.isFinite,
              contentLayoutRect.origin.y.isFinite,
              contentLayoutRect.size.width.isFinite,
              contentLayoutRect.size.height.isFinite,
              contentLayoutRect.height > 0 else {
            return false
        }
        return pointInWindow.y > contentLayoutRect.maxY
    }

    public static func shouldTerminateOnWindowClose(
        isClosingWindowPrimary: Bool,
        otherVisiblePrimaryWindowCount: Int
    ) -> Bool {
        isClosingWindowPrimary && otherVisiblePrimaryWindowCount == 0
    }

    public struct TouchWindowCandidate {
        public let isHidden: Bool
        public let alpha: CGFloat
        public let isUserInteractionEnabled: Bool
        public let boundsSize: CGSize
        public let windowLevel: CGFloat

        public init(
            isHidden: Bool,
            alpha: CGFloat,
            isUserInteractionEnabled: Bool,
            boundsSize: CGSize,
            windowLevel: CGFloat
        ) {
            self.isHidden = isHidden
            self.alpha = alpha
            self.isUserInteractionEnabled = isUserInteractionEnabled
            self.boundsSize = boundsSize
            self.windowLevel = windowLevel
        }
    }

    public static func orderedTouchCandidateIndices(
        _ windows: [TouchWindowCandidate]
    ) -> [Int] {
        windows.enumerated()
            .filter { _, win in
                !win.isHidden
                    && win.alpha.isFinite
                    && win.alpha > 0.01
                    && win.isUserInteractionEnabled
                    && win.boundsSize.width.isFinite
                    && win.boundsSize.height.isFinite
                    && win.boundsSize.width > 1
                    && win.boundsSize.height > 1
            }
            .sorted { lhs, rhs in
                if lhs.element.windowLevel != rhs.element.windowLevel {
                    return lhs.element.windowLevel > rhs.element.windowLevel
                }
                return lhs.offset > rhs.offset
            }
            .map(\.offset)
    }

    public static func pointInWindow(
        scenePoint: CGPoint,
        windowOrigin: CGPoint
    ) -> CGPoint {
        guard scenePoint.x.isFinite,
              scenePoint.y.isFinite,
              windowOrigin.x.isFinite,
              windowOrigin.y.isFinite else {
            return scenePoint
        }
        return CGPoint(
            x: scenePoint.x - windowOrigin.x,
            y: scenePoint.y - windowOrigin.y
        )
    }
}

public enum PTControlTransitionInvalidation: Equatable {
    case none
    case nonButtonActions
    case allActions
}

public enum PTControlModeTransitionPolicy {
    public static func usesDirectTouchMouse(modeRawValue: String) -> Bool {
        modeRawValue == "arbitraryClick" || modeRawValue == "textInput"
    }

    // swiftlint:disable:next function_parameter_count
    public static func invalidation(
        from previousModeRawValue: String,
        to nextModeRawValue: String,
        wasCursorHidden: Bool,
        nextCursorHidden: Bool,
        isInitial: Bool,
        keymappingEnabled: Bool
    ) -> PTControlTransitionInvalidation {
        guard !isInitial, keymappingEnabled else {
            return .none
        }
        if nextModeRawValue == "off" || nextModeRawValue == "editor" {
            if previousModeRawValue != nextModeRawValue || wasCursorHidden != nextCursorHidden {
                return .allActions
            }
            return .none
        }
        if wasCursorHidden != nextCursorHidden {
            return .nonButtonActions
        }
        let prevTouch = usesDirectTouchMouse(modeRawValue: previousModeRawValue)
        let nextTouch = usesDirectTouchMouse(modeRawValue: nextModeRawValue)
        if previousModeRawValue != nextModeRawValue && prevTouch != nextTouch {
            return .nonButtonActions
        }
        return .none
    }
}

public struct PTLongPressStateMachine {
    public static let defaultMinimumHoldMilliseconds: Int = 650

    public private(set) var isActive: Bool = false
    public private(set) var isPhysicalButtonDown: Bool = false
    public private(set) var minHoldCompleted: Bool = false
    public private(set) var generation: UInt64 = 0
    public private(set) var anchorPoint: CGPoint = .zero

    public init() {}

    public mutating func begin(at point: CGPoint) -> (cancelledPrevious: Bool, generation: UInt64) {
        let cancelledPrevious = isActive
        generation &+= 1
        isActive = true
        isPhysicalButtonDown = true
        minHoldCompleted = false
        anchorPoint = point
        return (cancelledPrevious, generation)
    }

    public mutating func allowMove(to point: CGPoint) -> Bool {
        guard isActive, isPhysicalButtonDown, minHoldCompleted else {
            return false
        }
        anchorPoint = point
        return true
    }

    public mutating func onMinimumHoldElapsed(generation: UInt64) -> Bool {
        guard isActive, self.generation == generation else {
            return false
        }
        minHoldCompleted = true
        guard !isPhysicalButtonDown else {
            return false
        }
        isActive = false
        return true
    }

    public mutating func onPhysicalRelease() -> Bool {
        guard isActive else {
            isPhysicalButtonDown = false
            return false
        }
        isPhysicalButtonDown = false
        guard minHoldCompleted else {
            return false
        }
        isActive = false
        return true
    }

    public mutating func finishEarly() -> Bool {
        let wasActive = isActive
        isActive = false
        isPhysicalButtonDown = false
        minHoldCompleted = false
        generation &+= 1
        return wasActive
    }

    public mutating func invalidate() -> Bool {
        finishEarly()
    }
}
