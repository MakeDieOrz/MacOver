//
//  ModifierKeyObserver.swift
//  PlayCover
//
//  Created by Venti on 14/02/2024.
//

import AppKit
import Foundation
import Observation
import PlayCoverCore

@MainActor
@Observable
public final class ModifierKeyObserver {
    public var isOptionKeyPressed = false
    public var isCommandKeyPressed = false
    public var isControlKeyPressed = false
    public var isShiftKeyPressed = false

    @ObservationIgnored private var eventMonitor: Any?

    public init() {
        guard !ProcessInfo.isRunningUnitTests else { return }
        let mask: NSEvent.EventTypeMask = [.flagsChanged]
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .flagsChanged {
                self.applyModifierFlags(event.modifierFlags)
            }
            return event
        }
    }

    public func applyModifierFlags(_ flags: NSEvent.ModifierFlags) {
        let option = flags.contains(.option)
        let command = flags.contains(.command)
        let control = flags.contains(.control)
        let shift = flags.contains(.shift)

        if isOptionKeyPressed != option { isOptionKeyPressed = option }
        if isCommandKeyPressed != command { isCommandKeyPressed = command }
        if isControlKeyPressed != control { isControlKeyPressed = control }
        if isShiftKeyPressed != shift { isShiftKeyPressed = shift }
    }

    isolated deinit {
        if let eventMonitor = eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }
}
