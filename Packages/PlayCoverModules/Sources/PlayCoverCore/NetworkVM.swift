//
//  NetworkVM.swift
//  PlayCover
//
//  Created by Isaac Marovitz on 09/10/2022.
//

import Foundation
import Network
import Synchronization

public class NetworkVM {
    private final class PathMonitorBox: @unchecked Sendable {
        static let shared = PathMonitorBox()

        private let queue = DispatchQueue(label: "app.makedie.MacOver.NetworkVM.monitor", qos: .utility)
        private let monitor = NWPathMonitor()
        private let status = Mutex<NWPath.Status?>(nil)
        private let initialSignal = DispatchSemaphore(value: 0)
        private let didSignal = Mutex<Bool>(false)

        private init() {
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self else { return }
                self.status.withLock { $0 = path.status }
                let shouldSignal = self.didSignal.withLock { signaled -> Bool in
                    guard !signaled else { return false }
                    signaled = true
                    return true
                }
                if shouldSignal {
                    self.initialSignal.signal()
                }
            }
            monitor.start(queue: queue)
        }

        func isConnected() -> Bool {
            if let current = status.withLock({ $0 }) {
                return current == .satisfied
            }
            _ = initialSignal.wait(timeout: .now() + .milliseconds(150))
            if let updated = status.withLock({ $0 }) {
                return updated == .satisfied
            }
            return monitor.currentPath.status == .satisfied
        }
    }

    public static func isConnectedToNetwork() -> Bool {
        let result = PathMonitorBox.shared.isConnected()

        if !result && !PlayCoverDiagnostics.hasActiveToast(ofType: .network) {
            PlayCoverDiagnostics.showToast(
                toastType: .network,
                toastDetails: NSLocalizedString("ipaLibrary.noNetworkConnection.toast", comment: "")
            )
        }

        return result
    }

    public static func isURLAccessible(url: URL, popup: Bool = false) async -> (URL?, Bool) {
        guard isConnectedToNetwork() else {
            return (nil, false)
        }

        let validStatusCodes = [200, 301, 302, 303, 307, 308]
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if validStatusCodes.contains(httpResponse.statusCode) {
                    return (httpResponse.url, true)
                } else if popup {
                    PlayCoverDiagnostics.reportError(
                        "Unable to download: \(httpResponse.statusCode) " +
                        "\(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))"
                    )
                }
            }
        } catch {
            if popup {
                PlayCoverDiagnostics.reportError(error)
            } else {
                PlayCoverDiagnostics.log(error.localizedDescription, isError: true)
            }
        }

        return (nil, false)
    }

    public static func urlAccessible(url: URL,
                                     popup: Bool = false,
                                     completion: (@Sendable (URL?, Bool) -> Void)? = nil) {
        Task {
            let (finalURL, available) = await isURLAccessible(url: url, popup: popup)
            await MainActor.run {
                completion?(finalURL, available)
            }
        }
    }
}
