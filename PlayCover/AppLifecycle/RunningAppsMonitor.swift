//
//  RunningAppsMonitor.swift
//  PlayCover
//

import AppKit
import Darwin
import Foundation
import Observation
import PlayCoverCore

@MainActor
@Observable
final class RunningAppsMonitor {
    private struct HostLaunchContext {
        let launchDate: Date
        var discordLinked: Bool
    }

    private struct TrackedProcess {
        weak var app: PlayApp?
        let runningApplication: NSRunningApplication
        let pid: pid_t
        var terminationObservation: NSKeyValueObservation?
        var settingsObserverID: UUID?
        var hostContext: HostLaunchContext?
    }

    @ObservationIgnored weak var dependencies: PlayCoverDependencies?
    @ObservationIgnored private var trackedByBundleURL: [URL: TrackedProcess] = [:]
    @ObservationIgnored private var workspaceObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var appObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var indexedAppURLs: [URL] = []
    @ObservationIgnored private var appsByBundleID: [String: [PlayApp]] = [:]
    @ObservationIgnored private var appsByCanonicalPath: [String: PlayApp] = [:]

    private static let managedAppsDirPrefixes: (raw: String, canonical: String) = (
        normalizedDirPrefix(AppsVM.appDirectory.standardizedFileURL),
        normalizedDirPrefix(AppsVM.appDirectory.standardizedFileURL.resolvingSymlinksInPath())
    )
    private static let aliasDirPrefixes: (raw: String, canonical: String) = (
        normalizedDirPrefix(PlayApp.aliasDirectory.standardizedFileURL),
        normalizedDirPrefix(PlayApp.aliasDirectory.standardizedFileURL.resolvingSymlinksInPath())
    )

    private static func normalizedDirPrefix(_ directory: URL) -> String {
        var path = directory.path
        if !path.hasSuffix("/") {
            path += "/"
        }
        return path
    }

    init(observeWorkspace: Bool = !ProcessInfo.isRunningUnitTests) {
        if observeWorkspace {
            startObservingWorkspace()
        }
    }

    // MARK: - Pure Testable Helpers

