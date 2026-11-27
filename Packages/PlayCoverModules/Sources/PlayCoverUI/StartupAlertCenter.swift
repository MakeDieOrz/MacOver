import Foundation
import Observation

public enum StartupAlertItem: Identifiable, Equatable, Sendable {
    case lowPowerMode
    case audioSampleRate(deviceID: UInt32, currentSampleRate: Double)
    case safeModeActivated(appName: String, bundleID: String, breadcrumbPath: String)

    public var id: String {
        switch self {
        case .lowPowerMode:
            return "lowPowerMode"
        case let .audioSampleRate(deviceID, _):
            return "audioSampleRate.\(deviceID)"
        case let .safeModeActivated(_, bundleID, _):
            return "safeModeActivated.\(bundleID)"
        }
    }
}

@MainActor
@Observable
public final class StartupAlertCenter {
    public var activeAlert: StartupAlertItem?
    @ObservationIgnored private var queue: [StartupAlertItem] = []

    nonisolated public init() {}

    public func enqueue(_ item: StartupAlertItem) {
        if activeAlert?.id == item.id || queue.contains(where: { $0.id == item.id }) {
            return
        }
        if activeAlert == nil {
            activeAlert = item
        } else {
            queue.append(item)
        }
    }

    public func dismissCurrent() {
        if queue.isEmpty {
            activeAlert = nil
        } else {
            activeAlert = queue.removeFirst()
        }
    }

    public func resetForTesting() {
        queue.removeAll()
        activeAlert = nil
    }
}
