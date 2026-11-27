//
//  DebugController.swift
//  PlayTools
//
//  Created by 许沂聪 on 2024/5/28.
//

import Foundation

@MainActor
final class DebugController {
    static let instance = DebugController()
    private init() {

    }

    private var debugView = DebugContainer.instance

    public func toggleDebugOverlay() {
        guard let window = screen.keyWindow ?? screen.primaryWindow,
              let view = window.rootViewController?.view else {
            return
        }
        if debugView.superview == nil {
            PlaySettings.tagInternalView(debugView)
            view.addSubview(debugView)
            view.bringSubviewToFront(debugView)
            debugView.isHidden = false
            debugView.isUserInteractionEnabled = false
            PlayInput.touchQueue.async {
                DebugModel.instance.setEnabled(true)
            }
        } else {
            debugView.removeFromSuperview()
            PlayInput.touchQueue.async {
                DebugModel.instance.setEnabled(false)
            }
        }
    }
}
