import Compression
import Darwin
import Foundation
import PlayCoverCore
import PlayCoverMachO

public enum MCPCLIError: LocalizedError, Equatable, Sendable {
    case zipArchiveError(String)
    case invalidDestination(String)

    public var errorDescription: String? {
        switch self {
        case .zipArchiveError(let detail):
            return "ZIP archive error: \(detail)"
        case .invalidDestination(let detail):
            return "Invalid destination path: \(detail)"
        }
    }
}

public struct MCPCLIServerConfig: Sendable {
    public static let defaultRequestTimeoutSeconds: Double = 65.0

    public let sessionURL: URL
    public let applicationsDirectory: URL
    public let requestTimeoutSeconds: Double

    public init(
        sessionURL: URL = MCPDaemonSessionFile.defaultURL(),
        applicationsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/app.makedie.MacOver/Applications", isDirectory: true),
        requestTimeoutSeconds: Double = defaultRequestTimeoutSeconds
    ) {
        self.sessionURL = sessionURL
        self.applicationsDirectory = applicationsDirectory
        self.requestTimeoutSeconds = max(Self.defaultRequestTimeoutSeconds, requestTimeoutSeconds)
    }
}

public enum MCPSettingsPatchPolicy {
    public static let immutableKeys: Set<String> = [
        "bundleIdentifier",
        "mitmRuntimePort",
        "storedHasIntrospection",
        "storedHasIosFrameworks",
        "originalBundleName",
        "originalMinimumOSVersion",
        "version"
    ]

    public static let blockedSecurityKeys: Set<String> = [
        "externalProxyHost",
        "externalProxyPort",
        "externalProxyProtocol",
        "mitmAllowPinningBypass",
        "playChainDebugging"
    ]

    public static let allowedProxyModes: Set<String> = [
        "direct",
        "builtInMITM"
    ]

    public static func validate(
        patch: [String: MCPJSONValue],
        knownKeys: Set<String>
    ) -> String? {
        for (key, value) in patch {
            if immutableKeys.contains(key) {
                return "Setting '\(key)' is immutable via MCP."
            }
            if blockedSecurityKeys.contains(key) {
                return "Setting '\(key)' is security-restricted and cannot be modified via MCP."
            }
            if !knownKeys.contains(key) {
                return "Unknown setting key '\(key)'."
            }
            if key == "networkProxyMode" {
                guard let mode = value.stringValue, allowedProxyModes.contains(mode) else {
                    return "Setting 'networkProxyMode' only permits 'direct' or 'builtInMITM' via MCP."
                }
            }
        }
        return nil
    }
}

