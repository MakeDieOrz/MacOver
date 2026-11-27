import Foundation
import Synchronization

public final class TrafficCaptureStore: Sendable {
    public let bundleID: String
    public let maxEntries: Int
    public let maxBodyBytes: Int

    private struct Storage {
        var entries: [MITMCaptureEntry] = []
        var observers: [UUID: @Sendable ([MITMCaptureEntry]) -> Void] = [:]
    }

    private let storage = Mutex<Storage>(Storage())

    public init(bundleID: String, maxEntries: Int = 2000, maxBodyBytes: Int = 512 * 1024) {
        self.bundleID = bundleID
        self.maxEntries = max(1, maxEntries)
        self.maxBodyBytes = max(1024, maxBodyBytes)
    }

    public func append(_ entry: MITMCaptureEntry) {
        var clipped = entry
        if let reqBody = clipped.requestBody, reqBody.count > maxBodyBytes {
            clipped = MITMCaptureEntry(
                id: clipped.id,
                timestamp: clipped.timestamp,
                bundleID: clipped.bundleID,
                method: clipped.method,
                scheme: clipped.scheme,
                host: clipped.host,
                port: clipped.port,
                path: clipped.path,
                urlString: clipped.urlString,
                requestHeaders: clipped.requestHeaders,
                requestBody: reqBody.prefix(maxBodyBytes),
                requestBodyTruncated: true,
                statusCode: clipped.statusCode,
                responseHeaders: clipped.responseHeaders,
                responseBody: clipped.responseBody,
                responseBodyTruncated: clipped.responseBodyTruncated,
                durationMs: clipped.durationMs,
                disposition: clipped.disposition,
                errorDescription: clipped.errorDescription
            )
        }
        if let respBody = clipped.responseBody, respBody.count > maxBodyBytes {
            clipped = MITMCaptureEntry(
                id: clipped.id,
                timestamp: clipped.timestamp,
                bundleID: clipped.bundleID,
                method: clipped.method,
                scheme: clipped.scheme,
                host: clipped.host,
                port: clipped.port,
                path: clipped.path,
                urlString: clipped.urlString,
                requestHeaders: clipped.requestHeaders,
                requestBody: clipped.requestBody,
                requestBodyTruncated: clipped.requestBodyTruncated,
                statusCode: clipped.statusCode,
                responseHeaders: clipped.responseHeaders,
                responseBody: respBody.prefix(maxBodyBytes),
                responseBodyTruncated: true,
                durationMs: clipped.durationMs,
                disposition: clipped.disposition,
                errorDescription: clipped.errorDescription
            )
        }

        let (snapshot, observers) = storage.withLock { state -> (
            [MITMCaptureEntry], [@Sendable ([MITMCaptureEntry]) -> Void]
        ) in
            state.entries.append(clipped)
            if state.entries.count > maxEntries {
                state.entries.removeFirst(state.entries.count - maxEntries)
            }
            return (state.entries, Array(state.observers.values))
        }
        for observer in observers {
            observer(snapshot)
        }
    }

    public func entries() -> [MITMCaptureEntry] {
        storage.withLock { $0.entries }
    }

    public func clear() {
        let observers = storage.withLock { state -> [@Sendable ([MITMCaptureEntry]) -> Void] in
            state.entries.removeAll(keepingCapacity: true)
            return Array(state.observers.values)
        }
        for observer in observers {
            observer([])
        }
    }

    public func exportHAR(appVersion: String = "1.0.7") throws -> Data {
        try HARExporter.export(entries: entries(), appVersion: appVersion)
    }

    public func updates() -> AsyncStream<[MITMCaptureEntry]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let token = UUID()
            let initial = storage.withLock { state -> [MITMCaptureEntry] in
                state.observers[token] = { snapshot in
                    continuation.yield(snapshot)
                }
                return state.entries
            }
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                self?.storage.withLock { state in
                    _ = state.observers.removeValue(forKey: token)
                }
            }
        }
    }
}
