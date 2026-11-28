//
//  ControlMode.swift
//  PlayTools
//

import Foundation
import GameController

let mode = ControlMode.mode

public enum ControlModeLiteral: String {
    case textInput
    case cameraRotate
    case arbitraryClick
    case off
    case editor
}
// This class handles different control logic under different control mode

public final class ControlMode: Equatable, @unchecked Sendable {
    static public let mode = ControlMode()

    private let stateLock = PTUnfairLock()
    private var controlMode = ControlModeLiteral.off

    private var keyboardAdapter: KeyboardEventAdapter?
    private var mouseAdapter: MouseEventAdapter?
    private var controllerAdapter: ControllerEventAdapter?
    private var keyWindowObserver: NSObjectProtocol?

    private var currentMode: ControlModeLiteral {
        stateLock.withLock { controlMode }
    }

    public func cursorHidden() -> Bool {
        let adapter = stateLock.withLock { mouseAdapter }
        return adapter?.cursorHidden() ?? false
    }

    public func initialize() {
        if PlaySettings.shared.noKMOnInput {
            setupTextInputObservers()
            set(.arbitraryClick)
        } else {
            set(.off)
        }

        setupGameController()
        setupKeyboard()
        if PlaySettings.shared.enableScrollWheel {
            setupScrollWheel()
        }

        // Mouse polling rate as high as 1000 causes issue to some games
        setupMouseMoved(maxPollingRate: 125)
        setupMouseButtons()

        if PlaySettings.shared.resizableWindow {
            initializeResizableWindowSupport()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            if PlaySettings.shared.keymapping {
                ActionDispatcher.invalidateActions()
            }
        }

        ActionDispatcher.build()
    }

