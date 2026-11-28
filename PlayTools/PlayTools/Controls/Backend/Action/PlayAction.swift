//
//  PlayAction.swift
//  PlayTools
//

import Foundation
import Synchronization

protocol Action: AnyObject, Sendable {
    func invalidate()
}
// Actions hold touch point IDs, perform fake touch

class ButtonAction: Action, @unchecked Sendable {
    func invalidate() {
        PlayInput.touchQueue.async { [weak self] in
            guard let self = self else { return }
            Toucher.touchcam(point: self.point, phase: UITouch.Phase.ended, tid: &self.id,
                             actionName: "Button", keyName: self.keyName)
        }
    }

    let keyCode: Int
    let keyName: String
    let point: CGPoint
    var id: Int?

    init(keyCode: Int, keyName: String, point: CGPoint) {
        self.keyCode = keyCode
        self.keyName = keyName
        self.point = point
        let code = keyCode
        let codeName = KeyCodeNames.keyCodes[code] ?? "Btn"
        // TODO: set both key names in draggable button, so as to depracate key code
        ActionDispatcher.register(key: code == KeyCodeNames.defaultCode ? keyName: codeName, handler: self.update)
    }

    convenience init(data: Button) {
        let keyCode = data.keyCode
        self.init(
            keyCode: keyCode,
            keyName: data.keyName,
            point: CGPoint(
                x: data.transform.xCoord.absoluteX,
                y: data.transform.yCoord.absoluteY))
    }

    func update(pressed: Bool) {
        if pressed {
            Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: &id,
                             actionName: "Button", keyName: keyName)
        } else {
            Toucher.touchcam(point: point, phase: UITouch.Phase.ended, tid: &id,
                             actionName: "Button", keyName: keyName)
        }
    }
}

final class DraggableButtonAction: ButtonAction, @unchecked Sendable {
    private static let activeCursorHideCount = Mutex<Int>(0)
    var releasePoint: CGPoint
    private var didRequestCursorHide = false

    override init(keyCode: Int, keyName: String, point: CGPoint) {
        self.releasePoint = point
        super.init(keyCode: keyCode, keyName: keyName, point: point)
    }

    convenience init(data: Button) {
        let resolvedKeyName = data.buttonKeyName ?? KeyCodeNames.keyCodes[data.keyCode] ?? data.keyName
        self.init(
            keyCode: data.keyCode,
            keyName: resolvedKeyName,
            point: CGPoint(
                x: data.transform.xCoord.absoluteX,
                y: data.transform.yCoord.absoluteY
            )
        )
    }

    private func acquireCursorHideIfNeeded() {
        guard !didRequestCursorHide, !mode.cursorHidden() else { return }
        didRequestCursorHide = true
        let shouldHide = Self.activeCursorHideCount.withLock { count -> Bool in
            count += 1
            return count == 1
        }
        if shouldHide {
            AKInterface.shared?.hideCursor()
        }
    }

    private func releaseCursorHideIfNeeded() {
        guard didRequestCursorHide else { return }
        didRequestCursorHide = false
        let shouldUnhide = Self.activeCursorHideCount.withLock { count -> Bool in
            guard count > 0 else { return false }
            count -= 1
            return count == 0
        }
        if shouldUnhide && !mode.cursorHidden() {
            AKInterface.shared?.unhideCursor()
        }
    }