public enum MCPKeymapNameValidator {
    public static func isValidName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == name, name.count <= 128 else {
            return false
        }
        if name.hasPrefix(".") || name.contains("..") {
            return false
        }
        if name.contains("/") || name.contains("\\") || name.contains(":") {
            return false
        }
        for scalar in name.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
            return false
        }
        return true
    }

    public static func resolvedPlistURL(
        name: String,
        in baseDirectory: URL,
        keymappingRoot: URL? = nil
    ) -> URL? {
        guard isValidName(name) else { return nil }

        // Open baseDirectory with O_DIRECTORY | O_NOFOLLOW so baseDirectory itself cannot be a symlink.
        let baseFD = Darwin.open(baseDirectory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard baseFD >= 0 else {
            return nil
        }
        defer { Darwin.close(baseFD) }

        var baseStat = stat()
        guard Darwin.fstat(baseFD, &baseStat) == 0,
              (baseStat.st_mode & S_IFMT) == S_IFDIR,
              baseStat.st_uid == getuid() else {
            return nil
        }

        if let keymappingRoot {
            let rootFD = Darwin.open(keymappingRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard rootFD >= 0 else {
                return nil
            }
            defer { Darwin.close(rootFD) }

            var rootStat = stat()
            guard Darwin.fstat(rootFD, &rootStat) == 0,
                  (rootStat.st_mode & S_IFMT) == S_IFDIR,
                  rootStat.st_uid == getuid() else {
                return nil
            }

            let canonicalRoot = keymappingRoot.resolvingSymlinksInPath().standardizedFileURL
            let canonicalBase = baseDirectory.resolvingSymlinksInPath().standardizedFileURL
            let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
            guard canonicalBase.path.hasPrefix(rootPrefix),
                  canonicalBase.path != canonicalRoot.path else {
                return nil
            }

            // Verify every component between canonicalRoot and baseDirectory has no symlinks.
            let relativePart = String(canonicalBase.path.dropFirst(rootPrefix.count))
            let components = relativePart.split(separator: "/").map(String.init)
            guard !components.isEmpty else { return nil }
            var cursorFD = rootFD
            var ownedFDs: [Int32] = []
            defer {
                for fd in ownedFDs {
                    Darwin.close(fd)
                }
            }
            for comp in components {
                guard !comp.isEmpty, comp != ".", comp != ".." else { return nil }
                let nextFD = Darwin.openat(cursorFD, comp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard nextFD >= 0 else { return nil }
                ownedFDs.append(nextFD)
                var compStat = stat()
                guard Darwin.fstat(nextFD, &compStat) == 0,
                      (compStat.st_mode & S_IFMT) == S_IFDIR,
                      compStat.st_uid == getuid() else {
                    return nil
                }
                cursorFD = nextFD
            }
        }

        let filename = "\(name).plist"
        var fileStat = stat()
        if Darwin.fstatat(baseFD, filename, &fileStat, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (fileStat.st_mode & S_IFMT) == S_IFREG,
                  fileStat.st_uid == getuid() else {
                return nil
            }
        }

        let canonicalBase = baseDirectory.resolvingSymlinksInPath().standardizedFileURL
        let candidate = canonicalBase.appendingPathComponent(filename)
        guard candidate.standardizedFileURL.deletingLastPathComponent() == canonicalBase else {
            return nil
        }
        return candidate
    }
}

public enum MCPDiagnosticsFilter {
    private static let redactedLogSubstrings: [String] = [
        "macover_automation_token",
        "authorization:",
        "proxy-authorization:",
        "set-cookie:",
        "cookie:",
        "<key>com.apple.",
        "com.apple.security.",
        "entitlements"
    ]

    public static func filterScopedLogLines(
        rawLog: String,
        bundleID: String,
        appName: String,
        appBundleFilename: String? = nil,
        userFilter: String? = nil,
        limit: Int = 80
    ) -> [String] {
        let budget = max(10, min(400, limit))
        let scopeNeedles = [bundleID, appName, appBundleFilename ?? ""]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { $0.count >= 3 }
        guard !scopeNeedles.isEmpty else { return [] }

        let customFilter = userFilter?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lines = rawLog.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let matched = lines.filter { line in
            let lower = line.lowercased()
            if redactedLogSubstrings.contains(where: { lower.contains($0) }) {
                return false
            }
            guard scopeNeedles.contains(where: { lower.contains($0) }) else {
                return false
            }
            if let customFilter, !customFilter.isEmpty {
                return lower.contains(customFilter)
            }
            return true
        }
        return Array(matched.suffix(budget))
    }

    public static func matchesCrashReport(
        fileURL: URL,
        executableName: String,
        bundleID: String
    ) -> Bool {
        guard !executableName.isEmpty else { return false }
        let ext = fileURL.pathExtension.lowercased()
        guard ext == "ips" || ext == "crash" || ext == "diag" else {
            return false
        }
        let filename = fileURL.lastPathComponent
        guard filename.hasPrefix("\(executableName)-") || filename.hasPrefix("\(executableName)_") else {
            return false
        }
        if ext == "ips", let headerBundleID = readIPSHeaderBundleID(at: fileURL) {
            return headerBundleID == bundleID
        }
        return true
    }

    private static func readIPSHeaderBundleID(at url: URL) -> String? {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        let n = buf.withUnsafeMutableBytes { rawBuf -> Int in
            guard let base = rawBuf.baseAddress else { return -1 }
            return Darwin.read(fd, base, rawBuf.count)
        }
        guard n > 0 else { return nil }
        let prefixData = Data(buf[0..<n])
        let firstLineData: Data
        if let nl = prefixData.firstIndex(of: 0x0A) {
            firstLineData = Data(prefixData[..<nl])
        } else {
            firstLineData = prefixData
        }
        guard let obj = try? JSONSerialization.jsonObject(with: firstLineData) as? [String: Any] else {
            return nil
        }
        if let bid = obj["bundleID"] as? String, !bid.isEmpty {
            return bid
        }
        if let appName = obj["app_name"] as? String, appName == obj["bundleID"] as? String {
            return appName
        }
        return nil
    }
}

public enum MCPAgentPluginExporter {
    public static func export(
        from sourceDir: URL,
        to destination: URL,
        executablePath: String,
        protectedBundleURL: URL? = Bundle.main.bundleURL
    ) throws {
        let fm = FileManager.default
        let canonicalSource = canonicalPathForContainment(sourceDir)
        let canonicalDest = canonicalPathForContainment(destination)

        if isSameOrInside(canonicalDest, parent: canonicalSource)
            || isSameOrInside(canonicalSource, parent: canonicalDest) {
            throw MCPCLIError.invalidDestination(
                "Export destination cannot overlap the built-in plugin source directory."
            )
        }

        if let protectedBundleURL {
            let canonicalBundle = canonicalPathForContainment(protectedBundleURL)
            if isSameOrInside(canonicalDest, parent: canonicalBundle)
                || isSameOrInside(canonicalBundle, parent: canonicalDest) {
                throw MCPCLIError.invalidDestination(
                    "Export destination cannot point inside or overwrite the MacOver application bundle."
                )
            }
        }

        let parentDir = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let stagingRoot = parentDir.appendingPathComponent(
            ".macover-plugin-stage-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        let stagedPlugin = stagingRoot.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try fm.copyItem(at: sourceDir, to: stagedPlugin)

        let configPayload: [String: Any] = [
            "mcpServers": [
                "macover": [
                    "command": executablePath,
                    "args": []
                ]
            ]
        ]
        let configData = try JSONSerialization.data(
            withJSONObject: configPayload,
            options: [.prettyPrinted, .sortedKeys]
        )
        let configURL = stagedPlugin.appendingPathComponent("mcp_config.json")
        try configData.write(to: configURL, options: [.atomic])

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: stagedPlugin)
        } else {
            try fm.moveItem(at: stagedPlugin, to: destination)
        }
    }

    private static func canonicalPathForContainment(_ url: URL) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        // Resolve the nearest existing ancestor so symlinks (e.g. /var -> /private/var) still match.
        var tailComponents: [String] = []
        var cursor = url.standardizedFileURL
        while !fm.fileExists(atPath: cursor.path) {
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path {
                break
            }
            tailComponents.append(cursor.lastPathComponent)
            cursor = parent
        }
        var resolved = cursor.resolvingSymlinksInPath().standardizedFileURL
        for component in tailComponents.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

    private static func isSameOrInside(_ childPath: String, parent parentPath: String) -> Bool {
        let normChild = childPath.count > 1 && childPath.hasSuffix("/") ? String(childPath.dropLast()) : childPath
        let normParent = parentPath.count > 1 && parentPath.hasSuffix("/") ? String(parentPath.dropLast()) : parentPath
        return normChild == normParent || normChild.hasPrefix(normParent + "/")
    }
}

public final class MCPCLIRunner: Sendable {
    private static let inspectionQueue = DispatchQueue(
        label: "app.makedie.MacOver.MCPCLIRunner.inspect",
        qos: .utility,
        attributes: .concurrent
    )

    private let config: MCPCLIServerConfig
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(config: MCPCLIServerConfig = MCPCLIServerConfig()) {
        self.config = config
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
        self.decoder = JSONDecoder()
    }

    public static func run() async {
        let runner = MCPCLIRunner()
        await runner.runStdioLoop(
            input: FileHandle.standardInput,
            output: FileHandle.standardOutput
        )
    }

    public func effectiveRequestTimeoutSeconds(
        for toolName: String,
        arguments: [String: MCPJSONValue]
    ) -> Double {
        var timeout = max(MCPCLIServerConfig.defaultRequestTimeoutSeconds, config.requestTimeoutSeconds)
        if toolName == "macover_wait", let waitMs = arguments.int("timeoutMs") {
            let boundedMs = max(100, min(60_000, waitMs))
            timeout = max(timeout, Double(boundedMs) / 1000.0 + 10.0)
        }
        return timeout
    }

    public func runStdioLoop(input: FileHandle, output: FileHandle) async {
        var buffer = Data()
        var activeMode: MCPFramingMode = .ndjson
        while true {
            do {
                guard let frame = try MCPStdioFramer.readNextFrame(
                    from: input,
                    buffer: &buffer,
                    activeMode: &activeMode
                ) else {
                    return
                }
                if let response = await handleFramePayload(frame.payload) {
                    let data = try encoder.encode(response)
                    let encodedFrame = MCPStdioFramer.encodeFrame(data, mode: frame.mode)
                    try output.write(contentsOf: encodedFrame)
                }
            } catch let rpcError as MCPRPCError {
                let response = MCPRPCResponse(id: nil, error: rpcError)
                if let data = try? encoder.encode(response) {
                    try? output.write(contentsOf: MCPStdioFramer.encodeFrame(data, mode: activeMode))
                }
            } catch {
                fputs("macover-mcp I/O error: \(error.localizedDescription)\n", stderr)
                return
            }
        }
    }

    public func handleFramePayload(_ payload: Data) async -> MCPRPCResponse? {
        let request: MCPRPCRequest
        do {
            request = try decoder.decode(MCPRPCRequest.self, from: payload)
        } catch {
            return MCPRPCResponse(id: nil, error: .parseError(error.localizedDescription))
        }

        // JSON-RPC 2.0 §4.1: notifications (omitted id) MUST NOT receive a response.
        if request.id == nil {
            return nil
        }

        switch request.method {
        case "initialize":
            let requested = request.params?.objectValue?.string("protocolVersion")
            return MCPRPCResponse(id: request.id, result: MCPProtocol.makeInitializeResult(requestedVersion: requested))

        case "ping":
            return MCPRPCResponse(id: request.id, result: .object([:]))

        case "tools/list":
            return MCPRPCResponse(id: request.id, result: MCPToolRegistry.toolsListPayload())

        case "tools/call":
            guard let params = request.params?.objectValue,
                  let name = params.string("name") else {
                return MCPRPCResponse(id: request.id, error: .invalidParams("Missing tool name"))
            }
            let args = params["arguments"]?.objectValue ?? [:]
            let toolResult = await dispatchToolCall(name: name, arguments: args)
            guard let resultData = try? encoder.encode(toolResult),
                  let resultValue = try? decoder.decode(MCPJSONValue.self, from: resultData) else {
                return MCPRPCResponse(id: request.id, error: .internalError("Failed to encode tool result"))
            }
            return MCPRPCResponse(id: request.id, result: resultValue)

        default:
            return MCPRPCResponse(id: request.id, error: .methodNotFound(request.method))
        }
    }

    public func dispatchToolCall(name: String, arguments: [String: MCPJSONValue]) async -> MCPToolCallResult {
        do {
            let session = try MCPDaemonSessionFile.read(from: config.sessionURL)
            if session.isHostProcessAlive {
                do {
                    let timeoutSeconds = effectiveRequestTimeoutSeconds(for: name, arguments: arguments)
                    return try MCPLoopbackClient.call(
                        session: session,
                        toolName: name,
                        arguments: arguments,
                        timeoutSeconds: timeoutSeconds
                    )
                } catch {
                    return handleOfflineOrFallback(
                        name: name,
                        arguments: arguments,
                        hostFailureReason: error.localizedDescription
                    )
                }
            }
        } catch let sessionErr as MCPDaemonSessionFileError {
            if case .insecurePermissions = sessionErr {
                return handleOfflineOrFallback(
                    name: name,
                    arguments: arguments,
                    hostFailureReason: sessionErr.localizedDescription
                )
            }
        } catch {
            // Treat missing/unreadable session file as host offline.
        }
        return handleOfflineOrFallback(name: name, arguments: arguments, hostFailureReason: nil)
    }

    private func handleOfflineOrFallback(
        name: String,
        arguments: [String: MCPJSONValue],
        hostFailureReason: String?
    ) -> MCPToolCallResult {
        if name == "macover_apps" {
            let op = arguments.string("op") ?? ""
            if op == "inspect_ipa", let rawPath = arguments.string("path") {
                return Self.inspectBinaryOrIPA(atPath: rawPath)
            }
            if op == "list" {
                return listOfflineInstalledApps(hostFailureReason: hostFailureReason)
            }
        }

        let detail: String
        if let hostFailureReason {
            detail = "Failed to communicate with MacOver host daemon (\(hostFailureReason)). "
                + "Verify MacOver.app is running and Settings -> MCP is enabled."
        } else {
            detail = "MacOver MCP host daemon is not running or disabled. "
                + "Open MacOver.app and enable Settings -> MCP to use '\(name)'."
        }
        return .text(detail, isError: true)
    }

    private func listOfflineInstalledApps(hostFailureReason: String?) -> MCPToolCallResult {
        let fm = FileManager.default
        let sanitizedFailure = hostFailureReason?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let entries = try? fm.contentsOfDirectory(
            at: config.applicationsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            if let sanitizedFailure {
                return .text(
                    "# hostRunning=error hostFailureReason=\"\(sanitizedFailure)\" apps=0\n"
                        + "Live MacOver host daemon call failed; no offline apps found.",
                    isError: true
                )
            }
            return .text("# hostRunning=false apps=0\nNo installed MacOver apps found.")
        }

        var lines: [String]
        if let sanitizedFailure {
            lines = [
                "# hostRunning=error hostFailureReason=\"\(sanitizedFailure)\" "
                    + "appsDir=\(config.applicationsDirectory.path)"
            ]
        } else {
            lines = ["# hostRunning=false appsDir=\(config.applicationsDirectory.path)"]
        }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where entry.pathExtension == "app" {
            let plistURL = entry.appendingPathComponent("Info.plist")
            guard fm.fileExists(atPath: plistURL.path) else { continue }
            let info = AppInfo(contentsOf: plistURL)
            lines.append("\(info.bundleIdentifier)\t\(info.displayName)\tv\(info.bundleVersion)\tstopped")
        }
        return .text(lines.joined(separator: "\n"), isError: sanitizedFailure != nil)
    }

    public static func inspectBinaryOrIPAAsync(atPath rawPath: String) async -> MCPToolCallResult {
        await withCheckedContinuation { continuation in
            inspectionQueue.async {
                continuation.resume(returning: inspectBinaryOrIPA(atPath: rawPath))
            }
        }
    }

    public static func inspectBinaryOrIPA(atPath rawPath: String) -> MCPToolCallResult {
        let url = URL(fileURLWithPath: rawPath)
        let ext = url.pathExtension.lowercased()
        guard ext == "ipa" || ext == "app" else {
            return .text(
                "Unsupported inspection target '\(url.lastPathComponent)': only .ipa and .app are allowed",
                isError: true
            )
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .text("File not found: \(url.path)", isError: true)
        }

        do {
            if ext == "ipa" {
                return try inspectIPAArchive(at: url)
            }
            return try inspectAppBundle(at: url)
        } catch {
            return .text("Failed to inspect '\(url.path)': \(error.localizedDescription)", isError: true)
        }
    }

    private static func inspectAppBundle(at url: URL) throws -> MCPToolCallResult {
        let canonicalApp = url.resolvingSymlinksInPath()
        let canonicalPrefix = canonicalApp.path.hasSuffix("/") ? canonicalApp.path : canonicalApp.path + "/"

        let plistURL = canonicalApp.appendingPathComponent("Info.plist")
        try verifyContainedRegularFile(plistURL, insidePrefix: canonicalPrefix, label: "Info.plist")
        let info = AppInfo(contentsOf: plistURL)
        let execName = info.executableName
        guard !execName.isEmpty, !execName.contains("/"), !execName.contains("\\"), !execName.contains("..") else {
            return .text("Invalid CFBundleExecutable in Info.plist", isError: true)
        }
        let execURL = canonicalApp.appendingPathComponent(execName)
        try verifyContainedRegularFile(execURL, insidePrefix: canonicalPrefix, label: "executable")

        let inspection = try Macho.inspectBinary(atURL: execURL, playToolsPath: PlayTools.playToolsPath.path)
        let encrypted = (try? Macho.isMachoEncrypted(atURL: execURL)) ?? false
        return .json(.object([
            "path": .string(url.path),
            "bundleID": .string(info.bundleIdentifier),
            "displayName": .string(info.displayName),
            "bundleVersion": .string(info.bundleVersion),
            "minimumOSVersion": .string(info.minimumOSVersion),
            "executable": .string(info.executableName),
            "hasPlayTools": .bool(inspection.hasPlayTools),
            "isCatalyst": .bool(inspection.isCatalyst),
            "isEncrypted": .bool(encrypted)
        ]))
    }

    private static func verifyContainedRegularFile(_ fileURL: URL, insidePrefix: String, label: String) throws {
        var st = stat()
        guard lstat(fileURL.path, &st) == 0 else {
            throw MCPCLIError.zipArchiveError("Missing \(label) at \(fileURL.lastPathComponent)")
        }
        guard (st.st_mode & S_IFMT) == S_IFREG else {
            throw MCPCLIError.zipArchiveError("Unsafe \(label): symlinks and non-regular files are rejected")
        }
        let resolved = fileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(insidePrefix) else {
            throw MCPCLIError.zipArchiveError("Unsafe \(label): resolved path escapes bundle root")
        }
    }

    private static func inspectIPAArchive(at url: URL) throws -> MCPToolCallResult {
        let reader = try SafeZIPArchiveReader(url: url)
        defer { reader.close() }
        let entries = try reader.readCentralDirectory()

        guard let plistEntry = entries.first(where: { entry in
            let parts = entry.name.split(separator: "/", omittingEmptySubsequences: false)
            return parts.count == 3
                && parts[0] == "Payload"
                && parts[1].hasSuffix(".app")
                && parts[2] == "Info.plist"
        }) else {
            return .text("Invalid IPA: missing Payload/*.app/Info.plist", isError: true)
        }

        let appPrefix = String(plistEntry.name.dropLast("Info.plist".count))
        let plistData = try reader.extractEntry(plistEntry, maxBytes: SafeZIPArchiveReader.maxInfoPlistBytes)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("macover-mcp-ipa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: scratch,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: scratch) }

        let tempPlist = scratch.appendingPathComponent("Info.plist")
        try plistData.write(to: tempPlist, options: [.atomic])
        let info = AppInfo(contentsOf: tempPlist)
        let execName = info.executableName
        guard !execName.isEmpty, !execName.contains("/"), !execName.contains("\\"), !execName.contains("..") else {
            return .text("Invalid IPA: unsafe CFBundleExecutable", isError: true)
        }

        let expectedExecEntryName = appPrefix + execName
        guard let execEntry = entries.first(where: { $0.name == expectedExecEntryName }) else {
            return .text("Invalid IPA: missing executable '\(expectedExecEntryName)'", isError: true)
        }
        let execData = try reader.extractEntry(execEntry, maxBytes: SafeZIPArchiveReader.maxExecutableBytes)
        let tempExec = scratch.appendingPathComponent("binary")
        try execData.write(to: tempExec, options: [.atomic])

        let inspection = try Macho.inspectBinary(atURL: tempExec, playToolsPath: PlayTools.playToolsPath.path)
        let encrypted = (try? Macho.isMachoEncrypted(atURL: tempExec)) ?? false
        return .json(.object([
            "path": .string(url.path),
            "bundleID": .string(info.bundleIdentifier),
            "displayName": .string(info.displayName),
            "bundleVersion": .string(info.bundleVersion),
            "minimumOSVersion": .string(info.minimumOSVersion),
            "executable": .string(info.executableName),
            "hasPlayTools": .bool(inspection.hasPlayTools),
            "isCatalyst": .bool(inspection.isCatalyst),
            "isEncrypted": .bool(encrypted)
        ]))
    }
}

final class SafeZIPArchiveReader {
    static let maxEntries = 50_000
    static let maxCentralDirectoryBytes = 64 * 1024 * 1024
    static let maxTotalDeclaredBytes: UInt64 = 4 * 1024 * 1024 * 1024
    static let maxInfoPlistBytes = 2 * 1024 * 1024
    static let maxExecutableBytes = 512 * 1024 * 1024

    struct Entry {
        let name: String
        let compressionMethod: UInt16
        let compressedSize: UInt64
        let uncompressedSize: UInt64
        let localHeaderOffset: UInt64
    }

    private let handle: FileHandle
    private let fileSize: UInt64
    private var isClosed = false

    init(url: URL) throws {
        let fh = try FileHandle(forReadingFrom: url)
        do {
            self.fileSize = try fh.seekToEnd()
            self.handle = fh
        } catch {
            try? fh.close()
            throw error
        }
    }

    deinit {
        close()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }

    func readCentralDirectory() throws -> [Entry] {
        guard fileSize >= 22 else {
            throw zipError("Archive too small to be a valid ZIP/IPA")
        }
        let searchWindow = min(fileSize, 65_557)
        let searchStart = fileSize - searchWindow
        try handle.seek(toOffset: searchStart)
        let tail = try handle.read(upToCount: Int(searchWindow)) ?? Data()

        guard let eocdRel = findEOCDOffset(in: tail) else {
            throw zipError("Missing ZIP End of Central Directory record")
        }
        let (eocdAbs, eocdOv) = searchStart.addingReportingOverflow(UInt64(eocdRel))
        guard !eocdOv, eocdAbs <= fileSize else {
            throw zipError("EOCD offset overflow")
        }
        var totalEntries = UInt64(readUInt16(tail, at: eocdRel + 10))
        var cdSize = UInt64(readUInt32(tail, at: eocdRel + 12))
        var cdOffset = UInt64(readUInt32(tail, at: eocdRel + 16))

        if totalEntries == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            guard eocdAbs >= 20 else {
                throw zipError("Invalid ZIP64 locator offset")
            }
            try handle.seek(toOffset: eocdAbs - 20)
            let loc = try handle.read(upToCount: 20) ?? Data()
            guard loc.count == 20, readUInt32(loc, at: 0) == 0x0706_4B50 else {
                throw zipError("Missing ZIP64 End of Central Directory locator")
            }
            let z64Offset = readUInt64(loc, at: 8)
            let (z64End, z64Ov) = z64Offset.addingReportingOverflow(56)
            guard !z64Ov, z64End <= fileSize else {
                throw zipError("ZIP64 EOCD offset out of bounds")
            }
            try handle.seek(toOffset: z64Offset)
            let z64 = try handle.read(upToCount: 56) ?? Data()
            guard z64.count == 56, readUInt32(z64, at: 0) == 0x0606_4B50 else {
                throw zipError("Invalid ZIP64 EOCD signature")
            }
            totalEntries = readUInt64(z64, at: 32)
            cdSize = readUInt64(z64, at: 40)
            cdOffset = readUInt64(z64, at: 48)
        }

        guard totalEntries <= UInt64(Self.maxEntries) else {
            throw zipError("IPA entry count (\(totalEntries)) exceeds safety limit")
        }
        let (cdEnd, cdOv) = cdOffset.addingReportingOverflow(cdSize)
        guard cdSize <= UInt64(Self.maxCentralDirectoryBytes), !cdOv, cdEnd <= fileSize else {
            throw zipError("IPA central directory size/offset out of bounds")
        }

        try handle.seek(toOffset: cdOffset)
        let cdData = try handle.read(upToCount: Int(cdSize)) ?? Data()
        guard UInt64(cdData.count) == cdSize else {
            throw zipError("Truncated IPA central directory")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(min(Int(totalEntries), 4096))
        var cursor = 0
        var declaredBytesTotal: UInt64 = 0

        while cursor <= cdData.count - 46 {
            guard readUInt32(cdData, at: cursor) == 0x0201_4B50 else {
                throw zipError("Invalid central directory entry signature")
            }
            let method = readUInt16(cdData, at: cursor + 10)
            var compSize = UInt64(readUInt32(cdData, at: cursor + 20))
            var uncompSize = UInt64(readUInt32(cdData, at: cursor + 24))
            let nameLen = Int(readUInt16(cdData, at: cursor + 28))
            let extraLen = Int(readUInt16(cdData, at: cursor + 30))
            let commentLen = Int(readUInt16(cdData, at: cursor + 32))
            let extAttrs = readUInt32(cdData, at: cursor + 38)
            var localOffset = UInt64(readUInt32(cdData, at: cursor + 42))

            let entryEnd = cursor + 46 + nameLen + extraLen + commentLen
            guard entryEnd <= cdData.count else {
                throw zipError("Truncated central directory entry")
            }

            let unixMode = (extAttrs >> 16) & 0xFFFF
            if (unixMode & 0o170000) == 0o120000 {
                throw zipError("IPA contains prohibited symlink entry")
            }

            let nameStart = cursor + 46
            let nameData = cdData[nameStart..<(nameStart + nameLen)]
            guard let name = String(data: nameData, encoding: .utf8), !name.isEmpty else {
                throw zipError("IPA contains non-UTF-8 entry name")
            }
            if name.hasPrefix("/") || name.hasPrefix("\\") || name.contains("\\") || name.contains("\0")
                || name.split(separator: "/").contains("..") {
                throw zipError("IPA contains unsafe path traversal entry '\(name)'")
            }

            if compSize == 0xFFFF_FFFF || uncompSize == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                let extraStart = nameStart + nameLen
                let extraSlice = cdData[extraStart..<(extraStart + extraLen)]
                applyZIP64Extra(
                    extraSlice,
                    uncompSize: &uncompSize,
                    compSize: &compSize,
                    localOffset: &localOffset
                )
            }

            let (nextTotal, overflow) = declaredBytesTotal.addingReportingOverflow(uncompSize)
            if overflow || nextTotal > Self.maxTotalDeclaredBytes {
                throw zipError("IPA declared uncompressed size exceeds safety cap")
            }
            declaredBytesTotal = nextTotal

            entries.append(Entry(
                name: name,
                compressionMethod: method,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                localHeaderOffset: localOffset
            ))
            if entries.count > Self.maxEntries {
                throw zipError("IPA entry count exceeds safety cap")
            }
            cursor = entryEnd
        }

        return entries
    }

    func extractEntry(_ entry: Entry, maxBytes: Int) throws -> Data {
        guard maxBytes > 0, entry.uncompressedSize <= UInt64(maxBytes) else {
            throw zipError("Entry '\(entry.name)' exceeds maximum allowed size (\(maxBytes) bytes)")
        }
        let (doubledMax, mulOv) = UInt64(maxBytes).multipliedReportingOverflow(by: 2)
        let (maxCompressedBytes, addOv) = mulOv
            ? (UInt64.max, true)
            : doubledMax.addingReportingOverflow(65_536)
        let effectiveCompCap = addOv ? UInt64(maxBytes) : maxCompressedBytes
        guard entry.compressedSize <= effectiveCompCap else {
            throw zipError("Compressed entry '\(entry.name)' exceeds maximum allowed size (\(effectiveCompCap) bytes)")
        }

        let (localHeaderEnd, localOv) = entry.localHeaderOffset.addingReportingOverflow(30)
        guard !localOv, localHeaderEnd <= fileSize else {
            throw zipError("Entry local header offset out of bounds")
        }
        try handle.seek(toOffset: entry.localHeaderOffset)
        let localHdr = try handle.read(upToCount: 30) ?? Data()
        guard localHdr.count == 30, readUInt32(localHdr, at: 0) == 0x0403_4B50 else {
            throw zipError("Invalid local file header for '\(entry.name)'")
        }
        let nameLen = UInt64(readUInt16(localHdr, at: 26))
        let extraLen = UInt64(readUInt16(localHdr, at: 28))
        let (afterName, nameOv) = localHeaderEnd.addingReportingOverflow(nameLen)
        guard !nameOv else {
            throw zipError("Local header name offset overflow for '\(entry.name)'")
        }
        let (dataOffset, extraOv) = afterName.addingReportingOverflow(extraLen)
        guard !extraOv else {
            throw zipError("Local header extra offset overflow for '\(entry.name)'")
        }
        let (dataEnd, dataOv) = dataOffset.addingReportingOverflow(entry.compressedSize)
        guard !dataOv, dataEnd <= fileSize else {
            throw zipError("Compressed payload out of bounds for '\(entry.name)'")
        }
        try handle.seek(toOffset: dataOffset)

        switch entry.compressionMethod {
        case 0:
            guard entry.compressedSize <= UInt64(maxBytes) else {
                throw zipError("Stored entry exceeds size cap")
            }
            return try readExactBytes(count: Int(entry.compressedSize))
        case 8:
            return try inflateBounded(compressedSize: entry.compressedSize, maxOutputBytes: maxBytes)
        default:
            throw zipError("Unsupported ZIP compression method \(entry.compressionMethod)")
        }
    }

    private func readExactBytes(count: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(min(count, 64 * 1024))
        var remaining = count
        while remaining > 0 {
            let chunk = try handle.read(upToCount: min(remaining, 64 * 1024)) ?? Data()
            if chunk.isEmpty {
                throw zipError("Unexpected EOF reading stored ZIP entry")
            }
            out.append(chunk)
            remaining -= chunk.count
        }
        return out
    }

    private func inflateBounded(compressedSize: UInt64, maxOutputBytes: Int) throws -> Data {
        let dummyDst = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { dummyDst.deallocate() }
        var stream = compression_stream(
            dst_ptr: dummyDst,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(dummyDst),
            src_size: 0,
            state: nil
        )

        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK else {
            throw zipError("Failed to initialize DEFLATE decoder")
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data()
        var dstBuffer = [UInt8](repeating: 0, count: 64 * 1024)
        var remaining = compressedSize

        while true {
            let chunkSize = Int(min(remaining, 64 * 1024))
            let srcChunk = chunkSize > 0 ? (try handle.read(upToCount: chunkSize) ?? Data()) : Data()
            if chunkSize > 0 && srcChunk.isEmpty {
                throw zipError("Unexpected EOF reading compressed ZIP entry")
            }
            remaining -= UInt64(srcChunk.count)
            let flags: Int32 = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0

            let done = try srcChunk.withUnsafeBytes { rawSrc -> Bool in
                let srcBase = rawSrc.bindMemory(to: UInt8.self).baseAddress
                stream.src_ptr = srcBase ?? UnsafePointer<UInt8>(dummyDst)
                stream.src_size = srcChunk.count

                while true {
                    let status: compression_status = dstBuffer.withUnsafeMutableBufferPointer { dstBuf in
                        guard let dstBase = dstBuf.baseAddress else { return COMPRESSION_STATUS_ERROR }
                        stream.dst_ptr = dstBase
                        stream.dst_size = dstBuf.count
                        return compression_stream_process(&stream, flags)
                    }
                    let produced = dstBuffer.count - stream.dst_size
                    if produced > 0 {
                        if output.count + produced > maxOutputBytes {
                            throw zipError("Decompressed ZIP entry exceeded safety cap (possible zip bomb)")
                        }
                        output.append(contentsOf: dstBuffer[0..<produced])
                    }
                    switch status {
                    case COMPRESSION_STATUS_OK:
                        if stream.src_size == 0 && produced == 0 {
                            return false
                        }
                        if stream.src_size == 0 && flags == 0 {
                            return false
                        }
                    case COMPRESSION_STATUS_END:
                        return true
                    default:
                        throw zipError("Corrupt DEFLATE stream in IPA")
                    }
                }
            }
            if done {
                return output
            }
            if remaining == 0 && srcChunk.isEmpty {
                throw zipError("Truncated DEFLATE stream in IPA")
            }
        }
    }

    private func findEOCDOffset(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        for offset in stride(from: data.count - 22, through: 0, by: -1)
        where readUInt32(data, at: offset) == 0x0605_4B50 {
            let commentLen = Int(readUInt16(data, at: offset + 20))
            if offset + 22 + commentLen == data.count {
                return offset
            }
        }
        return nil
    }

    private func applyZIP64Extra(
        _ slice: Data.SubSequence,
        uncompSize: inout UInt64,
        compSize: inout UInt64,
        localOffset: inout UInt64
    ) {
        let bytes = Data(slice)
        var pos = 0
        while pos + 4 <= bytes.count {
            let headerID = readUInt16(bytes, at: pos)
            let fieldSize = Int(readUInt16(bytes, at: pos + 2))
            let bodyStart = pos + 4
            guard bodyStart + fieldSize <= bytes.count else { break }
            if headerID == 0x0001 {
                var fieldCursor = bodyStart
                if uncompSize == 0xFFFF_FFFF, fieldCursor + 8 <= bodyStart + fieldSize {
                    uncompSize = readUInt64(bytes, at: fieldCursor)
                    fieldCursor += 8
                }
                if compSize == 0xFFFF_FFFF, fieldCursor + 8 <= bodyStart + fieldSize {
                    compSize = readUInt64(bytes, at: fieldCursor)
                    fieldCursor += 8
                }
                if localOffset == 0xFFFF_FFFF, fieldCursor + 8 <= bodyStart + fieldSize {
                    localOffset = readUInt64(bytes, at: fieldCursor)
                }
                return
            }
            pos = bodyStart + fieldSize
        }
    }

    private func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        return b0 | (b1 << 8)
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        let lo = UInt64(readUInt32(data, at: offset))
        let hi = UInt64(readUInt32(data, at: offset + 4))
        return lo | (hi << 32)
    }

    private func zipError(_ message: String) -> MCPCLIError {
        MCPCLIError.zipArchiveError(message)
    }
}
