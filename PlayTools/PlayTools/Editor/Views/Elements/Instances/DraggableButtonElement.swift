//
//  Draggable.swift
//  PlayTools
//
//  Created by 许沂聪 on 2024/6/2.
//

import Foundation

class DraggableButtonElement: Element {
    override func update() {
        super.update()
        var updatedConfig = configuration ?? UIButton.Configuration.plain()
        updatedConfig.contentInsets = NSDirectionalEdgeInsets(
            top: frame.height / 2,
            leading: 2,
            bottom: 2,
            trailing: 2
        )
        configuration = updatedConfig
        guard let child = (model as? DraggableButtonModel)?.childButton?.button else {
            return
        }
        let buttonSize = frame.width / 3
        let coord = (frame.width - buttonSize) / 2
        child.frame = CGRect(x: coord, y: coord, width: buttonSize, height: buttonSize)
        child.layer.cornerRadius = 0.5 * child.bounds.size.width
    }
}
