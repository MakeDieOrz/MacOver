//
//  CameraControlMouseEventAdapter.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/16.
//

import Foundation

// Mouse events handler when cursor is locked and keyboard mapping is on

public class CameraControlMouseEventAdapter: MouseEventAdapter {
    public func handleScrollWheel(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        _ = ActionDispatcher.dispatch(key: KeyCodeNames.scrollWheelScale, valueX: deltaX, valueY: deltaY)
        // I dont know why but this is the logic before the refactor.
        // Might be a mistake but keeping it for now
        return true
    }

    public func handleMove(deltaX: CGFloat, deltaY: CGFloat) -> Bool {
        let delta = PTCoordinateMath.scaledCameraDelta(
            deltaX: deltaX,
            deltaY: deltaY,
            sensitivity: PlaySettings.shared.sensitivity
        )
        return ActionDispatcher.dispatch(key: KeyCodeNames.mouseMove, valueX: delta.dx, valueY: delta.dy)
    }

    public func handleLeftButton(pressed: Bool) -> Bool {
        ActionDispatcher.dispatch(key: KeyCodeNames.leftMouseButton, pressed: pressed)
    }

    public func handleOtherButton(id: Int, pressed: Bool) -> Bool {
        ActionDispatcher.dispatch(key: EditorMouseEventAdapter.getMouseButtonName(id),
                                  pressed: pressed)
    }

    public func cursorHidden() -> Bool {
        true
    }

}
