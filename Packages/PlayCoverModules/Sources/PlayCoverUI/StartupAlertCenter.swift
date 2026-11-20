import Foundation

public enum StartupAlertItem: Identifiable, Equatable {
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
public final class StartupAlertCenter: ObservableObject {
    @Published public var activeAlert: StartupAlertItem?
    private var queue: [StartupAlertItem] = []

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