    static func matchApp(bundleURL: URL?, bundleIdentifier: String?, among apps: [PlayApp]) -> PlayApp? {
        if let bundleURL {
            let targetCanonical = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
            if let exact = apps.first(where: {
                $0.url.standardizedFileURL.resolvingSymlinksInPath() == targetCanonical
            }) {
                return exact
            }

            let inManagedApps = targetCanonical.path.hasPrefix(managedAppsDirPrefixes.canonical)
            let inAliases = targetCanonical.path.hasPrefix(aliasDirPrefixes.canonical)
            guard inManagedApps || inAliases else {
                return nil
            }
        }

        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return nil
        }
        return apps.first(where: { $0.info.bundleIdentifier == bundleIdentifier })
    }

    static func shouldPreventDisplaySleep(runState: AppRunState, disableTimeoutEnabled: Bool) -> Bool {
        disableTimeoutEnabled && runState == .running(isActive: true)
    }

    static func isProcessAlive(pid: pid_t, isTerminated: Bool) -> Bool {
        guard !isTerminated, pid > 0 else { return false }
        if kill(pid, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    private static func hasManagedOrAliasPrefix(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return path.hasPrefix(managedAppsDirPrefixes.raw)
            || path.hasPrefix(managedAppsDirPrefixes.canonical)
            || path.hasPrefix(aliasDirPrefixes.raw)
            || path.hasPrefix(aliasDirPrefixes.canonical)
    }

    private func ensureIndicesUpToDate(for apps: [PlayApp]) {
        let currentURLs = apps.map(\.url)
        guard currentURLs != indexedAppURLs else { return }

        var byID: [String: [PlayApp]] = [:]
        var byPath: [String: PlayApp] = [:]
        byID.reserveCapacity(apps.count)
        byPath.reserveCapacity(apps.count)

        for app in apps {
            let bid = app.info.bundleIdentifier
            if !bid.isEmpty {
                byID[bid, default: []].append(app)
            }
            let canonical = app.url.standardizedFileURL.resolvingSymlinksInPath().path
            byPath[canonical] = app
        }
        appsByBundleID = byID
        appsByCanonicalPath = byPath
        indexedAppURLs = currentURLs
    }

    func matchAppIndexed(_ running: NSRunningApplication, among apps: [PlayApp]) -> PlayApp? {
        guard !apps.isEmpty else { return nil }
        ensureIndicesUpToDate(for: apps)

        let bid = running.bundleIdentifier
        let rawPath = running.bundleURL?.path
        let idCandidates = (bid?.isEmpty == false) ? bid.flatMap { appsByBundleID[$0] } : nil
        guard idCandidates != nil || Self.hasManagedOrAliasPrefix(rawPath) else {
            return nil
        }

        if let bundleURL = running.bundleURL {
            let targetCanonical = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
            if let exact = appsByCanonicalPath[targetCanonical] {
                return exact
            }
            guard targetCanonical.hasPrefix(Self.managedAppsDirPrefixes.canonical)
                || targetCanonical.hasPrefix(Self.aliasDirPrefixes.canonical) else {
                return nil
            }
        }

        return idCandidates?.first
    }

    // MARK: - Public Coordination API

    func startObservingWorkspace() {
        guard !isStarted else { return }
        isStarted = true

        let wsCenter = NSWorkspace.shared.notificationCenter
        let mainQueue = OperationQueue.main

        workspaceObservers.append(
            wsCenter.addObserver(
                forName: NSWorkspace.willLaunchApplicationNotification,
                object: nil,
                queue: mainQueue
            ) { [weak self] notification in
                let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor [weak self] in
                    guard let self, let running else { return }
                    self.handleWillLaunch(running)
                }
            }
        )

        workspaceObservers.append(
            wsCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: mainQueue
            ) { [weak self] notification in
                let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor [weak self] in
                    guard let self, let running else { return }
                    self.handleDidLaunch(running)
                }
            }
        )

        workspaceObservers.append(
            wsCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: mainQueue
            ) { [weak self] notification in
                let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor [weak self] in
                    guard let self, let running else { return }
                    self.handleDidActivate(running)
                }
            }
        )

        workspaceObservers.append(
            wsCenter.addObserver(
                forName: NSWorkspace.didDeactivateApplicationNotification,
                object: nil,
                queue: mainQueue
            ) { [weak self] notification in
                let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor [weak self] in
                    guard let self, let running else { return }
                    self.handleDidDeactivate(running)
                }
            }
        )

        workspaceObservers.append(
            wsCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: mainQueue
            ) { [weak self] notification in
                let running = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor [weak self] in
                    guard let self, let running else { return }
                    self.handleDidTerminate(running)
                }
            }
        )

        appObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: mainQueue
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, let apps = self.dependencies?.appsVM.apps, !apps.isEmpty else { return }
                    self.reconcile(apps: apps)
                }
            }
        )
    }

    func reconcile(apps: [PlayApp]) {
        ensureIndicesUpToDate(for: apps)
        let activeRunning = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        var seenApps = Set<URL>()

        for runningApp in activeRunning {
            guard let matched = matchAppIndexed(runningApp, among: apps) else {
                continue
            }
            seenApps.insert(matched.url)
            attachProcess(runningApp, to: matched, hostContext: trackedByBundleURL[matched.url]?.hostContext)
        }

        for trackedKey in Array(trackedByBundleURL.keys) where !seenApps.contains(trackedKey) {
            guard let entry = trackedByBundleURL[trackedKey] else { continue }
            if !Self.isProcessAlive(pid: entry.pid, isTerminated: entry.runningApplication.isTerminated) {
                finalizeTermination(for: trackedKey, pid: entry.pid)
            }
        }

        for app in apps where !seenApps.contains(app.url) && trackedByBundleURL[app.url] == nil {
            guard app.isRunning || app.isTerminating else { continue }
            let isAlive = app.snapshotRunningApplication().map {
                Self.isProcessAlive(pid: $0.processIdentifier, isTerminated: $0.isTerminated)
            } ?? false
            if !isAlive {
                app.clearRunningApplication()
                app.enableTimeOut()
                app.launchSnapshot = nil
                app.setRunState(.idle)
            }
        }
    }

    func notifyProcessTerminated(for app: PlayApp, pid: pid_t) {
        if let tracked = trackedByBundleURL[app.url], pid <= 0 || tracked.pid == pid {
            finalizeTermination(for: app.url, pid: tracked.pid)
            return
        }
        let cleared = pid > 0 ? app.clearRunningApplicationIfMatches(processIdentifier: pid) : false
        if !cleared {
            app.clearRunningApplication()
        }
        app.enableTimeOut()
        app.launchSnapshot = nil
        app.setRunState(.idle)
    }

    func registerHostLaunch(
        app: PlayApp,
        runningApplication: NSRunningApplication,
        launchDate: Date,
        launchSnapshot: AppSettingsData,
        discordAlreadyLinked: Bool
    ) {
        app.launchSnapshot = launchSnapshot
        let context = HostLaunchContext(launchDate: launchDate, discordLinked: discordAlreadyLinked)
        attachProcess(runningApplication, to: app, hostContext: context)
        linkDiscordIfNeeded(for: app)

        if runningApplication.isTerminated {
            finalizeTermination(for: app.url, pid: runningApplication.processIdentifier)
        }
    }

    func shutdown() {
        for (url, entry) in trackedByBundleURL {
            entry.terminationObservation?.invalidate()
            if let settingsObserverID = entry.settingsObserverID {
                entry.app?.settings.removeChangeObserver(settingsObserverID)
            }
            entry.app?.enableTimeOut()
            trackedByBundleURL.removeValue(forKey: url)
        }
        let wsCenter = NSWorkspace.shared.notificationCenter
        for token in workspaceObservers {
            wsCenter.removeObserver(token)
        }
        workspaceObservers.removeAll()
        let center = NotificationCenter.default
        for token in appObservers {
            center.removeObserver(token)
        }
        appObservers.removeAll()
        isStarted = false
    }

    // MARK: - Notification Handlers

    private func handleWillLaunch(_ running: NSRunningApplication) {
        guard let app = matchedApp(for: running) else { return }
        if !app.isRunning && !app.isTerminating {
            app.setRunState(.launching)
        }
    }

    private func handleDidLaunch(_ running: NSRunningApplication) {
        guard !running.isTerminated, let app = matchedApp(for: running) else { return }
        attachProcess(running, to: app, hostContext: trackedByBundleURL[app.url]?.hostContext)
    }

    private func handleDidActivate(_ running: NSRunningApplication) {
        guard !running.isTerminated, let app = matchedApp(for: running) else { return }
        if trackedByBundleURL[app.url]?.pid != running.processIdentifier {
            attachProcess(running, to: app, hostContext: trackedByBundleURL[app.url]?.hostContext)
        } else {
            app.setRunState(.running(isActive: true))
            syncDisplaySleepPolicy(for: app, runningApplication: running)
            linkDiscordIfNeeded(for: app)
        }
    }

    private func handleDidDeactivate(_ running: NSRunningApplication) {
        guard let app = matchedApp(for: running) else { return }
        guard trackedByBundleURL[app.url]?.pid == running.processIdentifier else { return }
        app.setRunState(.running(isActive: false))
        app.enableTimeOut()
    }

    private func handleDidTerminate(_ running: NSRunningApplication) {
        if let app = matchedApp(for: running) {
            let pidToFinalize: pid_t
            if let tracked = trackedByBundleURL[app.url],
               tracked.runningApplication === running
                || running.processIdentifier <= 0
                || tracked.pid == running.processIdentifier {
                pidToFinalize = tracked.pid
            } else {
                pidToFinalize = running.processIdentifier
            }
            finalizeTermination(for: app.url, pid: pidToFinalize)
            return
        }

        let matchedEntry = trackedByBundleURL.first { _, entry in
            entry.runningApplication === running
                || (running.processIdentifier > 0 && entry.pid == running.processIdentifier)
        }
        if let matchedEntry {
            finalizeTermination(for: matchedEntry.key, pid: matchedEntry.value.pid)
        }
    }

    // MARK: - Process Lifecycle Internals

    private func matchedApp(for running: NSRunningApplication) -> PlayApp? {
        guard let apps = dependencies?.appsVM.apps else { return nil }
        return matchAppIndexed(running, among: apps)
    }

    private func attachProcess(
        _ runningApplication: NSRunningApplication,
        to app: PlayApp,
        hostContext: HostLaunchContext?
    ) {
        let pid = runningApplication.processIdentifier
        if let existing = trackedByBundleURL[app.url], existing.pid == pid {
            if let hostContext {
                var updated = existing
                updated.hostContext = hostContext
                trackedByBundleURL[app.url] = updated
            }
            let nextState: AppRunState = .running(isActive: runningApplication.isActive)
            if app.runState != nextState {
                app.setRunState(nextState)
            }
            syncDisplaySleepPolicy(for: app, runningApplication: runningApplication)
            return
        }

        if let previous = trackedByBundleURL[app.url] {
            previous.terminationObservation?.invalidate()
            if let settingsObserverID = previous.settingsObserverID {
                app.settings.removeChangeObserver(settingsObserverID)
            }
        }

        app.setRunningApplication(runningApplication)
        app.setRunState(.running(isActive: runningApplication.isActive))

        let bundleURL = app.url
        let expectedPID = pid
        let kvoToken = runningApplication.observe(\.isTerminated, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            Task { @MainActor [weak self] in
                self?.finalizeTermination(for: bundleURL, pid: expectedPID)
            }
        }

        let settingsObserverID = app.settings.addChangeObserver { [weak self, weak app] in
            Task { @MainActor [weak self, weak app] in
                guard let self, let app,
                      let tracked = self.trackedByBundleURL[app.url],
                      !tracked.runningApplication.isTerminated else {
                    return
                }
                self.syncDisplaySleepPolicy(for: app, runningApplication: tracked.runningApplication)
                if let mitmCoordinator = self.dependencies?.mitmCoordinator {
                    let bid = app.info.bundleIdentifier
                    let snapshot = app.settings.settings
                    Task { await mitmCoordinator.updateLiveConfiguration(for: bid, settings: snapshot) }
                }
            }
        }

        trackedByBundleURL[app.url] = TrackedProcess(
            app: app,
            runningApplication: runningApplication,
            pid: pid,
            terminationObservation: kvoToken,
            settingsObserverID: settingsObserverID,
            hostContext: hostContext
        )

        syncDisplaySleepPolicy(for: app, runningApplication: runningApplication)
    }

    private func syncDisplaySleepPolicy(for app: PlayApp, runningApplication: NSRunningApplication) {
        let shouldDisable = Self.shouldPreventDisplaySleep(
            runState: .running(isActive: runningApplication.isActive),
            disableTimeoutEnabled: app.settings.settings.disableTimeout
        )
        if shouldDisable {
            app.disableTimeOut()
        } else {
            app.enableTimeOut()
        }
    }

    private func linkDiscordIfNeeded(for app: PlayApp) {
        guard var tracked = trackedByBundleURL[app.url],
              let hostContext = tracked.hostContext,
              !hostContext.discordLinked,
              app.settings.settings.discordActivity.enable,
              app.container.doesExist() else {
            return
        }
        app.loadDiscordIPC()
        tracked.hostContext?.discordLinked = true
        trackedByBundleURL[app.url] = tracked
    }

    private func finalizeTermination(for appURL: URL, pid: pid_t) {
        guard let tracked = trackedByBundleURL[appURL], tracked.pid == pid else { return }
        trackedByBundleURL.removeValue(forKey: appURL)
        tracked.terminationObservation?.invalidate()

        guard let app = tracked.app else { return }
        if let settingsObserverID = tracked.settingsObserverID {
            app.settings.removeChangeObserver(settingsObserverID)
        }

        let cleared = app.clearRunningApplicationIfMatches(processIdentifier: pid)
        if cleared || app.snapshotRunningApplication() == nil {
            app.setRunState(.idle)
            app.launchSnapshot = nil
        }

        app.enableTimeOut()

        if let hostContext = tracked.hostContext {
            app.releaseDiscordIPC()
            app.lockKeyCover()

            if let mitmCoordinator = dependencies?.mitmCoordinator {
                let bid = app.info.bundleIdentifier
                let appSettings = app.settings
                Task { await mitmCoordinator.handleAppTermination(bundleID: bid, settings: appSettings) }
            }

            let elapsed = Date().timeIntervalSince(hostContext.launchDate)
            let breadcrumbURL = app.container.containerUrl
                .appendingPathComponent("Data/Library/Caches/app.makedie.PlayTools/.launching_in_progress")
            if elapsed < 3.0 && FileManager.default.fileExists(atPath: breadcrumbURL.path) {
                let msg = "\(app.name) exited abnormally within 3 seconds; " +
                    "next launch will automatically use Safe Mode."
                PlayCoverDiagnostics.log(msg, isError: true)
                PlayCoverDiagnostics.showToast(
                    toastType: .error,
                    toastDetails: msg,
                    timeRemaining: 5
                )
                dependencies?.startupAlerts.enqueue(
                    .safeModeActivated(
                        appName: app.name,
                        bundleID: app.info.bundleIdentifier,
                        breadcrumbPath: breadcrumbURL.path
                    )
                )
            }
        }
    }
}
