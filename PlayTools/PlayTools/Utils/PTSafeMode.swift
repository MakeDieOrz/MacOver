//
//  PTSafeMode.swift
//  PlayTools
//
//  Post-mortem Safe Mode supervisor and diagnostic logger.
//

import Darwin
import Foundation

public enum PTDiagnosticLogger {
    private static let lock = PTUnfairLock()
    private static let formatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    public static func sanitizedBundleID(_ raw: String?) -> String {
        let base = (raw?.isEmpty == false ? raw! : Bundle.main.bundleIdentifier) ?? "unknown"
        let mapped = base.map { ch -> Character in
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_") {
                return ch
            }
            return "_"
        }
        return String(mapped)
    }

    public static func defaultLogURL(bundleIdentifier: String? = nil) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PlayTools-\(sanitizedBundleID(bundleIdentifier)).log")
    }

    public static func log(
        _ message: String,
        bundleIdentifier: String? = nil,
        fallbackDirectory: URL? = nil,
        force: Bool = false,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        explicitLogURL: URL? = nil
    ) {
        let debugEnabled = environment["PLAYTOOLS_DEBUG_LOG"] == "1"
        guard force || debugEnabled else { return }

        lock.withLock {
            let timestamp = formatter.string(from: Date())
            let line = "[\(timestamp)] [PlayTools] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            let primary = explicitLogURL ?? defaultLogURL(bundleIdentifier: bundleIdentifier)
            if append(data, to: primary) {
                return
            }
            let effectiveFallbackDir = fallbackDirectory
                ?? (explicitLogURL == nil ? PTSafeMode.defaultStateDirectory() : nil)
            if let fallbackDir = effectiveFallbackDir {
                let fallbackURL = fallbackDir.appendingPathComponent("PlayTools.log")
                _ = append(data, to: fallbackURL)
            }
        }
    }

    @discardableResult
    private static func append(_ data: Data, to url: URL) -> Bool {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: url.path) {
            return fm.createFile(atPath: url.path, contents: data, attributes: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return false
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }
}

@objc public final class PTSafeMode: NSObject {
    @objc public static let shared = PTSafeMode()

    public static let breadcrumbFilename = ".launching_in_progress"
    public static let triggeredMarkerFilename = ".safe_mode_last_triggered"
    public static let defaultStabilityWindow: TimeInterval = 3.0

    private let lock = PTUnfairLock()
    private let stateDirectoryOverride: URL?
    private let bundleIdentifierOverride: String?
    private var _isSafeModeActive = false
    private var _hasEvaluatedProcessLaunch = false
    private var stabilityWorkItem: DispatchWorkItem?
    private var launchGeneration: UInt64 = 0

    @objc public static var isActive: Bool {
        shared.isSafeModeActive
    }

    @objc public var isSafeModeActive: Bool {
        lock.withLock { _isSafeModeActive }
    }

    public init(stateDirectory: URL? = nil, bundleIdentifier: String? = nil) {
        self.stateDirectoryOverride = stateDirectory
        self.bundleIdentifierOverride = bundleIdentifier
        super.init()
    }

