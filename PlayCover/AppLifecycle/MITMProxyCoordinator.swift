import Foundation
import Observation
import PlayCoverCore
import PlayCoverMachO
import PlayCoverNetwork
import SwiftUI

@MainActor
@Observable
final class MITMProxyCoordinator {
    let certificateStore: PerAppCertificateStore

    private(set) var activePorts: [String: UInt16] = [:]
    private(set) var capturedEntries: [String: [MITMCaptureEntry]] = [:]
    private(set) var certificateRevisions: [String: Int] = [:]

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
            if servers[bundleID] != nil {
                Task { [weak self] in
                    await self?.reloadRootCAIfNeeded(for: bundleID)
                }
            }
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
        let customAnchors = certificateStore.enabledCustomAnchorDERs(for: bundleID)
        let server = try LocalMITMProxyServer(
            rootCertificateDER: rootCA.certificateDER,
            rootPrivateKeyDER: rootCA.privateKeyDER,
            configuration: serverConfig,
            captureStore: store,
            upstreamCustomAnchorDERs: customAnchors,
            allowedClientAppBundleURL: app.url
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

    func stopAllServers(apps: [PlayApp]) async {
        let bundleIDs = Set(Array(servers.keys) + apps.map(\.info.bundleIdentifier))
        for bundleID in bundleIDs where !bundleID.isEmpty {
            await stopServer(for: bundleID)
        }
        for app in apps where app.settings.settings.mitmRuntimePort != 0 {
            app.settings.update { $0.mitmRuntimePort = 0 }
            _ = app.settings.flush()
        }
    }

    func prepareForHostTermination(apps: [PlayApp]) {
        for app in apps where app.settings.settings.mitmRuntimePort != 0 {
            app.settings.update { $0.mitmRuntimePort = 0 }
            _ = app.settings.flush()
        }
        let runningServers = Array(servers.values)
        for task in observerTasks.values {
            task.cancel()
        }
        observerTasks.removeAll()
        servers.removeAll()
        activePorts.removeAll()
        for server in runningServers {
            server.stopImmediately()
        }
    }

    func updateLiveConfiguration(for bundleID: String, settings: AppSettingsData) async {
        let shouldInject = settings.enableCustomCertificates || settings.networkProxyMode == "builtInMITM"
        try? certificateStore.syncRuntimeCertificates(for: bundleID, enabled: shouldInject)
        if let server = servers[bundleID] {
            let serverConfig = makeServerConfiguration(bundleID: bundleID, settings: settings)
            await server.updateConfiguration(serverConfig)
            await reloadRootCAIfNeeded(for: bundleID)
        }
    }

    private func reloadRootCAIfNeeded(for bundleID: String) async {
        guard let server = servers[bundleID] else {
            return
        }
        let customAnchors = certificateStore.enabledCustomAnchorDERs(for: bundleID)
        await server.updateUpstreamCustomAnchors(customAnchors)

        let material: (record: AppCertificateRecord, certificateDER: Data, privateKeyDER: Data)
        if let existing = certificateStore.builtInRootCAMaterial(for: bundleID) {
            material = existing
        } else {
            do {
                material = try certificateStore.ensureBuiltInRootCA(for: bundleID)
                try certificateStore.syncRuntimeCertificates(for: bundleID, enabled: true)
                bumpCertificateRevision(for: bundleID)
            } catch {
                PlayCoverDiagnostics.log(
                    "Failed to regenerate deleted MITM Root CA for \(bundleID): \(error.localizedDescription)",
                    isError: true
                )
                return
            }
        }
        do {
            try await server.updateRootCA(
                certificateDER: material.certificateDER,
                privateKeyDER: material.privateKeyDER
            )
        } catch {
            PlayCoverDiagnostics.log(
                "Failed to reload MITM Root CA for \(bundleID): \(error.localizedDescription)",
                isError: true
            )
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
            captureBodies: settings.mitmCaptureBodies,
            blockLoopbackTargets: true
        )
    }
}