    override func update(pressed: Bool) {
        if pressed {
            Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: &id,
                             actionName: "DraggableButton", keyName: keyName)
            self.releasePoint = point
            ActionDispatcher.registerDraggable(
                key: KeyCodeNames.mouseMove,
                token: ObjectIdentifier(self),
                handler: self.onMouseMoved
            )
            acquireCursorHideIfNeeded()
        } else {
            Toucher.touchcam(point: releasePoint, phase: UITouch.Phase.ended, tid: &id,
                             actionName: "DraggableButton", keyName: keyName)
            if id == nil {
                ActionDispatcher.unregisterDraggable(
                    key: KeyCodeNames.mouseMove,
                    token: ObjectIdentifier(self)
                )
                releaseCursorHideIfNeeded()
            }
        }
    }

    override func invalidate() {
        ActionDispatcher.unregisterDraggable(
            key: KeyCodeNames.mouseMove,
            token: ObjectIdentifier(self)
        )
        PlayInput.touchQueue.async { [weak self] in
            guard let self = self else { return }
            Toucher.touchcam(point: self.releasePoint, phase: UITouch.Phase.ended, tid: &self.id,
                             actionName: "DraggableButton", keyName: self.keyName)
            if self.id == nil {
                self.releaseCursorHideIfNeeded()
            }
        }
    }

    func onMouseMoved(deltaX: CGFloat, deltaY: CGFloat) {
        self.releasePoint.x += deltaX
        self.releasePoint.y -= deltaY
        Toucher.touchcam(point: self.releasePoint, phase: UITouch.Phase.moved, tid: &id,
                         actionName: "DraggableButton", keyName: keyName)
    }
}

class ContinuousJoystickAction: Action, @unchecked Sendable {
    var key: String
    var center: CGPoint
    var position: CGPoint
    private var id: Int?
    var sensitivity: CGFloat
    var mode: JoystickMode
    var begun = false

    init(data: Joystick) {
        self.center = CGPoint(
            x: data.transform.xCoord.absoluteX,
            y: data.transform.yCoord.absoluteY)
        self.key = data.keyName
        self.position = center
        self.sensitivity = data.transform.size.absoluteSize / 4
        self.mode = data.mode ?? Joystick.defaultMode
        if key == KeyCodeNames.mouseMove {
            ActionDispatcher.register(key: key, handler: self.mouseUpdate)
        } else {
            ActionDispatcher.register(key: key, handler: self.thumbstickUpdate)
        }
    }

    func update(_ point: CGPoint) {
        let dis = (center.x - point.x).magnitude + (center.y - point.y).magnitude
        if dis < 16 {
            if begun {
                begun = false
                Toucher.touchcam(point: point, phase: UITouch.Phase.ended, tid: &id,
                                 actionName: "ControllerJoystick", keyName: key)
            }
        } else if !begun {
            begun = true
            beginTouch(point)
        } else {
            Toucher.touchcam(point: point, phase: UITouch.Phase.moved, tid: &id,
                             actionName: "ControllerJoystick", keyName: key)
        }
    }

    func beginTouch(_ point: CGPoint) {
        if mode == .FIXED {
            Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: &id,
                             actionName: "ControllerJoystick", keyName: key)
        } else if mode == .FLOATING {
            Toucher.touchcam(point: self.center, phase: UITouch.Phase.began, tid: &id,
                             actionName: "ControllerJoystick", keyName: key)
            PlayInput.touchQueue.asyncAfter(deadline: .now() + 0.04, qos: .userInitiated) { [weak self] in
                guard let self = self, self.id != nil else {
                    return
                }
                Toucher.touchcam(point: point, phase: UITouch.Phase.moved, tid: &self.id,
                                 actionName: "ControllerJoystick", keyName: self.key)
            }
        }
    }

    func thumbstickUpdate(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        let pos = CGPoint(x: center.x + deltaX * sensitivity,
                          y: center.y - deltaY * sensitivity)
        self.update(pos)
    }

    func mouseUpdate(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        let maxRadius = max(sensitivity, 16)
        var nextX = position.x + deltaX
        var nextY = position.y - deltaY
        let dx = nextX - center.x
        let dy = nextY - center.y
        let distance = hypot(dx, dy)
        if distance > maxRadius && distance > 0 {
            let scale = maxRadius / distance
            nextX = center.x + dx * scale
            nextY = center.y + dy * scale
        }
        position = CGPoint(x: nextX, y: nextY)
        self.update(position)
    }

    func invalidate() {
        PlayInput.touchQueue.async { [weak self] in
            guard let self = self else { return }
            let endPoint = self.position
            self.begun = false
            self.position = self.center
            Toucher.touchcam(point: endPoint, phase: UITouch.Phase.ended, tid: &self.id,
                             actionName: "ControllerJoystick", keyName: self.key)
        }
    }
}