    public static func defaultStateDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("app.makedie.PlayTools", isDirectory: true)
    }

    public var stateDirectoryURL: URL {
        stateDirectoryOverride ?? Self.defaultStateDirectory()
    }

    public var breadcrumbURL: URL {
        stateDirectoryURL.appendingPathComponent(Self.breadcrumbFilename)
    }

    public var lastTriggeredURL: URL {
        stateDirectoryURL.appendingPathComponent(Self.triggeredMarkerFilename)
    }

    @discardableResult
    @objc public func ensureEvaluatedForCurrentProcess() -> Bool {
        let shouldEvaluate: Bool = lock.withLock {
            if _hasEvaluatedProcessLaunch {
                return false
            }
            _hasEvaluatedProcessLaunch = true
            return true
        }
        if shouldEvaluate {
            return evaluateAndBeginLaunch()
        }
        return isSafeModeActive
    }

    @discardableResult
    @objc(evaluateAndBeginLaunch)
    public func evaluateAndBeginLaunchObjC() -> Bool {
        evaluateAndBeginLaunch()
    }

    @discardableResult
    public func evaluateAndBeginLaunch(
        bundleIdentifier: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stabilityWindow: TimeInterval = PTSafeMode.defaultStabilityWindow
    ) -> Bool {
        let resolvedBundleID = bundleIdentifier
            ?? bundleIdentifierOverride
            ?? (Bundle.main.bundleIdentifier ?? "")
        let fm = FileManager.default
        let stateDir = stateDirectoryURL
        let crumbURL = breadcrumbURL
        let triggeredURL = lastTriggeredURL

        if let rawOverride = environment["PLAYTOOLS_SAFE_MODE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !rawOverride.isEmpty {
            if rawOverride == "1" || rawOverride == "true" || rawOverride == "yes" {
                lock.withLock {
                    launchGeneration &+= 1
                    stabilityWorkItem?.cancel()
                    stabilityWorkItem = nil
                    _isSafeModeActive = true
                }
                ensureDirectory(stateDir)
                try? fm.removeItem(at: crumbURL)
                let marker = "reason=env\nbundleIdentifier=\(resolvedBundleID)\npid=\(getpid())\n"
                try? marker.data(using: .utf8)?.write(to: triggeredURL, options: .atomic)
                PTDiagnosticLogger.log(
                    "Safe Mode activated via PLAYTOOLS_SAFE_MODE override for \(resolvedBundleID)",
                    bundleIdentifier: resolvedBundleID,
                    fallbackDirectory: stateDir,
                    force: true,
                    environment: environment
                )
                return true
            } else if rawOverride == "0" || rawOverride == "false" || rawOverride == "no" {
                ensureDirectory(stateDir)
                try? fm.removeItem(at: crumbURL)
                let generation: UInt64 = lock.withLock {
                    launchGeneration &+= 1
                    stabilityWorkItem?.cancel()
                    stabilityWorkItem = nil
                    _isSafeModeActive = false
                    return launchGeneration
                }
                writeBreadcrumb(to: crumbURL, bundleIdentifier: resolvedBundleID)
                scheduleStabilityTimer(generation: generation, window: stabilityWindow)
                return false
            }
        }

        ensureDirectory(stateDir)

        if fm.fileExists(atPath: crumbURL.path) {
            try? fm.removeItem(at: crumbURL)
            lock.withLock {
                launchGeneration &+= 1
                stabilityWorkItem?.cancel()
                stabilityWorkItem = nil
                _isSafeModeActive = true
            }
            let marker = "reason=post_mortem_breadcrumb\nbundleIdentifier=\(resolvedBundleID)\npid=\(getpid())\n"
            try? marker.data(using: .utf8)?.write(to: triggeredURL, options: .atomic)
            PTDiagnosticLogger.log(
                "Safe Mode triggered post-mortem due to stale launch breadcrumb at \(crumbURL.path)",
                bundleIdentifier: resolvedBundleID,
                fallbackDirectory: stateDir,
                force: true,
                environment: environment
            )
            return true
        }

        let generation: UInt64 = lock.withLock {
            launchGeneration &+= 1
            stabilityWorkItem?.cancel()
            stabilityWorkItem = nil
            _isSafeModeActive = false
            return launchGeneration
        }
        writeBreadcrumb(to: crumbURL, bundleIdentifier: resolvedBundleID)
        scheduleStabilityTimer(generation: generation, window: stabilityWindow)
        return false
    }

    @objc public func markLaunchStable() {
        lock.withLock {
            stabilityWorkItem?.cancel()
            stabilityWorkItem = nil
        }
        try? FileManager.default.removeItem(at: breadcrumbURL)
    }

    @objc public func markGracefulTermination() {
        markLaunchStable()
    }

    private func ensureDirectory(_ url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func writeBreadcrumb(to url: URL, bundleIdentifier: String) {
        let payload = [
            "pid=\(getpid())",
            "bundleIdentifier=\(bundleIdentifier)",
            "startedAt=\(Date().timeIntervalSince1970)"
        ].joined(separator: "\n") + "\n"
        try? payload.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func scheduleStabilityTimer(generation: UInt64, window: TimeInterval) {
        let delay = max(0, window)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let shouldClear = self.lock.withLock {
                self.launchGeneration == generation
            }
            if shouldClear {
                self.markLaunchStable()
            }
        }
        lock.withLock {
            stabilityWorkItem = work
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }
}
