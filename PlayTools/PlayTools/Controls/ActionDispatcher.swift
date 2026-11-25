//
//  ActionDispatcher.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/16.
//

import Foundation
import os.lock

// If the same key is mapped to multiple different tasks, distinguish by priority
public enum ActionDispatchPriority: Int {
    case DRAGGABLE
    case DEFAULT
    case CAMERA
}

// This class reads keymap and thereby dispatch events

public class ActionDispatcher {
    static private let keymapVersion = "2.0."
    static private let lock = NSLock()
    static private var actions = [Action]()
    static private var buttonHandlers: [String: [(Bool) -> Void]] = [:]

    static private let priorityCount = 3
    // You can't put more than 8 cameras or 8 joysticks in a keymap right?
    static private let mappingCountPerPriority = 8
    static private let directionPadStorage = DirectionPadStorage(
        priorityCount: priorityCount,
        mappingCountPerPriority: mappingCountPerPriority
    )

    static private func clear() {
        lock.lock()
        let existingActions = actions
        actions = []
        buttonHandlers.removeAll(keepingCapacity: true)
        directionPadStorage.clear()
        lock.unlock()

        for action in existingActions {
            action.invalidate()
        }
        Toucher.clearCachedTargets()
        ThumbstickCursorControl.invalidateAll()
    }

    // Backend interfaces

    // This should be called whenever keymap may change
    static public func build() {
        clear()

        let rightLongPress = FakeRightLongPressAction()
        var newActions: [Action] = [
            FakeMouseAction(onPressWillBegin: { rightLongPress.finishEarlyOnTouchQueue() }),
            rightLongPress
        ]

        // current keymap version is 2.0.x.
        // in future, keymap format will be upgraded.
        // PlayTools would maintain limited backwards compatibility.
        // Meanwhile, keymap format upgrade would be rare.
        let currentMap = keymap.currentKeymap
        if !currentMap.version.hasPrefix(keymapVersion) {
            lock.lock()
            actions.append(contentsOf: newActions)
            lock.unlock()
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .seconds(5)) {
                    Toast.showHint(title: "Keymap format too new",
                       text: ["Current keymap version \(currentMap.version)" +
                              " is too new and cannot be recognized\n" +
                              "For protection of your data, keymap is not loaded\n" +
                              "Please upgrade PlayCover, " +
                              "or import an older version of keymap (requires \(keymapVersion)x"])
            }
            return
        }

        for button in currentMap.buttonModels {
            newActions.append(ButtonAction(data: button))
        }

        for draggableButton in currentMap.draggableButtonModels {
            newActions.append(DraggableButtonAction(data: draggableButton))
        }

        for mouse in currentMap.mouseAreaModel {
            newActions.append(CameraAction(data: mouse))
        }

        for joystick in currentMap.joystickModel {
            // Left Thumbstick, Right Thumbstick, Mouse
            if JoystickModel.isAnalog(joystick) {
                newActions.append(ContinuousJoystickAction(data: joystick))
            } else { // Keyboard
                newActions.append(JoystickAction(data: joystick))
            }
        }
        lock.lock()
        actions.append(contentsOf: newActions)
        lock.unlock()
        // `cursorHideNecessary` is used to disable `option` toggle when there is no mouse mapping
        // but in the case this new feature disabled, `option` should always function.
        // this variable is set here to be checked for mouse mapping later.
        cursorHideNecessary =
        (getDispatchPriority(key: KeyCodeNames.leftMouseButton) ?? .DRAGGABLE) != .DRAGGABLE ||
        (getDispatchPriority(key: KeyCodeNames.mouseMove) ?? .DRAGGABLE) != .DRAGGABLE
    }

    static public func register(key: String, handler: @escaping (Bool) -> Void) {
        // this function is called when setting up `button` type of mapping
        lock.lock()
        defer { lock.unlock() }
        if buttonHandlers[key] == nil {
            buttonHandlers[key] = []
        }
        buttonHandlers[key]?.append(handler)
    }

    static public func register(key: String,
                                handler: @escaping (CGFloat, CGFloat) -> Void,
                                priority: ActionDispatchPriority = .DEFAULT) {
        lock.lock()
        defer { lock.unlock() }
        directionPadStorage.register(key: key, handler: handler, priority: priority)
    }

    static public func unregister(key: String) {
        // Only draggable can be unregistered
        lock.lock()
        defer { lock.unlock() }
        directionPadStorage.unregisterDraggable(key: key)
    }

    // Frontend interfaces

    static public var cursorHideNecessary = true

    /**
        Lift off (release) all actions' touch points.
        Would be called during mode switching where target mode shouldn't have any touch remain.
    */
    static public func invalidateActions() {
        lock.lock()
        let currentActions = actions
        lock.unlock()
        for action in currentActions {
            // This is just a rescue feature, in case any key stuck pressed for any reason
            // Might be called on control mode state transition
            action.invalidate()
        }
    }

    /**
        Lift off (release) touch points of actions that moves freely under control of the
        user. (e.g. camera control action) Would be called during every mode switching
        where `invalidateActions` is not called. In such scenario button-type
        actions are not released, because users may continue using them across different modes.
        (e.g. holding W while unhiding cursor to click something)

        But non-button-type actions (e.g. camera control action, fake mouse action) are unlikely
        used across modes. If they're not released, they would interfere with and ruin the game's
        camera control (becomes random zoom in zoom out)
    */
    static public func invalidateNonButtonActions() {
        lock.lock()
        let currentActions = actions
        lock.unlock()
        for action in currentActions
        where !(action is ButtonAction || action is JoystickAction) {
            action.invalidate()
        }
    }

    static public func getDispatchPriority(key: String) -> ActionDispatchPriority? {
        if let priority = directionPadStorage.priority(forKey: key) {
            return priority
        }

        lock.lock()
        let hasButtonHandler = buttonHandlers[key] != nil
        lock.unlock()
        if hasButtonHandler {
            return .DEFAULT
        }
        return nil
    }

    static public func dispatch(key: String, pressed: Bool) -> Bool {
        lock.lock()
        let handlers = buttonHandlers[key]
        lock.unlock()
        guard let handlers, !handlers.isEmpty else {
            return false
        }
        if handlers.count == 1, let onlyHandler = handlers.first {
            PlayInput.touchQueue.async(qos: .userInteractive) {
                onlyHandler(pressed)
            }
            return true
        }
        PlayInput.touchQueue.async(qos: .userInteractive) {
            for handler in handlers {
                handler(pressed)
            }
        }
        // return value matters. A false value makes a beep sound
        return true
    }

    /// Single-scan combined priority check + dispatch (avoids redundant 24-slot scans on mouse move hot paths).
    static public func dispatchAtPriority(_ priority: ActionDispatchPriority,
                                          key: String,
                                          valueX: CGFloat,
                                          valueY: CGFloat) -> Bool {
        guard let handle = directionPadStorage.handler(atPriority: priority, key: key) else {
            return false
        }
        PlayInput.touchQueue.async(qos: .userInteractive) {
            handle(valueX, valueY)
        }
        return true
    }

    static public func dispatch(key: String, valueX: CGFloat, valueY: CGFloat) -> Bool {
        guard let handle = directionPadStorage.handler(forKey: key) else {
            return false
        }
        PlayInput.touchQueue.async(qos: .userInteractive) {
            handle(valueX, valueY)
        }
        return true
    }
}

