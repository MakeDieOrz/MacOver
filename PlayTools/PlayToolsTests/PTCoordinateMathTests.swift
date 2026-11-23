import CoreGraphics
import XCTest

final class PTCoordinateMathTests: XCTestCase {
    func testCursorPositionCenteredAndAspectRatio() throws {
        let viewRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windowFrame = CGRect(x: 0, y: 0, width: 960, height: 540)

        let center = try XCTUnwrap(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 480, y: 270),
            windowFrame: windowFrame,
            viewRect: viewRect,
            resizable: false,
            fullscreen: false
        ))
        XCTAssertEqual(center.x, 960, accuracy: 0.001)
        XCTAssertEqual(center.y, 540, accuracy: 0.001)

        // Wide 16:10 window with 16:9 content (horizontal pillarbox centering)
        let wideWindow = CGRect(x: 0, y: 0, width: 1200, height: 540)
        let wideCenter = try XCTUnwrap(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 600, y: 270),
            windowFrame: wideWindow,
            viewRect: viewRect,
            resizable: false,
            fullscreen: false
        ))
        XCTAssertEqual(wideCenter.x, 960, accuracy: 0.001)
        XCTAssertEqual(wideCenter.y, 540, accuracy: 0.001)

        // Tall 4:3 window in fullscreen vs non-fullscreen
        let tallWindow = CGRect(x: 0, y: 0, width: 960, height: 720)
        let fsCenter = try XCTUnwrap(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 480, y: 360),
            windowFrame: tallWindow,
            viewRect: viewRect,
            resizable: true,
            fullscreen: true
        ))
        XCTAssertEqual(fsCenter.x, 960, accuracy: 0.001)
        XCTAssertEqual(fsCenter.y, 540, accuracy: 0.001)

        // Traffic light rejection when non-fullscreen and point.y * rate > viewRect.height
        let aboveTrafficLight = PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 480, y: 600),
            windowFrame: tallWindow,
            viewRect: viewRect,
            resizable: false,
            fullscreen: false
        )
        XCTAssertNil(aboveTrafficLight)
    }

    func testCursorPositionEdgeMarginAndDegenerateBounds() {
        let viewRect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let windowFrame = CGRect(x: 0, y: 0, width: 960, height: 540)

        XCTAssertNil(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 9.9, y: 100),
            windowFrame: windowFrame,
            viewRect: viewRect,
            resizable: true,
            fullscreen: false
        ))
        XCTAssertNotNil(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 10.0, y: 100),
            windowFrame: windowFrame,
            viewRect: viewRect,
            resizable: true,
            fullscreen: false
        ))
        XCTAssertNil(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 100, y: 100),
            windowFrame: CGRect(x: 0, y: 0, width: 0.5, height: 540),
            viewRect: viewRect,
            resizable: false,
            fullscreen: false
        ))
        XCTAssertNil(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 100, y: 100),
            windowFrame: windowFrame,
            viewRect: .zero,
            resizable: false,
            fullscreen: false
        ))
    }

    func testAspectRatioAndRelativeAbsoluteConversions() {
        XCTAssertEqual(PTCoordinateMath.aspectRatio(width: 1920, height: 1080), 1920.0 / 1080.0, accuracy: 0.0001)
        XCTAssertEqual(PTCoordinateMath.aspectRatio(width: 1080, height: 1920), 1920.0 / 1080.0, accuracy: 0.0001)
        XCTAssertEqual(PTCoordinateMath.aspectRatio(width: 1000, height: 1000), 1.0, accuracy: 0.0001)
        XCTAssertEqual(PTCoordinateMath.aspectRatio(width: 0, height: 1080), 0)
        XCTAssertEqual(PTCoordinateMath.aspectRatio(width: -10, height: 1080), 0)

        let screenSize = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(PTCoordinateMath.screenPercent(for: screenSize), 19.2, accuracy: 0.0001)

        let relX = PTCoordinateMath.relativeX(960, screenWidth: screenSize.width)
        let relY = PTCoordinateMath.relativeY(270, screenHeight: screenSize.height)
        let relSize = PTCoordinateMath.relativeSize(96, screenSize: screenSize)
        XCTAssertEqual(PTCoordinateMath.absoluteX(relX, screenWidth: screenSize.width), 960, accuracy: 0.0001)
        XCTAssertEqual(PTCoordinateMath.absoluteY(relY, screenHeight: screenSize.height), 270, accuracy: 0.0001)
        XCTAssertEqual(PTCoordinateMath.absoluteSize(relSize, screenSize: screenSize), 96, accuracy: 0.0001)

        XCTAssertEqual(PTCoordinateMath.relativeX(10, screenWidth: 0), 0)
        XCTAssertEqual(PTCoordinateMath.relativeY(10, screenHeight: 0), 0)
        XCTAssertEqual(PTCoordinateMath.relativeSize(10, screenSize: .zero), 0)
    }

    func testSwipeOutOfBoundsVelocityScalerAndDelta() {
        let bounds = CGSize(width: 1000, height: 600)
        XCTAssertFalse(PTCoordinateMath.isPointOutOfBounds(CGPoint(x: 0, y: 0), boundsSize: bounds))
        XCTAssertFalse(PTCoordinateMath.isPointOutOfBounds(CGPoint(x: 1000, y: 600), boundsSize: bounds))
        XCTAssertTrue(PTCoordinateMath.isPointOutOfBounds(CGPoint(x: -0.1, y: 10), boundsSize: bounds))
        XCTAssertTrue(PTCoordinateMath.isPointOutOfBounds(CGPoint(x: 1000.1, y: 10), boundsSize: bounds))
        XCTAssertTrue(PTCoordinateMath.isPointOutOfBounds(CGPoint(x: 10, y: -1), boundsSize: bounds))
        XCTAssertTrue(PTCoordinateMath.isPointOutOfBounds(CGPoint(x: 10, y: 601), boundsSize: bounds))

        let inBoundsScaler = PTCoordinateMath.velocityScaler(
            predicted: CGPoint(x: 800, y: 500),
            current: CGPoint(x: 500, y: 300),
            boundsSize: bounds
        )
        XCTAssertEqual(inBoundsScaler, 1.0, accuracy: 0.0001)

        let leftOverflow = PTCoordinateMath.velocityScaler(
            predicted: CGPoint(x: -100, y: 300),
            current: CGPoint(x: 100, y: 300),
            boundsSize: bounds
        )
        XCTAssertEqual(leftOverflow, 0.5, accuracy: 0.0001)

        let diagonalOverflow = PTCoordinateMath.velocityScaler(
            predicted: CGPoint(x: 1500, y: 1200),
            current: CGPoint(x: 500, y: 400),
            boundsSize: bounds
        )
        XCTAssertEqual(diagonalOverflow, 0.25, accuracy: 0.0001)

        let zeroDelta = PTCoordinateMath.velocityScaler(
            predicted: CGPoint(x: 500, y: 300),
            current: CGPoint(x: 500, y: 300),
            boundsSize: bounds
        )
        XCTAssertEqual(zeroDelta, 1.0, accuracy: 0.0001)

        let moved = PTCoordinateMath.applySwipeDelta(CGPoint(x: 100, y: 200), deltaX: 15, deltaY: 25)
        XCTAssertEqual(moved, CGPoint(x: 115, y: 175))
    }

    func testCameraDeltaAndClampPoint() {
        let delta = PTCoordinateMath.scaledCameraDelta(deltaX: 10, deltaY: -20, sensitivity: 5.0)
        XCTAssertEqual(delta.dx, 30.0, accuracy: 0.0001)
        XCTAssertEqual(delta.dy, 60.0, accuracy: 0.0001)

        let zeroSens = PTCoordinateMath.scaledCameraDelta(deltaX: 10, deltaY: 20, sensitivity: 0)
        XCTAssertEqual(zeroSens, .zero)

        let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
        XCTAssertEqual(PTCoordinateMath.clampPoint(CGPoint(x: -5, y: 90), to: rect), CGPoint(x: 10, y: 70))
        XCTAssertEqual(PTCoordinateMath.clampPoint(CGPoint(x: 50, y: 40), to: rect), CGPoint(x: 50, y: 40))
        XCTAssertEqual(PTCoordinateMath.clampPoint(CGPoint(x: 50, y: 40), to: .null), .zero)
    }

    func testNonFiniteAndDegenerateGeometryEdges() {
        let validView = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let validWindow = CGRect(x: 0, y: 0, width: 960, height: 540)

        XCTAssertNil(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: CGFloat.nan, y: 100),
            windowFrame: validWindow,
            viewRect: validView,
            resizable: false,
            fullscreen: false
        ))
        XCTAssertNil(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: CGFloat.infinity, y: 100),
            windowFrame: validWindow,
            viewRect: validView,
            resizable: false,
            fullscreen: false
        ))
        XCTAssertNil(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 100, y: 100),
            windowFrame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 540),
            viewRect: validView,
            resizable: false,
            fullscreen: false
        ))
        XCTAssertNil(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 100, y: 100),
            windowFrame: validWindow,
            viewRect: CGRect(x: 0, y: 0, width: 1920, height: CGFloat.nan),
            resizable: false,
            fullscreen: false
        ))
        XCTAssertNil(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 100, y: 100),
            windowFrame: CGRect(x: 100, y: 100, width: -50, height: -50),
            viewRect: validView,
            resizable: false,
            fullscreen: false
        ))
        XCTAssertNil(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: 5, y: 5),
            windowFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
            viewRect: validView,
            resizable: true,
            fullscreen: false,
            edgeMargin: 10
        ))

        let negSize = CGSize(width: -100, height: -50)
        XCTAssertEqual(PTCoordinateMath.screenPercent(for: negSize), 0)
        XCTAssertEqual(PTCoordinateMath.absoluteSize(10, screenSize: negSize), 0)
        XCTAssertEqual(PTCoordinateMath.aspectRatio(width: .nan, height: 100), 0)

        XCTAssertEqual(
            PTCoordinateMath.velocityScaler(
                predicted: CGPoint(x: 100, y: 100),
                current: CGPoint(x: 50, y: 50),
                boundsSize: .zero
            ),
            0
        )
        XCTAssertEqual(
            PTCoordinateMath.velocityScaler(
                predicted: CGPoint(x: 100, y: 100),
                current: CGPoint(x: -10, y: 50),
                boundsSize: CGSize(width: 960, height: 540)
            ),
            0
        )
        XCTAssertEqual(
            PTCoordinateMath.velocityScaler(
                predicted: CGPoint(x: -.infinity, y: 100),
                current: CGPoint(x: 50, y: 50),
                boundsSize: CGSize(width: 960, height: 540)
            ),
            0
        )

        XCTAssertEqual(PTCoordinateMath.clampPoint(CGPoint(x: CGFloat.nan, y: 50), to: validWindow), .zero)
        XCTAssertEqual(PTCoordinateMath.clampPoint(CGPoint(x: 50, y: 50), to: .infinite), .zero)
        XCTAssertEqual(
            PTCoordinateMath.clampPoint(CGPoint(x: 50, y: 50), to: CGRect(x: 100, y: 100, width: -50, height: -50)),
            .zero
        )

        // Subnormal underflow & finite overflow guards (G-02)
        XCTAssertNil(PTCoordinateMath.cursorPosition(
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
        ))
        XCTAssertNil(PTCoordinateMath.cursorPosition(
            mousePoint: CGPoint(x: -1e308, y: 100),
            windowFrame: validWindow,
            viewRect: validView,
            resizable: false,
            fullscreen: false
        ))

        XCTAssertEqual(PTCoordinateMath.aspectRatio(width: 1e308, height: 0.5), 0)
        XCTAssertEqual(PTCoordinateMath.relativeX(1e308, screenWidth: 0.5), 0)
        XCTAssertEqual(PTCoordinateMath.relativeY(1e308, screenHeight: 0.5), 0)
        XCTAssertEqual(PTCoordinateMath.relativeSize(1e308, screenSize: CGSize(width: 0.5, height: 0.5)), 0)
        XCTAssertEqual(PTCoordinateMath.absoluteX(1e308, screenWidth: 10), 0)
        XCTAssertEqual(PTCoordinateMath.absoluteY(1e308, screenHeight: 10), 0)
        XCTAssertEqual(PTCoordinateMath.absoluteSize(1e308, screenSize: CGSize(width: 1000, height: 1000)), 0)

        XCTAssertEqual(
            PTCoordinateMath.scaledCameraDelta(deltaX: .nan, deltaY: .infinity, sensitivity: 1.0),
            .zero
        )
        XCTAssertEqual(
            PTCoordinateMath.scaledCameraDelta(deltaX: 10, deltaY: 20, sensitivity: Float.nan),
            .zero
        )
        XCTAssertEqual(
            PTCoordinateMath.scaledCameraDelta(deltaX: 1e308, deltaY: 1, sensitivity: 10.0),
            .zero
        )

        XCTAssertEqual(
            PTCoordinateMath.applySwipeDelta(CGPoint(x: CGFloat.nan, y: 10), deltaX: 1, deltaY: 2),
            .zero
        )
        XCTAssertEqual(
            PTCoordinateMath.applySwipeDelta(CGPoint(x: 100, y: 200), deltaX: .nan, deltaY: 2),
            CGPoint(x: 100, y: 200)
        )
        XCTAssertEqual(
            PTCoordinateMath.applySwipeDelta(CGPoint(x: 1e308, y: 200), deltaX: 1e308, deltaY: 0),
            CGPoint(x: 1e308, y: 200)
        )
    }

    func testDeadZoneAndMouseMoveCoalescer() throws {
        XCTAssertTrue(PTCoordinateMath.isWithinDeadZone(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 10.15, y: 10.15),
            deadZone: 0.25
        ))
        XCTAssertFalse(PTCoordinateMath.isWithinDeadZone(
            from: CGPoint(x: 10, y: 10),
            to: CGPoint(x: 11, y: 10),
            deadZone: 0.25
        ))
        XCTAssertFalse(PTCoordinateMath.isWithinDeadZone(
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
        XCTAssertNil(coalescer.ingest(deltaX: 2.0, deltaY: 1.0, timestampNanoseconds: 2_000_000))
        XCTAssertNil(coalescer.ingest(deltaX: .nan, deltaY: 1.0, timestampNanoseconds: 3_000_000))
        XCTAssertNil(coalescer.ingest(deltaX: 3.0, deltaY: -0.5, timestampNanoseconds: 7_999_999))

        // At 8ms boundary: flushes accumulated sum (5.0, 0.5)
        let flushed = try XCTUnwrap(coalescer.ingest(deltaX: 1.0, deltaY: 1.5, timestampNanoseconds: 8_000_000))
        XCTAssertEqual(flushed.dx, 6.0, accuracy: 0.0001)
        XCTAssertEqual(flushed.dy, 2.0, accuracy: 0.0001)

        // Below dead-zone even after 8ms: stays held until exceeding deadZone
        XCTAssertNil(coalescer.ingest(deltaX: 0.2, deltaY: 0.2, timestampNanoseconds: 20_000_000))
        let second = try XCTUnwrap(coalescer.ingest(deltaX: 0.5, deltaY: 0.0, timestampNanoseconds: 28_000_000))
        XCTAssertEqual(second.dx, 0.7, accuracy: 0.0001)
        XCTAssertEqual(second.dy, 0.2, accuracy: 0.0001)
    }

    func testWindowGeometryMathClampingOrientationAndCentering() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let clamped = PTWindowGeometryMath.clampedContentSize(
            requested: CGSize(width: 2560, height: 1440),
            visibleScreenFrame: visible,
            aspectRatio: CGSize(width: 16, height: 9)
        )
        XCTAssertLessThanOrEqual(clamped.width, visible.width)
        XCTAssertLessThanOrEqual(clamped.height, visible.height)
        XCTAssertEqual(clamped.width / clamped.height, 16.0 / 9.0, accuracy: 0.02)

        XCTAssertEqual(PTWindowGeometryMath.clampedContentSize(requested: .zero, visibleScreenFrame: visible), .zero)
        XCTAssertEqual(
            PTWindowGeometryMath.clampedContentSize(requested: CGSize(width: CGFloat.nan, height: 600), visibleScreenFrame: visible),
            .zero
        )

        let base = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(PTWindowGeometryMath.orientedSize(baseSize: base, portrait: true), CGSize(width: 1080, height: 1920))
        XCTAssertEqual(PTWindowGeometryMath.orientedSize(baseSize: base, portrait: false), CGSize(width: 1920, height: 1080))

        let centered = PTWindowGeometryMath.centeredFrame(
            forContentSize: CGSize(width: 800, height: 600),
            currentFrame: CGRect(x: 100, y: 100, width: 400, height: 300),
            visibleScreenFrame: visible,
            titleBarHeight: 28
        )
        XCTAssertGreaterThanOrEqual(centered.minX, visible.minX)
        XCTAssertGreaterThanOrEqual(centered.minY, visible.minY)
        XCTAssertLessThanOrEqual(centered.maxX, visible.maxX)
        XCTAssertLessThanOrEqual(centered.maxY, visible.maxY)
        XCTAssertEqual(centered.width, 800)
        XCTAssertEqual(centered.height, 628)
    }

    func testTouchInputPipelineLatencyUnder4Milliseconds() {
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
        XCTAssertGreaterThan(resolvedCount, 900)
        XCTAssertLessThan(elapsedMs, 4.0)
    }

    func testAuxiliaryHostAndUIWindowFiltering() {
        // macOS TextInputUI floating cursor window must be rejected
        XCTAssertTrue(PTWindowGeometryMath.isAuxiliaryHostWindow(
            className: "TUINSWindow",
            delegateClassName: "TUINSWindow",
            isPanel: false,
            hasTitleOrFullScreenStyle: false,
            frameSize: CGSize(width: 64, height: 64)
        ))

        // NSPanel (open/save panels, IME candidate panels) must be rejected
        XCTAssertTrue(PTWindowGeometryMath.isAuxiliaryHostWindow(
            className: "NSOpenPanel",
            delegateClassName: nil,
            isPanel: true,
            hasTitleOrFullScreenStyle: true,
            frameSize: CGSize(width: 800, height: 600)
        ))

        // Primary Mac Catalyst scene host window must be accepted
        XCTAssertFalse(PTWindowGeometryMath.isAuxiliaryHostWindow(
            className: "UINSWindow",
            delegateClassName: "UINSSceneWindowController",
            isPanel: false,
            hasTitleOrFullScreenStyle: true,
            frameSize: CGSize(width: 1024, height: 796)
        ))

        // UIKit keyboard/effects overlay windows vs normal content windows
        XCTAssertTrue(PTWindowGeometryMath.isAuxiliaryUIWindow(className: "UITextEffectsWindow"))
        XCTAssertTrue(PTWindowGeometryMath.isAuxiliaryUIWindow(className: "UIRemoteKeyboardWindow"))
        XCTAssertFalse(PTWindowGeometryMath.isAuxiliaryUIWindow(className: "UIWindow"))
    }

    func testTouchWindowOrderingAndPointTranslation() {
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
        XCTAssertEqual(ordered, [2, 3, 0])

        let translated = PTWindowGeometryMath.pointInWindow(
            scenePoint: CGPoint(x: 250, y: 420),
            windowOrigin: CGPoint(x: 50, y: 100)
        )
        XCTAssertEqual(translated, CGPoint(x: 200, y: 320))
    }

    func testControlModeTransitionPolicyPreservesInFlightTextInputClick() {
        // Initial startup mode transition does not invalidate actions
        XCTAssertEqual(
            PTControlModeTransitionPolicy.invalidation(
                from: "off",
                to: "arbitraryClick",
                wasCursorHidden: false,
                nextCursorHidden: false,
                isInitial: true,
                keymappingEnabled: true
            ),
            .none
        )

        // Tapping a text view triggers arbitraryClick -> textInput before leftMouseUp;
        // both modes share direct-touch FakeMouseAction so in-flight tap must complete cleanly.
        XCTAssertEqual(
            PTControlModeTransitionPolicy.invalidation(
                from: "arbitraryClick",
                to: "textInput",
                wasCursorHidden: false,
                nextCursorHidden: false,
                isInitial: false,
                keymappingEnabled: true
            ),
            .none
        )
        XCTAssertEqual(
            PTControlModeTransitionPolicy.invalidation(
                from: "textInput",
                to: "arbitraryClick",
                wasCursorHidden: false,
                nextCursorHidden: false,
                isInitial: false,
                keymappingEnabled: true
            ),
            .none
        )

        // Switching to editor or off must invalidate all actions even when cursor stays visible
        XCTAssertEqual(
            PTControlModeTransitionPolicy.invalidation(
                from: "arbitraryClick",
                to: "editor",
                wasCursorHidden: false,
                nextCursorHidden: false,
                isInitial: false,
                keymappingEnabled: true
            ),
            .allActions
        )
        XCTAssertEqual(
            PTControlModeTransitionPolicy.invalidation(
                from: "textInput",
                to: "off",
                wasCursorHidden: false,
                nextCursorHidden: false,
                isInitial: false,
                keymappingEnabled: true
            ),
            .allActions
        )

        // Switching between direct-touch mode and cameraRotate must invalidate non-button actions
        XCTAssertEqual(
            PTControlModeTransitionPolicy.invalidation(
                from: "arbitraryClick",
                to: "cameraRotate",
                wasCursorHidden: false,
                nextCursorHidden: true,
                isInitial: false,
                keymappingEnabled: true
            ),
            .nonButtonActions
        )
    }

    func testLongPressStateMachineQuickClickHoldDragAndCancellation() {
        var sm = PTLongPressStateMachine()
        XCTAssertFalse(sm.isActive)

        // 1. Quick right-click: press, jitter before release, release before 650ms -> holds until timer fires
        let p0 = CGPoint(x: 120, y: 240)
        let first = sm.begin(at: p0)
        XCTAssertFalse(first.cancelledPrevious)
        XCTAssertTrue(sm.isActive)
        XCTAssertTrue(sm.isPhysicalButtonDown)
        XCTAssertFalse(sm.minHoldCompleted)
        XCTAssertEqual(sm.anchorPoint, p0)

        // Jitter while min hold has not elapsed must be suppressed
        XCTAssertFalse(sm.allowMove(to: CGPoint(x: 122, y: 243)))
        XCTAssertEqual(sm.anchorPoint, p0)

        // Quick physical release before min hold does NOT release touch yet
        XCTAssertFalse(sm.onPhysicalRelease())
        XCTAssertTrue(sm.isActive)
        XCTAssertFalse(sm.isPhysicalButtonDown)
        XCTAssertFalse(sm.allowMove(to: CGPoint(x: 150, y: 260)))

        // Timer fires for first.generation -> now releases touch
        XCTAssertTrue(sm.onMinimumHoldElapsed(generation: first.generation))
        XCTAssertFalse(sm.isActive)
        XCTAssertEqual(sm.anchorPoint, p0)

        // Redundant release or stale generation timer must be no-op
        XCTAssertFalse(sm.onMinimumHoldElapsed(generation: first.generation))
        XCTAssertFalse(sm.onPhysicalRelease())

        // 2. Press-and-hold >= 650ms -> keeps touch alive past 650ms, allows drag after 650ms, ends on release
        let p1 = CGPoint(x: 300, y: 400)
        let second = sm.begin(at: p1)
        XCTAssertFalse(second.cancelledPrevious)
        // Stale generation from earlier tap must be ignored
        XCTAssertFalse(sm.onMinimumHoldElapsed(generation: first.generation))
        // Pre-threshold drag still suppressed
        XCTAssertFalse(sm.allowMove(to: CGPoint(x: 302, y: 401)))

        // Threshold reached while physical button still held -> remains active
        XCTAssertFalse(sm.onMinimumHoldElapsed(generation: second.generation))
        XCTAssertTrue(sm.isActive)
        XCTAssertTrue(sm.minHoldCompleted)

        // Post-threshold drag allowed and updates anchorPoint
        let pDrag = CGPoint(x: 340, y: 420)
        XCTAssertTrue(sm.allowMove(to: pDrag))
        XCTAssertEqual(sm.anchorPoint, pDrag)

        // Physical release now ends the touch
        XCTAssertTrue(sm.onPhysicalRelease())
        XCTAssertFalse(sm.isActive)

        // 3. Re-press while quick-click auto-release still pending, and early finish (left click)
        let third = sm.begin(at: CGPoint(x: 50, y: 60))
        XCTAssertFalse(sm.onPhysicalRelease())
        let fourth = sm.begin(at: CGPoint(x: 80, y: 90))
        XCTAssertTrue(fourth.cancelledPrevious)
        XCTAssertFalse(sm.onMinimumHoldElapsed(generation: third.generation))
        XCTAssertTrue(sm.finishEarly())
        XCTAssertFalse(sm.isActive)
        XCTAssertFalse(sm.finishEarly())
        XCTAssertFalse(sm.onMinimumHoldElapsed(generation: fourth.generation))

        // 4. Invalidation tears down active long press and invalidates pending timer generation
        let fifth = sm.begin(at: CGPoint(x: 10, y: 20))
        XCTAssertTrue(sm.invalidate())
        XCTAssertFalse(sm.isActive)
        XCTAssertFalse(sm.invalidate())
        XCTAssertFalse(sm.onMinimumHoldElapsed(generation: fifth.generation))
    }

    func testTitlebarAwareClamping() {
        let laptopVisible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let titleBarHeight: CGFloat = 28

        // Tall portrait iPad (1024 x 1366) must subtract titleBarHeight BEFORE clamping
        let clampedPad = PTWindowGeometryMath.clampedContentSize(
            requested: CGSize(width: 1024, height: 1366),
            visibleScreenFrame: laptopVisible,
            titleBarHeight: titleBarHeight
        )
        XCTAssertLessThanOrEqual(clampedPad.width, laptopVisible.width)
        XCTAssertLessThanOrEqual(clampedPad.height + titleBarHeight, laptopVisible.height)
        XCTAssertEqual(clampedPad.width / clampedPad.height, 1024.0 / 1366.0, accuracy: 0.005)
        let centeredPad = PTWindowGeometryMath.centeredFrame(
            forContentSize: clampedPad,
            currentFrame: .zero,
            visibleScreenFrame: laptopVisible,
            titleBarHeight: titleBarHeight
        )
        XCTAssertGreaterThanOrEqual(centeredPad.minY, laptopVisible.minY)
        XCTAssertLessThanOrEqual(centeredPad.maxY, laptopVisible.maxY)

        // Fractional visible height still guarantees content + titlebar <= visible height
        let fractionalVisible = CGRect(x: 0, y: 0, width: 1440, height: 875.8)
        let clampedFrac = PTWindowGeometryMath.clampedContentSize(
            requested: CGSize(width: 440, height: 956),
            visibleScreenFrame: fractionalVisible,
            titleBarHeight: 28.0
        )
        XCTAssertLessThanOrEqual(clampedFrac.height + 28.0, fractionalVisible.height)
        XCTAssertEqual(clampedFrac.width / clampedFrac.height, 440.0 / 956.0, accuracy: 0.005)
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

    private func verifyStrictSpecs(_ expectations: [StrictSpecExpectation], expectedScale: Double) {
        for entry in expectations {
            let spec = PTWindowGeometryMath.StrictDeviceDisplaySpec.resolve(forModel: entry.model)
            XCTAssertEqual(spec.nativePixelWidth, entry.pxW)
            XCTAssertEqual(spec.nativePixelHeight, entry.pxH)
            XCTAssertEqual(spec.nativeScale, expectedScale)
            XCTAssertEqual(spec.logicalSize(orientation: "portrait"), entry.portrait)
            XCTAssertEqual(spec.logicalSize(orientation: "landscape"), entry.landscape)
        }
    }

    func testStrictDeviceDisplaySpecsForIPadModels() {
        let ipadExpected: [StrictSpecExpectation] = [
            .init("iPad6,7", 2048, 2732, 1024, 1366),
            .init("iPad8,6", 2048, 2732, 1024, 1366),
            .init("iPad13,8", 2048, 2732, 1024, 1366),
            .init("iPad14,5", 2048, 2732, 1024, 1366),
            .init("iPad16,6", 2064, 2752, 1032, 1376),
            .init("iPad17,3", 2064, 2752, 1032, 1376)
        ]
        verifyStrictSpecs(ipadExpected, expectedScale: 2.0)
        XCTAssertEqual(
            PTWindowGeometryMath.StrictDeviceDisplaySpec.resolve(forModel: "UnknownDevice").model,
            "iPad13,8"
        )
    }

    func testStrictDeviceDisplaySpecsForIPhoneModels() {
        let iphoneExpected: [StrictSpecExpectation] = [
            .init("iPhone12,5", 1242, 2688, 414, 896),
            .init("iPhone14,3", 1284, 2778, 428, 926),
            .init("iPhone15,3", 1290, 2796, 430, 932),
            .init("iPhone16,2", 1290, 2796, 430, 932),
            .init("iPhone17,2", 1320, 2868, 440, 956),
            .init("iPhone18,2", 1320, 2868, 440, 956)
        ]
        verifyStrictSpecs(iphoneExpected, expectedScale: 3.0)
        XCTAssertEqual(
            PTWindowGeometryMath.StrictDeviceDisplaySpec.resolve(forModel: "iPhone99,1").model,
            "iPhone17,2"
        )
    }

    func testStrictViewportWindowPlansFitScreenAndNative1x() {
        let laptopVisible = CGRect(x: 0, y: 25, width: 1440, height: 875)
        let titleBarHeight: CGFloat = 28

        let fitOversized = PTWindowGeometryMath.strictViewportWindowPlan(
            logicalSceneSize: CGSize(width: 1024, height: 1366),
            scaleMode: "fitScreen",
            visibleScreenFrame: laptopVisible,
            titleBarHeight: titleBarHeight
        )
        XCTAssertEqual(fitOversized.logicalSceneSize, CGSize(width: 1024, height: 1366))
        XCTAssertEqual(fitOversized.lockedAspectRatio, CGSize(width: 1024, height: 1366))
        XCTAssertEqual(fitOversized.windowContentSize, CGSize(width: 635, height: 847))
        XCTAssertTrue(fitOversized.allowsUserResize)

        let fitSmallPhone = PTWindowGeometryMath.strictViewportWindowPlan(
            logicalSceneSize: CGSize(width: 932, height: 430),
            scaleMode: "fitScreen",
            visibleScreenFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            titleBarHeight: titleBarHeight
        )
        XCTAssertEqual(fitSmallPhone.windowContentSize, CGSize(width: 932, height: 430))
        XCTAssertTrue(fitSmallPhone.allowsUserResize)

        let nativeOversized = PTWindowGeometryMath.strictViewportWindowPlan(
            logicalSceneSize: CGSize(width: 1024, height: 1366),
            scaleMode: "native1x",
            visibleScreenFrame: laptopVisible,
            titleBarHeight: titleBarHeight
        )
        XCTAssertEqual(nativeOversized.windowContentSize, CGSize(width: 635, height: 847))
        XCTAssertFalse(nativeOversized.allowsUserResize)

        let nativeSmall = PTWindowGeometryMath.strictViewportWindowPlan(
            logicalSceneSize: CGSize(width: 430, height: 932),
            scaleMode: "native1x",
            visibleScreenFrame: CGRect(x: 0, y: 0, width: 2560, height: 1415),
            titleBarHeight: titleBarHeight
        )
        XCTAssertEqual(nativeSmall.windowContentSize, CGSize(width: 430, height: 932))
        XCTAssertFalse(nativeSmall.allowsUserResize)
    }
}