class JoystickAction: Action, @unchecked Sendable {
    let keys: [Int]
    let center: CGPoint
    var touch: CGPoint
    let shift: CGFloat
    var mode: JoystickMode
    var id: Int?
    private var keyPressed = [Bool](repeating: false, count: 4)
    init(keys: [Int], center: CGPoint, shift: CGFloat, mode: JoystickMode) {
        self.keys = keys
        self.center = center
        self.touch = center
        self.shift = shift / 4
        self.mode = mode
        for index in 0..<keys.count {
            let key = keys[index]
            guard let codeName = KeyCodeNames.keyCodes[key] else { continue }
            ActionDispatcher.register(key: codeName,
                                      handler: self.getPressedHandler(index: index))
        }
    }

    convenience init(data: Joystick) {
        self.init(
            keys: [
                data.upKeyCode,
                data.downKeyCode,
                data.leftKeyCode,
                data.rightKeyCode
            ],
            center: CGPoint(
                x: data.transform.xCoord.absoluteX,
                y: data.transform.yCoord.absoluteY),
            shift: data.transform.size.absoluteSize,
            mode: data.mode ?? Joystick.defaultMode)
    }

    func invalidate() {
        PlayInput.touchQueue.async { [weak self] in
            guard let self = self else { return }
            self.keyPressed = [Bool](repeating: false, count: 4)
            self.touch = self.center
            Toucher.touchcam(point: self.center, phase: UITouch.Phase.ended, tid: &self.id,
                             actionName: "KeyboardJoystick", keyName: "Keyboard")
        }
    }

    func getPressedHandler(index: Int) -> @Sendable (Bool) -> Void {
        if mode == .FIXED {
            return { pressed in
                self.updateTouch(index: index, pressed: pressed)
                self.handleFixed()
            }
        } else if mode == .FLOATING {
            return { pressed in
                self.updateTouch(index: index, pressed: pressed)
                self.handleFree()
            }
        } else {
            return { _ in
                // do nothing
            }
        }
    }

    func updateTouch(index: Int, pressed: Bool) {
        self.keyPressed[index] = pressed
        let isPlus = index & 1 != 0
        let realShift = isPlus ? shift : -shift
        if index > 1 {
            if pressed {
                touch.x = center.x + realShift
            } else if self.keyPressed[index ^ 1] {
                touch.x = center.x - realShift
            } else {
                touch.x = center.x
            }
        } else {
            if pressed {
                touch.y = center.y + realShift
            } else if self.keyPressed[index ^ 1] {
                touch.y = center.y - realShift
            } else {
                touch.y = center.y
            }
        }
    }

    func atCenter() -> Bool {
        return (center.x - touch.x).magnitude + (center.y - touch.y).magnitude < 8
    }

    func handleCommon(_ begin: () -> Void) {
        let moving = id != nil
        if atCenter() {
            if moving {
                Toucher.touchcam(point: touch, phase: UITouch.Phase.ended, tid: &id,
                                 actionName: "KeyboardJoystick", keyName: "Keyboard")
            }
        } else {
            if moving {
                Toucher.touchcam(point: touch, phase: UITouch.Phase.moved, tid: &id,
                                 actionName: "KeyboardJoystick", keyName: "Keyboard")
            } else {
                begin()
            }
        }
    }

    func handleFree() {
        handleCommon {
            Toucher.touchcam(point: self.center, phase: UITouch.Phase.began, tid: &id,
                             actionName: "KeyboardJoystick", keyName: "Keyboard")
            PlayInput.touchQueue.asyncAfter(deadline: .now() + 0.04, qos: .userInitiated) { [weak self] in
                guard let self = self, self.id != nil else {
                    return
                }
                Toucher.touchcam(point: self.touch, phase: UITouch.Phase.moved, tid: &self.id,
                                 actionName: "KeyboardJoystick", keyName: "Keyboard")
            } // end closure
        }
    }

