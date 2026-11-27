//
//  PerformanceSignpost.swift
//  PlayCoverCore
//

import OSLog

public enum PerformanceSignpost {
    private static let log = OSLog(subsystem: "app.makedie.MacOver", category: "Performance")
    private static let signposter = OSSignposter(logHandle: log)

    public static func beginInterval(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    public static func endInterval(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    public static func emitEvent(_ name: StaticString) {
        signposter.emitEvent(name, id: signposter.makeSignpostID())
    }
}
