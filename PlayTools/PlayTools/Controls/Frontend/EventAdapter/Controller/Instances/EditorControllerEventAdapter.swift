//
//  EditorControllerEventAdapter.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/9/16.
//

import Foundation
import GameController

// Controller events handler when in editor mode

public class EditorControllerEventAdapter: ControllerEventAdapter {
    public func handleValueChanged(_ profile: GCExtendedGamepad, _ element: GCControllerElement) {
        guard var alias = element.aliases.first else {
            return
        }
        if alias == "Direction Pad" {
            guard let dpadElement = element as? GCControllerDirectionPad else {
                Toast.showOver(msg: "cannot map direction pad: element type not recognizable")
                return
            }
            if dpadElement.xAxis.value > 0, let rightAlias = dpadElement.right.aliases.first {
                alias = rightAlias
            } else if dpadElement.xAxis.value < 0, let leftAlias = dpadElement.left.aliases.first {
                alias = leftAlias
            }
            if dpadElement.yAxis.value > 0, let upAlias = dpadElement.up.aliases.first {
                alias = upAlias
            } else if dpadElement.yAxis.value < 0, let downAlias = dpadElement.down.aliases.first {
                alias = downAlias
            }
        }
        if alias == "Direction Pad" {
            return
        }
        let resolvedAlias = alias
        DispatchQueue.main.async {
            EditorController.shared.setKey(resolvedAlias)
        }
    }
}
