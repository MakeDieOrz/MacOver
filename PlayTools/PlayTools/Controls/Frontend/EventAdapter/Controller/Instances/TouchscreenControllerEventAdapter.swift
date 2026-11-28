//
//  TouchscreenControllerEventAdapter.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/16.
//

import Foundation
import GameController

// Controller events handler when keymap is on

public final class TouchscreenControllerEventAdapter: ControllerEventAdapter, @unchecked Sendable {

    private let dpadStateLock = PTUnfairLock()
    private var directionPadStateByProfile: [ObjectIdentifier: (x: Float, y: Float)] = [:]
    private static let controlsLock = PTUnfairLock()
    nonisolated(unsafe) static private var thumbstickCursorControl: [String: ThumbstickCursorControl] = [:]

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
            let profileID = ObjectIdentifier(profile)
            let nextX = xAxis.value
            let nextY = yAxis.value
            let previous = dpadStateLock.withLock { () -> (x: Float, y: Float) in
                let prev = directionPadStateByProfile[profileID] ?? (0, 0)
                if directionPadStateByProfile.count > 32 {
                    let activeIDs = Set(
                        GCController.controllers()
                            .compactMap { $0.extendedGamepad }
                            .map(ObjectIdentifier.init)
                    )
                    directionPadStateByProfile = directionPadStateByProfile.filter {
                        activeIDs.contains($0.key)
                    }
                }
                directionPadStateByProfile[profileID] = (nextX, nextY)
                return prev
            }
            if (nextX > 0) != (previous.x > 0) {
                handleValueChanged(profile, dpad.right)
            }
            if (nextX < 0) != (previous.x < 0) {
                handleValueChanged(profile, dpad.left)
            }
            if (nextY > 0) != (previous.y > 0) {
                handleValueChanged(profile, dpad.up)
            }
            if (nextY < 0) != (previous.y < 0) {
                handleValueChanged(profile, dpad.down)
            }
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
            let ctrl = Self.controlsLock.withLock { () -> ThumbstickCursorControl in
                if let existing = Self.thumbstickCursorControl[name] {
                    return existing
                }
                let created = ThumbstickCursorControl(name)
                Self.thumbstickCursorControl[name] = created
                return created
            }
            ctrl.update(velocityX: cgDx * 6, velocityY: cgDy * 6)
        }
    }

}

final class ThumbstickCursorControl: @unchecked Sendable {
    private static let instancesLock = PTUnfairLock()
    nonisolated(unsafe) private static var activeInstances: [ThumbstickCursorControl] = []

    private let stateLock = PTUnfairLock()
    private var thumbstickVelocity: CGVector = CGVector.zero
    private var thumbstickPolling: Bool = false
    private let key: String

    init(_ key: String) {
        self.key = key
        Self.instancesLock.withLock {
            Self.activeInstances.append(self)
        }
    }

    static func invalidateAll() {
        let snapshot = instancesLock.withLock { activeInstances }
        for instance in snapshot {
            instance.reset()
        }
    }

    func reset() {
        stateLock.withLock {
            thumbstickVelocity = .zero
            thumbstickPolling = false
        }
    }

    static private func isVectorSignificant(_ vector: CGVector) -> Bool {
        return vector.dx.magnitude + vector.dy.magnitude > 0.2
    }

    public func update(velocityX: CGFloat, velocityY: CGFloat) {
        let shouldStart = stateLock.withLock { () -> Bool in
            self.thumbstickVelocity.dx = velocityX
            self.thumbstickVelocity.dy = velocityY
            if !thumbstickPolling {
                thumbstickPolling = true
                return true
            }
            return false
        }

        if shouldStart {
            PlayInput.touchQueue.async { [weak self] in
                self?.thumbstickPoll()
            }
        }
    }

    private func thumbstickPoll() {
        let velocity: CGVector? = stateLock.withLock {
            if !thumbstickPolling || !ThumbstickCursorControl.isVectorSignificant(thumbstickVelocity) {
                thumbstickPolling = false
                return nil
            }
            return thumbstickVelocity
        }
        guard let velocity else { return }

        _ = ActionDispatcher.dispatch(key: key, valueX: velocity.dx, valueY: velocity.dy)
        PlayInput.touchQueue.asyncAfter(deadline: DispatchTime.now() + 0.017) { [weak self] in
            self?.thumbstickPoll()
        }
    }
}
