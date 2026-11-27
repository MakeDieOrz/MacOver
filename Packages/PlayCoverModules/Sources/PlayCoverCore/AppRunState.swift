//
//  AppRunState.swift
//  PlayCoverCore
//

import Foundation

public enum AppLaunchStage: String, Equatable, Sendable, Codable {
    case verifying
    case unlocking
    case opening

    public var localizationKey: String {
        switch self {
        case .verifying:
            return "app.state.preparing.verifying"
        case .unlocking:
            return "app.state.preparing.unlocking"
        case .opening:
            return "app.state.preparing.opening"
        }
    }
}

public enum AppRunState: Equatable, Sendable {
    case idle
    case preparing(AppLaunchStage)
    case launching
    case running(isActive: Bool)
    case terminating

    public var isRunning: Bool {
        if case .running = self {
            return true
        }
        return false
    }

    public var isActive: Bool {
        if case .running(let active) = self {
            return active
        }
        return false
    }

    public var isStarting: Bool {
        switch self {
        case .preparing, .launching:
            return true
        case .idle, .running, .terminating:
            return false
        }
    }

    public var isTerminating: Bool {
        self == .terminating
    }

    public var isBusy: Bool {
        isStarting || isTerminating
    }

    /// Automatic grid ordering priority: running apps first, transitioning apps second, idle apps last.
    public var sortRank: Int {
        switch self {
        case .running:
            return 0
        case .preparing, .launching, .terminating:
            return 1
        case .idle:
            return 2
        }
    }
}
