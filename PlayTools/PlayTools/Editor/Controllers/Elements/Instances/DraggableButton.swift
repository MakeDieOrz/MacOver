//
//  DraggableButton.swift
//  PlayTools
//
//  Created by 许沂聪 on 2023/12/25.
//

import Foundation

class DraggableButtonModel: ControlModel<Button>, ParentElement {
    func unfocusChildren() {
        childButton?.focus(false)
    }

    var childButton: ChildButtonModel?

    func save() -> Button {
        if let child = childButton {
            data.keyCode = child.data.keyCode
            data.buttonKeyName = child.data.keyName
        }
        return data
    }

    override init(data: Button) {
        super.init(data: data)
        button = DraggableButtonElement(frame: CGRect(
            x: data.transform.xCoord.absoluteX - data.transform.size.absoluteSize/2,
            y: data.transform.yCoord.absoluteY - data.transform.size.absoluteSize/2,
            width: data.transform.size.absoluteSize,
            height: data.transform.size.absoluteSize
        ))
        button.model = self
        // `data.keyName` is the drag device ("Mouse" or thumbstick), while
        // `data.buttonKeyName` / `data.keyCode` stores the trigger button key.
        let childKeyName = data.buttonKeyName ?? KeyCodeNames.keyCodes[data.keyCode] ?? "Btn"
        let childData = Button(
            keyCode: data.keyCode,
            keyName: childKeyName,
            transform: self.data.transform,
            buttonKeyName: data.buttonKeyName
        )
        childButton = ChildButtonModel(
            data: childData,
            parent: self
        )
        setKey(name: data.keyName)
        button.update()
    }

    override func setKey(code: Int, name: String) {
        if code == KeyCodeNames.defaultCode && (name == "Mouse" || name.hasSuffix("tick")) {
            // set the parent drag-device key
            self.data.keyName = name
            button.setTitle(data.keyName, for: UIControl.State.normal)
        } else {
            // set the child trigger key
            childButton?.setKey(code: code, name: name)
        }
    }

    override func focus(_ focus: Bool) {
        super.focus(focus)
        if !focus {
            unfocusChildren()
        }
    }
}