private struct DirectionPadHandler {
    static let empty = DirectionPadHandler(key: "", handle: { _, _ in })
    let key: String
    let handle: (CGFloat, CGFloat) -> Void
}

private final class DirectionPadStorage {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let priorityCount: Int
    private var handlers: [[DirectionPadHandler]]
    private var activePriorityMask: UInt8 = 0

    init(priorityCount: Int, mappingCountPerPriority: Int) {
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
        self.priorityCount = priorityCount
        self.handlers = Array(
            repeating: Array(repeating: DirectionPadHandler.empty, count: mappingCountPerPriority),
            count: priorityCount
        )
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    private func refreshPriorityMaskLocked() {
        var mask: UInt8 = 0
        for p in 0..<priorityCount {
            if handlers[p].contains(where: { !$0.key.isEmpty }) {
                mask |= UInt8(1 << p)
            }
        }
        activePriorityMask = mask
    }

    func clear() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        for p in 0..<handlers.count {
            for idx in 0..<handlers[p].count {
                handlers[p][idx] = .empty
            }
        }
        activePriorityMask = 0
    }

    func register(key: String, handler: @escaping (CGFloat, CGFloat) -> Void, priority: ActionDispatchPriority) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let row = priority.rawValue
        if let existingIndex = handlers[row].firstIndex(where: { $0.key == key }) {
            handlers[row][existingIndex] = DirectionPadHandler(key: key, handle: handler)
        } else if let emptyIndex = handlers[row].firstIndex(where: { $0.key.isEmpty }) {
            handlers[row][emptyIndex] = DirectionPadHandler(key: key, handle: handler)
        }
        refreshPriorityMaskLocked()
    }

    func unregisterDraggable(key: String) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let row = ActionDispatchPriority.DRAGGABLE.rawValue
        if let index = handlers[row].firstIndex(where: { $0.key == key }) {
            handlers[row][index] = .empty
            refreshPriorityMaskLocked()
        }
    }

    func priority(forKey key: String) -> ActionDispatchPriority? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard activePriorityMask != 0 else { return nil }
        for priority in 0..<priorityCount where (activePriorityMask & UInt8(1 << priority)) != 0 {
            if handlers[priority].contains(where: { $0.key == key }) {
                return ActionDispatchPriority(rawValue: priority)
            }
        }
        return nil
    }

    func handler(atPriority priority: ActionDispatchPriority, key: String) -> ((CGFloat, CGFloat) -> Void)? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard (activePriorityMask & UInt8(1 << priority.rawValue)) != 0 else {
            return nil
        }
        return handlers[priority.rawValue].first(where: { $0.key == key })?.handle
    }

    func handler(forKey key: String) -> ((CGFloat, CGFloat) -> Void)? {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard activePriorityMask != 0 else { return nil }
        for priority in 0..<priorityCount where (activePriorityMask & UInt8(1 << priority)) != 0 {
            if let match = handlers[priority].first(where: { $0.key == key }) {
                return match.handle
            }
        }
        return nil
    }
}
