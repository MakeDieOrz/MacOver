//
//  ActionDispatcher.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/16.
//

import Foundation
import Synchronization

// If the same key is mapped to multiple different tasks, distinguish by priority
public enum ActionDispatchPriority: Int {
    case DRAGGABLE
    case DEFAULT
    case CAMERA
}

// This class reads keymap and thereby dispatch events

public final class ActionDispatcher: Sendable {
    static private let keymapVersion = "2.0."
    private struct DispatchState: Sendable {
        var actions = [Action]()
        var buttonHandlers: [String: [@Sendable (Bool) -> Void]] = [:]
        var cursorHideNecessary = true
    }
    static private let state = Mutex<DispatchState>(DispatchState())

    static private let priorityCount = 3
    // You can't put more than 8 cameras or 8 joysticks in a keymap right?
    static private let mappingCountPerPriority = 8
    static private let directionPadStorage = DirectionPadStorage(
        priorityCount: priorityCount,
        mappingCountPerPriority: mappingCountPerPriority
    )

    static private func clear() {
        let existingActions = state.withLock { state in
            let existing = state.actions
            state.actions = []
            state.buttonHandlers.removeAll(keepingCapacity: true)
            directionPadStorage.clear()
            return existing
        }

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
            state.withLock { $0.actions.append(contentsOf: newActions) }
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
        state.withLock { $0.actions.append(contentsOf: newActions) }
        // `cursorHideNecessary` is used to disable `option` toggle when there is no mouse mapping
        // but in the case this new feature disabled, `option` should always function.
        // this variable is set here to be checked for mouse mapping later.
        cursorHideNecessary =
        (getDispatchPriority(key: KeyCodeNames.leftMouseButton) ?? .DRAGGABLE) != .DRAGGABLE ||
        (getDispatchPriority(key: KeyCodeNames.mouseMove) ?? .DRAGGABLE) != .DRAGGABLE
    }

    static public func register(key: String, handler: @escaping @Sendable (Bool) -> Void) {
        // this function is called when setting up `button` type of mapping
        state.withLock { state in
            if state.buttonHandlers[key] == nil {
                state.buttonHandlers[key] = []
            }
            state.buttonHandlers[key]?.append(handler)
        }
    }

    static public func register(key: String,
                                handler: @escaping @Sendable (CGFloat, CGFloat) -> Void,
                                priority: ActionDispatchPriority = .DEFAULT) {
        directionPadStorage.register(key: key, handler: handler, priority: priority)
    }

    static public func unregister(key: String) {
        // Only draggable can be unregistered
        directionPadStorage.unregisterDraggable(key: key)
    }

    // Frontend interfaces

    static public var cursorHideNecessary: Bool {
        get {
            state.withLock { $0.cursorHideNecessary }
        }
        set {
            state.withLock { $0.cursorHideNecessary = newValue }
        }
    }

    /**
        Lift off (release) all actions' touch points.
        Would be called during mode switching where target mode shouldn't have any touch remain.
    */
    static public func invalidateActions() {
        let currentActions = state.withLock { $0.actions }
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
        let currentActions = state.withLock { $0.actions }
        for action in currentActions
        where !(action is ButtonAction || action is JoystickAction) {
            action.invalidate()
        }
    }

    static public func getDispatchPriority(key: String) -> ActionDispatchPriority? {
        if let priority = directionPadStorage.priority(forKey: key) {
            return priority
        }

        let hasButtonHandler = state.withLock { $0.buttonHandlers[key] != nil }
        if hasButtonHandler {
            return .DEFAULT
        }
        return nil
    }

    static public func dispatch(key: String, pressed: Bool) -> Bool {
        let handlers = state.withLock { $0.buttonHandlers[key] }
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

private struct DirectionPadHandler: Sendable {
    static let empty = DirectionPadHandler(key: "", handle: { _, _ in })
    let key: String
    let handle: @Sendable (CGFloat, CGFloat) -> Void
}

private final class DirectionPadStorage: Sendable {
    private struct Storage: Sendable {
        var handlers: [[DirectionPadHandler]]
        var activePriorityMask: UInt8 = 0
    }

    private let priorityCount: Int
    private let storage: Mutex<Storage>

    init(priorityCount: Int, mappingCountPerPriority: Int) {
        self.priorityCount = priorityCount
        let initialHandlers = Array(
            repeating: Array(repeating: DirectionPadHandler.empty, count: mappingCountPerPriority),
            count: priorityCount
        )
        self.storage = Mutex(Storage(handlers: initialHandlers))
    }

    private func refreshPriorityMaskLocked(_ state: inout Storage) {
        var mask: UInt8 = 0
        for p in 0..<priorityCount where state.handlers[p].contains(where: { !$0.key.isEmpty }) {
            mask |= UInt8(1 << p)
        }
        state.activePriorityMask = mask
    }

    func clear() {
        storage.withLock { state in
            for p in 0..<state.handlers.count {
                for idx in 0..<state.handlers[p].count {
                    state.handlers[p][idx] = .empty
                }
            }
            state.activePriorityMask = 0
        }
    }

    func register(
        key: String,
        handler: @escaping @Sendable (CGFloat, CGFloat) -> Void,
        priority: ActionDispatchPriority
    ) {
        storage.withLock { state in
            let row = priority.rawValue
            if let existingIndex = state.handlers[row].firstIndex(where: { $0.key == key }) {
                state.handlers[row][existingIndex] = DirectionPadHandler(key: key, handle: handler)
            } else if let emptyIndex = state.handlers[row].firstIndex(where: { $0.key.isEmpty }) {
                state.handlers[row][emptyIndex] = DirectionPadHandler(key: key, handle: handler)
            }
            refreshPriorityMaskLocked(&state)
        }
    }

    func unregisterDraggable(key: String) {
        storage.withLock { state in
            let row = ActionDispatchPriority.DRAGGABLE.rawValue
            if let index = state.handlers[row].firstIndex(where: { $0.key == key }) {
                state.handlers[row][index] = .empty
                refreshPriorityMaskLocked(&state)
            }
        }
    }

    func priority(forKey key: String) -> ActionDispatchPriority? {
        storage.withLock { state in
            guard state.activePriorityMask != 0 else { return nil }
            for priority in 0..<priorityCount where (state.activePriorityMask & UInt8(1 << priority)) != 0 {
                if state.handlers[priority].contains(where: { $0.key == key }) {
                    return ActionDispatchPriority(rawValue: priority)
                }
            }
            return nil
        }
    }

    func handler(atPriority priority: ActionDispatchPriority, key: String) -> (@Sendable (CGFloat, CGFloat) -> Void)? {
        storage.withLock { state in
            guard (state.activePriorityMask & UInt8(1 << priority.rawValue)) != 0 else {
                return nil
            }
            return state.handlers[priority.rawValue].first(where: { $0.key == key })?.handle
        }
    }

    func handler(forKey key: String) -> (@Sendable (CGFloat, CGFloat) -> Void)? {
        storage.withLock { state in
            guard state.activePriorityMask != 0 else { return nil }
            for priority in 0..<priorityCount where (state.activePriorityMask & UInt8(1 << priority)) != 0 {
                if let match = state.handlers[priority].first(where: { $0.key == key }) {
                    return match.handle
                }
            }
            return nil
        }
    }
}