    func handleFixed() {
        handleCommon {
            Toucher.touchcam(point: self.touch, phase: UITouch.Phase.began, tid: &id,
                             actionName: "KeyboardJoystick", keyName: "Keyboard")
        }
    }
}

final class CameraAction: Action, @unchecked Sendable {
    var swipeMove, swipeScale1, swipeScale2: SwipeAction
    static let swipeDrag = SwipeAction(actionName: "Drag", keyName: "ScrollWheel")
    var key: String
    var center: CGPoint

    init(data: MouseArea) {
        self.key = data.keyName
        let centerX = data.transform.xCoord.absoluteX
        let centerY = data.transform.yCoord.absoluteY
        center = CGPoint(x: centerX, y: centerY)
        swipeMove = SwipeAction(actionName: "Camera", keyName: key)
        swipeScale1 = SwipeAction(actionName: "Zoom1", keyName: "ScrollWheel")
        swipeScale2 = SwipeAction(actionName: "Zoom2", keyName: "ScrollWheel")
        ActionDispatcher.register(key: key, handler: self.moveUpdated,
                                  priority: .CAMERA)
        ActionDispatcher.register(key: KeyCodeNames.scrollWheelScale,
                                  handler: self.scaleUpdated)
        ActionDispatcher.register(key: KeyCodeNames.scrollWheelDrag,
                                  handler: CameraAction.dragUpdated)
    }
    func moveUpdated(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        swipeMove.move(from: {return center}, deltaX: deltaX, deltaY: deltaY)
    }

    func scaleUpdated(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        let centerY = screen.height / 2
        let centerX = screen.width / 2
        let minGap = max(centerY / 16, 8)
        var effectiveDeltaY = deltaY
        if effectiveDeltaY < 0 {
            let currentY2 = swipeScale2.isActive ? swipeScale2.location.y : (centerY + centerY / 2)
            let availableInward = currentY2 - (centerY + minGap)
            if availableInward <= 0 {
                swipeScale1.doLiftOff()
                swipeScale2.doLiftOff()
                return
            }
            effectiveDeltaY = max(effectiveDeltaY, -availableInward)
        }
        swipeScale1.move(from: {
            CGPoint(x: centerX, y: centerY / 2)
        }, deltaX: 0, deltaY: effectiveDeltaY)

        swipeScale2.move(from: {
            CGPoint(x: centerX, y: centerY + (centerY / 2))
        }, deltaX: 0, deltaY: -effectiveDeltaY)
        // Lift off once the two pinch touches reach the minimum separation around centerY.
        if swipeScale2.isActive &&
            (swipeScale2.location.y - centerY <= minGap || centerY - swipeScale1.location.y <= minGap) {
            swipeScale1.doLiftOff()
            swipeScale2.doLiftOff()
        }
    }

    static func dragUpdated(_ deltaX: CGFloat, _ deltaY: CGFloat) {
        swipeDrag.move(from: TouchscreenMouseEventAdapter.cursorPos, deltaX: deltaX * 4, deltaY: -deltaY * 4)
    }

    func invalidate() {
        swipeMove.invalidate()
        swipeScale1.invalidate()
        swipeScale2.invalidate()
        CameraAction.swipeDrag.invalidate()
    }
}

final class SwipeAction: Action, @unchecked Sendable {
    var location: CGPoint = CGPoint.zero
    private var id: Int?
    var isActive: Bool { id != nil }
    let timer = DispatchSource.makeTimerSource(flags: [], queue: PlayInput.touchQueue)
    private let timerLock = PTUnfairLock()
    private var isTimerSuspended = true
    private var isCancelled = false
    private let actionName: String, keyName: String
    init(actionName: String, keyName: String) {
        self.actionName = actionName
        self.keyName = keyName
        timer.schedule(deadline: DispatchTime.now() + 1, repeating: 0.1, leeway: DispatchTimeInterval.milliseconds(50))
        timer.setEventHandler(qos: .userInteractive) { [weak self] in
            self?.checkEnded()
        }
        timer.activate()
        timer.suspend()
    }

