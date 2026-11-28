import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Observation
import PlayCoverCore
import PlayCoverKeymapping
import PlayCoverMCP
import PlayCoverMachO
import PlayCoverNetwork
import Synchronization
import UniformTypeIdentifiers

@MainActor
@Observable
final class MCPHostCoordinator {
    let preferences: MCPPreferences
    private(set) var isRunning = false
    private(set) var daemonPort: UInt16?
    private(set) var bridgePort: UInt16?
    private(set) var connectedBridgeBundleIDs: [String] = []
    private(set) var axTrusted: Bool = AXAccessibilityEngine.isProcessTrusted(prompt: false)
    private(set) var lastError: String?

    @ObservationIgnored weak var dependencies: PlayCoverDependencies?
    @ObservationIgnored private let bridgeHub = MCPBridgeHub(requireAppBundleMatch: true)
    @ObservationIgnored private let axEngine = AXAccessibilityEngine()
    @ObservationIgnored private let revisionStore = UITreeRevisionStore()
    @ObservationIgnored private let expectedExecutablePaths = Mutex<[String: String]>([:])
    @ObservationIgnored private let diagnosticsQueue = DispatchQueue(
        label: "app.makedie.MacOver.MCPHostCoordinator.diagnostics",
        qos: .utility,
        attributes: .concurrent
    )
    @ObservationIgnored private var daemonServer: MCPLoopbackServer?
    @ObservationIgnored private var startedDeferred = false

    init(preferences: MCPPreferences) {
        self.preferences = preferences
    }

    func startIfEnabled() {
        refreshAXTrustStatus(prompt: false)
        guard !ProcessInfo.isRunningUnitTests else { return }
        if preferences.isEnabled {
            start()
        } else {
            MCPDaemonSessionFile.remove()
        }
    }

    func setEnabled(_ enabled: Bool) {
        preferences.isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard !isRunning else { return }
        do {
            let bPort = try bridgeHub.start()
            let server = MCPLoopbackServer { [weak self] toolName, arguments in
                guard let self else {
                    return .text("MacOver host coordinator deallocated", isError: true)
                }
                return await self.handleToolCall(name: toolName, arguments: arguments)
            }
            let (dPort, token) = try server.start()
            let session = MCPDaemonSession(
                port: dPort,
                token: token,
                pid: ProcessInfo.processInfo.processIdentifier,
                version: MCPProtocol.serverVersion
            )
            try MCPDaemonSessionFile.write(session)
            self.daemonServer = server
            self.daemonPort = dPort
            self.bridgePort = bPort
            self.isRunning = true
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
            stop()
        }
    }

    func stop() {
        daemonServer?.stop()
        daemonServer = nil
        bridgeHub.stop()
        MCPDaemonSessionFile.remove()
        isRunning = false
        daemonPort = nil
        bridgePort = nil
        connectedBridgeBundleIDs = []
    }

    func prepareForHostTermination() {
        stop()
    }

    func handleAppTerminated(bundleID: String) {
        guard !bundleID.isEmpty else { return }
        bridgeHub.disconnect(bundleID: bundleID)
        revisionStore.clear(bundleID: bundleID)
        Task { await axEngine.clearCache(for: bundleID) }
        syncBridgeState()
    }

    @discardableResult
    func refreshAXTrustStatus(prompt: Bool = false) -> Bool {
        let trusted = AXAccessibilityEngine.isProcessTrusted(prompt: prompt)
        axTrusted = trusted
        return trusted
    }

    nonisolated func prepareAutomationEnvironment(for bundleID: String) -> [String: String] {
        guard !bundleID.isEmpty,
              let port = bridgeHub.currentPort else {
            return [:]
        }
        let expectedPath = expectedExecutablePaths.withLock { $0[bundleID] }
        let token = bridgeHub.issueLaunchToken(
            for: bundleID,
            expectedExecutablePath: expectedPath,
            ttlSeconds: 15.0
        )
        return [
            "MACOVER_AUTOMATION_PORT": String(port),
            "MACOVER_AUTOMATION_TOKEN": token,
            "MACOVER_AUTOMATION_BUNDLE_ID": bundleID
        ]
    }

    func syncBridgeState() {
        connectedBridgeBundleIDs = bridgeHub.connectedBundleIDs()
        cacheExpectedExecutablePaths()
    }

    func handleToolCall(name: String, arguments: [String: MCPJSONValue]) async -> MCPToolCallResult {
        syncBridgeState()
        switch name {
        case "macover_apps":
            return await handleAppsTool(arguments)
        case "macover_settings":
            return await handleSettingsTool(arguments)
        case "macover_ui_snapshot":
            return await handleUISnapshotTool(arguments)
        case "macover_act":
            return await handleActTool(arguments)
        case "macover_wait":
            return await handleWaitTool(arguments)
        case "macover_screenshot":
            return await handleScreenshotTool(arguments)
        case "macover_network":
            return handleNetworkTool(arguments)
        case "macover_network_rules":
            return await handleNetworkRulesTool(arguments)
        case "macover_diagnostics":
            return await handleDiagnosticsTool(arguments)
        case "macover_keymap":
            return handleKeymapTool(arguments)
        default:
            return .text("Unknown tool: \(name)", isError: true)
        }
    }

    // MARK: - 1. macover_apps

