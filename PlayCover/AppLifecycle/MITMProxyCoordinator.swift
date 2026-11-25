import Foundation
import PlayCoverCore
import PlayCoverMachO
import PlayCoverNetwork
import SwiftUI

@MainActor
final class MITMProxyCoordinator: ObservableObject {
    let certificateStore: PerAppCertificateStore

    @Published private(set) var activePorts: [String: UInt16] = [:]
    @Published private(set) var capturedEntries: [String: [MITMCaptureEntry]] = [:]
    @Published private(set) var certificateRevisions: [String: Int] = [:]

    private var servers: [String: LocalMITMProxyServer] = [:]
    private var captureStores: [String: TrafficCaptureStore] = [:]
    private var observerTasks: [String: Task<Void, Never>] = [:]

    init(
        certificatesBaseURL: URL = PlayTools.playCoverContainer.appendingPathComponent("Certificates"),
        appSettingsBaseURL: URL = PlayTools.playCoverContainer.appendingPathComponent("App Settings")
    ) {
        self.certificateStore = PerAppCertificateStore(
            certificatesBaseURL: certificatesBaseURL,
            appSettingsBaseURL: appSettingsBaseURL
        )
    }

    func bumpCertificateRevision(for bundleID: String) {
        certificateRevisions[bundleID, default: 0] += 1
    }

    func captureStore(for bundleID: String) -> TrafficCaptureStore {
        if let existing = captureStores[bundleID] {
            return existing
        }
        let store = TrafficCaptureStore(bundleID: bundleID)
        captureStores[bundleID] = store
        return store
    }

    func entries(for bundleID: String) -> [MITMCaptureEntry] {
        capturedEntries[bundleID] ?? []
    }

    func clearCaptures(for bundleID: String) {
        captureStore(for: bundleID).clear()
        capturedEntries[bundleID] = []
    }

    func exportHAR(for bundleID: String) throws -> Data {
        try captureStore(for: bundleID).exportHAR()
    }

    func syncCertificates(for bundleID: String, settings: AppSettingsData) {
        let shouldInject = settings.enableCustomCertificates || settings.networkProxyMode == "builtInMITM"
        do {
            try certificateStore.syncRuntimeCertificates(for: bundleID, enabled: shouldInject)
            bumpCertificateRevision(for: bundleID)
        } catch {
            PlayCoverDiagnostics.log(
                "Failed to sync runtime certificates for \(bundleID): \(error.localizedDescription)",
                isError: true
            )
        }
    }

    func prepareForLaunch(app: PlayApp, safeModeOneShot: Bool) async throws {
        let bundleID = app.info.bundleIdentifier
        guard !bundleID.isEmpty else { return }

        if safeModeOneShot {
            await stopServer(for: bundleID)
            try? certificateStore.syncRuntimeCertificates(for: bundleID, enabled: false)
            if app.settings.settings.mitmRuntimePort != 0 {
                app.settings.update { $0.mitmRuntimePort = 0 }
                _ = app.settings.flush()
            }
            return
        }

        let currentSettings = app.settings.settings
        if currentSettings.networkProxyMode != "builtInMITM" {
            await stopServer(for: bundleID)
            try? certificateStore.syncRuntimeCertificates(
                for: bundleID,
                enabled: currentSettings.enableCustomCertificates
            )
            if currentSettings.mitmRuntimePort != 0 {
                app.settings.update { $0.mitmRuntimePort = 0 }
                _ = app.settings.flush()
            }
            return
        }

        await stopServer(for: bundleID)
        let rootCA = try certificateStore.ensureBuiltInRootCA(for: bundleID)
        try certificateStore.syncRuntimeCertificates(for: bundleID, enabled: true)
        bumpCertificateRevision(for: bundleID)

        let store = captureStore(for: bundleID)
        let serverConfig = makeServerConfiguration(bundleID: bundleID, settings: currentSettings)
        let server = try LocalMITMProxyServer(
            rootCertificateDER: rootCA.certificateDER,
            rootPrivateKeyDER: rootCA.privateKeyDER,
            configuration: serverConfig,
            captureStore: store
        )

        let boundPort = try await server.start()
        servers[bundleID] = server
        activePorts[bundleID] = boundPort
        attachCaptureObserver(for: bundleID, store: store)

        app.settings.update { $0.mitmRuntimePort = Int(boundPort) }
        _ = app.settings.flush()
    }

    func handleAppTermination(bundleID: String, settings: AppSettings) async {
        await stopServer(for: bundleID)
        if settings.settings.mitmRuntimePort != 0 {
            settings.update { $0.mitmRuntimePort = 0 }
            _ = settings.flush()
        }
    }

    func updateLiveConfiguration(for bundleID: String, settings: AppSettingsData) async {
        let shouldInject = settings.enableCustomCertificates || settings.networkProxyMode == "builtInMITM"
        try? certificateStore.syncRuntimeCertificates(for: bundleID, enabled: shouldInject)
        if let server = servers[bundleID] {
            let serverConfig = makeServerConfiguration(bundleID: bundleID, settings: settings)
            await server.updateConfiguration(serverConfig)
        }
    }

    private func stopServer(for bundleID: String) async {
        observerTasks[bundleID]?.cancel()
        observerTasks.removeValue(forKey: bundleID)
        if let server = servers.removeValue(forKey: bundleID) {
            await server.stop()
        }
        activePorts.removeValue(forKey: bundleID)
    }

    private func attachCaptureObserver(for bundleID: String, store: TrafficCaptureStore) {
        observerTasks[bundleID]?.cancel()
        observerTasks[bundleID] = Task { [weak self] in
            let stream = store.updates()
            for await snapshot in stream {
                if Task.isCancelled { break }
                self?.capturedEntries[bundleID] = snapshot
            }
        }
    }

    private func makeServerConfiguration(bundleID: String, settings: AppSettingsData) -> MITMServerConfiguration {
        let clampedPort = max(0, min(65_535, settings.mitmPort))
        return MITMServerConfiguration(
            bundleID: bundleID,
            listenPort: UInt16(clampedPort),
            mitmAllHosts: settings.mitmAllHosts,
            mitmHostPatterns: settings.mitmHostPatterns,
            enableNetworkRules: settings.enableNetworkRules,
            networkBlockMock200: settings.networkBlockMock200,
            blockedURLPatterns: settings.blockedURLPatterns,
            captureBodies: settings.mitmCaptureBodies
        )
    }
}