    deinit {
        timerLock.withLock {
            if !isCancelled {
                isCancelled = true
                if isTimerSuspended {
                    isTimerSuspended = false
                    timer.resume()
                }
                timer.cancel()
            }
        }
    }

    private func resumeTimerIfNeeded() {
        timerLock.withLock {
            if !isCancelled && isTimerSuspended {
                isTimerSuspended = false
                timer.resume()
            }
        }
    }

    private func suspendTimerIfNeeded() {
        timerLock.withLock {
            if !isCancelled && !isTimerSuspended {
                isTimerSuspended = true
                timer.suspend()
            }
        }
    }

    func delay(_ delay: Double, closure: @escaping @Sendable () -> Void) {
        let when = DispatchTime.now() + delay
        PlayInput.touchQueue.asyncAfter(deadline: when, execute: closure)
    }
    // Count swipe duration
    var counter = 0
    // if should wait before beginning next touch
    var cooldown = false
    var lastCounter = 0
    var shouldEdgeReset = false

    func checkEnded() {
        if self.counter == self.lastCounter {
            if self.counter < 4 {
                counter += 1
            } else {
                self.doLiftOff()
            }
        }
        self.lastCounter = self.counter
     }

    private func checkXYOutOfWindow(coordX: CGFloat, coordY: CGFloat) -> Bool {
        PTCoordinateMath.isPointOutOfBounds(
            CGPoint(x: coordX, y: coordY),
            boundsSize: CGSize(width: screen.width, height: screen.height)
        )
    }

    /**
     get a multiplier to current velocity, so as to make the predicted coordinate inside window
     */
    private func getVelocityScaler(predictX: CGFloat, predictY: CGFloat,
                                   nowX: CGFloat, nowY: CGFloat) -> CGFloat {
        PTCoordinateMath.velocityScaler(
            predicted: CGPoint(x: predictX, y: predictY),
            current: CGPoint(x: nowX, y: nowY),
            boundsSize: CGSize(width: screen.width, height: screen.height)
        )
    }

    public func move(from: () -> CGPoint?, deltaX: CGFloat, deltaY: CGFloat) {
        if id == nil {
            if cooldown {
                return
            }
            guard let start = from() else {return}
            location = start
            counter = 0
            Toucher.touchcam(point: location, phase: UITouch.Phase.began, tid: &id,
                             actionName: actionName, keyName: keyName)
            resumeTimerIfNeeded()
        } else {
            if shouldEdgeReset {
                doLiftOff()
                return
            }
            // 1. Put location update after touch action, so that final `end` touch has different location
            // 2. If `began` touched, do not `move` touch at the same time, otherwise the two may conflict
            Toucher.touchcam(point: self.location, phase: UITouch.Phase.moved, tid: &id,
                             actionName: actionName, keyName: keyName)
        }
        // Scale movement down, so that an edge reset won't cause a too short touch sequence
        var scaledDeltaX = deltaX
        var scaledDeltaY = deltaY
        // A scroll must have this number of touch events to get inertia
        let minTotalCounter = 16
        if counter < minTotalCounter {
            // Suppose the touch velocity doesn't change
            let predictX = self.location.x + CGFloat((minTotalCounter - counter)) * deltaX
            let predictY = self.location.y - CGFloat((minTotalCounter - counter)) * deltaY
            if checkXYOutOfWindow(coordX: predictX, coordY: predictY) {
                // Velocity needs scale down
                let scaler = getVelocityScaler(predictX: predictX, predictY: predictY,
                                               nowX: self.location.x, nowY: self.location.y)
                scaledDeltaX *= scaler
                scaledDeltaY *= scaler
            }
        }
        // count touch duration
        counter += 1
        self.location = PTCoordinateMath.applySwipeDelta(
            self.location,
            deltaX: scaledDeltaX,
            deltaY: scaledDeltaY
        )
        // Check if new location is out of window (position overflows)
        // May fail in some games if point moves out of window
        // If next touch is predicted out of window then this lift off instead
        if checkXYOutOfWindow(coordX: self.location.x + scaledDeltaX,
                              coordY: self.location.y - scaledDeltaY) {
            // Wait until next event to lift off, so as to maintain smooth scrolling speed
            shouldEdgeReset = true
        }
    }

