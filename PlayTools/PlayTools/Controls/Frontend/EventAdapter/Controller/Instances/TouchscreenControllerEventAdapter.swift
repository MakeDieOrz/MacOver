//
//  TouchscreenControllerEventAdapter.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/16.
//

import Foundation
import GameController

// Controller events handler when keymap is on

public class TouchscreenControllerEventAdapter: ControllerEventAdapter {

    private var directionPadXValue: Float = 0,
                directionPadYValue: Float = 0
    static private var thumbstickCursorControl: [String: ThumbstickCursorControl] = [:]

    public func handleValueChanged(_ profile: GCExtendedGamepad, _ element: GCControllerElement) {
        guard let name = element.aliases.first else { return }
        if let buttonElement = element as? GCControllerButtonInput {
            _ = ActionDispatcher.dispatch(key: name, pressed: buttonElement.isPressed)
        } else if let dpadElement = element as? GCControllerDirectionPad {
            handleDirectionPad(profile, dpadElement)
        } else {
            Toast.showOver(msg: "unrecognised controller element input happens")
        }
    }

    private func handleDirectionPad(_ profile: GCExtendedGamepad, _ dpad: GCControllerDirectionPad) {
        guard let name = dpad.aliases.first else { return }
        let xAxis = dpad.xAxis, yAxis = dpad.yAxis
        if name == "Direction Pad" {
            if (xAxis.value > 0) != (directionPadXValue > 0) {
                handleValueChanged(profile, dpad.right)
            }
            if (xAxis.value < 0) != (directionPadXValue < 0) {
                handleValueChanged(profile, dpad.left)
            }
            if (yAxis.value > 0) != (directionPadYValue > 0) {
                handleValueChanged(profile, dpad.up)
            }
            if (yAxis.value < 0) != (directionPadYValue < 0) {
                handleValueChanged(profile, dpad.down)
            }
            directionPadXValue = xAxis.value
            directionPadYValue = yAxis.value
            return
        }
        let deltaX = xAxis.value, deltaY = yAxis.value
        let cgDx = CGFloat(deltaX)
        let cgDy = CGFloat(deltaY)
        let dispatchType = ActionDispatcher.getDispatchPriority(key: name)
        if dispatchType == nil {
            return
        } else if dispatchType == .DEFAULT {
            _ = ActionDispatcher.dispatch(key: name, valueX: cgDx, valueY: cgDy)
        } else {
            let ctrl: ThumbstickCursorControl
            if let existing = Self.thumbstickCursorControl[name] {
                ctrl = existing
            } else {
                ctrl = ThumbstickCursorControl(name)
                Self.thumbstickCursorControl[name] = ctrl
            }
            ctrl.update(velocityX: cgDx * 6, velocityY: cgDy * 6)
        }
    }

}

class ThumbstickCursorControl {
    private static let instancesLock: UnsafeMutablePointer<os_unfair_lock_s> = {
        let ptr = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        ptr.initialize(to: os_unfair_lock_s())
        return ptr
    }()
    private static var activeInstances: [ThumbstickCursorControl] = []

    private let stateLock: UnsafeMutablePointer<os_unfair_lock_s>
    private var thumbstickVelocity: CGVector = CGVector.zero
    private var thumbstickPolling: Bool = false
    private let key: String

    init(_ key: String) {
        self.key = key
        self.stateLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        self.stateLock.initialize(to: os_unfair_lock_s())
        os_unfair_lock_lock(Self.instancesLock)
        Self.activeInstances.append(self)
        os_unfair_lock_unlock(Self.instancesLock)
    }

    deinit {
        stateLock.deinitialize(count: 1)
        stateLock.deallocate()
    }

    static func invalidateAll() {
        os_unfair_lock_lock(instancesLock)
        let snapshot = activeInstances
        os_unfair_lock_unlock(instancesLock)
        for instance in snapshot {
            instance.reset()
        }
    }

    func reset() {
        os_unfair_lock_lock(stateLock)
        thumbstickVelocity = .zero
        thumbstickPolling = false
        os_unfair_lock_unlock(stateLock)
    }

    static private func isVectorSignificant(_ vector: CGVector) -> Bool {
        return vector.dx.magnitude + vector.dy.magnitude > 0.2
    }

    public func update(velocityX: CGFloat, velocityY: CGFloat) {
        os_unfair_lock_lock(stateLock)
        self.thumbstickVelocity.dx = velocityX
        self.thumbstickVelocity.dy = velocityY
        let shouldStart = !thumbstickPolling
        if shouldStart {
            thumbstickPolling = true
        }
        os_unfair_lock_unlock(stateLock)

        if shouldStart {
            PlayInput.touchQueue.async { [weak self] in
                self?.thumbstickPoll()
            }
        }
    }

    private func thumbstickPoll() {
        os_unfair_lock_lock(stateLock)
        let velocity = thumbstickVelocity
        let isPolling = thumbstickPolling
        if !isPolling || !ThumbstickCursorControl.isVectorSignificant(velocity) {
            thumbstickPolling = false
            os_unfair_lock_unlock(stateLock)
            return
        }
        os_unfair_lock_unlock(stateLock)

        _ = ActionDispatcher.dispatch(key: key, valueX: velocity.dx, valueY: velocity.dy)
        PlayInput.touchQueue.asyncAfter(deadline: DispatchTime.now() + 0.017) { [weak self] in
            self?.thumbstickPoll()
        }
    }
}
