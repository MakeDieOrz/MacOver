import Foundation
import UIKit
import GameController

// This class is a coordinator (and module entrance), coordinating other concrete classes

final class PlayInput: Sendable {
    static let shared = PlayInput()

    static let touchQueue = DispatchQueue.init(label: "com.apple.uikit.hid-dispatch",
                                               qos: .userInteractive,
                                               autoreleaseFrequency: .workItem)

    func initialize() {
        Toast.cleanupLegacyUserDefaults()

        if PlaySettings.shared.disableBuiltinMouse && !PlaySettings.shared.bypass {
            simulateGCMouseDisconnect()
        }

        if !PlaySettings.shared.keymapping {
            return
        }

        let centre = NotificationCenter.default
        let main = OperationQueue.main

        centre.addObserver(forName: NSNotification.Name(rawValue: "NSWindowDidBecomeKeyNotification"), object: nil,
            queue: main) { _ in
            if mode.cursorHidden() {
                AKInterface.shared?.warpCursor()
            }
        }

        if !PlaySettings.shared.bypass {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, qos: .utility) {
                if mode.cursorHidden() || !ActionDispatcher.cursorHideNecessary {
                    return
                }
                Toast.initialize()
            }
        }
        mode.initialize()
    }

    private func simulateGCMouseDisconnect() {
        NotificationCenter.default.addObserver(
            forName: .GCMouseDidConnect,
            object: nil,
            queue: .main
        ) { nofitication in
            guard let mouse = nofitication.object as? GCMouse else {
                return
            }
            nonisolated(unsafe) let unsafeMouse = mouse
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) {
                NotificationCenter.default.post(name: .GCMouseDidDisconnect, object: unsafeMouse)
                unsafeMouse.mouseInput?.leftButton.pressedChangedHandler = nil
                unsafeMouse.mouseInput?.leftButton.valueChangedHandler = nil
                unsafeMouse.mouseInput?.rightButton?.pressedChangedHandler = nil
                unsafeMouse.mouseInput?.rightButton?.valueChangedHandler = nil
                unsafeMouse.mouseInput?.middleButton?.pressedChangedHandler = nil
                unsafeMouse.mouseInput?.middleButton?.valueChangedHandler = nil
                unsafeMouse.mouseInput?.auxiliaryButtons?.forEach { button in
                    button.pressedChangedHandler = nil
                    button.valueChangedHandler = nil
                }
                unsafeMouse.mouseInput?.scroll.valueChangedHandler = nil
                unsafeMouse.mouseInput?.mouseMovedHandler = nil
            }
        }
    }
}