    @MainActor
    private static func hasOtherActiveTextInputResponder(excludingObjectID endingID: ObjectIdentifier?) -> Bool {
        let firstResponderSelector = NSSelectorFromString("firstResponder")
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for win in ws.windows where !win.isHidden && win.responds(to: firstResponderSelector) {
                guard let unmanaged = win.perform(firstResponderSelector),
                      let responder = unmanaged.takeUnretainedValue() as? UIResponder else {
                    continue
                }
                if responder is UITextInput, ObjectIdentifier(responder) != endingID {
                    return true
                }
            }
        }
        return false
    }

    private func setupTextInputObservers() {
        let centre = NotificationCenter.default
        let main = OperationQueue.main
        centre.addObserver(forName: UITextField.textDidEndEditingNotification, object: nil, queue: main) { note in
            let endingID = (note.object as AnyObject?).map(ObjectIdentifier.init)
            let hasOther = MainActor.assumeIsolated {
                Self.hasOtherActiveTextInputResponder(excludingObjectID: endingID)
            }
            if !hasOther {
                ModeAutomaton.onUITextInputEndEdit()
            }
            Toucher.writeLog(logMessage: "uitextinput end edit")
        }
        centre.addObserver(forName: UITextField.textDidBeginEditingNotification, object: nil, queue: main) { _ in
            ModeAutomaton.onUITextInputBeginEdit()
            Toucher.writeLog(logMessage: "uitextinput begin edit")
        }
        centre.addObserver(forName: UITextView.textDidEndEditingNotification, object: nil, queue: main) { note in
            let endingID = (note.object as AnyObject?).map(ObjectIdentifier.init)
            let hasOther = MainActor.assumeIsolated {
                Self.hasOtherActiveTextInputResponder(excludingObjectID: endingID)
            }
            if !hasOther {
                ModeAutomaton.onUITextInputEndEdit()
            }
            Toucher.writeLog(logMessage: "uitextinput end edit")
        }
        centre.addObserver(forName: UITextView.textDidBeginEditingNotification, object: nil, queue: main) { _ in
            ModeAutomaton.onUITextInputBeginEdit()
            Toucher.writeLog(logMessage: "uitextinput begin edit")
        }
    }

    private func shouldEnableBackgroundControllerMonitoring() -> Bool {
        (PlaySettings.shared.reportedIOSVersion as String) != "compat13_7"
    }

    private func configureGameController(_ controller: GCController) {
        controller.handlerQueue = PlayInput.touchQueue
        controller.extendedGamepad?.valueChangedHandler = { [weak self] profile, element in
            guard let self else { return }
            let adapter = self.stateLock.withLock { self.controllerAdapter }
            adapter?.handleValueChanged(profile, element)
        }
    }

    private func setupGameController() {
        let centre = NotificationCenter.default
        let main = OperationQueue.main
        if shouldEnableBackgroundControllerMonitoring() {
            GCController.shouldMonitorBackgroundEvents = true
        }
        for existing in GCController.controllers() {
            configureGameController(existing)
        }
        if let current = GCController.current {
            configureGameController(current)
        }
        centre.addObserver(
            forName: NSNotification.Name.GCControllerDidConnect,
            object: nil,
            queue: main
        ) { [weak self] note in
            guard let self else { return }
            if self.shouldEnableBackgroundControllerMonitoring() {
                GCController.shouldMonitorBackgroundEvents = true
            }
            if let connected = note.object as? GCController {
                self.configureGameController(connected)
            } else if let current = GCController.current {
                self.configureGameController(current)
            }
        }
    }

    private func setupKeyboard() {
        AKInterface.shared?.setupKeyboard(
            keyboard: { [weak self] keycode, pressed, isRepeat, ctrlModified in
                guard let self else { return false }
                let adapter = self.stateLock.withLock { self.keyboardAdapter }
                return adapter?.handleKey(
                    keycode: keycode,
                    pressed: pressed,
                    isRepeat: isRepeat,
                    ctrlModified: ctrlModified
                ) ?? false
            },
            swapMode: ModeAutomaton.onOption
        )
    }

    private func setupScrollWheel() {
        AKInterface.shared?.setupScrollWheel({ [weak self] deltaX, deltaY in
            guard let self else { return false }
            let adapter = self.stateLock.withLock { self.mouseAdapter }
            return adapter?.handleScrollWheel(deltaX: deltaX, deltaY: deltaY) ?? false
        })
    }

    private func setupMouseButtons() {
        AKInterface.shared?.setupMouseButton(left: true, right: false, { [weak self] _, pressed in
            guard let self else { return false }
            let adapter = self.stateLock.withLock { self.mouseAdapter }
            return adapter?.handleLeftButton(pressed: pressed) ?? false
        })

        AKInterface.shared?.setupMouseButton(left: false, right: false, { [weak self] id, pressed in
            guard let self else { return false }
            let adapter = self.stateLock.withLock { self.mouseAdapter }
            return adapter?.handleOtherButton(id: id, pressed: pressed) ?? false
        })

        AKInterface.shared?.setupMouseButton(left: false, right: true, { [weak self] id, pressed in
            guard let self else { return false }
            let adapter = self.stateLock.withLock { self.mouseAdapter }
            return adapter?.handleOtherButton(id: id, pressed: pressed) ?? false
        })
    }

    private func initializeResizableWindowSupport() {
        // Reactivate keymapping once the key window is initialized
        let observer = NotificationCenter.default.addObserver(forName: UIWindow.didBecomeKeyNotification,
            object: nil, queue: .main) { [weak self] _ in
            ActionDispatcher.build()
            guard let self else { return }
            let registered = self.stateLock.withLock { () -> NSObjectProtocol? in
                let existing = self.keyWindowObserver
                self.keyWindowObserver = nil
                return existing
            }
            if let registered {
                NotificationCenter.default.removeObserver(registered)
            }
        }
        stateLock.withLock {
            keyWindowObserver = observer
        }
        // Reactivate keymapping once the user finishes resizing the window
        NotificationCenter.default.addObserver(forName: Notification.Name("NSWindowDidEndLiveResizeNotification"),
            object: nil, queue: .main) { _ in
            ActionDispatcher.build()
        }
    }

    private func setupMouseMoved(maxPollingRate: Int) {
        var coalescer = PTMouseMoveCoalescer(maxPollingRate: maxPollingRate, deadZone: 0)
        // Repeat the return value of last processed event
        var consumed = true

        AKInterface.shared?.setupMouseMoved({ [weak self] deltaX, deltaY in
            let nowNs = DispatchTime.now().uptimeNanoseconds
            guard let flushed = coalescer.ingest(
                deltaX: deltaX,
                deltaY: deltaY,
                timestampNanoseconds: nowNs
            ) else {
                return consumed
            }
            guard let self else { return false }
            let adapter = self.stateLock.withLock { self.mouseAdapter }
            consumed = adapter?.handleMove(deltaX: flushed.dx, deltaY: flushed.dy) ?? false
            return consumed
        })
    }

    public func set(_ mode: ControlModeLiteral) {
        let nextKeyboard = EventAdapters.keyboard(controlMode: mode)
        let nextMouse = EventAdapters.mouse(controlMode: mode)
        let nextController = EventAdapters.controller(controlMode: mode)
        let nextHidden = nextMouse.cursorHidden()

        let (previousMode, wasHidden, first) = stateLock.withLock { () -> (ControlModeLiteral, Bool, Bool) in
            let prev = controlMode
            let prevHidden = mouseAdapter?.cursorHidden() ?? false
            let isFirst = mouseAdapter == nil
            keyboardAdapter = nextKeyboard
            mouseAdapter = nextMouse
            controllerAdapter = nextController
            controlMode = mode
            return (prev, prevHidden, isFirst)
        }

        let invalidation = PTControlModeTransitionPolicy.invalidation(
            from: previousMode.rawValue,
            to: mode.rawValue,
            wasCursorHidden: wasHidden,
            nextCursorHidden: nextHidden,
            isInitial: first,
            keymappingEnabled: settings.keymapping
        )

        if nextHidden != wasHidden && settings.keymapping {
            if wasHidden {
                Toast.internalNotificationCenter.post(name: NSNotification.Name.playtoolsCursorWillShow,
                                                      object: nil, userInfo: [:])
                if screen.fullscreen {
                    screen.switchDock(true)
                }
                AKInterface.shared?.unhideCursor()
            } else {
                Toast.internalNotificationCenter.post(name: NSNotification.Name.playtoolsCursorWillHide,
                                                      object: nil, userInfo: [:])
                AKInterface.shared?.hideCursor()
                if screen.fullscreen {
                    screen.switchDock(false)
                }
            }
            Toucher.writeLog(logMessage: "cursor show switched to \(!wasHidden)")
        }

        switch invalidation {
        case .none:
            break
        case .nonButtonActions:
            ActionDispatcher.invalidateNonButtonActions()
        case .allActions:
            ActionDispatcher.invalidateActions()
        }
    }

    public static func == (lhs: ControlModeLiteral, rhs: ControlMode) -> Bool {
        lhs == rhs.currentMode
    }

    public static func == (lhs: ControlMode, rhs: ControlModeLiteral) -> Bool {
        rhs == lhs
    }

    public static func == (lhs: ControlMode, rhs: ControlMode) -> Bool {
        rhs.currentMode == lhs.currentMode
    }

}

extension NSNotification.Name {
    public static let playtoolsCursorWillHide: NSNotification.Name
                    = NSNotification.Name("playtools.cursorWillHide")

    public static let playtoolsCursorWillShow: NSNotification.Name
                    = NSNotification.Name("playtools.cursorWillShow")
}
