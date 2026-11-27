//
//  AppSettings.swift
//  PlayCover
//
//  Created by Александр Дорофеев on 07.12.2021.
//

import AppKit
import Foundation
import Observation
import PlayCoverCore
import Synchronization
import UniformTypeIdentifiers

@Observable
nonisolated final class AppSettings: @unchecked Sendable {
    static var appSettingsDir: URL {
        let settingsFolder =
            PlayTools.playCoverContainer.appendingPathComponent("App Settings")
        if !FileManager.default.fileExists(atPath: settingsFolder.path) {
            do {
                try FileManager.default.createDirectory(at: settingsFolder,
                                                        withIntermediateDirectories: true,
                                                        attributes: [:])
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
        }
        return settingsFolder
    }

    let info: AppInfo
    let settingsUrl: URL
    var openWithLLDB: Bool = false {
        didSet { fireChangeObservers() }
    }
    var openLLDBWithTerminal: Bool = true {
        didSet { fireChangeObservers() }
    }
    var effectiveOpenWithLLDB: Bool {
        settings.effectiveOpenWithLLDB(openWithLLDB)
    }
    private static let metalHUDQueue = DispatchQueue(
        label: "app.makedie.MacOver.AppSettings.metalHUD",
        qos: .utility
    )
    private static let metalHUDGenerations = Mutex<[String: UInt64]>([:])
    private static let lastSyncedMetalHUD = Mutex<[String: Bool]>([:])

    private struct PendingMetalHUDUpdate: Sendable {
        let bundleID: String
        let enabled: Bool
        let generation: UInt64
    }

    @ObservationIgnored private let lock = Mutex<Void>(())
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "app.makedie.MacOver.AppSettings.io", qos: .utility)
    @ObservationIgnored private var pendingSaveWorkItem: DispatchWorkItem?
    @ObservationIgnored private var hasPendingWrite = false
    @ObservationIgnored let debounceInterval: TimeInterval
    @ObservationIgnored private let metalHUDExecutor: @Sendable (String, Bool) throws -> Void
    @ObservationIgnored private let usesDefaultMetalHUDExecutor: Bool
    @ObservationIgnored private var suppressPersistence = false
    @ObservationIgnored private var isResetting = false
    @ObservationIgnored private var _settings: AppSettingsData
    @ObservationIgnored private var changeObservers: [UUID: @Sendable () -> Void] = [:]

    private static func reserveMetalHUDGeneration(for bundleID: String) -> UInt64 {
        metalHUDGenerations.withLock { generations in
            let next = (generations[bundleID] ?? 0) &+ 1
            generations[bundleID] = next
            return next
        }
    }

    private static func isLatestMetalHUDGeneration(_ generation: UInt64, for bundleID: String) -> Bool {
        metalHUDGenerations.withLock { $0[bundleID] == generation }
    }

    private static func isSystemMetalHUDUpToDate(bundleID: String, enabled: Bool) -> Bool {
        if let cached = lastSyncedMetalHUD.withLock({ $0[bundleID] }) {
            return cached == enabled
        }
        if let persisted = CFPreferencesCopyAppValue(
            "MetalForceHudEnabled" as CFString,
            bundleID as CFString
        ) as? Bool {
            lastSyncedMetalHUD.withLock { $0[bundleID] = persisted }
            return persisted == enabled
        }
        return false
    }

    private static func enqueueMetalHUDUpdate(
        _ pending: PendingMetalHUDUpdate,
        usesDefaultExecutor: Bool,
        executor: @escaping @Sendable (String, Bool) throws -> Void
    ) {
        metalHUDQueue.async {
            guard isLatestMetalHUDGeneration(pending.generation, for: pending.bundleID) else { return }
            if usesDefaultExecutor && isSystemMetalHUDUpToDate(bundleID: pending.bundleID, enabled: pending.enabled) {
                return
            }
            do {
                try executor(pending.bundleID, pending.enabled)
                if usesDefaultExecutor {
                    lastSyncedMetalHUD.withLock { $0[pending.bundleID] = pending.enabled }
                }
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
        }
    }

    static func syncMetalHUD(
        bundleID: String,
        enabled: Bool,
        executor: (@Sendable (String, Bool) throws -> Void)? = nil
    ) async {
        guard !bundleID.isEmpty else { return }
        let generation = reserveMetalHUDGeneration(for: bundleID)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            metalHUDQueue.async {
                defer { continuation.resume() }
                guard isLatestMetalHUDGeneration(generation, for: bundleID) else { return }
                if executor == nil && isSystemMetalHUDUpToDate(bundleID: bundleID, enabled: enabled) {
                    return
                }
                let runExecutor = executor ?? { try Shell.setMetalHUD($0, enabled: $1) }
                if (try? runExecutor(bundleID, enabled)) != nil, executor == nil {
                    lastSyncedMetalHUD.withLock { $0[bundleID] = enabled }
                }
            }
        }
    }

    @discardableResult
    func addChangeObserver(_ observer: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.withLock { _ in
            changeObservers[id] = observer
        }
        return id
    }

    func removeChangeObserver(_ id: UUID) {
        lock.withLock { _ in
            _ = changeObservers.removeValue(forKey: id)
        }
    }

    private func fireChangeObservers() {
        let observers = lock.withLock { _ in Array(changeObservers.values) }
        guard !observers.isEmpty else { return }
        if Thread.isMainThread {
            for observer in observers {
                observer()
            }
        } else {
            DispatchQueue.main.async {
                for observer in observers {
                    observer()
                }
            }
        }
    }

    private func notifyChangedOnMain() {
        withMutation(keyPath: \.settings) {}
        fireChangeObservers()
    }

    var settings: AppSettingsData {
        get {
            access(keyPath: \.settings)
            return lock.withLock { _ in _settings }
        }
        set {
            update { $0 = newValue }
        }
    }

    static func settingsURL(forBundleIdentifier bundleIdentifier: String) -> URL {
        appSettingsDir
            .appendingEscapedPathComponent(bundleIdentifier)
            .appendingPathExtension("plist")
    }

    convenience init(_ info: AppInfo) {
        let url = AppSettings.settingsURL(forBundleIdentifier: info.bundleIdentifier)
        self.init(settingsUrl: url, info: info, debounceInterval: 0.5)
    }

    init(
        settingsUrl: URL,
        info: AppInfo,
        debounceInterval: TimeInterval = 0.5,
        metalHUDExecutor: (@Sendable (String, Bool) throws -> Void)? = nil
    ) {
        self.info = info
        self.settingsUrl = settingsUrl
        self.debounceInterval = debounceInterval
        self.usesDefaultMetalHUDExecutor = metalHUDExecutor == nil
        self.metalHUDExecutor = metalHUDExecutor ?? { try Shell.setMetalHUD($0, enabled: $1) }
        var defaults = AppSettingsData()
        defaults.bundleIdentifier = info.bundleIdentifier
        defaults.notch = NSScreen.hasNotch()
        _settings = defaults

        if !decode() {
            preserveUnreadableSettingsIfPresent()
            encode()
        } else if settings.bundleIdentifier != info.bundleIdentifier {
            update { $0.bundleIdentifier = info.bundleIdentifier }
            _ = flush()
        }
    }

    deinit {
        _ = flush()
    }

    private func reserveMetalHUDIfNeededLocked(
        from previous: AppSettingsData,
        to current: AppSettingsData
    ) -> PendingMetalHUDUpdate? {
        guard previous.effectiveMetalHUD != current.effectiveMetalHUD,
              !current.bundleIdentifier.isEmpty else {
            return nil
        }
        let generation = Self.reserveMetalHUDGeneration(for: current.bundleIdentifier)
        return PendingMetalHUDUpdate(
            bundleID: current.bundleIdentifier,
            enabled: current.effectiveMetalHUD,
            generation: generation
        )
    }

    func update(_ mutate: (inout AppSettingsData) -> Void) {
        let pendingHUD: PendingMetalHUDUpdate? = lock.withLock { _ in
            let previous = _settings
            var updated = _settings
            mutate(&updated)
            guard updated != previous else {
                return nil
            }
            _settings = updated
            let nextHUD: PendingMetalHUDUpdate?
            if !suppressPersistence {
                nextHUD = reserveMetalHUDIfNeededLocked(from: previous, to: updated)
                scheduleDebouncedWriteLocked()
            } else {
                nextHUD = nil
            }
            return nextHUD
        }

        notifyChangedOnMain()

        if let pendingHUD {
            Self.enqueueMetalHUDUpdate(
                pendingHUD,
                usesDefaultExecutor: usesDefaultMetalHUDExecutor,
                executor: metalHUDExecutor
            )
        }
    }

    private func scheduleDebouncedWriteLocked() {
        hasPendingWrite = true
        pendingSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performScheduledWrite()
        }
        pendingSaveWorkItem = workItem
        ioQueue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func performScheduledWrite() {
        lock.withLock { _ in
            guard hasPendingWrite else { return }
            pendingSaveWorkItem = nil
            _ = encodeLocked()
            hasPendingWrite = false
        }
    }

    @discardableResult
    public func flush() -> Bool {
        lock.withLock { _ in
            pendingSaveWorkItem?.cancel()
            pendingSaveWorkItem = nil
            guard hasPendingWrite else { return true }
            let ok = encodeLocked()
            hasPendingWrite = false
            return ok
        }
    }

    public func sync() {
        let hasNotch = NSScreen.hasNotch()
        let autoRes = AppSettings.autoResolution()
        update { updatedSettings in
            guard !updatedSettings.strictEmulationMode else { return }
            updatedSettings.notch = hasNotch
            if updatedSettings.resolution == 1 {
                updatedSettings.windowWidth = autoRes.width
                updatedSettings.windowHeight = autoRes.height
            }
        }
    }

    static func autoResolution() -> (width: Int, height: Int) {
        let width = Int(NSScreen.main?.frame.width ?? 1920)
        let height = Int(NSScreen.main?.frame.height ?? 1080)
        return AppSettingsPersistence.autoResolution(
            screenWidth: width,
            screenHeight: height,
            hasNotch: NSScreen.hasNotch()
        )
    }

    public func reset() {
        var defaults = AppSettingsData()
        defaults.bundleIdentifier = info.bundleIdentifier
        defaults.notch = NSScreen.hasNotch()
        let pendingHUD: PendingMetalHUDUpdate? = lock.withLock { _ in
            pendingSaveWorkItem?.cancel()
            pendingSaveWorkItem = nil
            hasPendingWrite = false
            let previous = _settings
            isResetting = true
            defer { isResetting = false }
            _settings = defaults
            let nextHUD = reserveMetalHUDIfNeededLocked(from: previous, to: defaults)
            _ = encodeLocked()
            return nextHUD
        }

        notifyChangedOnMain()

        if let pendingHUD {
            Self.enqueueMetalHUDUpdate(
                pendingHUD,
                usesDefaultExecutor: usesDefaultMetalHUDExecutor,
                executor: metalHUDExecutor
            )
        }
    }

    @discardableResult
    public func decode() -> Bool {
        let decodeResult: Result<Void, Error> = lock.withLock { _ in
            pendingSaveWorkItem?.cancel()
            pendingSaveWorkItem = nil
            hasPendingWrite = false
            do {
                let decoded = try AppSettingsPersistence.decode(from: settingsUrl)
                suppressPersistence = true
                _settings = decoded
                suppressPersistence = false
                return .success(())
            } catch {
                suppressPersistence = false
                return .failure(error)
            }
        }
        switch decodeResult {
        case .success:
            notifyChangedOnMain()
            return true
        case let .failure(error):
            if FileManager.default.fileExists(atPath: settingsUrl.path) {
                PlayCoverDiagnostics.log(
                    "App settings decode failed for \(info.bundleIdentifier): \(error.localizedDescription)",
                    isError: true
                )
            }
            return false
        }
    }

    @discardableResult
    public func encode() -> Bool {
        lock.withLock { _ in
            pendingSaveWorkItem?.cancel()
            pendingSaveWorkItem = nil
            hasPendingWrite = false
            return encodeLocked()
        }
    }

    @discardableResult
    private func encodeLocked() -> Bool {
        do {
            let persisted = try AppSettingsPersistence.encode(
                _settings,
                to: settingsUrl,
                preservingExistingKeys: !isResetting
            )
            if _settings.keymappingDisabledAt != persisted.keymappingDisabledAt {
                _settings.keymappingDisabledAt = persisted.keymappingDisabledAt
            }
            return true
        } catch {
            PlayCoverDiagnostics.log(
                "App settings write failed for \(info.bundleIdentifier): \(error.localizedDescription)",
                isError: true
            )
            return false
        }
    }

    private func preserveUnreadableSettingsIfPresent() {
        _ = AppSettingsPersistence.preserveUnreadableFileIfPresent(
            at: settingsUrl,
            bundleIdentifier: info.bundleIdentifier
        )
    }
}

nonisolated extension NSScreen {
    public static func hasNotch() -> Bool {
        // check if any of the connected screens contains a notch
        return NSScreen.screens.contains { $0.safeAreaInsets.top != 0 }
    }
}
