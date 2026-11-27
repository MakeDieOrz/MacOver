//
//  DebugModel.swift
//  PlayTools
//
//  Created by 许沂聪 on 2024/5/28.
//

import Foundation

final class DebugModel: @unchecked Sendable {
    static let instance = DebugModel()
    private init() {
        touches = []
    }
    struct TouchPoint: Sendable {
        var point: CGPoint
        var phase: UITouch.Phase
        var description: String
    }

    private let stateLock = PTUnfairLock()
    public var touches: [TouchPoint]
    private var _enabled = false
    public var enabled: Bool {
        get { stateLock.withLock { _enabled } }
        set { stateLock.withLock { _enabled = newValue } }
    }

    public func setEnabled(_ isEnabled: Bool) {
        enabled = isEnabled
        if !isEnabled {
            DispatchQueue.main.async {
                self.touches.removeAll(keepingCapacity: true)
            }
        }
    }

    public func record(point: CGPoint, phase: UITouch.Phase, tid: Int, description: String) {
        // If debug screen not enabled, do not record
        if !enabled || tid < 0 {
            return
        }
        // Run in main thread, because `touches` is not thread safe
        DispatchQueue.main.async {
            while self.touches.count < tid {
                // report error
                self.touches.append(TouchPoint(
                    point: CGPoint(x: 100, y: 100),
                    phase: UITouch.Phase.cancelled,
                    description: "Error recording debug info: point id exceeds record array"
                ))
            }
            if self.touches.count == tid {
                self.touches.append(TouchPoint(point: point, phase: phase, description: description))
            } else {
                self.touches[tid] = TouchPoint(point: point, phase: phase, description: description)
            }
        }
    }
}