    public func doLiftOff() {
        if id == nil {
            return
        }
        Toucher.touchcam(point: self.location, phase: UITouch.Phase.ended, tid: &id,
                         actionName: actionName, keyName: keyName)
        // Touch might somehow fail to end
        if id == nil {
            suspendTimerIfNeeded()
            delay(0.02) { [weak self] in
                self?.cooldown = false
            }
            cooldown = true
            shouldEdgeReset = false
        }
    }

    func invalidate() {
        PlayInput.touchQueue.async { [weak self] in
            guard let self = self else { return }
            self.doLiftOff()
            self.suspendTimerIfNeeded()
        }
    }
}

final class FakeMouseAction: Action, @unchecked Sendable {
    var id: Int?
    var pos: CGPoint = CGPoint()
    private let onPressWillBegin: (@Sendable () -> Void)?

    public init(onPressWillBegin: (@Sendable () -> Void)? = nil) {
        self.onPressWillBegin = onPressWillBegin
        ActionDispatcher.register(key: KeyCodeNames.fakeMouse, handler: buttonPressHandler)
        ActionDispatcher.register(key: KeyCodeNames.fakeMouse, handler: buttonLiftHandler)
    }

    func buttonPressHandler(xValue: CGFloat, yValue: CGFloat) {
        onPressWillBegin?()
        if id != nil {
            Toucher.touchcam(point: pos, phase: UITouch.Phase.cancelled, tid: &id,
                             actionName: "FakeMouse", keyName: "FakeMouse")
        }
        pos = CGPoint(x: xValue, y: yValue)
        Toucher.touchcam(point: pos, phase: UITouch.Phase.began, tid: &id,
                         actionName: "FakeMouse", keyName: "FakeMouse")
        if id != nil {
            ActionDispatcher.register(key: KeyCodeNames.fakeMouse,
                                      handler: movementHandler,
                                      priority: .DRAGGABLE)
        }
    }

    func buttonLiftHandler(pressed: Bool) {
        if pressed {
            Toast.showHint(title: "Error", text: ["Fake mouse lift handler received a press event"])
            return
        }
        ActionDispatcher.unregister(key: KeyCodeNames.fakeMouse)
        guard id != nil else { return }
        Toucher.touchcam(point: pos, phase: UITouch.Phase.ended, tid: &id,
                         actionName: "FakeMouse", keyName: "FakeMouse")
    }

    func movementHandler(xValue: CGFloat, yValue: CGFloat) {
        pos.x = xValue
        pos.y = yValue
        Toucher.touchcam(point: pos, phase: UITouch.Phase.moved, tid: &id,
                         actionName: "FakeMouse", keyName: "FakeMouse")
    }

    func invalidate() {
        ActionDispatcher.unregister(key: KeyCodeNames.fakeMouse)
        PlayInput.touchQueue.async { [weak self] in
            guard let self = self, self.id != nil else { return }
            Toucher.touchcam(point: self.pos,
                             phase: UITouch.Phase.cancelled, tid: &self.id,
                             actionName: "FakeMouse", keyName: "FakeMouse")
        }
    }

}

final class FakeRightLongPressAction: Action, @unchecked Sendable {
    var id: Int?
    private var state = PTLongPressStateMachine()
    private var autoReleaseWorkItem: DispatchWorkItem?

