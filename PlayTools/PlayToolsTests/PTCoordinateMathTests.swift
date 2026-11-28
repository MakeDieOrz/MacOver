import CoreGraphics
import Foundation
import Synchronization
import Testing

@Suite
struct PTCoordinateMathTests {
    @Test
    func cursorPositionCenteredAndAspectRatio() throws {
        let viewRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windowFrame = CGRect(x: 0, y: 0, width: 960, height: 540)

        let center = try #require(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 480, y: 270),
            windowFrame: windowFrame,
            viewRect: viewRect,
            resizable: false,
            fullscreen: false
        ))
        #expect(abs(center.x - 960) <= 0.001)
        #expect(abs(center.y - 540) <= 0.001)

        // Wide 16:10 window with 16:9 content (horizontal pillarbox centering)
        let wideWindow = CGRect(x: 0, y: 0, width: 1200, height: 540)
        let wideCenter = try #require(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 600, y: 270),
            windowFrame: wideWindow,
            viewRect: viewRect,
            resizable: false,
            fullscreen: false
        ))
        #expect(abs(wideCenter.x - 960) <= 0.001)
        #expect(abs(wideCenter.y - 540) <= 0.001)

        // Tall 4:3 window in fullscreen vs non-fullscreen
        let tallWindow = CGRect(x: 0, y: 0, width: 960, height: 720)
        let fsCenter = try #require(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 480, y: 360),
            windowFrame: tallWindow,
            viewRect: viewRect,
            resizable: true,
            fullscreen: true
        ))
        #expect(abs(fsCenter.x - 960) <= 0.001)
        #expect(abs(fsCenter.y - 540) <= 0.001)

        // Traffic light rejection when non-fullscreen and point.y * rate > viewRect.height
        let aboveTrafficLight = PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 480, y: 600),
            windowFrame: tallWindow,
            viewRect: viewRect,
            resizable: false,
            fullscreen: false
        )
        #expect(aboveTrafficLight == nil)
    }

    @Test
    func cursorPositionEdgeMarginAndDegenerateBounds() {
        let viewRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windowFrame = CGRect(x: 0, y: 0, width: 960, height: 540)

        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 9.9, y: 100),
            windowFrame: windowFrame,
            viewRect: viewRect,
            resizable: true,
            fullscreen: false
        ) == nil)
        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 10.0, y: 100),
            windowFrame: windowFrame,
            viewRect: viewRect,
            resizable: true,
            fullscreen: false
        ) != nil)
        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 100, y: 100),
            windowFrame: CGRect(x: 0, y: 0, width: 0.5, height: 540),
            viewRect: viewRect,
            resizable: false,
            fullscreen: false
        ) == nil)
        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 100, y: 100),
            windowFrame: windowFrame,
            viewRect: .zero,
            resizable: false,
            fullscreen: false
        ) == nil)
    }

    @Test
    func aspectRatioAndRelativeAbsoluteConversions() {
        #expect(abs(PTCoordinateMath.aspectRatio(width: 1920, height: 1080) - (1920.0 / 1080.0)) <= 0.0001)
        #expect(abs(PTCoordinateMath.aspectRatio(width: 1080, height: 1920) - (1920.0 / 1080.0)) <= 0.0001)
        #expect(abs(PTCoordinateMath.aspectRatio(width: 1000, height: 1000) - 1.0) <= 0.0001)
        #expect(PTCoordinateMath.aspectRatio(width: 0, height: 1080) == 0)
        #expect(PTCoordinateMath.aspectRatio(width: -10, height: 1080) == 0)

        let screenSize = CGSize(width: 1920, height: 1080)
        #expect(abs(PTCoordinateMath.screenPercent(for: screenSize) - 19.2) <= 0.0001)

        let relX = PTCoordinateMath.relativeX(960, screenWidth: screenSize.width)
        let relY = PTCoordinateMath.relativeY(270, screenHeight: screenSize.height)
        let relSize = PTCoordinateMath.relativeSize(96, screenSize: screenSize)
        #expect(abs(PTCoordinateMath.absoluteX(relX, screenWidth: screenSize.width) - 960) <= 0.0001)
        #expect(abs(PTCoordinateMath.absoluteY(relY, screenHeight: screenSize.height) - 270) <= 0.0001)
        #expect(abs(PTCoordinateMath.absoluteSize(relSize, screenSize: screenSize) - 96) <= 0.0001)

        #expect(PTCoordinateMath.relativeX(10, screenWidth: 0) == 0)
        #expect(PTCoordinateMath.relativeY(10, screenHeight: 0) == 0)
        #expect(PTCoordinateMath.relativeSize(10, screenSize: .zero) == 0)
    }

    @Test
    func swipeOutOfBoundsVelocityScalerAndDelta() {
        let bounds = CGSize(width: 1000, height: 600)
        #expect(!PTCoordinateMath.isPointOutOfBounds(CGPoint(x: 0, y: 0), boundsSize: bounds))
        #expect(!PTCoordinateMath.isPointOutOfBounds(CGPoint(x: 1000, y: 600), boundsSize: bounds))
        #expect(PTCoordinateMath.isPointOutOfBounds(CGPoint(x: -0.1, y: 10), boundsSize: bounds))
        #expect(PTCoordinateMath.isPointOutOfBounds(CGPoint(x: 1000.1, y: 10), boundsSize: bounds))
        #expect(PTCoordinateMath.isPointOutOfBounds(CGPoint(x: 10, y: -1), boundsSize: bounds))
        #expect(PTCoordinateMath.isPointOutOfBounds(CGPoint(x: 10, y: 601), boundsSize: bounds))

        let inBoundsScaler = PTCoordinateMath.velocityScaler(
            predicted: CGPoint(x: 800, y: 500),
            current: CGPoint(x: 500, y: 300),
            boundsSize: bounds
        )
        #expect(abs(inBoundsScaler - 1.0) <= 0.0001)

        let leftOverflow = PTCoordinateMath.velocityScaler(
            predicted: CGPoint(x: -100, y: 300),
            current: CGPoint(x: 100, y: 300),
            boundsSize: bounds
        )
        #expect(abs(leftOverflow - 0.5) <= 0.0001)

        let diagonalOverflow = PTCoordinateMath.velocityScaler(
            predicted: CGPoint(x: 1500, y: 1200),
            current: CGPoint(x: 500, y: 400),
            boundsSize: bounds
        )
        #expect(abs(diagonalOverflow - 0.25) <= 0.0001)

        let zeroDelta = PTCoordinateMath.velocityScaler(
            predicted: CGPoint(x: 500, y: 300),
            current: CGPoint(x: 500, y: 300),
            boundsSize: bounds
        )
        #expect(abs(zeroDelta - 1.0) <= 0.0001)

        let moved = PTCoordinateMath.applySwipeDelta(CGPoint(x: 100, y: 200), deltaX: 15, deltaY: 25)
        #expect(moved == CGPoint(x: 115, y: 175))
    }

    @Test
    func cameraDeltaAndClampPoint() {
        let delta = PTCoordinateMath.scaledCameraDelta(deltaX: 10, deltaY: -20, sensitivity: 5.0)
        #expect(abs(delta.dx - 30.0) <= 0.0001)
        #expect(abs(delta.dy - 60.0) <= 0.0001)

        let zeroSens = PTCoordinateMath.scaledCameraDelta(deltaX: 10, deltaY: 20, sensitivity: 0)
        #expect(zeroSens == .zero)

        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        #expect(PTCoordinateMath.clampPoint(CGPoint(x: -5, y: 90), to: rect) == CGPoint(x: 10, y: 70))
        #expect(PTCoordinateMath.clampPoint(CGPoint(x: 50, y: 40), to: rect) == CGPoint(x: 50, y: 40))
        #expect(PTCoordinateMath.clampPoint(CGPoint(x: 50, y: 40), to: .null) == .zero)
    }

    @Test
    func nonFiniteAndDegenerateGeometryEdges() {
        let validView = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let validWindow = CGRect(x: 0, y: 0, width: 960, height: 540)

        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: CGFloat.nan, y: 100),
            windowFrame: validWindow,
            viewRect: validView,
            resizable: false,
            fullscreen: false
        ) == nil)
        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: CGFloat.infinity, y: 100),
            windowFrame: validWindow,
            viewRect: validView,
            resizable: false,
            fullscreen: false
        ) == nil)
        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 100, y: 100),
            windowFrame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 540),
            viewRect: validView,
            resizable: false,
            fullscreen: false
        ) == nil)
        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 100, y: 100),
            windowFrame: validWindow,
            viewRect: CGRect(x: 0, y: 0, width: 1920, height: CGFloat.nan),
            resizable: false,
            fullscreen: false
        ) == nil)
        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 100, y: 100),
            windowFrame: CGRect(x: 100, y: 100, width: -50, height: -50),
            viewRect: validView,
            resizable: false,
            fullscreen: false
        ) == nil)
        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 5, y: 5),
            windowFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
            viewRect: validView,
            resizable: true,
            fullscreen: false,
            edgeMargin: 10
        ) == nil)

        let negSize = CGSize(width: -100, height: -50)
        #expect(PTCoordinateMath.screenPercent(for: negSize) == 0)
        #expect(PTCoordinateMath.absoluteSize(10, screenSize: negSize) == 0)
        #expect(PTCoordinateMath.aspectRatio(width: .nan, height: 100) == 0)

        #expect(
            PTCoordinateMath.velocityScaler(
                predicted: CGPoint(x: 100, y: 100),
                current: CGPoint(x: 50, y: 50),
                boundsSize: .zero
            ) == 0
        )
        #expect(
            PTCoordinateMath.velocityScaler(
                predicted: CGPoint(x: 100, y: 100),
                current: CGPoint(x: -10, y: 50),
                boundsSize: CGSize(width: 960, height: 540)
            ) == 0
        )
        #expect(
            PTCoordinateMath.velocityScaler(
                predicted: CGPoint(x: -.infinity, y: 100),
                current: CGPoint(x: 50, y: 50),
                boundsSize: CGSize(width: 960, height: 540)
            ) == 0
        )

        #expect(PTCoordinateMath.clampPoint(CGPoint(x: CGFloat.nan, y: 50), to: validWindow) == .zero)
        #expect(PTCoordinateMath.clampPoint(CGPoint(x: 50, y: 50), to: .infinite) == .zero)
        #expect(
            PTCoordinateMath.clampPoint(CGPoint(x: 50, y: 50), to: CGRect(x: 100, y: 100, width: -50, height: -50)) ==
                .zero
        )

        // Subnormal underflow & finite overflow guards (G-02)
        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 500, y: 500),
            windowFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            viewRect: CGRect(
                x: 0,
                y: 0,
                width: CGFloat.leastNonzeroMagnitude,
                height: CGFloat.leastNonzeroMagnitude
            ),
            resizable: false,
            fullscreen: false
        ) == nil)
        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: -1e308, y: 100),
            windowFrame: validWindow,
            viewRect: validView,
            resizable: false,
            fullscreen: false
        ) == nil)

        #expect(PTCoordinateMath.aspectRatio(width: 1e308, height: 0.5) == 0)
        #expect(PTCoordinateMath.relativeX(1e308, screenWidth: 0.5) == 0)
        #expect(PTCoordinateMath.relativeY(1e308, screenHeight: 0.5) == 0)
        #expect(PTCoordinateMath.relativeSize(1e308, screenSize: CGSize(width: 0.5, height: 0.5)) == 0)
        #expect(PTCoordinateMath.absoluteX(1e308, screenWidth: 10) == 0)
        #expect(PTCoordinateMath.absoluteY(1e308, screenHeight: 10) == 0)
        #expect(PTCoordinateMath.absoluteSize(1e308, screenSize: CGSize(width: 1000, height: 1000)) == 0)

        #expect(
            PTCoordinateMath.scaledCameraDelta(deltaX: .nan, deltaY: .infinity, sensitivity: 1.0) == .zero
        )
        #expect(
            PTCoordinateMath.scaledCameraDelta(deltaX: 10, deltaY: 20, sensitivity: Float.nan) == .zero
        )
        #expect(
            PTCoordinateMath.scaledCameraDelta(deltaX: 1e308, deltaY: 1, sensitivity: 10.0) == .zero
        )

        #expect(
            PTCoordinateMath.applySwipeDelta(CGPoint(x: CGFloat.nan, y: 10), deltaX: 1, deltaY: 2) == .zero
        )
        #expect(
            PTCoordinateMath.applySwipeDelta(CGPoint(x: 100, y: 200), deltaX: .nan, deltaY: 2) ==
                CGPoint(x: 100, y: 200)
        )
        #expect(
            PTCoordinateMath.applySwipeDelta(CGPoint(x: 1e308, y: 200), deltaX: 1e308, deltaY: 0) ==
                CGPoint(x: 1e308, y: 200)
        )
    }

    @Test
    func deadZoneAndMouseMoveCoalescer() throws {
        #expect(PTCoordinateMath.isWithinDeadZone(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 10.15, y: 10.15),
            deadZone: 0.25
        ))
        #expect(!PTCoordinateMath.isWithinDeadZone(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 11, y: 10),
            deadZone: 0.25
        ))
        #expect(!PTCoordinateMath.isWithinDeadZone(
            from: CGPoint(x: CGFloat.nan, y: 10),
            to: CGPoint(x: 10, y: 10),
            deadZone: 0.25
        ))

        // 125 Hz -> 8_000_000 ns interval
        var coalescer = PTMouseMoveCoalescer(
            maxPollingRate: 125,
            deadZone: 0.5,
            initialTimestampNanoseconds: 0
        )
        // Before 8ms: accumulates
        let before2ms = coalescer.ingest(deltaX: 2.0, deltaY: 1.0, timestampNanoseconds: 2_000_000)
        #expect(before2ms == nil)
        let before3ms = coalescer.ingest(deltaX: .nan, deltaY: 1.0, timestampNanoseconds: 3_000_000)
        #expect(before3ms == nil)
        let before8ms = coalescer.ingest(deltaX: 3.0, deltaY: -0.5, timestampNanoseconds: 7_999_999)
        #expect(before8ms == nil)

        // At 8ms boundary: flushes accumulated sum (5.0, 0.5)
        let flushedRaw = coalescer.ingest(deltaX: 1.0, deltaY: 1.5, timestampNanoseconds: 8_000_000)
        let flushed = try #require(flushedRaw)
        #expect(abs(flushed.dx - 6.0) <= 0.0001)
        #expect(abs(flushed.dy - 2.0) <= 0.0001)

        // Below dead-zone even after 8ms: stays held until exceeding deadZone
        let subDeadZone = coalescer.ingest(deltaX: 0.2, deltaY: 0.2, timestampNanoseconds: 20_000_000)
        #expect(subDeadZone == nil)
        let secondRaw = coalescer.ingest(deltaX: 0.5, deltaY: 0.0, timestampNanoseconds: 28_000_000)
        let second = try #require(secondRaw)
        #expect(abs(second.dx - 0.7) <= 0.0001)
        #expect(abs(second.dy - 0.2) <= 0.0001)
    }

    @Test
    func windowGeometryMathClampingOrientationAndCentering() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let clamped = PTWindowGeometryMath.clampedContentSize(
            requested: CGSize(width: 2560, height: 1440),
            visibleScreenFrame: visible,
            aspectRatio: CGSize(width: 16, height: 9)
        )
        #expect(clamped.width <= visible.width)
        #expect(clamped.height <= visible.height)
        #expect(abs((clamped.width / clamped.height) - (16.0 / 9.0)) <= 0.02)

        #expect(PTWindowGeometryMath.clampedContentSize(requested: .zero, visibleScreenFrame: visible) == .zero)
        #expect(
            PTWindowGeometryMath.clampedContentSize(
                requested: CGSize(width: CGFloat.nan, height: 600),
                visibleScreenFrame: visible
            ) == .zero
        )

        let base = CGSize(width: 1920, height: 1080)
        #expect(
            PTWindowGeometryMath.orientedSize(baseSize: base, portrait: true) == CGSize(width: 1080, height: 1920)
        )
        #expect(
            PTWindowGeometryMath.orientedSize(baseSize: base, portrait: false) == CGSize(width: 1920, height: 1080)
        )

        let centered = PTWindowGeometryMath.centeredFrame(
            forContentSize: CGSize(width: 800, height: 600),
            currentFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            visibleScreenFrame: visible,
            titleBarHeight: 28
        )
        #expect(centered.minX >= visible.minX)
        #expect(centered.minY >= visible.minY)
        #expect(centered.maxX <= visible.maxX)
        #expect(centered.maxY <= visible.maxY)
        #expect(centered.width == 800)
        #expect(centered.height == 628)
    }

    @Test
    func touchInputPipelineLatencyUnder4Milliseconds() {
        let viewRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windowFrame = CGRect(x: 0, y: 0, width: 960, height: 540)
        var coalescer = PTMouseMoveCoalescer(maxPollingRate: 240, deadZone: 0.25, initialTimestampNanoseconds: 0)

        let startNs = DispatchTime.now().uptimeNanoseconds
        var timestamp: UInt64 = 0
        var resolvedCount = 0
        for i in 0..<1000 {
            timestamp &+= 5_000_000
            if let delta = coalescer.ingest(deltaX: 1.5, deltaY: -0.75, timestampNanoseconds: timestamp) {
                let pt = CGPoint(x: Double(i % 900) + 30 + delta.dx, y: Double(i % 500) + 20 + delta.dy)
                if PTCoordinateMath.cursorPosition(
                    mousePoint: pt,
                    windowFrame: windowFrame,
                    viewRect: viewRect,
                    resizable: true,
                    fullscreen: false
                ) != nil {
                    resolvedCount += 1
                }
            }
        }
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds &- startNs) / 1_000_000.0
        #expect(resolvedCount > 900)
        #expect(elapsedMs < 4.0)
    }

    @Test
    func auxiliaryHostAndUIWindowFiltering() {
        // macOS TextInputUI floating cursor window must be rejected
        #expect(PTWindowGeometryMath.isAuxiliaryHostWindow(
            className: "TUINSWindow",
            delegateClassName: "TUINSWindow",
            isPanel: false,
            hasTitleOrFullScreenStyle: false,
            frameSize: CGSize(width: 64, height: 64)
        ))

        // NSPanel (open/save panels, IME candidate panels) must be rejected
        #expect(PTWindowGeometryMath.isAuxiliaryHostWindow(
            className: "NSOpenPanel",
            delegateClassName: nil,
            isPanel: true,
            hasTitleOrFullScreenStyle: true,
            frameSize: CGSize(width: 800, height: 600)
        ))

        // Primary Mac Catalyst scene host window must be accepted
        #expect(!PTWindowGeometryMath.isAuxiliaryHostWindow(
            className: "UINSWindow",
            delegateClassName: "UINSSceneWindowController",
            isPanel: false,
            hasTitleOrFullScreenStyle: true,
            frameSize: CGSize(width: 1024, height: 796)
        ))

        // UIKit keyboard/effects overlay windows vs normal content windows
        #expect(PTWindowGeometryMath.isAuxiliaryUIWindow(className: "UITextEffectsWindow"))
        #expect(PTWindowGeometryMath.isAuxiliaryUIWindow(className: "UIRemoteKeyboardWindow"))
        #expect(PTWindowGeometryMath.isAuxiliaryUIWindow(className: "PTCustomInputWindow"))
        #expect(!PTWindowGeometryMath.isAuxiliaryUIWindow(className: "UIWindow"))
    }

    @Test
    func touchWindowOrderingAndPointTranslation() {
        let candidates: [PTWindowGeometryMath.TouchWindowCandidate] = [
            // 0: Primary content UIWindow at level 0
            .init(
                isHidden: false,
                alpha: 1.0,
                isUserInteractionEnabled: true,
                boundsSize: CGSize(width: 1025, height: 769),
                windowLevel: 0
            ),
            // 1: Hidden overlay window at high level 1001 (must be skipped)
            .init(
                isHidden: true,
                alpha: 1.0,
                isUserInteractionEnabled: true,
                boundsSize: CGSize(width: 1025, height: 769),
                windowLevel: 1001
            ),
            // 2: Visible UITextEffectsWindow (accessory toolbar host) at level 10
            .init(
                isHidden: false,
                alpha: 1.0,
                isUserInteractionEnabled: true,
                boundsSize: CGSize(width: 1025, height: 769),
                windowLevel: 10
            ),
            // 3: Another normal-level modal window added after window 0
            .init(
                isHidden: false,
                alpha: 1.0,
                isUserInteractionEnabled: true,
                boundsSize: CGSize(width: 400, height: 300),
                windowLevel: 0
            )
        ]

        let ordered = PTWindowGeometryMath.orderedTouchCandidateIndices(candidates)
        #expect(ordered == [2, 3, 0])

        let translated = PTWindowGeometryMath.pointInWindow(
            scenePoint: CGPoint(x: 250, y: 420),
            windowOrigin: CGPoint(x: 50, y: 100)
        )
        #expect(translated == CGPoint(x: 200, y: 320))
    }

    @Test
    func controlModeTransitionPolicyPreservesInFlightTextInputClick() {
        // Initial startup mode transition does not invalidate actions
        #expect(
            PTControlModeTransitionPolicy.invalidation(
                from: "off",
                to: "arbitraryClick",
                wasCursorHidden: false,
                nextCursorHidden: false,
                isInitial: true,
                keymappingEnabled: true
            ) == .none
        )

        // Tapping a text view triggers arbitraryClick -> textInput before leftMouseUp;
        // both modes share direct-touch FakeMouseAction so in-flight tap must complete cleanly.
        #expect(
            PTControlModeTransitionPolicy.invalidation(
                from: "arbitraryClick",
                to: "textInput",
                wasCursorHidden: false,
                nextCursorHidden: false,
                isInitial: false,
                keymappingEnabled: true
            ) == .none
        )
        #expect(
            PTControlModeTransitionPolicy.invalidation(
                from: "textInput",
                to: "arbitraryClick",
                wasCursorHidden: false,
                nextCursorHidden: false,
                isInitial: false,
                keymappingEnabled: true
            ) == .none
        )

        // Switching to editor or off must invalidate all actions even when cursor stays visible
        #expect(
            PTControlModeTransitionPolicy.invalidation(
                from: "arbitraryClick",
                to: "editor",
                wasCursorHidden: false,
                nextCursorHidden: false,
                isInitial: false,
                keymappingEnabled: true
            ) == .allActions
        )
        #expect(
            PTControlModeTransitionPolicy.invalidation(
                from: "textInput",
                to: "off",
                wasCursorHidden: false,
                nextCursorHidden: false,
                isInitial: false,
                keymappingEnabled: true
            ) == .allActions
        )

        // Switching between direct-touch mode and cameraRotate must invalidate non-button actions
        #expect(
            PTControlModeTransitionPolicy.invalidation(
                from: "arbitraryClick",
                to: "cameraRotate",
                wasCursorHidden: false,
                nextCursorHidden: true,
                isInitial: false,
                keymappingEnabled: true
            ) == .nonButtonActions
        )
    }

    @Test
    func longPressStateMachineQuickClickHoldDragAndCancellation() {
        var sm = PTLongPressStateMachine()
        #expect(!sm.isActive)

        // 1. Quick right-click: press, jitter before release, release before 650ms -> holds until timer fires
        let p0 = CGPoint(x: 120, y: 240)
        let first = sm.begin(at: p0)
        #expect(!first.cancelledPrevious)
        #expect(sm.isActive)
        #expect(sm.isPhysicalButtonDown)
        #expect(!sm.minHoldCompleted)
        #expect(sm.anchorPoint == p0)

        // Jitter while min hold has not elapsed must be suppressed
        let move1 = sm.allowMove(to: CGPoint(x: 122, y: 243))
        #expect(!move1)
        #expect(sm.anchorPoint == p0)

        // Quick physical release before min hold does NOT release touch yet
        let rel1 = sm.onPhysicalRelease()
        #expect(!rel1)
        #expect(sm.isActive)
        #expect(!sm.isPhysicalButtonDown)
        let move2 = sm.allowMove(to: CGPoint(x: 150, y: 260))
        #expect(!move2)

        // Timer fires for first.generation -> now releases touch
        let elapsed1 = sm.onMinimumHoldElapsed(generation: first.generation)
        #expect(elapsed1)
        #expect(!sm.isActive)
        #expect(sm.anchorPoint == p0)

        // Redundant release or stale generation timer must be no-op
        let elapsed1Dup = sm.onMinimumHoldElapsed(generation: first.generation)
        #expect(!elapsed1Dup)
        let rel1Dup = sm.onPhysicalRelease()
        #expect(!rel1Dup)

        // 2. Press-and-hold >= 650ms -> keeps touch alive past 650ms, allows drag after 650ms, ends on release
        let p1 = CGPoint(x: 300, y: 400)
        let second = sm.begin(at: p1)
        #expect(!second.cancelledPrevious)
        // Stale generation from earlier tap must be ignored
        let staleElapsed = sm.onMinimumHoldElapsed(generation: first.generation)
        #expect(!staleElapsed)
        // Pre-threshold drag still suppressed
        let preDrag = sm.allowMove(to: CGPoint(x: 302, y: 401))
        #expect(!preDrag)

        // Threshold reached while physical button still held -> remains active
        let elapsed2 = sm.onMinimumHoldElapsed(generation: second.generation)
        #expect(!elapsed2)
        #expect(sm.isActive)
        #expect(sm.minHoldCompleted)

        // Post-threshold drag allowed and updates anchorPoint
        let pDrag = CGPoint(x: 340, y: 420)
        let postDrag = sm.allowMove(to: pDrag)
        #expect(postDrag)
        #expect(sm.anchorPoint == pDrag)

        // Physical release now ends the touch
        let rel2 = sm.onPhysicalRelease()
        #expect(rel2)
        #expect(!sm.isActive)

        // 3. Re-press while quick-click auto-release still pending, and early finish (left click)
        let third = sm.begin(at: CGPoint(x: 50, y: 60))
        let rel3 = sm.onPhysicalRelease()
        #expect(!rel3)
        let fourth = sm.begin(at: CGPoint(x: 80, y: 90))
        #expect(fourth.cancelledPrevious)
        let elapsed3 = sm.onMinimumHoldElapsed(generation: third.generation)
        #expect(!elapsed3)
        let finish1 = sm.finishEarly()
        #expect(finish1)
        #expect(!sm.isActive)
        let finish2 = sm.finishEarly()
        #expect(!finish2)
        let elapsed4 = sm.onMinimumHoldElapsed(generation: fourth.generation)
        #expect(!elapsed4)

        // 4. Invalidation tears down active long press and invalidates pending timer generation
        let fifth = sm.begin(at: CGPoint(x: 10, y: 20))
        let inv1 = sm.invalidate()
        #expect(inv1)
        #expect(!sm.isActive)
        let inv2 = sm.invalidate()
        #expect(!inv2)
        let elapsed5 = sm.onMinimumHoldElapsed(generation: fifth.generation)
        #expect(!elapsed5)
    }

    @Test
    func titlebarAwareClamping() {
        let laptopVisible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let titleBarHeight: CGFloat = 28

        // Tall portrait iPad (1024 x 1366) must subtract titleBarHeight BEFORE clamping
        let clampedPad = PTWindowGeometryMath.clampedContentSize(
            requested: CGSize(width: 1024, height: 1366),
            visibleScreenFrame: laptopVisible,
            titleBarHeight: titleBarHeight
        )
        #expect(clampedPad.width <= laptopVisible.width)
        #expect(clampedPad.height + titleBarHeight <= laptopVisible.height)
        #expect(abs((clampedPad.width / clampedPad.height) - (1024.0 / 1366.0)) <= 0.005)
        let centeredPad = PTWindowGeometryMath.centeredFrame(
            forContentSize: clampedPad,
            currentFrame: .zero,
            visibleScreenFrame: laptopVisible,
            titleBarHeight: titleBarHeight
        )
        #expect(centeredPad.minY >= laptopVisible.minY)
        #expect(centeredPad.maxY <= laptopVisible.maxY)

        // Fractional visible height still guarantees content + titlebar <= visible height
        let fractionalVisible = CGRect(x: 0, y: 0, width: 1440, height: 875.8)
        let clampedFrac = PTWindowGeometryMath.clampedContentSize(
            requested: CGSize(width: 440, height: 956),
            visibleScreenFrame: fractionalVisible,
            titleBarHeight: 28.0
        )
        #expect(clampedFrac.height + 28.0 <= fractionalVisible.height)
        #expect(abs((clampedFrac.width / clampedFrac.height) - (440.0 / 956.0)) <= 0.005)
    }

    private struct StrictSpecExpectation {
        let model: String
        let pxW: Int
        let pxH: Int
        let portrait: CGSize
        let landscape: CGSize

        init(
            _ model: String,
            _ pxW: Int,
            _ pxH: Int,
            _ portraitWidth: CGFloat,
            _ portraitHeight: CGFloat
        ) {
            self.model = model
            self.pxW = pxW
            self.pxH = pxH
            self.portrait = CGSize(width: portraitWidth, height: portraitHeight)
            self.landscape = CGSize(width: portraitHeight, height: portraitWidth)
        }
    }

    private func verifyStrictSpecs(
        _ expectations: [StrictSpecExpectation],
        expectedScale: Double,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        for entry in expectations {
            let spec = PTWindowGeometryMath.StrictDeviceDisplaySpec.resolve(forModel: entry.model)
            #expect(spec.nativePixelWidth == entry.pxW, sourceLocation: sourceLocation)
            #expect(spec.nativePixelHeight == entry.pxH, sourceLocation: sourceLocation)
            #expect(spec.nativeScale == expectedScale, sourceLocation: sourceLocation)
            #expect(spec.logicalSize(orientation: "portrait") == entry.portrait, sourceLocation: sourceLocation)
            #expect(spec.logicalSize(orientation: "landscape") == entry.landscape, sourceLocation: sourceLocation)
        }
    }

    @Test
    func strictDeviceDisplaySpecsForIPadModels() {
        let ipadExpected: [StrictSpecExpectation] = [
            .init("iPad6,7", 2048, 2732, 1024, 1366),
            .init("iPad8,6", 2048, 2732, 1024, 1366),
            .init("iPad13,8", 2048, 2732, 1024, 1366),
            .init("iPad14,5", 2048, 2732, 1024, 1366),
            .init("iPad16,6", 2064, 2752, 1032, 1376),
            .init("iPad17,3", 2064, 2752, 1032, 1376)
        ]
        verifyStrictSpecs(ipadExpected, expectedScale: 2.0)
        #expect(PTWindowGeometryMath.StrictDeviceDisplaySpec.resolve(forModel: "UnknownDevice").model == "iPad13,8")
    }

    @Test
    func strictDeviceDisplaySpecsForIPhoneModels() {
        let iphoneExpected: [StrictSpecExpectation] = [
            .init("iPhone12,5", 1242, 2688, 414, 896),
            .init("iPhone14,3", 1284, 2778, 428, 926),
            .init("iPhone15,3", 1290, 2796, 430, 932),
            .init("iPhone16,2", 1290, 2796, 430, 932),
            .init("iPhone17,2", 1320, 2868, 440, 956),
            .init("iPhone18,2", 1320, 2868, 440, 956)
        ]
        verifyStrictSpecs(iphoneExpected, expectedScale: 3.0)
        #expect(PTWindowGeometryMath.StrictDeviceDisplaySpec.resolve(forModel: "iPhone99,1").model == "iPhone17,2")
    }

    @Test
    func strictViewportWindowPlansFitScreenAndNative1x() {
        let laptopVisible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let titleBarHeight: CGFloat = 28

        let fitOversized = PTWindowGeometryMath.strictViewportWindowPlan(
            logicalSceneSize: CGSize(width: 1024, height: 1366),
            scaleMode: "fitScreen",
            visibleScreenFrame: laptopVisible,
            titleBarHeight: titleBarHeight
        )
        #expect(fitOversized.logicalSceneSize == CGSize(width: 1024, height: 1366))
        #expect(fitOversized.lockedAspectRatio == CGSize(width: 1024, height: 1366))
        #expect(fitOversized.windowContentSize == CGSize(width: 635, height: 847))
        #expect(fitOversized.allowsUserResize)

        let fitSmallPhone = PTWindowGeometryMath.strictViewportWindowPlan(
            logicalSceneSize: CGSize(width: 932, height: 430),
            scaleMode: "fitScreen",
            visibleScreenFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            titleBarHeight: titleBarHeight
        )
        #expect(fitSmallPhone.windowContentSize == CGSize(width: 932, height: 430))
        #expect(fitSmallPhone.allowsUserResize)

        let nativeOversized = PTWindowGeometryMath.strictViewportWindowPlan(
            logicalSceneSize: CGSize(width: 1024, height: 1366),
            scaleMode: "native1x",
            visibleScreenFrame: laptopVisible,
            titleBarHeight: titleBarHeight
        )
        #expect(nativeOversized.windowContentSize == CGSize(width: 635, height: 847))
        #expect(!nativeOversized.allowsUserResize)

        let nativeSmall = PTWindowGeometryMath.strictViewportWindowPlan(
            logicalSceneSize: CGSize(width: 430, height: 932),
            scaleMode: "native1x",
            visibleScreenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415),
            titleBarHeight: titleBarHeight
        )
        #expect(nativeSmall.windowContentSize == CGSize(width: 430, height: 932))
        #expect(!nativeSmall.allowsUserResize)
    }

    @Test
    func strictViewportFocusPolicyPreservesFitScreenResizeAcrossFocus() {
        let screenA = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let screenB = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let landscapeKey = PTStrictViewportFocusKey(
            sceneID: nil, deviceModel: "iPad13,8", scaleMode: "fitScreen",
            targetSize: CGSize(width: 1366, height: 1024), screenFrame: screenA
        )

        let first = PTStrictViewportFocusPolicy.shouldApplyContentSizeOnFocus(
            isStrictEmulationMode: true, lastAppliedFitScreenKey: nil, currentKey: landscapeKey
        )
        #expect(first.shouldApply)
        #expect(first.nextAppliedFitScreenKey == landscapeKey)

        let repeatFocus = PTStrictViewportFocusPolicy.shouldApplyContentSizeOnFocus(
            isStrictEmulationMode: true,
            lastAppliedFitScreenKey: first.nextAppliedFitScreenKey,
            currentKey: landscapeKey
        )
        #expect(!repeatFocus.shouldApply)
        #expect(repeatFocus.nextAppliedFitScreenKey == landscapeKey)

        let portraitKey = PTStrictViewportFocusKey(
            sceneID: nil, deviceModel: "iPad13,8", scaleMode: "fitScreen",
            targetSize: CGSize(width: 1024, height: 1366), screenFrame: screenA
        )
        let rotated = PTStrictViewportFocusPolicy.shouldApplyContentSizeOnFocus(
            isStrictEmulationMode: true,
            lastAppliedFitScreenKey: repeatFocus.nextAppliedFitScreenKey,
            currentKey: portraitKey
        )
        #expect(rotated.shouldApply)
        #expect(rotated.nextAppliedFitScreenKey == portraitKey)

        let movedScreenKey = PTStrictViewportFocusKey(
            sceneID: nil, deviceModel: "iPad13,8", scaleMode: "fitScreen",
            targetSize: CGSize(width: 1024, height: 1366), screenFrame: screenB
        )
        let moved = PTStrictViewportFocusPolicy.shouldApplyContentSizeOnFocus(
            isStrictEmulationMode: true,
            lastAppliedFitScreenKey: rotated.nextAppliedFitScreenKey,
            currentKey: movedScreenKey
        )
        #expect(moved.shouldApply)
        #expect(moved.nextAppliedFitScreenKey == movedScreenKey)
    }

    @Test
    func strictViewportFocusPolicyNative1xAndNonStrictAlwaysApply() {
        let screenA = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let landscapeKey = PTStrictViewportFocusKey(
            sceneID: nil,
            deviceModel: "iPad13,8",
            scaleMode: "fitScreen",
            targetSize: CGSize(width: 1366, height: 1024),
            screenFrame: screenA
        )
        let native1xKey = PTStrictViewportFocusKey(
            sceneID: nil,
            deviceModel: "iPad13,8",
            scaleMode: "native1x",
            targetSize: CGSize(width: 1366, height: 1024),
            screenFrame: screenA
        )
        let nativeApply = PTStrictViewportFocusPolicy.shouldApplyContentSizeOnFocus(
            isStrictEmulationMode: true,
            lastAppliedFitScreenKey: landscapeKey,
            currentKey: native1xKey
        )
        #expect(nativeApply.shouldApply)
        #expect(nativeApply.nextAppliedFitScreenKey == nil)

        let nonStrict = PTStrictViewportFocusPolicy.shouldApplyContentSizeOnFocus(
            isStrictEmulationMode: false,
            lastAppliedFitScreenKey: landscapeKey,
            currentKey: landscapeKey
        )
        #expect(nonStrict.shouldApply)
        #expect(nonStrict.nextAppliedFitScreenKey == nil)
    }

    @Test
    func hideTitleBarZeroTitleHeightAvoids32ptInflation() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let zeroTitlePlan = PTWindowGeometryMath.strictViewportWindowPlan(
            logicalSceneSize: CGSize(width: 1024, height: 1366),
            scaleMode: "fitScreen",
            visibleScreenFrame: visible,
            titleBarHeight: 0
        )
        #expect(zeroTitlePlan.windowContentSize.height == 875)
        let centeredNoTitle = PTWindowGeometryMath.centeredFrame(
            forContentSize: zeroTitlePlan.windowContentSize,
            currentFrame: .zero,
            visibleScreenFrame: visible,
            titleBarHeight: 0
        )
        #expect(centeredNoTitle.height == 875)
    }

    @Test
    func windowChromeHitTestingAndCloseTerminationPolicy() {
        let contentRect = CGRect(x: 0, y: 0, width: 1280, height: 720)
        // Above contentLayoutRect is title bar / chrome
        #expect(PTWindowGeometryMath.isPointInTitleBar(
            pointInWindow: CGPoint(x: 16, y: 734),
            contentLayoutRect: contentRect
        ))
        // Boundary and content area are not title bar
        #expect(!PTWindowGeometryMath.isPointInTitleBar(
            pointInWindow: CGPoint(x: 16, y: 720),
            contentLayoutRect: contentRect
        ))
        #expect(!PTWindowGeometryMath.isPointInTitleBar(
            pointInWindow: CGPoint(x: 200, y: 400),
            contentLayoutRect: contentRect
        ))
        // Non-finite or zero-height rects return false
        #expect(!PTWindowGeometryMath.isPointInTitleBar(
            pointInWindow: CGPoint(x: CGFloat.nan, y: 734),
            contentLayoutRect: contentRect
        ))
        #expect(!PTWindowGeometryMath.isPointInTitleBar(
            pointInWindow: CGPoint(x: 16, y: 10),
            contentLayoutRect: .zero
        ))

        // Close-to-quit policy
        #expect(PTWindowGeometryMath.shouldTerminateOnWindowClose(
            isClosingWindowPrimary: true,
            otherVisiblePrimaryWindowCount: 0
        ))
        #expect(!PTWindowGeometryMath.shouldTerminateOnWindowClose(
            isClosingWindowPrimary: true,
            otherVisiblePrimaryWindowCount: 1
        ))
        #expect(!PTWindowGeometryMath.shouldTerminateOnWindowClose(
            isClosingWindowPrimary: false,
            otherVisiblePrimaryWindowCount: 0
        ))
        #expect(!PTWindowGeometryMath.shouldTerminateOnWindowClose(
            quitOnWindowCloseEnabled: false,
            isClosingWindowPrimary: true,
            otherVisiblePrimaryWindowCount: 0
        ))
        #expect(PTWindowGeometryMath.shouldTerminateOnWindowClose(
            quitOnWindowCloseEnabled: true,
            isClosingWindowPrimary: true,
            otherVisiblePrimaryWindowCount: 0
        ))
        #expect(!PTWindowGeometryMath.shouldTerminateOnWindowClose(
            quitOnWindowCloseEnabled: true,
            isClosingWindowPrimary: true,
            otherVisiblePrimaryWindowCount: 1
        ))
    }

    @Test
    func terminationWatchdogFiresOffMainQueueAndRespectsCancelOrRearm() {
        let queue = DispatchQueue(label: "test.watchdog.queue", qos: .userInitiated)

        // 1. Armed watchdog fires off main thread when not cancelled
        let firedOffMain = Mutex<(count: Int, isMainThread: Bool)>((0, true))
        let group = DispatchGroup()
        group.enter()
        let watchdog = PTTerminationWatchdogController(queue: queue) {
            firedOffMain.withLock { state in
                state.count += 1
                state.isMainThread = Thread.isMainThread
            }
            group.leave()
        }
        #expect(!watchdog.isArmed)
        _ = watchdog.arm(timeoutSeconds: 0.05)
        #expect(watchdog.isArmed)
        #expect(group.wait(timeout: .now() + 2.0) == .success)
        let firstOutcome = firedOffMain.withLock { $0 }
        #expect(firstOutcome.count == 1)
        #expect(!firstOutcome.isMainThread)
        #expect(!watchdog.isArmed)

        // 2. Cancelled watchdog does not fire
        let cancelCount = Mutex(0)
        let cancelWatchdog = PTTerminationWatchdogController(queue: queue) {
            cancelCount.withLock { $0 += 1 }
        }
        let token = cancelWatchdog.arm(timeoutSeconds: 0.05)
        #expect(cancelWatchdog.isArmed)
        cancelWatchdog.cancel(token: token)
        #expect(!cancelWatchdog.isArmed)
        Thread.sleep(forTimeInterval: 0.12)
        #expect(cancelCount.withLock { $0 } == 0)

        // 3. Re-arming cancels previous token so callback fires once
        let rearmCount = Mutex(0)
        let rearmGroup = DispatchGroup()
        rearmGroup.enter()
        let rearmWatchdog = PTTerminationWatchdogController(queue: queue) {
            rearmCount.withLock { $0 += 1 }
            rearmGroup.leave()
        }
        _ = rearmWatchdog.arm(timeoutSeconds: 0.04)
        _ = rearmWatchdog.arm(timeoutSeconds: 0.08)
        #expect(rearmGroup.wait(timeout: .now() + 2.0) == .success)
        Thread.sleep(forTimeInterval: 0.08)
        #expect(rearmCount.withLock { $0 } == 1)
    }

    @Test
    func cursorPositionRejectsLetterboxAndPillarboxBlackBarClicks() {
        let viewRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        // Wide window (pillarboxed: content spans x in [120, 1080])
        let wideWindow = CGRect(x: 0, y: 0, width: 1200, height: 540)
        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 50, y: 270),
            windowFrame: wideWindow,
            viewRect: viewRect,
            resizable: false,
            fullscreen: false
        ) == nil)
        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 1150, y: 270),
            windowFrame: wideWindow,
            viewRect: viewRect,
            resizable: false,
            fullscreen: false
        ) == nil)

        // Tall fullscreen window (letterboxed: content spans y in [90, 630])
        let tallWindow = CGRect(x: 0, y: 0, width: 960, height: 720)
        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 480, y: 20),
            windowFrame: tallWindow,
            viewRect: viewRect,
            resizable: true,
            fullscreen: true
        ) == nil)
        #expect(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 480, y: 700),
            windowFrame: tallWindow,
            viewRect: viewRect,
            resizable: true,
            fullscreen: true
        ) == nil)
    }

    @Test
    func strictDeviceDisplaySpecEnforcesIOSMajorBounds() {
        func resolved(_ model: String, mode: String, host: Int) -> String {
            PTWindowGeometryMath.StrictDeviceDisplaySpec.effectiveModel(
                for: model,
                normalizedReportedIOSVersion: mode,
                hostIOSMajor: host
            )
        }

        // EOL iPad6,7 (9..16)
        #expect(resolved("iPad6,7", mode: "automatic", host: 16) == "iPad6,7")
        #expect(resolved("iPad6,7", mode: "automatic", host: 17) == "iPad13,8")
        #expect(resolved("iPad6,7", mode: "compat18_3", host: 27) == "iPad13,8")
        #expect(resolved("iPad6,7", mode: "compat13_7", host: 27) == "iPad6,7")

        // EOL iPad8,6 (12..18)
        #expect(resolved("iPad8,6", mode: "compat18_3", host: 27) == "iPad8,6")
        #expect(resolved("iPad8,6", mode: "automatic", host: 26) == "iPad13,8")

        // Future iPhone18,* / iPad17,* (26..99)
        #expect(resolved("iPhone18,2", mode: "compat18_3", host: 27) == "iPhone17,2")
        #expect(resolved("iPhone18,2", mode: "automatic", host: 26) == "iPhone18,2")
        #expect(resolved("iPhone18,2", mode: "compat13_7", host: 27) == "iPhone12,5")
        #expect(resolved("iPad17,3", mode: "compat18_3", host: 27) == "iPad16,6")
        #expect(resolved("iPad17,3", mode: "automatic", host: 26) == "iPad17,3")
        #expect(resolved("iPad17,3", mode: "compat13_7", host: 27) == "iPad8,6")

        // M1 iPad13,8 (14..99)
        #expect(resolved("iPad13,8", mode: "compat13_7", host: 27) == "iPad8,6")
        #expect(resolved("iPad13,8", mode: "automatic", host: 27) == "iPad13,8")
    }

    @Test
    func touchRoutingIncludesCustomInputHostAndExcludesChromeOverlay() {
        #expect(!PTWindowGeometryMath.isExcludedFromTouchRouting(
            isChromeOverlayWindow: false,
            internalOverlayTagValue: nil
        ))
        #expect(!PTWindowGeometryMath.isExcludedFromTouchRouting(
            isChromeOverlayWindow: false,
            internalOverlayTagValue: PTWindowGeometryMath.interactiveInputHostOverlayTagValue
        ))
        #expect(PTWindowGeometryMath.isExcludedFromTouchRouting(
            isChromeOverlayWindow: true,
            internalOverlayTagValue: 1
        ))
        #expect(PTWindowGeometryMath.isExcludedFromTouchRouting(
            isChromeOverlayWindow: true,
            internalOverlayTagValue: PTWindowGeometryMath.interactiveInputHostOverlayTagValue
        ))
        #expect(PTWindowGeometryMath.isExcludedFromTouchRouting(
            isChromeOverlayWindow: false,
            internalOverlayTagValue: 1
        ))

        let candidates = [
            PTWindowGeometryMath.TouchWindowCandidate(
                isHidden: false,
                alpha: 1.0,
                isUserInteractionEnabled: true,
                boundsSize: CGSize(width: 1280, height: 720),
                windowLevel: 0
            ),
            PTWindowGeometryMath.TouchWindowCandidate(
                isHidden: false,
                alpha: 1.0,
                isUserInteractionEnabled: true,
                boundsSize: CGSize(width: 1280, height: 720),
                windowLevel: 1999
            )
        ]
        #expect(PTWindowGeometryMath.orderedTouchCandidateIndices(candidates) == [1, 0])
    }
}
