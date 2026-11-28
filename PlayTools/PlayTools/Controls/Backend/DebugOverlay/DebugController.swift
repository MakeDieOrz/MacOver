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
        if debugView.superview == nil {
            guard let container = PTOverlayWindowHost.shared.ensureOverlayContainerView() else {
                return
            }
            PlaySettings.tagInternalView(debugView)
            debugView.frame = container.bounds
            debugView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(debugView)
            container.bringSubviewToFront(debugView)
            debugView.isHidden = false
            debugView.isUserInteractionEnabled = false
            PlayInput.touchQueue.async {
                DebugModel.instance.setEnabled(true)
            }
        } else {
            debugView.removeFromSuperview()
            PTOverlayWindowHost.shared.hideIfEmpty()
            PlayInput.touchQueue.async {
                DebugModel.instance.setEnabled(false)
            }
        }
    }
}
