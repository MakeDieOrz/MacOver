//
//  DebugModel.swift
//  PlayTools
//
//  Created by 许沂聪 on 2024/5/28.
//

import Foundation
import Synchronization

final class DebugModel: Sendable {
    static let instance = DebugModel()
    private init() {}

    struct TouchPoint: Sendable {
        var point: CGPoint
        var phase: UITouch.Phase
        var description: String
    }

    private let _enabled = Mutex(false)
    @MainActor public var touches: [TouchPoint] = []
    public var enabled: Bool {
        get { _enabled.withLock { $0 } }
        set { _enabled.withLock { $0 = newValue } }
    }

    public func setEnabled(_ isEnabled: Bool) {
        enabled = isEnabled
        if !isEnabled {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.touches.removeAll(keepingCapacity: true)
                }
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
            MainActor.assumeIsolated {
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
}
