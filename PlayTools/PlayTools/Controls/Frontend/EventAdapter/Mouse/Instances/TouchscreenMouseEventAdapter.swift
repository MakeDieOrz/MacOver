//
//  TouchscreenMouseEventAdapter.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/16.
//

import Foundation

// Mouse events handler when cursor is free and keyboard mapping is on

public class TouchscreenMouseEventAdapter: MouseEventAdapter {
    public let isTextInput: Bool
    private var rightLongPressPending = false

    public init(isTextInput: Bool = false) {
        self.isTextInput = isTextInput
    }

    static public func cursorPos() -> CGPoint? {
        // IMPROVE: this is expensive (maybe?)
        guard let ak = AKInterface.shared else { return nil }
        return PTCoordinateMath.cursorPosition(
            mousePoint: ak.mousePoint,
            windowFrame: ak.windowFrame,
            viewRect: screen.screenRect,
            resizable: screen.resizable,
            fullscreen: screen.fullscreen
        )
    }

    public func handleScrollWheel(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        if isTextInput {
            return false
        }
        _ = ActionDispatcher.dispatch(key: KeyCodeNames.scrollWheelDrag, valueX: deltaX, valueY: deltaY)
        // I dont know why but this is the logic before the refactor.
        // Might be a mistake but keeping it for now
        return false
    }

    public func handleMove(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        if !isTextInput,
           ActionDispatcher.dispatchAtPriority(.DRAGGABLE, key: KeyCodeNames.mouseMove,
                                               valueX: deltaX, valueY: -deltaY) {
            return true
        }
        if ActionDispatcher.getDispatchPriority(key: KeyCodeNames.fakeMouse) == .DRAGGABLE {
            // condition meets when mouse pressed and draggable button not pressed
            guard let pos = TouchscreenMouseEventAdapter.cursorPos() else { return false }
            return ActionDispatcher.dispatchAtPriority(.DRAGGABLE, key: KeyCodeNames.fakeMouse,
                                                       valueX: pos.x, valueY: pos.y)
        }
        if ActionDispatcher.getDispatchPriority(key: KeyCodeNames.fakeRightLongPress) == .DRAGGABLE {
            guard let pos = TouchscreenMouseEventAdapter.cursorPos() else { return false }
            return ActionDispatcher.dispatchAtPriority(.DRAGGABLE, key: KeyCodeNames.fakeRightLongPress,
                                                       valueX: pos.x, valueY: pos.y)
        }
        return false
    }

    public func handleLeftButton(pressed: Bool) -> Bool {
        if !pressed {
            if ActionDispatcher.getDispatchPriority(key: KeyCodeNames.fakeMouse) == .DRAGGABLE {
                return ActionDispatcher.dispatch(key: KeyCodeNames.fakeMouse, pressed: false)
            }
            guard TouchscreenMouseEventAdapter.cursorPos() != nil else { return false }
            return ActionDispatcher.dispatch(key: KeyCodeNames.fakeMouse, pressed: false)
        }
        // It is necessary to calculate pos before pushing to dispatch queue
        // Otherwise, we don't know whether to return false or true
        guard let pos = TouchscreenMouseEventAdapter.cursorPos() else { return false }
        return ActionDispatcher.dispatch(key: KeyCodeNames.fakeMouse, valueX: pos.x, valueY: pos.y)
    }

    public func handleOtherButton(id: Int, pressed: Bool) -> Bool {
        let buttonName = EditorMouseEventAdapter.getMouseButtonName(id)
        if !isTextInput, ActionDispatcher.dispatch(key: buttonName, pressed: pressed) {
            return true
        }
        guard buttonName == KeyCodeNames.rightMouseButton,
              PlaySettings.shared.rightClickLongPress else {
            return false
        }
        if !pressed {
            if rightLongPressPending
                || ActionDispatcher.getDispatchPriority(key: KeyCodeNames.fakeRightLongPress) == .DRAGGABLE {
                rightLongPressPending = false
                return ActionDispatcher.dispatch(key: KeyCodeNames.fakeRightLongPress, pressed: false)
            }
            return false
        }
        guard let pos = TouchscreenMouseEventAdapter.cursorPos() else { return false }
        if screen.isPointInsideActiveTextInput(pos) {
            return false
        }
        let dispatched = ActionDispatcher.dispatch(
            key: KeyCodeNames.fakeRightLongPress,
            valueX: pos.x,
            valueY: pos.y
        )
        rightLongPressPending = dispatched
        return dispatched
    }

    public func cursorHidden() -> Bool {
        false
    }

}