    private func handleAppsTool(_ args: [String: MCPJSONValue]) async -> MCPToolCallResult {
        guard let op = args.string("op") else {
            return .text("Missing required 'op'", isError: true)
        }
        if op == "inspect_ipa" {
            guard let path = args.string("path") else {
                return .text("Missing 'path' for inspect_ipa", isError: true)
            }
            return await MCPCLIRunner.inspectBinaryOrIPAAsync(atPath: path)
        }
        guard let deps = dependencies else {
            return .text("Host dependencies unavailable", isError: true)
        }
        let apps = deps.appsVM.apps
        if op == "list" {
            let axOK = refreshAXTrustStatus(prompt: false)
            var lines = ["# hostRunning=true axReady=\(axOK) apps=\(apps.count)"]
            lines.append("# bundleID\tname\tversion\tstate\tpid\tbridgeReady\tmitmPort")
            for app in apps.sorted(by: { $0.info.bundleIdentifier < $1.info.bundleIdentifier }) {
                let bid = app.info.bundleIdentifier
                let runningApp = resolvedRunningApp(for: app)
                let pid = runningApp?.processIdentifier ?? 0
                let state = pid > 0 ? (runningApp?.isActive == true ? "active" : "running") : "idle"
                let bridgeReady = bridgeHub.sessionInfo(for: bid) != nil
                let mitmPort = deps.mitmCoordinator.activePorts[bid] ?? 0
                let row = [
                    bid, app.name, app.info.bundleVersion, state,
                    String(pid), String(bridgeReady), String(mitmPort)
                ].joined(separator: "\t")
                lines.append(row)
            }
            return .text(lines.joined(separator: "\n"))
        }

        guard let bundleID = args.string("bundleID"),
              let app = findApp(bundleID: bundleID) else {
            return .text("App not found for bundleID: \(args.string("bundleID") ?? "")", isError: true)
        }

        switch op {
        case "launch", "restart":
            if op == "launch", app.isRunning {
                let pid = resolvedRunningApp(for: app)?.processIdentifier ?? 0
                return .json(.object([
                    "bundleID": .string(bundleID),
                    "status": .string("already_running"),
                    "pid": .int(Int(pid)),
                    "axReady": .bool(refreshAXTrustStatus(prompt: false)),
                    "bridgeReady": .bool(bridgeHub.sessionInfo(for: bundleID) != nil)
                ]))
            }
            let useBridge = args.bool("bridge") ?? app.settings.settings.enableAutomationBridge
            let safeMode = args.bool("safeMode") ?? false
            let debugTrace = args.bool("debugTrace") ?? false
            if args.bool("enableMITM") == true && app.settings.settings.networkProxyMode != "builtInMITM" {
                app.settings.update { $0.networkProxyMode = "builtInMITM" }
                _ = app.settings.flush()
            }
            if op == "restart" {
                await app.restart(
                    safeModeOneShot: safeMode,
                    automationOneShot: useBridge,
                    captureDebugLog: debugTrace
                )
            } else {
                await app.launch(
                    safeModeOneShot: safeMode,
                    automationOneShot: useBridge,
                    captureDebugLog: debugTrace
                )
            }
            if useBridge && !safeMode {
                let deadline = Date().addingTimeInterval(5.0)
                while bridgeHub.sessionInfo(for: bundleID) == nil && Date() < deadline {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            syncBridgeState()
            let pid = resolvedRunningApp(for: app)?.processIdentifier ?? 0
            return .json(.object([
                "bundleID": .string(bundleID),
                "pid": .int(Int(pid)),
                "running": .bool(pid > 0),
                "axReady": .bool(refreshAXTrustStatus(prompt: false)),
                "bridgeReady": .bool(bridgeHub.sessionInfo(for: bundleID) != nil),
                "mitmPort": .int(Int(deps.mitmCoordinator.activePorts[bundleID] ?? 0))
            ]))

        case "stop":
            await app.terminate()
            handleAppTerminated(bundleID: bundleID)
            return .json(.object(["bundleID": .string(bundleID), "stopped": .bool(true)]))

        case "focus":
            let focused = app.activateRunningApplication()
            return .json(.object(["bundleID": .string(bundleID), "focused": .bool(focused)]))

        default:
            return .text("Unsupported op '\(op)'", isError: true)
        }
    }

    // MARK: - 2. macover_settings

    private func handleSettingsTool(_ args: [String: MCPJSONValue]) async -> MCPToolCallResult {
        guard let op = args.string("op"),
              let bundleID = args.string("bundleID"),
              let app = findApp(bundleID: bundleID) else {
            return .text("Missing or unknown bundleID", isError: true)
        }
        let defaults = AppSettingsData()
        guard let defaultDict = encodeSettingsDict(defaults) else {
            return .text("Failed to encode default settings", isError: true)
        }

        if op == "get" {
            guard var dict = encodeSettingsDict(app.settings.settings) else {
                return .text("Failed to encode app settings", isError: true)
            }
            if let keys = args.stringArray("keys"), !keys.isEmpty {
                let allow = Set(keys)
                dict = dict.filter { allow.contains($0.key) }
            } else if args.bool("nonDefaultOnly") == true {
                dict = dict.filter { key, value in defaultDict[key] != value }
            }
            return .json(.object(["bundleID": .string(bundleID), "settings": .object(dict)]))
        }

        if op == "patch" {
            guard let patch = args["patch"]?.objectValue else {
                return .text("Missing 'patch' object", isError: true)
            }
            if let policyViolation = MCPSettingsPatchPolicy.validate(
                patch: patch,
                knownKeys: Set(defaultDict.keys)
            ) {
                return .text(policyViolation, isError: true)
            }
            guard var merged = encodeSettingsDict(app.settings.settings) else {
                return .text("Failed to encode current settings", isError: true)
            }
            for (key, value) in patch {
                merged[key] = value
            }
            do {
                let data = try JSONEncoder().encode(MCPJSONValue.object(merged))
                var updated = try JSONDecoder().decode(AppSettingsData.self, from: data)
                updated.bundleIdentifier = app.info.bundleIdentifier
                normalizePatchedDisplaySettings(&updated, patch: patch)
                app.settings.update { current in
                    current = updated
                    current.bundleIdentifier = app.info.bundleIdentifier
                }
                _ = app.settings.flush()
                let effective = app.settings.settings
                if let mitm = dependencies?.mitmCoordinator {
                    await mitm.updateLiveConfiguration(for: bundleID, settings: effective)
                }
                let restartFields = app.restartRequiredChanges.map(\.rawValue)
                return .json(.object([
                    "bundleID": .string(bundleID),
                    "updated": .bool(true),
                    "restartRequiredChanges": .array(restartFields.map { .string($0) })
                ]))
            } catch {
                return .text("Invalid settings patch: \(error.localizedDescription)", isError: true)
            }
        }

        return .text("Unsupported op '\(op)'", isError: true)
    }

    // MARK: - 3. macover_ui_snapshot

    private func handleUISnapshotTool(_ args: [String: MCPJSONValue]) async -> MCPToolCallResult {
        guard let bundleID = args.string("bundleID"),
              let app = findApp(bundleID: bundleID) else {
            return .text("Unknown bundleID", isError: true)
        }
        guard let pid = resolvedPID(for: app), pid > 0 else {
            return .text("App '\(bundleID)' is not running", isError: true)
        }

        var scopeRawID: String?
        var scopeSemanticKey: String?
        if let scopeRef = args.string("scopeRef") {
            guard let scopeNode = revisionStore.scopeNode(forRef: scopeRef, bundleID: bundleID) else {
                return .text("STALE_REF \(scopeRef): unknown scopeRef for \(bundleID)", isError: true)
            }
            scopeRawID = scopeNode.rawID
            scopeSemanticKey = scopeNode.semanticKey
        }

        let boundsMode = UITreeBoundsMode(rawValue: args.string("bounds") ?? "none") ?? .none
        let query = UISnapshotQuery(
            interactiveOnly: args.bool("interactiveOnly") ?? true,
            viewportOnly: args.bool("viewportOnly") ?? true,
            query: args.string("query"),
            roles: args.stringArray("roles") ?? [],
            scopeRef: scopeRawID,
            scopeSemanticKey: scopeSemanticKey,
            maxNodes: args.int("maxNodes") ?? 80,
            maxDepth: args.int("maxDepth") ?? 8,
            bounds: boundsMode
        )

        do {
            let raw = try await captureRawTree(bundleID: bundleID, pid: pid, sourceArg: args.string("source"))
            let recorded = revisionStore.record(rawSnapshot: raw, query: query)
            if recorded.current.scopeNotFound {
                let refLabel = args.string("scopeRef") ?? ""
                return .text(
                    "STALE_REF \(refLabel): scoped element is no longer present in live UI tree",
                    isError: true
                )
            }
            if args.bool("diff") == true {
                let baseSnap = args.int("sinceRev").flatMap {
                    revisionStore.snapshot(for: bundleID, revision: $0)
                } ?? recorded.previous
                if let baseSnap {
                    return .text(UITreeRevisionStore.formatDiff(from: baseSnap, to: recorded.current))
                }
            }
            return .text(recorded.current.text)
        } catch {
            return .text(error.localizedDescription, isError: true)
        }
    }

    // MARK: - 4. macover_act

    private func handleActTool(_ args: [String: MCPJSONValue]) async -> MCPToolCallResult {
        guard let bundleID = args.string("bundleID"),
              let app = findApp(bundleID: bundleID) else {
            return .text("Unknown bundleID", isError: true)
        }
        guard let pid = resolvedPID(for: app), pid > 0 else {
            return .text("App '\(bundleID)' is not running", isError: true)
        }

        let stepObjects: [[String: MCPJSONValue]]
        if let steps = args["steps"]?.arrayValue, !steps.isEmpty {
            stepObjects = steps.compactMap(\.objectValue)
        } else {
            stepObjects = [args]
        }

        let topLevelRev = args.int("rev")
        var stepLogs: [String] = []
        for (idx, step) in stepObjects.enumerated() {
            guard let action = step.string("action") else {
                return .text("Missing 'action' in step \(idx)", isError: true)
            }
            do {
                let outcome = try await executeSingleAction(
                    app: app,
                    pid: pid,
                    action: action,
                    step: step,
                    defaultRevision: topLevelRev
                )
                stepLogs.append(outcome)
            } catch {
                return .text(error.localizedDescription, isError: true)
            }
        }

        let settleMs = max(0, min(5_000, args.int("settleMs") ?? 250))
        if settleMs > 0 {
            try? await Task.sleep(nanoseconds: UInt64(settleMs) * 1_000_000)
        }

        let observe = args.string("observe") ?? "diff"
        var summary = stepLogs.joined(separator: "; ")
        if observe != "none",
           let raw = try? await captureRawTree(bundleID: bundleID, pid: pid, sourceArg: args.string("source")) {
            let recorded = revisionStore.record(rawSnapshot: raw, query: UISnapshotQuery())
            if observe == "diff", let prev = recorded.previous {
                summary += "\n" + UITreeRevisionStore.formatDiff(from: prev, to: recorded.current)
            } else {
                summary += "\n" + recorded.current.text
            }
        }
        return .text(summary)
    }

    private func executeSingleAction(
        app: PlayApp,
        pid: pid_t,
        action: String,
        step: [String: MCPJSONValue],
        defaultRevision: Int?
    ) async throws -> String {
        let bundleID = app.info.bundleIdentifier
        let semanticActions: Set<String> = [
            "press", "set_value", "input", "scroll_to", "menu", "increment", "decrement"
        ]
        var targetNode: CompactedUINode?
        if let ref = step.string("ref") {
            let expectedRev = step.int("rev") ?? defaultRevision
            switch revisionStore.resolveRef(bundleID: bundleID, ref: ref, expectedRevision: expectedRev) {
            case .found(let node):
                targetNode = node
            case .stale(let message, let candidates):
                let hint = candidates.map(\.lineText).joined(separator: "\n")
                throw AXBridgeError.actionFailed(hint.isEmpty ? message : "\(message)\nCandidates:\n\(hint)")
            }
        }

        let forcedSource = step.string("source")
        let useAX = semanticActions.contains(action)
            && forcedSource != "bridge"
            && (targetNode?.source ?? (refreshAXTrustStatus() ? .ax : .bridge)) == .ax

        if useAX, let targetNode {
            try await axEngine.performAction(
                bundleID: bundleID,
                nodeID: targetNode.rawID,
                action: action,
                text: step.string("text"),
                clear: step.bool("clear") ?? true
            )
            return "ax:\(action)[\(targetNode.ref)]"
        }

        if let bridgeSession = bridgeHub.sessionInfo(for: bundleID) {
            let viewport = resolvedViewport(for: app, bridgeSession: bridgeSession)
            if action == "input" || action == "set_value", let targetNode {
                _ = try await bridgeHub.sendRequestAsync(
                    bundleID: bundleID,
                    method: "set_text",
                    params: [
                        "nodeID": .string(targetNode.rawID),
                        "text": .string(step.string("text") ?? ""),
                        "clear": .bool(step.bool("clear") ?? true)
                    ]
                )
                return "bridge:\(action)[\(targetNode.ref)]"
            }
            if action == "press", let targetNode {
                _ = try await bridgeHub.sendRequestAsync(
                    bundleID: bundleID,
                    method: "activate_node",
                    params: ["nodeID": .string(targetNode.rawID)]
                )
                return "bridge:press[\(targetNode.ref)]"
            }

            let startPoint: LogicalPoint
            if let targetNode {
                startPoint = try CoordinateMapper.centerPoint(of: targetNode.frame, viewport: viewport)
            } else {
                startPoint = try CoordinateMapper.resolvePoint(
                    x: step.double("x"),
                    y: step.double("y"),
                    nx: step.double("nx"),
                    ny: step.double("ny"),
                    viewport: viewport
                )
            }

            var touchParams: [String: MCPJSONValue] = [
                "gesture": .string(action == "press" ? "tap" : action),
                "x": .double(startPoint.x),
                "y": .double(startPoint.y)
            ]
            if action == "swipe" || action == "drag" {
                let endPoint = try CoordinateMapper.resolvePoint(
                    x: step.double("toX"),
                    y: step.double("toY"),
                    nx: step.double("toNx"),
                    ny: step.double("toNy"),
                    viewport: viewport
                )
                touchParams["toX"] = .double(endPoint.x)
                touchParams["toY"] = .double(endPoint.y)
            }
            if let durationMs = step.int("durationMs") {
                touchParams["durationMs"] = .int(durationMs)
            }
            if let scale = step.double("scale") {
                touchParams["scale"] = .double(scale)
            }
            _ = try await bridgeHub.sendRequestAsync(bundleID: bundleID, method: "touch", params: touchParams)
            return "bridge:\(action)@(\(Int(startPoint.x.rounded())),\(Int(startPoint.y.rounded())))"
        }

        if semanticActions.contains(action), let targetNode, targetNode.source == .ax {
            try await axEngine.performAction(
                bundleID: bundleID,
                nodeID: targetNode.rawID,
                action: action,
                text: step.string("text"),
                clear: step.bool("clear") ?? true
            )
            return "ax:\(action)"
        }

        throw AXBridgeError.actionFailed(
            "Action '\(action)' on pid \(pid) requires CoverUseBridge. "
                + "Re-launch via macover_apps(op:'launch', bundleID:'\(bundleID)', bridge:true)."
        )
    }

    // MARK: - 5. macover_wait

    private func handleWaitTool(_ args: [String: MCPJSONValue]) async -> MCPToolCallResult {
        guard let bundleID = args.string("bundleID"),
              let condition = args.string("condition"),
              let app = findApp(bundleID: bundleID) else {
            return .text("Missing or unknown bundleID/condition", isError: true)
        }
        let timeoutMs = max(100, min(60_000, args.int("timeoutMs") ?? 5_000))
        let pollMs = max(100, min(2_000, args.int("pollMs") ?? 250))
        let observe = args.string("observe") ?? "diff"
        let needle = args.string("value") ?? ""
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        let refTargetKey = condition == "refExists"
            ? revisionStore.semanticKey(forScopeRef: needle, bundleID: bundleID)
            : nil

        while true {
            if condition == "networkMatch" {
                let allowSecrets = preferences.allowSensitiveHeaders
                let entries = dependencies?.mitmCoordinator.entries(for: bundleID) ?? []
                let matched = entries.contains { entry in
                    if let host = args.string("host"), !entry.host.localizedCaseInsensitiveContains(host) {
                        return false
                    }
                    if let path = args.string("path") {
                        let visiblePath = visiblePathString(entry.path, allowSensitiveHeaders: allowSecrets)
                        if !visiblePath.localizedCaseInsensitiveContains(path) {
                            return false
                        }
                    }
                    if let status = args.int("status"), entry.statusCode != status {
                        return false
                    }
                    if !needle.isEmpty {
                        let visibleURL = HeaderRedactor.redactURL(
                            entry.urlString,
                            allowSensitiveHeaders: allowSecrets
                        )
                        if !visibleURL.localizedCaseInsensitiveContains(needle) {
                            return false
                        }
                    }
                    return true
                }
                if matched {
                    return .text("wait satisfied: networkMatch")
                }
            } else if condition == "appReady" {
                if let pid = resolvedPID(for: app), pid > 0 {
                    if refreshAXTrustStatus() || bridgeHub.sessionInfo(for: bundleID) != nil {
                        return .text("wait satisfied: appReady pid=\(pid)")
                    }
                }
            } else if let pid = resolvedPID(for: app), pid > 0,
                      let raw = try? await captureRawTree(bundleID: bundleID, pid: pid, sourceArg: nil) {
                // Compact transiently for polling without overwriting revisionStore ref history (H-15).
                let polled = AXTreeCompactor.compact(
                    snapshot: raw,
                    query: UISnapshotQuery(interactiveOnly: false),
                    revision: 0
                )
                let bodyText = polled.text
                let satisfied: Bool
                switch condition {
                case "textAppears":
                    satisfied = !needle.isEmpty && bodyText.localizedCaseInsensitiveContains(needle)
                case "textDisappears":
                    satisfied = !needle.isEmpty && !bodyText.localizedCaseInsensitiveContains(needle)
                case "refExists":
                    if let refTargetKey {
                        satisfied = polled.nodes.contains(where: { $0.semanticKey == refTargetKey })
                    } else {
                        satisfied = !needle.isEmpty && polled.nodes.contains(where: {
                            $0.ref == needle || $0.identifier == needle
                        })
                    }
                default:
                    satisfied = false
                }
                if satisfied {
                    if observe == "none" {
                        return .text("wait satisfied: \(condition)")
                    }
                    let recorded = revisionStore.record(rawSnapshot: raw, query: UISnapshotQuery())
                    if observe == "snapshot" {
                        return .text(recorded.current.text)
                    }
                    if observe == "diff", let prev = recorded.previous {
                        return .text(UITreeRevisionStore.formatDiff(from: prev, to: recorded.current))
                    }
                    return .text("wait satisfied: \(condition)")
                }
            }

            if Date() >= deadline {
                return .text("Timed out after \(timeoutMs)ms waiting for \(condition)", isError: true)
            }
            try? await Task.sleep(nanoseconds: UInt64(pollMs) * 1_000_000)
        }
    }

    // MARK: - 6. macover_screenshot

    private func handleScreenshotTool(_ args: [String: MCPJSONValue]) async -> MCPToolCallResult {
        guard let bundleID = args.string("bundleID"),
              let app = findApp(bundleID: bundleID) else {
            return .text("Unknown bundleID", isError: true)
        }
        guard let pid = resolvedPID(for: app), pid > 0 else {
            return .text("App '\(bundleID)' is not running", isError: true)
        }

        let latestSnap = revisionStore.latestSnapshot(for: bundleID)
        let format = (args.string("format") ?? "jpeg").lowercased()
        let maxDim = max(128, min(2048, args.int("maxDim") ?? 768))
        let quality = args.double("quality") ?? 0.65
        let overlayNodes = (args.bool("overlayRefs") == true) ? (latestSnap?.nodes ?? []) : []

        var resolvedClipRect: UITreeRect?
        if let clipRef = args.string("clipRef") {
            switch revisionStore.resolveRef(
                bundleID: bundleID,
                ref: clipRef,
                expectedRevision: args.int("rev")
            ) {
            case .found(let node):
                resolvedClipRect = node.frame
            case .stale(let message, _):
                return .text("\(message) for clipRef", isError: true)
            }
        } else if let rawClipNorm = args["clipNorm"] {
            guard let clipNorm = rawClipNorm.objectValue,
                  let nx = clipNorm.double("x"),
                  let ny = clipNorm.double("y"),
                  let nw = clipNorm.double("w"),
                  let nh = clipNorm.double("h") else {
                return .text("Invalid clipNorm: expected object with numeric x, y, w, h in 0...1", isError: true)
            }
            let viewport = resolvedViewport(for: app, bridgeSession: bridgeHub.sessionInfo(for: bundleID))
            do {
                resolvedClipRect = try CoordinateMapper.normalizedRectToLogical(
                    nx: nx, ny: ny, nw: nw, nh: nh,
                    viewport: viewport
                )
            } catch {
                return .text(error.localizedDescription, isError: true)
            }
        }

        let requestedSource = args.string("source") ?? "auto"
        if requestedSource != "window", bridgeHub.sessionInfo(for: bundleID) != nil, overlayNodes.isEmpty {
            var bridgeParams: [String: MCPJSONValue] = [
                "maxDim": .int(maxDim),
                "format": .string(format),
                "quality": .double(quality)
            ]
            if let resolvedClipRect {
                bridgeParams["clipRect"] = .object([
                    "x": .double(resolvedClipRect.x),
                    "y": .double(resolvedClipRect.y),
                    "w": .double(resolvedClipRect.width),
                    "h": .double(resolvedClipRect.height)
                ])
            }
            do {
                let resp = try await bridgeHub.sendRequestAsync(
                    bundleID: bundleID,
                    method: "screenshot",
                    params: bridgeParams
                )
                if let obj = resp.objectValue,
                   let b64 = obj.string("data"),
                   let mime = obj.string("mimeType") {
                    let meta = "screenshot src=bridge size=\(obj.int("width") ?? 0)x\(obj.int("height") ?? 0)"
                    return MCPToolCallResult(content: [.text(meta), .image(data: b64, mimeType: mime)])
                }
                if requestedSource == "bridge" {
                    return .text("CoverUseBridge returned malformed screenshot response", isError: true)
                }
            } catch {
                if requestedSource == "bridge" {
                    return .text(error.localizedDescription, isError: true)
                }
            }
        }

        do {
            let options = ScreenshotCaptureOptions(
                clipRect: resolvedClipRect,
                maxDim: maxDim,
                format: format,
                quality: quality,
                overlayNodes: overlayNodes
            )
            let shot = try await axEngine.captureWindowScreenshot(pid: pid, options: options)
            let meta = "screenshot src=window px=\(shot.pixelWidth)x\(shot.pixelHeight)"
            return MCPToolCallResult(content: [
                .text(meta),
                .image(data: shot.base64Data, mimeType: shot.mimeType)
            ])
        } catch {
            return .text(error.localizedDescription, isError: true)
        }
    }

    // MARK: - 7. macover_network

    private func handleNetworkTool(_ args: [String: MCPJSONValue]) -> MCPToolCallResult {
        guard let bundleID = args.string("bundleID"),
              let op = args.string("op"),
              let mitm = dependencies?.mitmCoordinator else {
            return .text("Missing bundleID, op, or MITM coordinator", isError: true)
        }

        let allowSecrets = preferences.allowSensitiveHeaders
        switch op {
        case "clear":
            mitm.clearCaptures(for: bundleID)
            return .text("Cleared MITM captures for \(bundleID)")

        case "list":
            let limit = max(1, min(200, args.int("limit") ?? 40))
            let filtered = mitm.entries(for: bundleID).filter { entry in
                if let host = args.string("host"), !entry.host.localizedCaseInsensitiveContains(host) {
                    return false
                }
                if let path = args.string("path") {
                    let visiblePath = visiblePathString(entry.path, allowSensitiveHeaders: allowSecrets)
                    if !visiblePath.localizedCaseInsensitiveContains(path) {
                        return false
                    }
                }
                if let method = args.string("method"), entry.method.caseInsensitiveCompare(method) != .orderedSame {
                    return false
                }
                if let status = args.int("status"), entry.statusCode != status {
                    return false
                }
                if let disp = args.string("disposition"), entry.disposition.rawValue != disp {
                    return false
                }
                return true
            }
            let recent = filtered.suffix(limit)
            var lines = ["# total=\(filtered.count) shown=\(recent.count)"]
            lines.append("# id\tmethod\tstatus\tdurationMs\tdisp\turl")
            for entry in recent {
                let code = entry.statusCode.map(String.init) ?? "-"
                let ms = Int(entry.durationMs.rounded())
                let disp = entry.disposition.rawValue
                let safeURL = HeaderRedactor.redactURL(entry.urlString, allowSensitiveHeaders: allowSecrets)
                let row = [
                    entry.id.uuidString, entry.method, code, String(ms), disp, safeURL
                ].joined(separator: "\t")
                lines.append(row)
            }
            return .text(lines.joined(separator: "\n"))

        case "detail":
            guard let idStr = args.string("id"),
                  let targetID = UUID(uuidString: idStr),
                  let entry = mitm.entries(for: bundleID).first(where: { $0.id == targetID }) else {
                return .text("MITM entry not found for id: \(args.string("id") ?? "")", isError: true)
            }
            let reqHeaders = HeaderRedactor.redact(headers: entry.requestHeaders, allowSensitiveHeaders: allowSecrets)
            let respHeaders = HeaderRedactor.redact(headers: entry.responseHeaders, allowSensitiveHeaders: allowSecrets)
            let safeURL = HeaderRedactor.redactURL(entry.urlString, allowSensitiveHeaders: allowSecrets)
            let maxBytes = args.int("maxBodyBytes") ?? BodyExtractor.defaultMaxBodyBytes
            let jsonPath = args.string("jsonPath")
            let grep = args.string("grep")
            let reqBody = BodyExtractor.extract(
                rawData: entry.requestBody,
                headers: entry.requestHeaders,
                maxBodyBytes: maxBytes,
                jsonPath: jsonPath,
                grep: grep,
                redactSensitive: !allowSecrets
            )
            let respBody = BodyExtractor.extract(
                rawData: entry.responseBody,
                headers: entry.responseHeaders,
                maxBodyBytes: maxBytes,
                jsonPath: jsonPath,
                grep: grep,
                redactSensitive: !allowSecrets
            )
            return .json(.object([
                "id": .string(entry.id.uuidString),
                "method": .string(entry.method),
                "url": .string(safeURL),
                "status": entry.statusCode.map { .int($0) } ?? .null,
                "disposition": .string(entry.disposition.rawValue),
                "durationMs": .double(entry.durationMs),
                "sensitiveRedacted": .bool(!allowSecrets),
                "requestHeaders": .object(reqHeaders.mapValues { .string($0) }),
                "responseHeaders": .object(respHeaders.mapValues { .string($0) }),
                "requestBody": reqBody.map { .string($0.text) } ?? .null,
                "responseBody": respBody.map { .string($0.text) } ?? .null,
                "error": entry.errorDescription.map { .string($0) } ?? .null
            ]))

        default:
            return .text("Unsupported op '\(op)'", isError: true)
        }
    }

    // MARK: - 8. macover_network_rules

    private func handleNetworkRulesTool(_ args: [String: MCPJSONValue]) async -> MCPToolCallResult {
        guard let bundleID = args.string("bundleID"),
              let op = args.string("op"),
              let app = findApp(bundleID: bundleID) else {
            return .text("Unknown bundleID or op", isError: true)
        }

        if op == "get" {
            let s = app.settings.settings
            return .json(.object([
                "bundleID": .string(bundleID),
                "enableNetworkRules": .bool(s.enableNetworkRules),
                "networkBlockMock200": .bool(s.networkBlockMock200),
                "networkProxyMode": .string(s.networkProxyMode),
                "mitmAllHosts": .bool(s.mitmAllHosts),
                "mitmHostPatterns": .array(s.mitmHostPatterns.map { .string($0) }),
                "blockedURLPatterns": .array(s.blockedURLPatterns.map { .string($0) }),
                "restartRequiredChanges": .array(app.restartRequiredChanges.map { .string($0.rawValue) })
            ]))
        }

        guard op == "add" || op == "remove" || op == "set" else {
            return .text("Unsupported op '\(op)'", isError: true)
        }

        let patterns = args.stringArray("patterns") ?? []
        app.settings.update { s in
            if let enable = args.bool("enableNetworkRules") { s.enableNetworkRules = enable }
            if let mock200 = args.bool("networkBlockMock200") { s.networkBlockMock200 = mock200 }
            if let mitmAll = args.bool("mitmAllHosts") { s.mitmAllHosts = mitmAll }
            if let hosts = args.stringArray("mitmHostPatterns") { s.mitmHostPatterns = hosts }
            switch op {
            case "add":
                for p in patterns where !s.blockedURLPatterns.contains(p) {
                    s.blockedURLPatterns.append(p)
                }
            case "remove":
                let removeSet = Set(patterns)
                s.blockedURLPatterns.removeAll { removeSet.contains($0) }
            case "set":
                s.blockedURLPatterns = patterns
            default:
                break
            }
        }
        _ = app.settings.flush()
        let snapshot = app.settings.settings
        if let mitm = dependencies?.mitmCoordinator {
            await mitm.updateLiveConfiguration(for: bundleID, settings: snapshot)
        }
        return .json(.object([
            "bundleID": .string(bundleID),
            "enableNetworkRules": .bool(snapshot.enableNetworkRules),
            "networkBlockMock200": .bool(snapshot.networkBlockMock200),
            "mitmAllHosts": .bool(snapshot.mitmAllHosts),
            "mitmHostPatterns": .array(snapshot.mitmHostPatterns.map { .string($0) }),
            "blockedURLPatterns": .array(snapshot.blockedURLPatterns.map { .string($0) }),
            "restartRequiredChanges": .array(app.restartRequiredChanges.map { .string($0.rawValue) })
        ]))
    }

    // MARK: - 9. macover_diagnostics

    private func handleDiagnosticsTool(_ args: [String: MCPJSONValue]) async -> MCPToolCallResult {
        guard let bundleID = args.string("bundleID"),
              let app = findApp(bundleID: bundleID) else {
            return .text("Unknown bundleID", isError: true)
        }
        let requested = Set(args.stringArray("sections") ?? ["runtime", "safemode"])
        var payload: [String: MCPJSONValue] = ["bundleID": .string(bundleID)]

        if requested.contains("runtime") {
            let pid = resolvedPID(for: app) ?? 0
            payload["runtime"] = .object([
                "pid": .int(Int(pid)),
                "running": .bool(pid > 0),
                "axReady": .bool(refreshAXTrustStatus(prompt: false)),
                "bridgeReady": .bool(bridgeHub.sessionInfo(for: bundleID) != nil),
                "mitmPort": .int(Int(dependencies?.mitmCoordinator.activePorts[bundleID] ?? 0)),
                "restartRequiredChanges": .array(app.restartRequiredChanges.map { .string($0.rawValue) })
            ])
        }

        if requested.contains("macho") {
            let execURL = app.executable
            let ptPath = PlayTools.playToolsPath.path
            let machoInfo: MCPJSONValue = await withCheckedContinuation { continuation in
                diagnosticsQueue.async {
                    let inspection = try? Macho.inspectBinary(atURL: execURL, playToolsPath: ptPath)
                    let plugins = PlayTools.userDylibs(bundleIdentifier: bundleID).map {
                        MCPJSONValue.string($0.lastPathComponent)
                    }
                    continuation.resume(returning: .object([
                        "executable": .string(execURL.path),
                        "hasPlayTools": .bool(inspection?.hasPlayTools ?? false),
                        "isCatalyst": .bool(inspection?.isCatalyst ?? false),
                        "userPlugins": .array(plugins)
                    ]))
                }
            }
            payload["macho"] = machoInfo
        }

        if requested.contains("safemode") {
            let breadcrumb = app.container.containerUrl
                .appendingPathComponent("Data/Library/Caches/app.makedie.PlayTools/.launching_in_progress")
            payload["safemode"] = .object([
                "breadcrumbPresent": .bool(FileManager.default.fileExists(atPath: breadcrumb.path)),
                "breadcrumbPath": .string(breadcrumb.path)
            ])
        }

        if requested.contains("logs") {
            let lineBudget = max(10, min(400, args.int("logLines") ?? 80))
            let filteredLogs = MCPDiagnosticsFilter.filterScopedLogLines(
                rawLog: dependencies?.log.logdata ?? "",
                bundleID: bundleID,
                appName: app.name,
                appBundleFilename: app.url.lastPathComponent,
                userFilter: args.string("logFilter"),
                limit: lineBudget
            )
            payload["logs"] = .array(filteredLogs.map { .string($0) })
        }

        if requested.contains("crash") {
            let execName = app.info.executableName
            let reports: [MCPJSONValue] = await withCheckedContinuation { continuation in
                diagnosticsQueue.async {
                    let crashDir = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
                    let matchingReports = (try? FileManager.default.contentsOfDirectory(
                        at: crashDir,
                        includingPropertiesForKeys: [.contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    ))?.filter {
                        MCPDiagnosticsFilter.matchesCrashReport(
                            fileURL: $0,
                            executableName: execName,
                            bundleID: bundleID
                        )
                    } ?? []
                    let sorted: [MCPJSONValue] = matchingReports
                        .sorted { $0.lastPathComponent > $1.lastPathComponent }
                        .prefix(5)
                        .map { .string($0.path) }
                    continuation.resume(returning: sorted)
                }
            }
            payload["crash"] = .array(reports)
        }

        return .json(.object(payload))
    }

    // MARK: - 10. macover_keymap

    private func handleKeymapTool(_ args: [String: MCPJSONValue]) -> MCPToolCallResult {
        guard let bundleID = args.string("bundleID"),
              let op = args.string("op"),
              let app = findApp(bundleID: bundleID) else {
            return .text("Unknown bundleID or op", isError: true)
        }

        let name = args.string("name") ?? "default"
        if op != "list" {
            guard MCPKeymapNameValidator.isValidName(name),
                  MCPKeymapNameValidator.resolvedPlistURL(
                      name: name,
                      in: app.keymapping.baseKeymapURL,
                      keymappingRoot: Keymapping.keymappingDir
                  ) != nil else {
                return .text("Invalid keymap name or unsafe keymap directory '\(name)'", isError: true)
            }
        }

        switch op {
        case "list":
            let names = app.keymapping.listKeymapNames()
            return .json(.object([
                "bundleID": .string(bundleID),
                "defaultName": .string(app.keymapping.keymapConfig.defaultKm.deletingPathExtension().lastPathComponent),
                "keymaps": .array(names.map { .string($0) })
            ]))

        case "get":
            do {
                let km = try app.keymapping.readKeymap(name: name)
                let data = try JSONEncoder().encode(km)
                let value = try JSONDecoder().decode(MCPJSONValue.self, from: data)
                return .json(.object(["name": .string(name), "keymap": value]))
            } catch {
                return .text("Failed to read keymap '\(name)': \(error.localizedDescription)", isError: true)
            }

        case "validate", "put":
            guard let kmObj = args["keymap"] else {
                return .text("Missing 'keymap' object", isError: true)
            }
            do {
                let data = try JSONEncoder().encode(kmObj)
                var km = try JSONDecoder().decode(Keymap.self, from: data)
                km.bundleIdentifier = bundleID
                let issues = validateKeymapCoordinates(km)
                if !issues.isEmpty {
                    return .json(.object([
                        "valid": .bool(false),
                        "issues": .array(issues.map { .string($0) })
                    ]), isError: op == "put")
                }
                if op == "put" {
                    try app.keymapping.saveKeymapValidated(name: name, map: km)
                }
                return .json(.object([
                    "valid": .bool(true),
                    "saved": .bool(op == "put"),
                    "name": .string(name)
                ]))
            } catch {
                return .text("Invalid keymap JSON: \(error.localizedDescription)", isError: true)
            }

        default:
            return .text("Unsupported op '\(op)'", isError: true)
        }
    }

    // MARK: - Helpers

    private func captureRawTree(
        bundleID: String,
        pid: pid_t,
        sourceArg: String?
    ) async throws -> RawUITreeSnapshot {
        let preferred = sourceArg ?? "auto"
        let hasBridge = bridgeHub.sessionInfo(for: bundleID) != nil
        let axReady = refreshAXTrustStatus(prompt: false)

        if preferred == "bridge" || (preferred == "auto" && !axReady && hasBridge) {
            let result = try await bridgeHub.sendRequestAsync(bundleID: bundleID, method: "get_ui_tree")
            let data = try JSONEncoder().encode(result)
            let snap = try JSONDecoder().decode(RawUITreeSnapshot.self, from: data)
            bridgeHub.updateViewport(for: bundleID, width: snap.width, height: snap.height, isLive: true)
            return snap
        }

        if preferred == "ax" || axReady {
            do {
                return try await axEngine.captureTree(pid: pid, bundleID: bundleID)
            } catch {
                if preferred == "auto" && hasBridge {
                    let result = try await bridgeHub.sendRequestAsync(bundleID: bundleID, method: "get_ui_tree")
                    let data = try JSONEncoder().encode(result)
                    let snap = try JSONDecoder().decode(RawUITreeSnapshot.self, from: data)
                    bridgeHub.updateViewport(for: bundleID, width: snap.width, height: snap.height, isLive: true)
                    return snap
                }
                throw error
            }
        }

        throw AXBridgeError.permissionDenied
    }

    private func resolvedViewport(
        for app: PlayApp,
        bridgeSession: MCPBridgeHub.SessionInfo?
    ) -> LogicalViewport {
        if let bridgeSession,
           bridgeSession.hasLiveViewport,
           bridgeSession.logicalWidth > 0,
           bridgeSession.logicalHeight > 0 {
            return LogicalViewport(width: bridgeSession.logicalWidth, height: bridgeSession.logicalHeight)
        }
        if let latest = revisionStore.latestSnapshot(for: app.info.bundleIdentifier),
           latest.width > 0, latest.height > 0 {
            return LogicalViewport(width: latest.width, height: latest.height)
        }
        if let bridgeSession,
           bridgeSession.logicalWidth > 0,
           bridgeSession.logicalHeight > 0 {
            return LogicalViewport(width: bridgeSession.logicalWidth, height: bridgeSession.logicalHeight)
        }
        let configuredW = Double(app.settings.settings.effectiveWindowWidth)
        let configuredH = Double(app.settings.settings.effectiveWindowHeight)
        if configuredW > 0, configuredH > 0 {
            return LogicalViewport(width: configuredW, height: configuredH)
        }
        return LogicalViewport(width: 1280, height: 800)
    }

    private func normalizePatchedDisplaySettings(
        _ updated: inout AppSettingsData,
        patch: [String: MCPJSONValue]
    ) {
        let touchedResolution = patch["resolution"] != nil || patch["aspectRatio"] != nil
        let touchedCustomDims = patch["windowWidth"] != nil || patch["windowHeight"] != nil
        if touchedResolution && !(updated.resolution == 5 && touchedCustomDims) {
            let dims = AppSettingsData.computedDimensions(
                resolution: updated.resolution,
                aspectRatio: updated.aspectRatio,
                customWidth: updated.windowWidth,
                customHeight: updated.windowHeight
            )
            updated.windowWidth = dims.width
            updated.windowHeight = dims.height
        }
        if patch["resizableAspectRatioType"] != nil {
            switch updated.resizableAspectRatioType {
            case 0:
                updated.resizableAspectRatioWidth = 0
                updated.resizableAspectRatioHeight = 0
            case 1:
                updated.resizableAspectRatioWidth = max(1, updated.resizableAspectRatioWidth)
                updated.resizableAspectRatioHeight = max(1, updated.resizableAspectRatioHeight)
            case 2:
                updated.resizableAspectRatioWidth = 4
                updated.resizableAspectRatioHeight = 3
            case 3:
                updated.resizableAspectRatioWidth = 16
                updated.resizableAspectRatioHeight = 9
            case 4:
                updated.resizableAspectRatioWidth = 16
                updated.resizableAspectRatioHeight = 10
            default:
                updated.resizableAspectRatioWidth = 16
                updated.resizableAspectRatioHeight = 9
            }
        }
    }

    private func visiblePathString(_ rawPath: String, allowSensitiveHeaders: Bool) -> String {
        guard !allowSensitiveHeaders, let qIdx = rawPath.firstIndex(of: "?") else {
            return rawPath
        }
        let pathPart = String(rawPath[..<qIdx])
        let queryPart = String(rawPath[rawPath.index(after: qIdx)...])
        return "\(pathPart)?\(HeaderRedactor.redactKeyValueDelimitedString(queryPart, separator: "&"))"
    }

    private func cacheExpectedExecutablePaths() {
        guard let apps = dependencies?.appsVM.apps else { return }
        var map: [String: String] = [:]
        map.reserveCapacity(apps.count)
        for app in apps where !app.info.bundleIdentifier.isEmpty {
            map[app.info.bundleIdentifier] = app.executable.resolvingSymlinksInPath().path
        }
        expectedExecutablePaths.withLock { $0 = map }
    }

    private func findApp(bundleID: String) -> PlayApp? {
        cacheExpectedExecutablePaths()
        return dependencies?.appsVM.apps.first(where: { $0.info.bundleIdentifier == bundleID })
    }

    private func resolvedRunningApp(for app: PlayApp) -> NSRunningApplication? {
        if let snap = app.snapshotRunningApplication(), !snap.isTerminated {
            return snap
        }
        return NSRunningApplication.runningApplications(withBundleIdentifier: app.info.bundleIdentifier)
            .first(where: { !$0.isTerminated })
    }

    private func resolvedPID(for app: PlayApp) -> pid_t? {
        guard let running = resolvedRunningApp(for: app), !running.isTerminated else {
            return nil
        }
        return running.processIdentifier
    }

    private func encodeSettingsDict(_ settings: AppSettingsData) -> [String: MCPJSONValue]? {
        guard let data = try? JSONEncoder().encode(settings),
              let val = try? JSONDecoder().decode(MCPJSONValue.self, from: data) else {
            return nil
        }
        return val.objectValue
    }

    private func validateKeymapCoordinates(_ keymap: Keymap) -> [String] {
        var issues: [String] = []
        func check(_ label: String, transform: KeyModelTransform) {
            if !(0...100).contains(transform.xCoord) || !(0...100).contains(transform.yCoord) {
                issues.append("\(label): xCoord/yCoord (\(transform.xCoord), \(transform.yCoord)) outside 0...100")
            }
            if transform.size <= 0 || transform.size > 100 {
                issues.append("\(label): size \(transform.size) outside 1...100")
            }
        }
        for (idx, item) in keymap.buttonModels.enumerated() {
            check("buttonModels[\(idx)]", transform: item.transform)
        }
        for (idx, item) in keymap.draggableButtonModels.enumerated() {
            check("draggableButtonModels[\(idx)]", transform: item.transform)
        }
        for (idx, item) in keymap.joystickModel.enumerated() {
            check("joystickModel[\(idx)]", transform: item.transform)
        }
        for (idx, item) in keymap.mouseAreaModel.enumerated() {
            check("mouseAreaModel[\(idx)]", transform: item.transform)
        }
        return issues
    }
}