    public init() {
        ActionDispatcher.register(key: KeyCodeNames.fakeRightLongPress, handler: buttonPressHandler)
        ActionDispatcher.register(key: KeyCodeNames.fakeRightLongPress, handler: buttonLiftHandler)
    }

    private func finishTouch(phase: UITouch.Phase) {
        autoReleaseWorkItem?.cancel()
        autoReleaseWorkItem = nil
        ActionDispatcher.unregister(key: KeyCodeNames.fakeRightLongPress)
        guard id != nil else { return }
        Toucher.touchcam(point: state.anchorPoint, phase: phase, tid: &id,
                         actionName: "FakeRightLongPress", keyName: "FakeRightLongPress")
    }

    func buttonPressHandler(xValue: CGFloat, yValue: CGFloat) {
        autoReleaseWorkItem?.cancel()
        autoReleaseWorkItem = nil
        let point = CGPoint(x: xValue, y: yValue)
        let previousAnchor = state.anchorPoint
        let (cancelledPrevious, generation) = state.begin(at: point)
        if cancelledPrevious && id != nil {
            Toucher.touchcam(point: previousAnchor, phase: UITouch.Phase.cancelled, tid: &id,
                             actionName: "FakeRightLongPress", keyName: "FakeRightLongPress")
        }
        Toucher.touchcam(point: point, phase: UITouch.Phase.began, tid: &id,
                         actionName: "FakeRightLongPress", keyName: "FakeRightLongPress")
        guard id != nil else {
            _ = state.invalidate()
            ActionDispatcher.unregister(key: KeyCodeNames.fakeRightLongPress)
            return
        }

        ActionDispatcher.register(key: KeyCodeNames.fakeRightLongPress,
                                  handler: movementHandler,
                                  priority: .DRAGGABLE)
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.state.onMinimumHoldElapsed(generation: generation) {
                self.finishTouch(phase: UITouch.Phase.ended)
            }
        }
        autoReleaseWorkItem = workItem
        PlayInput.touchQueue.asyncAfter(
            deadline: .now() + .milliseconds(PTLongPressStateMachine.defaultMinimumHoldMilliseconds),
            execute: workItem
        )
    }

    func buttonLiftHandler(pressed: Bool) {
        guard !pressed else { return }
        if state.onPhysicalRelease() || id == nil {
            finishTouch(phase: UITouch.Phase.ended)
        }
    }

    func movementHandler(xValue: CGFloat, yValue: CGFloat) {
        let nextPoint = CGPoint(x: xValue, y: yValue)
        guard state.allowMove(to: nextPoint) else { return }
        Toucher.touchcam(point: nextPoint, phase: UITouch.Phase.moved, tid: &id,
                         actionName: "FakeRightLongPress", keyName: "FakeRightLongPress")
    }

    /// Completes any active long-press touch cleanly on `PlayInput.touchQueue` before a left-click begins.
    func finishEarlyOnTouchQueue() {
        autoReleaseWorkItem?.cancel()
        autoReleaseWorkItem = nil
        let endPoint = state.anchorPoint
        let wasActive = state.finishEarly()
        ActionDispatcher.unregister(key: KeyCodeNames.fakeRightLongPress)
        guard wasActive, id != nil else { return }
        Toucher.touchcam(point: endPoint, phase: UITouch.Phase.ended, tid: &id,
                         actionName: "FakeRightLongPress", keyName: "FakeRightLongPress")
    }

    func invalidate() {
        ActionDispatcher.unregister(key: KeyCodeNames.fakeRightLongPress)
        PlayInput.touchQueue.async { [weak self] in
            guard let self else { return }
            self.autoReleaseWorkItem?.cancel()
            self.autoReleaseWorkItem = nil
            let endPoint = self.state.anchorPoint
            _ = self.state.invalidate()
            guard self.id != nil else { return }
            Toucher.touchcam(point: endPoint, phase: UITouch.Phase.cancelled, tid: &self.id,
                             actionName: "FakeRightLongPress", keyName: "FakeRightLongPress")
        }
    }
}
