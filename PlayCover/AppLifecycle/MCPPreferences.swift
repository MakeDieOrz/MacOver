import Foundation
import Observation
import Synchronization

@Observable
nonisolated final class MCPPreferences: @unchecked Sendable {
    private enum Keys {
        static let isEnabled = "mcp.server.enabled"
        static let allowSensitiveHeaders = "mcp.mitm.allowSensitiveHeaders"
    }

    private struct State: Sendable {
        var isEnabled: Bool
        var allowSensitiveHeaders: Bool
    }

    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private let stateLock: Mutex<State>

    private func notifyMutation<T>(_ keyPath: KeyPath<MCPPreferences, T> & Sendable) {
        if Thread.isMainThread {
            withMutation(keyPath: keyPath) {}
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.withMutation(keyPath: keyPath) {}
            }
        }
    }

    var isEnabled: Bool {
        get {
            if Thread.isMainThread {
                access(keyPath: \.isEnabled)
            }
            return stateLock.withLock { $0.isEnabled }
        }
        set {
            let changed = stateLock.withLock { state -> Bool in
                guard state.isEnabled != newValue else { return false }
                state.isEnabled = newValue
                return true
            }
            if changed {
                userDefaults.set(newValue, forKey: Keys.isEnabled)
                notifyMutation(\.isEnabled)
            }
        }
    }

    var allowSensitiveHeaders: Bool {
        get {
            if Thread.isMainThread {
                access(keyPath: \.allowSensitiveHeaders)
            }
            return stateLock.withLock { $0.allowSensitiveHeaders }
        }
        set {
            let changed = stateLock.withLock { state -> Bool in
                guard state.allowSensitiveHeaders != newValue else { return false }
                state.allowSensitiveHeaders = newValue
                return true
            }
            if changed {
                userDefaults.set(newValue, forKey: Keys.allowSensitiveHeaders)
                notifyMutation(\.allowSensitiveHeaders)
            }
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let enabled = userDefaults.object(forKey: Keys.isEnabled) != nil
            ? userDefaults.bool(forKey: Keys.isEnabled)
            : false
        let allowHeaders = userDefaults.object(forKey: Keys.allowSensitiveHeaders) != nil
            ? userDefaults.bool(forKey: Keys.allowSensitiveHeaders)
            : false
        self.stateLock = Mutex(State(isEnabled: enabled, allowSensitiveHeaders: allowHeaders))
    }
}
