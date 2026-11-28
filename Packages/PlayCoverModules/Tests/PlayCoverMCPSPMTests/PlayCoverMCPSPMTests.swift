import Darwin
import Foundation
import PlayCoverCore
@testable import PlayCoverMCP
import Testing

@Suite
struct PlayCoverMCPSPMTests {
    @Test
    func toolRegistryCountAndTokenBudget() {
        #expect(MCPToolRegistry.tools.count == 10)
        let names = Set(MCPToolRegistry.tools.map(\.name))
        #expect(names == [
            "macover_apps",
            "macover_settings",
            "macover_ui_snapshot",
            "macover_act",
            "macover_wait",
            "macover_screenshot",
            "macover_network",
            "macover_network_rules",
            "macover_diagnostics",
            "macover_keymap"
        ])
        let estimatedTokens = MCPToolRegistry.estimatedSchemaTokenCount()
        #expect(estimatedTokens <= MCPToolRegistry.maxToolsSchemaTokenBudget)

        // MCP2-20: macover_screenshot exposes optional rev parameter alongside clipRef.
        let screenshotTool = MCPToolRegistry.tools.first(where: { $0.name == "macover_screenshot" })
        let screenshotProps = screenshotTool?.inputSchema["properties"]?.objectValue
        #expect(screenshotProps?["rev"] != nil)
        #expect(screenshotProps?["clipRef"] != nil)
    }

    @Test
    func stdioFramerSupportsBothNDJSONAndContentLength() throws {
        let pipeND = Pipe()
        let msg1 = #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
        pipeND.fileHandleForWriting.write(Data((msg1 + "\n").utf8))
        pipeND.fileHandleForWriting.closeFile()

        var bufND = Data()
        let parsed1 = try MCPStdioFramer.readNextFrame(from: pipeND.fileHandleForReading, buffer: &bufND)
        #expect(parsed1?.mode == .ndjson)
        #expect(String(data: parsed1?.payload ?? Data(), encoding: .utf8) == msg1)

        let pipeCL = Pipe()
        let msg2 = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let framed = MCPStdioFramer.encodeFrame(Data(msg2.utf8), mode: .contentLength)
        pipeCL.fileHandleForWriting.write(framed)
        pipeCL.fileHandleForWriting.closeFile()

        var bufCL = Data()
        let parsed2 = try MCPStdioFramer.readNextFrame(from: pipeCL.fileHandleForReading, buffer: &bufCL)
        #expect(parsed2?.mode == .contentLength)
        #expect(String(data: parsed2?.payload ?? Data(), encoding: .utf8) == msg2)
    }

    @Test
    func stdioFramerReadsSmallFramesWithoutEOFOnOpenPipe() throws {
        // Gate-8 regression: interactive clients keep stdin open after sending small frames (< 64 KiB).
        let pipeND = Pipe()
        defer {
            try? pipeND.fileHandleForWriting.close()
            try? pipeND.fileHandleForReading.close()
        }
        let msgND1 = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
        try pipeND.fileHandleForWriting.write(contentsOf: Data((msgND1 + "\n").utf8))

        var bufND = Data()
        let parsedND1 = try MCPStdioFramer.readNextFrame(from: pipeND.fileHandleForReading, buffer: &bufND)
        #expect(parsedND1?.mode == .ndjson)
        #expect(String(data: parsedND1?.payload ?? Data(), encoding: .utf8) == msgND1)

        let msgND2 = #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#
        try pipeND.fileHandleForWriting.write(contentsOf: Data((msgND2 + "\n").utf8))
        let parsedND2 = try MCPStdioFramer.readNextFrame(from: pipeND.fileHandleForReading, buffer: &bufND)
        #expect(parsedND2?.mode == .ndjson)
        #expect(String(data: parsedND2?.payload ?? Data(), encoding: .utf8) == msgND2)

        let pipeCL = Pipe()
        defer {
            try? pipeCL.fileHandleForWriting.close()
            try? pipeCL.fileHandleForReading.close()
        }
        let msgCL1 = #"{"jsonrpc":"2.0","id":3,"method":"initialize"}"#
        try pipeCL.fileHandleForWriting.write(
            contentsOf: MCPStdioFramer.encodeFrame(Data(msgCL1.utf8), mode: .contentLength)
        )

        var bufCL = Data()
        let parsedCL1 = try MCPStdioFramer.readNextFrame(from: pipeCL.fileHandleForReading, buffer: &bufCL)
        #expect(parsedCL1?.mode == .contentLength)
        #expect(String(data: parsedCL1?.payload ?? Data(), encoding: .utf8) == msgCL1)

        let msgCL2 = #"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#
        try pipeCL.fileHandleForWriting.write(
            contentsOf: MCPStdioFramer.encodeFrame(Data(msgCL2.utf8), mode: .contentLength)
        )
        let parsedCL2 = try MCPStdioFramer.readNextFrame(from: pipeCL.fileHandleForReading, buffer: &bufCL)
        #expect(parsedCL2?.mode == .contentLength)
        #expect(String(data: parsedCL2?.payload ?? Data(), encoding: .utf8) == msgCL2)
    }

    @Test
    func stdioFramerDrainsMalformedHeadersAndMatchesActiveFramingMode() async throws {
        let inPipe = Pipe()
        let outPipe = Pipe()

        var inputBytes = Data()
        // 1. Invalid UTF-8 header block
        inputBytes.append(contentsOf: [0xFF, 0xFE, 0x0D, 0x0A, 0x0D, 0x0A])
        // 2. Missing Content-Length header block
        inputBytes.append(Data("X-Test: foo\r\n\r\n".utf8))
        // 3. Oversized Content-Length header block
        inputBytes.append(Data("Content-Length: 999999999\r\n\r\n".utf8))
        // 4. Valid Content-Length ping request afterwards
        let ping = Data(#"{"jsonrpc":"2.0","id":7,"method":"ping"}"#.utf8)
        inputBytes.append(MCPStdioFramer.encodeFrame(ping, mode: .contentLength))

        inPipe.fileHandleForWriting.write(inputBytes)
        inPipe.fileHandleForWriting.closeFile()

        let runner = MCPCLIRunner()
        await runner.runStdioLoop(
            input: inPipe.fileHandleForReading,
            output: outPipe.fileHandleForWriting
        )
        outPipe.fileHandleForWriting.closeFile()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let outText = try #require(String(data: outData, encoding: .utf8))
        // All error responses after Content-Length header blocks must use Content-Length framing,
        // and the loop must drain bad headers cleanly and process id: 7 without spinning.
        #expect(outText.contains("Content-Length:"))
        #expect(outText.contains("-32700"))
        #expect(outText.contains(#""id":7"#))
    }

    @Test
    func cliRunnerHandlesInitializeToolsListPingNotificationsAndErrors() async throws {
        let missingSession = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-mcp-session-\(UUID().uuidString).json")
        let emptyAppsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-mcp-apps-\(UUID().uuidString)", isDirectory: true)
        let runner = MCPCLIRunner(config: MCPCLIServerConfig(
            sessionURL: missingSession,
            applicationsDirectory: emptyAppsDir
        ))

        let initPayload = #"{"jsonrpc":"2.0","id":1,"method":"initialize","#
            + #""params":{"protocolVersion":"2025-03-26"}}"#
        let initResp = await runner.handleFramePayload(Data(initPayload.utf8))
        #expect(initResp?.error == nil)
        #expect(initResp?.result?["serverInfo"]?["name"]?.stringValue == "macover-mcp")

        let listResp = await runner.handleFramePayload(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))
        #expect(listResp?.result?["tools"]?.arrayValue?.count == 10)

        let pingResp = await runner.handleFramePayload(Data(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#.utf8))
        #expect(pingResp?.error == nil)

        // JSON-RPC 2.0 §4.1: ALL notifications (omitted id) must produce nil regardless of method name.
        let stdNotif = await runner.handleFramePayload(
            Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        )
        #expect(stdNotif == nil)
        let customNotif = await runner.handleFramePayload(
            Data(#"{"jsonrpc":"2.0","method":"custom/unrecognized"}"#.utf8)
        )
        #expect(customNotif == nil)

        let offlineList = await runner.dispatchToolCall(name: "macover_apps", arguments: ["op": .string("list")])
        #expect(offlineList.isError == nil)

        let offlineUI = await runner.dispatchToolCall(
            name: "macover_ui_snapshot",
            arguments: ["bundleID": .string("com.example.app")]
        )
        #expect(offlineUI.isError == true)

        // Live daemon session with mismatched token must surface hostFailureReason on macover_apps(list) (L-03).
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macover-mcp-fail-list-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let server = MCPLoopbackServer { _, _ in .text("ok") }
        let (port, _) = try server.start()
        defer { server.stop() }

        let badSessionURL = tmpDir.appendingPathComponent("daemon.json")
        let badSession = MCPDaemonSession(port: port, token: "wrong-token", pid: getpid(), version: "1.0.10")
        try MCPDaemonSessionFile.write(badSession, to: badSessionURL)

        let liveFailRunner = MCPCLIRunner(config: MCPCLIServerConfig(
            sessionURL: badSessionURL,
            applicationsDirectory: emptyAppsDir
        ))
        let failedList = await liveFailRunner.dispatchToolCall(
            name: "macover_apps",
            arguments: ["op": .string("list")]
        )
        #expect(failedList.isError == true)
        if case .text(let body) = failedList.content.first {
            #expect(body.contains("hostRunning=error"))
            #expect(body.contains("hostFailureReason="))
        } else {
            Issue.record("Expected text output on failed list")
        }
    }

    @Test
    func axTreeCompactorRevisionedRefsScopeSemanticKeyAndDiffLabelsAndDuplicates() throws {
        let leafChildren = [
            UITreeNode(
                id: "n-lbl",
                role: "AXStaticText",
                label: "Save Changes",
                frame: UITreeRect(x: 110, y: 110, width: 80, height: 20),
                isInteractive: false
            ),
            UITreeNode(
                id: "n-img",
                role: "AXImage",
                frame: UITreeRect(x: 90, y: 110, width: 16, height: 16),
                isInteractive: false
            )
        ]
        let btn = UITreeNode(
            id: "n-btn",
            role: "AXButton",
            identifier: "save_btn",
            frame: UITreeRect(x: 80, y: 100, width: 140, height: 40),
            actions: ["AXPress"],
            isInteractive: true,
            children: leafChildren
        )
        let toggle1 = UITreeNode(
            id: "n-sw",
            role: "AXSwitch",
            label: "Notifications",
            value: "1",
            frame: UITreeRect(x: 80, y: 160, width: 200, height: 32),
            actions: ["AXPress"],
            isInteractive: true
        )
        let offscreen = UITreeNode(
            id: "n-off",
            role: "AXButton",
            label: "Offscreen Button",
            frame: UITreeRect(x: 80, y: 2000, width: 100, height: 40),
            actions: ["AXPress"],
            isInteractive: true
        )
        let hidden = UITreeNode(
            id: "n-hid",
            role: "AXButton",
            label: "Hidden Button",
            hidden: true,
            frame: UITreeRect(x: 80, y: 220, width: 100, height: 40),
            actions: ["AXPress"],
            isInteractive: true
        )
        let wrapper = UITreeNode(
            id: "n-grp",
            role: "AXGroup",
            frame: UITreeRect(x: 0, y: 0, width: 1280, height: 800),
            children: [btn, toggle1, offscreen, hidden]
        )
        let win = UITreeNode(
            id: "n-win",
            role: "AXWindow",
            label: "Settings",
            frame: UITreeRect(x: 0, y: 0, width: 1280, height: 800),
            children: [wrapper]
        )
        let snap1 = RawUITreeSnapshot(
            bundleID: "com.example.app",
            pid: 1234,
            width: 1280,
            height: 800,
            source: .ax,
            root: win
        )

        let rawJSONBytes = try JSONEncoder().encode(snap1).count
        let store = UITreeRevisionStore()
        let first = store.record(rawSnapshot: snap1, query: UISnapshotQuery())
        #expect(first.current.revision == 1)
        #expect(first.current.nodes.count == 3)
        #expect(first.current.nodes.map(\.ref) == ["r1e1", "r1e2", "r1e3"])
        #expect(Double(first.current.text.utf8.count) < Double(rawJSONBytes) * 0.35)
        #expect(first.current.text.contains("Save Changes"))
        #expect(!first.current.text.contains("Offscreen Button"))
        #expect(!first.current.text.contains("Hidden Button"))

        // Change label on identified button, change switch value, add alert + duplicate sibling Buy buttons
        let btnRenamed = UITreeNode(
            id: "n-btn-new-dfs",
            role: "AXButton",
            label: "Apply Now",
            identifier: "save_btn",
            frame: UITreeRect(x: 80, y: 100, width: 140, height: 40),
            actions: ["AXPress"],
            isInteractive: true
        )
        let toggle2 = UITreeNode(
            id: "n-sw",
            role: "AXSwitch",
            label: "Notifications",
            value: "0",
            frame: UITreeRect(x: 80, y: 160, width: 200, height: 32),
            actions: ["AXPress"],
            isInteractive: true
        )
        let buy1 = UITreeNode(
            id: "n-buy-1",
            role: "AXButton",
            label: "Buy",
            frame: UITreeRect(x: 80, y: 220, width: 90, height: 36),
            actions: ["AXPress"],
            isInteractive: true
        )
        let buy2 = UITreeNode(
            id: "n-buy-2",
            role: "AXButton",
            label: "Buy",
            frame: UITreeRect(x: 180, y: 220, width: 90, height: 36),
            actions: ["AXPress"],
            isInteractive: true
        )
        let alert = UITreeNode(
            id: "n-alert",
            role: "AXDialog",
            label: "Saved",
            frame: UITreeRect(x: 400, y: 300, width: 300, height: 120),
            isInteractive: true
        )
        let snap2 = RawUITreeSnapshot(
            bundleID: "com.example.app",
            pid: 1234,
            width: 1280,
            height: 800,
            source: .ax,
            root: UITreeNode(
                id: "n-win",
                role: "AXWindow",
                label: "Settings",
                frame: UITreeRect(x: 0, y: 0, width: 1280, height: 800),
                children: [btnRenamed, toggle2, buy1, buy2, alert]
            )
        )
        let second = store.record(rawSnapshot: snap2, query: UISnapshotQuery())
        let prevSnap = try #require(second.previous)
        let diff = UITreeRevisionStore.formatDiff(from: prevSnap, to: second.current)
        #expect(diff.contains("# diff rev 1->2"))
        #expect(diff.contains("lbl=Save Changes->Apply Now"))
        #expect(diff.contains("~ [r2e3] switch \"Notifications\" val=1->0"))
        #expect(diff.contains("+ [r2e6] alert \"Saved\""))

        // Duplicate "Buy" siblings must have unique semanticKeys (M-12).
        let buyNodes = second.current.nodes.filter { $0.label == "Buy" }
        #expect(buyNodes.count == 2)
        #expect(buyNodes[0].semanticKey != buyNodes[1].semanticKey)

        // Revisioned ref aliasing prevention (H-15): r1e3 must be STALE at rev 2; bare "e3" without rev is STALE.
        if case .stale(let msg, let candidates) = store.resolveRef(bundleID: "com.example.app", ref: "r1e3") {
            #expect(msg.contains("STALE_REF r1e3"))
            #expect(!candidates.isEmpty)
        } else {
            Issue.record("Expected STALE_REF for r1e3 when latest is rev 2")
        }
        if case .stale(let msg, _) = store.resolveRef(bundleID: "com.example.app", ref: "e3") {
            #expect(msg.contains("unrevisioned ref rejected"))
        } else {
            Issue.record("Expected STALE_REF for bare unrevisioned ref e3")
        }
        if case .found(let node) = store.resolveRef(bundleID: "com.example.app", ref: "r2e3") {
            #expect(node.label == "Notifications")
        } else {
            Issue.record("Expected r2e3 to resolve in rev 2")
        }
        if case .found(let node) = store.resolveRef(bundleID: "com.example.app", ref: "e3", expectedRevision: 2) {
            #expect(node.ref == "r2e3")
        } else {
            Issue.record("Expected e3 with rev=2 to resolve to r2e3")
        }

        // scopeRef via semanticKey survives changed raw DFS IDs, and missing scope sets scopeNotFound (H-15).
        let scopeKey = try #require(store.semanticKey(forScopeRef: "r2e2", bundleID: "com.example.app"))
        let snap3WithShiftedIDs = RawUITreeSnapshot(
            bundleID: "com.example.app",
            pid: 1234,
            width: 1280,
            height: 800,
            source: .ax,
            root: UITreeNode(
                id: "n-win-99",
                role: "AXWindow",
                label: "Settings",
                frame: UITreeRect(x: 0, y: 0, width: 1280, height: 800),
                children: [
                    UITreeNode(
                        id: "completely-different-dfs-id",
                        role: "AXButton",
                        label: "Apply Now",
                        identifier: "save_btn",
                        frame: UITreeRect(x: 80, y: 100, width: 140, height: 40),
                        actions: ["AXPress"],
                        isInteractive: true
                    )
                ]
            )
        )
        let scoped = store.record(
            rawSnapshot: snap3WithShiftedIDs,
            query: UISnapshotQuery(scopeSemanticKey: scopeKey)
        )
        #expect(scoped.current.scopeNotFound == false)
        #expect(scoped.current.nodes.count == 1)
        #expect(scoped.current.nodes.first?.identifier == "save_btn")

        let missingScope = store.record(
            rawSnapshot: snap3WithShiftedIDs,
            query: UISnapshotQuery(scopeSemanticKey: "btn|id=does_not_exist|win:Settings/btn:does_not_exist")
        )
        #expect(missingScope.current.scopeNotFound == true)
        #expect(store.latestSnapshot(for: "com.example.app")?.revision == 3)
    }

    @Test
    func coordinateMapperHeaderRedactorURLAndBodyRedaction() throws {
        let viewport = LogicalViewport(width: 1920, height: 1080)
        let p = try CoordinateMapper.resolvePoint(
            x: nil,
            y: nil,
            nx: 0.25,
            ny: 0.5,
            viewport: viewport
        )
        #expect(p.x == 480)
        #expect(p.y == 540)
        #expect(throws: CoordinateMapperError.self) {
            _ = try CoordinateMapper.resolvePoint(
                x: nil,
                y: nil,
                nx: 1.5,
                ny: 0.2,
                viewport: viewport
            )
        }

        // Expanded sensitive headers (H-13)
        let headers = [
            "Authorization": "Bearer secret-jwt",
            "X-Goog-Api-Key": "google-secret",
            "Ocp-Apim-Subscription-Key": "azure-sub-secret",
            "WWW-Authenticate": "Bearer realm=\"example\"",
            "Set-Cookie2": "sid=xyz",
            "X-Session-Id": "sess-123",
            "X-Auth": "raw-auth",
            "X-Hub-Signature-256": "sha256=deadbeef",
            "Content-Type": "application/json"
        ]
        let redacted = HeaderRedactor.redact(headers: headers, allowSensitiveHeaders: false)
        #expect(redacted["Authorization"] == "[REDACTED]")
        #expect(redacted["X-Goog-Api-Key"] == "[REDACTED]")
        #expect(redacted["Ocp-Apim-Subscription-Key"] == "[REDACTED]")
        #expect(redacted["WWW-Authenticate"] == "[REDACTED]")
        #expect(redacted["Set-Cookie2"] == "[REDACTED]")
        #expect(redacted["X-Session-Id"] == "[REDACTED]")
        #expect(redacted["X-Auth"] == "[REDACTED]")
        #expect(redacted["X-Hub-Signature-256"] == "[REDACTED]")
        #expect(redacted["Content-Type"] == "application/json")

        let plain = HeaderRedactor.redact(headers: headers, allowSensitiveHeaders: true)
        #expect(plain["Authorization"] == "Bearer secret-jwt")

        // URL query + userinfo + fragment redaction (H-13)
        let sensitiveURL = "https://alice:hunter2@api.example.com/v1/login"
            + "?access_token=tok123&api_key=k456&code=oauth789&page=2#id_token=jwt999&tab=home"
        let safeURL = HeaderRedactor.redactURL(sensitiveURL, allowSensitiveHeaders: false)
        #expect(!safeURL.contains("hunter2"))
        #expect(!safeURL.contains("tok123"))
        #expect(!safeURL.contains("k456"))
        #expect(!safeURL.contains("oauth789"))
        #expect(!safeURL.contains("jwt999"))
        #expect(safeURL.contains("page=2"))
        #expect(safeURL.contains("tab=home"))

        // JSON body redaction before jsonPath/grep (H-13)
        let secretJSON = Data(
            #"{"access_token":"secret-oauth","nested":{"password":"pw1"},"data":{"items":[{"id":"item-42"}]}}"#.utf8
        )
        let redactedPath = BodyExtractor.extract(
            rawData: secretJSON,
            headers: ["Content-Type": "application/json"],
            jsonPath: "$.access_token",
            redactSensitive: true
        )
        #expect(redactedPath?.text == "[REDACTED]")
        let safePath = BodyExtractor.extract(
            rawData: secretJSON,
            headers: ["Content-Type": "application/json"],
            jsonPath: "$.data.items[0].id",
            redactSensitive: true
        )
        #expect(safePath?.text == "item-42")
        let redactedFull = BodyExtractor.extract(
            rawData: secretJSON,
            headers: ["Content-Type": "application/json"],
            redactSensitive: true
        )
        #expect(redactedFull?.text.contains("secret-oauth") == false)
        #expect(redactedFull?.text.contains("pw1") == false)
        let grepSecret = BodyExtractor.extract(
            rawData: secretJSON,
            headers: ["Content-Type": "application/json"],
            grep: "secret-oauth",
            redactSensitive: true
        )
        #expect(grepSecret?.text == "<no lines matching 'secret-oauth'>")

        // Form URL-encoded body redaction + binary redaction
        let formBody = Data("user=alice&password=supersecret&refresh_token=rt999".utf8)
        let redactedForm = BodyExtractor.extract(
            rawData: formBody,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            redactSensitive: true
        )
        #expect(redactedForm?.text.contains("supersecret") == false)
        #expect(redactedForm?.text.contains("rt999") == false)
        #expect(redactedForm?.text.contains("user=alice") == true)

        let binaryBody = Data([0x00, 0x01, 0x02, 0xFE, 0xFF, 0x80, 0x00, 0x09])
        let redactedBin = BodyExtractor.extract(rawData: binaryBody, headers: [:], redactSensitive: true)
        #expect(redactedBin?.text.contains("[REDACTED binary body") == true)
        let allowedBin = BodyExtractor.extract(rawData: binaryBody, headers: [:], redactSensitive: false)
        #expect(allowedBin?.isHex == true)
    }

    @Test
    func jsonValueIntOverflowSafetyAndPolicyValidators() throws {
        // H-02: Double(Int.max) rounds to 2^63 and must NOT trap in intValue
        let huge = MCPJSONValue.double(Double(Int.max))
        #expect(huge.intValue == nil)
        #expect(MCPJSONValue.double(Double.nan).intValue == nil)
        #expect(MCPJSONValue.double(Double.infinity).intValue == nil)
        #expect(MCPJSONValue.double(123.5).intValue == nil)
        #expect(MCPJSONValue.double(42.0).intValue == 42)

        // H-03: Settings patch policy
        let known: Set<String> = [
            "bundleIdentifier", "mitmRuntimePort", "networkProxyMode",
            "externalProxyHost", "externalProxyPort", "externalProxyProtocol",
            "mitmAllowPinningBypass", "playChainDebugging", "resolution",
            "strictEmulationMode", "enableNetworkRules"
        ]
        #expect(MCPSettingsPatchPolicy.validate(
            patch: ["bundleIdentifier": .string("-globalDomain")],
            knownKeys: known
        ) != nil)
        #expect(MCPSettingsPatchPolicy.validate(
            patch: ["mitmRuntimePort": .int(1234)],
            knownKeys: known
        ) != nil)
        #expect(MCPSettingsPatchPolicy.validate(
            patch: ["networkProxyMode": .string("external")],
            knownKeys: known
        ) != nil)
        #expect(MCPSettingsPatchPolicy.validate(
            patch: ["externalProxyHost": .string("10.0.0.1")],
            knownKeys: known
        ) != nil)
        #expect(MCPSettingsPatchPolicy.validate(
            patch: ["mitmAllowPinningBypass": .bool(true)],
            knownKeys: known
        ) != nil)
        #expect(MCPSettingsPatchPolicy.validate(
            patch: ["playChainDebugging": .bool(true)],
            knownKeys: known
        ) != nil)
        #expect(MCPSettingsPatchPolicy.validate(
            patch: ["nonExistentKey": .bool(true)],
            knownKeys: known
        ) != nil)
        #expect(MCPSettingsPatchPolicy.validate(
            patch: ["networkProxyMode": .string("builtInMITM"), "resolution": .int(2)],
            knownKeys: known
        ) == nil)

        // H-01: Keymap name traversal & symlink validator
        #expect(MCPKeymapNameValidator.isValidName("default") == true)
        #expect(MCPKeymapNameValidator.isValidName("My Keymap 1") == true)
        #expect(MCPKeymapNameValidator.isValidName("../escape") == false)
        #expect(MCPKeymapNameValidator.isValidName("sub/name") == false)
        #expect(MCPKeymapNameValidator.isValidName("sub\\name") == false)
        #expect(MCPKeymapNameValidator.isValidName(".config") == false)
        #expect(MCPKeymapNameValidator.isValidName("foo..bar") == false)
        #expect(MCPKeymapNameValidator.isValidName("bad\nname") == false)
        #expect(MCPKeymapNameValidator.isValidName("") == false)

        let tmpBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("macover-km-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpBase) }
        let symTarget = tmpBase.appendingPathComponent("outside.plist")
        try Data("test".utf8).write(to: symTarget)
        let symLink = tmpBase.appendingPathComponent("evil.plist")
        try FileManager.default.createSymbolicLink(at: symLink, withDestinationURL: symTarget)
        #expect(MCPKeymapNameValidator.resolvedPlistURL(name: "evil", in: tmpBase) == nil)
        #expect(MCPKeymapNameValidator.resolvedPlistURL(name: "valid", in: tmpBase) != nil)
    }

    @Test
    func loopbackDaemonSessionFileHardeningAndBridgeHubEndToEnd() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macover-mcp-loopback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tmpDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let sessionURL = tmpDir.appendingPathComponent("daemon.json")

        let server = MCPLoopbackServer { toolName, args in
            MCPToolCallResult.text("handled:\(toolName):\(args.string("op") ?? "")")
        }
        let (port, token) = try server.start()
        defer { server.stop() }

        let session = MCPDaemonSession(port: port, token: token, pid: getpid(), version: "1.0.10")
        try MCPDaemonSessionFile.write(session, to: sessionURL)

        // M-02: Directory hardened to 0700 and file to 0600
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: tmpDir.path)
        #expect((dirAttrs[.posixPermissions] as? Int) == 0o700)
        let attrs = try FileManager.default.attributesOfItem(atPath: sessionURL.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)

        // M-02: Symlink session file rejected without TOCTOU
        let symSessionURL = tmpDir.appendingPathComponent("symlink-daemon.json")
        try FileManager.default.createSymbolicLink(at: symSessionURL, withDestinationURL: sessionURL)
        #expect(throws: MCPDaemonSessionFileError.self) {
            _ = try MCPDaemonSessionFile.read(from: symSessionURL)
        }

        // M-02: PID-reuse mismatch rejected
        let staleSession = MCPDaemonSession(
            port: port,
            token: token,
            pid: getpid(),
            version: "1.0.10",
            executablePath: "/usr/bin/false",
            processStartTimeSec: 1
        )
        #expect(staleSession.isHostProcessAlive == false)

        let loaded = try MCPDaemonSessionFile.read(from: sessionURL)
        #expect(loaded.port == port)
        #expect(loaded.token == token)
        #expect(loaded.isHostProcessAlive == true)

        let cli = MCPCLIRunner(config: MCPCLIServerConfig(sessionURL: sessionURL))
        let res = await cli.dispatchToolCall(name: "macover_apps", arguments: ["op": .string("list")])
        #expect(res.content == [.text("handled:macover_apps:list")])

        let badSession = MCPDaemonSession(port: port, token: "wrong-token", pid: getpid(), version: "1.0.10")
        #expect(throws: MCPSocketError.self) {
            _ = try MCPLoopbackClient.call(session: badSession, toolName: "macover_apps", arguments: [:])
        }

        // Test MCPBridgeHub pre-auth PID overflow (H-02), 64 KiB frame cap (M-01),
        // peer validation (M-03), hello_ack before publish (M-04), dynamic viewport (H-09),
        // command error non-disconnect (H-11), and async RPC (H-14).
        let hub = MCPBridgeHub()
        let bridgePort = try hub.start()
        defer { hub.stop() }
        let launchToken = hub.issueLaunchToken(for: "com.example.game", ttlSeconds: 10)

        // 1. Pre-auth oversized frame (> 64 KiB) rejected cleanly
        let hugeFD = try MCPFramedSocketIO.connectLoopback(port: bridgePort, timeoutSeconds: 5)
        defer { Darwin.close(hugeFD) }
        var hugeLenBE = UInt32(MCPFramedSocketIO.maxPreAuthFrameBytes + 1024).bigEndian
        _ = withUnsafeBytes(of: &hugeLenBE) { buf in
            Darwin.write(hugeFD, buf.baseAddress, buf.count)
        }
        let hugeResp = try? MCPFramedSocketIO.readFrame(from: hugeFD)
        #expect(hugeResp == nil)

        // 2. Pre-auth Int32 overflow PID must NOT trap host process (H-02)
        let overflowFD = try MCPFramedSocketIO.connectLoopback(port: bridgePort, timeoutSeconds: 5)
        defer { Darwin.close(overflowFD) }
        let overflowHello = try JSONEncoder().encode(MCPJSONValue.object([
            "type": .string("hello"),
            "token": .string("not-a-valid-token"),
            "bundleID": .string("com.example.game"),
            "pid": .int(Int.max)
        ]))
        try MCPFramedSocketIO.writeFrame(overflowHello, to: overflowFD)
        let overflowAck = (try MCPFramedSocketIO.readFrame(from: overflowFD))
            .flatMap { try? JSONDecoder().decode(MCPJSONValue.self, from: $0) }
        #expect(overflowAck?.objectValue?.bool("ok") == false)

        // 3. Wrong bundleID rejected and token NOT consumed
        let wrongBundleFD = try MCPFramedSocketIO.connectLoopback(port: bridgePort, timeoutSeconds: 5)
        defer { Darwin.close(wrongBundleFD) }
        let wrongHello = try JSONEncoder().encode(MCPJSONValue.object([
            "type": .string("hello"),
            "token": .string(launchToken),
            "bundleID": .string("com.other.app"),
            "pid": .int(Int(getpid()))
        ]))
        try MCPFramedSocketIO.writeFrame(wrongHello, to: wrongBundleFD)
        let wrongAck = (try MCPFramedSocketIO.readFrame(from: wrongBundleFD))
            .flatMap { try? JSONDecoder().decode(MCPJSONValue.self, from: $0) }
        #expect(wrongAck?.objectValue?.bool("ok") == false)

        // 4. Valid handshake using current real PID + live RPC echo loop
        let clientFD = try MCPFramedSocketIO.connectLoopback(port: bridgePort, timeoutSeconds: 5)
        let goodHello = try JSONEncoder().encode(MCPJSONValue.object([
            "type": .string("hello"),
            "token": .string(launchToken),
            "bundleID": .string("com.example.game"),
            "pid": .int(Int(getpid())),
            "logicalWidth": .double(1024),
            "logicalHeight": .double(768)
        ]))
        try MCPFramedSocketIO.writeFrame(goodHello, to: clientFD)
        let goodAck = (try MCPFramedSocketIO.readFrame(from: clientFD))
            .flatMap { try? JSONDecoder().decode(MCPJSONValue.self, from: $0) }
        #expect(goodAck?.objectValue?.bool("ok") == true)

        // Spin briefly to ensure connection published after hello_ack (M-04)
        for _ in 0..<20 where hub.sessionInfo(for: "com.example.game") == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(hub.sessionInfo(for: "com.example.game")?.pid == getpid())

        // Start mock guest responder on background queue
        let responderQueue = DispatchQueue(label: "test.bridge.responder")
        responderQueue.async {
            defer { Darwin.close(clientFD) }
            while let reqData = try? MCPFramedSocketIO.readFrame(from: clientFD),
                  let req = try? JSONDecoder().decode(MCPJSONValue.self, from: reqData),
                  let method = req.objectValue?.string("method") {
                let reply: MCPJSONValue
                switch method {
                case "get_ui_tree":
                    reply = .object([
                        "ok": .bool(true),
                        "result": .object([
                            "width": .double(1920),
                            "height": .double(1080),
                            "logicalWidth": .double(1920),
                            "logicalHeight": .double(1080)
                        ])
                    ])
                case "set_text":
                    reply = .object([
                        "ok": .bool(false),
                        "error": .string("Target node is not editable")
                    ])
                case "touch":
                    reply = .object([
                        "ok": .bool(true),
                        "result": .object([
                            "gesture": .string("tap"),
                            "logicalWidth": .double(1366),
                            "logicalHeight": .double(1024)
                        ])
                    ])
                default:
                    reply = .object(["ok": .bool(true), "result": .object([:])])
                }
                if let encoded = try? JSONEncoder().encode(reply) {
                    try? MCPFramedSocketIO.writeFrame(encoded, to: clientFD)
                }
            }
        }

        // H-09 + H-14: get_ui_tree updates live viewport dynamically off MainActor
        _ = try await hub.sendRequestAsync(bundleID: "com.example.game", method: "get_ui_tree")
        let infoAfterTree = try #require(hub.sessionInfo(for: "com.example.game"))
        #expect(infoAfterTree.logicalWidth == 1920)
        #expect(infoAfterTree.logicalHeight == 1080)
        #expect(infoAfterTree.hasLiveViewport == true)

        // H-11: Application-level {"ok": false} throws MCPBridgeCommandError WITHOUT disconnecting session
        await #expect(throws: MCPBridgeCommandError.self) {
            _ = try await hub.sendRequestAsync(bundleID: "com.example.game", method: "set_text")
        }
        #expect(hub.sessionInfo(for: "com.example.game") != nil)

        // Session stays alive and touch updates viewport again (H-09 + H-11)
        _ = try await hub.sendRequestAsync(bundleID: "com.example.game", method: "touch")
        let infoAfterTouch = try #require(hub.sessionInfo(for: "com.example.game"))
        #expect(infoAfterTouch.logicalWidth == 1366)
        #expect(infoAfterTouch.logicalHeight == 1024)

        // Token replay rejected
        let replayFD = try MCPFramedSocketIO.connectLoopback(port: bridgePort, timeoutSeconds: 5)
        defer { Darwin.close(replayFD) }
        try MCPFramedSocketIO.writeFrame(goodHello, to: replayFD)
        let replayAck = (try MCPFramedSocketIO.readFrame(from: replayFD))
            .flatMap { try? JSONDecoder().decode(MCPJSONValue.self, from: $0) }
        #expect(replayAck?.objectValue?.bool("ok") == false)

        // Strict app-bundle peer validator rejects non-app test runner process (M-03)
        let strictHub = MCPBridgeHub(requireAppBundleMatch: true)
        let strictPort = try strictHub.start()
        defer { strictHub.stop() }
        let strictTok = strictHub.issueLaunchToken(for: "com.example.game", ttlSeconds: 10)
        let strictFD = try MCPFramedSocketIO.connectLoopback(port: strictPort, timeoutSeconds: 5)
        defer { Darwin.close(strictFD) }
        let strictHello = try JSONEncoder().encode(MCPJSONValue.object([
            "type": .string("hello"),
            "token": .string(strictTok),
            "bundleID": .string("com.example.game"),
            "pid": .int(Int(getpid()))
        ]))
        try MCPFramedSocketIO.writeFrame(strictHello, to: strictFD)
        let strictAck = (try MCPFramedSocketIO.readFrame(from: strictFD))
            .flatMap { try? JSONDecoder().decode(MCPJSONValue.self, from: $0) }
        #expect(strictAck?.objectValue?.bool("ok") == false)
    }

    @Test
    func ipaInspectionDiagnosticsFilterAndPluginExporter() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macover-mcp-misc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // M-12 (Part A): Reject arbitrary non-.ipa/.app paths
        let txtFile = tmpDir.appendingPathComponent("notes.txt")
        try Data("secret".utf8).write(to: txtFile)
        let badExt = MCPCLIRunner.inspectBinaryOrIPA(atPath: txtFile.path)
        #expect(badExt.isError == true)

        // M-12 (Part A): Reject .app with symlinked Info.plist escaping bundle
        let escapedPlist = tmpDir.appendingPathComponent("outside-Info.plist")
        try Data("<plist/>".utf8).write(to: escapedPlist)
        let fakeApp = tmpDir.appendingPathComponent("Evil.app", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeApp, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fakeApp.appendingPathComponent("Info.plist"),
            withDestinationURL: escapedPlist
        )
        let symAppRes = MCPCLIRunner.inspectBinaryOrIPA(atPath: fakeApp.path)
        #expect(symAppRes.isError == true)

        // M-12 (Part A): Reject ZIP/IPA containing symlink entry
        let zipWork = tmpDir.appendingPathComponent("zipwork", isDirectory: true)
        let payloadApp = zipWork.appendingPathComponent("Payload/Evil.app", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadApp, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: payloadApp.appendingPathComponent("Info.plist"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )
        let evilIPA = tmpDir.appendingPathComponent("evil.ipa")
        let zipProc = Process()
        zipProc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zipProc.currentDirectoryURL = zipWork
        zipProc.arguments = ["-qry", evilIPA.path, "Payload"]
        try zipProc.run()
        zipProc.waitUntilExit()
        #expect(zipProc.terminationStatus == 0)
        let symIPARes = MCPCLIRunner.inspectBinaryOrIPA(atPath: evilIPA.path)
        #expect(symIPARes.isError == true)

        // M-12 (Part A): Valid compressed .ipa extracts Payload/*.app/Info.plist and binary cleanly
        let validWork = tmpDir.appendingPathComponent("validzip", isDirectory: true)
        let validApp = validWork.appendingPathComponent("Payload/Demo.app", isDirectory: true)
        try FileManager.default.createDirectory(at: validApp, withIntermediateDirectories: true)
        let plistDict: [String: Any] = [
            "CFBundleIdentifier": "com.example.demo",
            "CFBundleDisplayName": "Demo App",
            "CFBundleShortVersionString": "1.2.3",
            "MinimumOSVersion": "15.0",
            "CFBundleExecutable": "DemoBin"
        ]
        let plistBytes = try PropertyListSerialization.data(
            fromPropertyList: plistDict,
            format: .xml,
            options: 0
        )
        try plistBytes.write(to: validApp.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/usr/bin/true"),
            to: validApp.appendingPathComponent("DemoBin")
        )
        let validIPA = tmpDir.appendingPathComponent("valid.ipa")
        let validZipProc = Process()
        validZipProc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        validZipProc.currentDirectoryURL = validWork
        validZipProc.arguments = ["-qr", validIPA.path, "Payload"]
        try validZipProc.run()
        validZipProc.waitUntilExit()
        #expect(validZipProc.terminationStatus == 0)
        let validIPARes = await MCPCLIRunner.inspectBinaryOrIPAAsync(atPath: validIPA.path)
        #expect(validIPARes.isError == nil)
        if case .text(let jsonStr) = validIPARes.content.first {
            #expect(jsonStr.contains("com.example.demo"))
            #expect(jsonStr.contains("DemoBin"))
        } else {
            Issue.record("Expected JSON text result from valid IPA inspection")
        }

        // L-01: Atomic plugin export rewrites mcp_config.json with dynamic executable path
        let srcPlugin = tmpDir.appendingPathComponent("src-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: srcPlugin, withIntermediateDirectories: true)
        try Data(#"{"name":"macover-cover-use"}"#.utf8)
            .write(to: srcPlugin.appendingPathComponent("plugin.json"))
        try Data(#"{"mcpServers":{"macover":{"command":"/Applications/MacOver.app/Contents/MacOS/macover-mcp"}}}"#.utf8)
            .write(to: srcPlugin.appendingPathComponent("mcp_config.json"))

        let dstPlugin = tmpDir.appendingPathComponent("exported-plugin", isDirectory: true)
        try FileManager.default.createDirectory(at: dstPlugin, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: dstPlugin.appendingPathComponent("stale.txt"))

        let customCLI = "/Users/tester/Apps/MacOver.app/Contents/MacOS/macover-mcp"
        try MCPAgentPluginExporter.export(from: srcPlugin, to: dstPlugin, executablePath: customCLI)
        #expect(!FileManager.default.fileExists(atPath: dstPlugin.appendingPathComponent("stale.txt").path))
        let exportedCfgData = try Data(contentsOf: dstPlugin.appendingPathComponent("mcp_config.json"))
        let exportedCfg = try #require(
            try JSONSerialization.jsonObject(with: exportedCfgData) as? [String: Any]
        )
        let servers = try #require(exportedCfg["mcpServers"] as? [String: Any])
        let macoverEntry = try #require(servers["macover"] as? [String: Any])
        #expect((macoverEntry["command"] as? String) == customCLI)

        // L-02: Scoped diagnostics logs & strict crash report matching
        let rawLogs = [
            "com.other.app launched at /Users/a/Secret.app",
            "com.example.game failed to initialize shader",
            "com.example.game MACOVER_AUTOMATION_TOKEN=supersecret",
            "com.example.game <key>com.apple.security.app-sandbox</key>",
            "MyGame window resized to 1920x1080"
        ].joined(separator: "\n")
        let scopedLogs = MCPDiagnosticsFilter.filterScopedLogLines(
            rawLog: rawLogs,
            bundleID: "com.example.game",
            appName: "MyGame"
        )
        #expect(scopedLogs.count == 2)
        #expect(scopedLogs.allSatisfy { !$0.contains("com.other.app") && !$0.contains("supersecret") })

        let goodIPS = tmpDir.appendingPathComponent("Runner-2026-11-27-120000.ips")
        try Data(#"{"app_name":"Runner","bundleID":"com.example.game"}"#.utf8).write(to: goodIPS)
        let wrongBundleIPS = tmpDir.appendingPathComponent("Runner-2026-11-27-130000.ips")
        try Data(#"{"app_name":"Runner","bundleID":"com.other.runner"}"#.utf8).write(to: wrongBundleIPS)
        let substringIPS = tmpDir.appendingPathComponent("MyRunnerHelper-2026-11-27-140000.ips")
        try Data(#"{"app_name":"MyRunnerHelper","bundleID":"com.example.game"}"#.utf8).write(to: substringIPS)

        #expect(MCPDiagnosticsFilter.matchesCrashReport(
            fileURL: goodIPS,
            executableName: "Runner",
            bundleID: "com.example.game"
        ) == true)
        #expect(MCPDiagnosticsFilter.matchesCrashReport(
            fileURL: wrongBundleIPS,
            executableName: "Runner",
            bundleID: "com.example.game"
        ) == false)
        #expect(MCPDiagnosticsFilter.matchesCrashReport(
            fileURL: substringIPS,
            executableName: "Runner",
            bundleID: "com.example.game"
        ) == false)
    }

    @Test
    func wave2KeymapSymlinkParentZip64OverflowsRedactionAndExportGuards() throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("macover-mcp-wave2-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmpDir) }

        // HIGH-02: MCPKeymapNameValidator rejects symlinked baseDirectory and out-of-root directories.
        let kmRoot = tmpDir.appendingPathComponent("Keymapping", isDirectory: true)
        let realAppDir = kmRoot.appendingPathComponent("com.example.good", isDirectory: true)
        let outsideDir = tmpDir.appendingPathComponent("Outside", isDirectory: true)
        try fm.createDirectory(at: realAppDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let symAppDir = kmRoot.appendingPathComponent("com.example.evil", isDirectory: true)
        try fm.createSymbolicLink(at: symAppDir, withDestinationURL: outsideDir)

        #expect(MCPKeymapNameValidator.resolvedPlistURL(
            name: "default",
            in: realAppDir,
            keymappingRoot: kmRoot
        ) != nil)
        #expect(MCPKeymapNameValidator.resolvedPlistURL(
            name: "default",
            in: symAppDir,
            keymappingRoot: kmRoot
        ) == nil)
        #expect(MCPKeymapNameValidator.resolvedPlistURL(
            name: "default",
            in: outsideDir,
            keymappingRoot: kmRoot
        ) == nil)

        // HIGH-11: Crafted ZIP64 UInt64 overflow headers throw MCPCLIError instead of SIGTRAP.
        let overflowZ64URL = tmpDir.appendingPathComponent("overflow-z64.ipa")
        try makeCraftedZIP64(z64Offset: UInt64.max - 10).write(to: overflowZ64URL)
        #expect(throws: MCPCLIError.self) {
            let reader = try SafeZIPArchiveReader(url: overflowZ64URL)
            defer { reader.close() }
            _ = try reader.readCentralDirectory()
        }
        #expect(MCPCLIRunner.inspectBinaryOrIPA(atPath: overflowZ64URL.path).isError == true)

        let overflowCDURL = tmpDir.appendingPathComponent("overflow-cd.ipa")
        try makeCraftedZIP64WithOverflowCD(cdOffset: UInt64.max - 10, cdSize: 64).write(to: overflowCDURL)
        #expect(throws: MCPCLIError.self) {
            let reader = try SafeZIPArchiveReader(url: overflowCDURL)
            defer { reader.close() }
            _ = try reader.readCentralDirectory()
        }

        let dummyZip = tmpDir.appendingPathComponent("overflow-entry.ipa")
        try Data(repeating: 0, count: 128).write(to: dummyZip)
        do {
            let reader = try SafeZIPArchiveReader(url: dummyZip)
            defer { reader.close() }
            let overflowLocal = SafeZIPArchiveReader.Entry(
                name: "Payload/A.app/Info.plist",
                compressionMethod: 8,
                compressedSize: 16,
                uncompressedSize: 16,
                localHeaderOffset: UInt64.max - 10
            )
            #expect(throws: MCPCLIError.self) {
                _ = try reader.extractEntry(overflowLocal, maxBytes: 1024)
            }
            let overflowComp = SafeZIPArchiveReader.Entry(
                name: "Payload/A.app/Info.plist",
                compressionMethod: 8,
                compressedSize: UInt64.max - 10,
                uncompressedSize: 16,
                localHeaderOffset: 0
            )
            #expect(throws: MCPCLIError.self) {
                _ = try reader.extractEntry(overflowComp, maxBytes: 1024)
            }
        }

        // MED-05: URLs inside JSON values, "://" text lines, malformed URL ?code=, and jsonPath + grep.
        let malformed = "https://user:pw99@evil.example/cb with space?code=FIRSTSECRET&key=K2&page=1#sig=S3&tab=home"
        let safeMalformed = HeaderRedactor.redactURL(malformed, allowSensitiveHeaders: false)
        #expect(!safeMalformed.contains("pw99"))
        #expect(!safeMalformed.contains("FIRSTSECRET"))
        #expect(!safeMalformed.contains("K2"))
        #expect(!safeMalformed.contains("S3"))
        #expect(safeMalformed.contains("page=1"))
        #expect(safeMalformed.contains("tab=home"))

        let jsonWithURL = Data(
            (
                #"{"redirect_uri":"https://auth.example.com/cb?access_token=tok88&code=c77&page=2","#
                    + #""items":["Axe","Sword"]}"#
            ).utf8
        )
        let extractedRedirect = BodyExtractor.extract(
            rawData: jsonWithURL,
            headers: ["Content-Type": "application/json"],
            jsonPath: "$.redirect_uri",
            redactSensitive: true
        )
        #expect(extractedRedirect?.text.contains("tok88") == false)
        #expect(extractedRedirect?.text.contains("c77") == false)
        #expect(extractedRedirect?.text.contains("page=2") == true)

        let extractedPathAndGrep = BodyExtractor.extract(
            rawData: jsonWithURL,
            headers: ["Content-Type": "application/json"],
            jsonPath: "$.items",
            grep: "Sword",
            redactSensitive: true
        )
        #expect(extractedPathAndGrep?.text.contains("Sword") == true)
        #expect(extractedPathAndGrep?.text.contains("Axe") == false)

        let textWithURL = Data("Visit https://api.example.com/v1?api_key=leakkey&code=leakcode&lang=en now".utf8)
        let extractedText = BodyExtractor.extract(
            rawData: textWithURL,
            headers: ["Content-Type": "text/plain"],
            redactSensitive: true
        )
        #expect(extractedText?.text.contains("leakkey") == false)
        #expect(extractedText?.text.contains("leakcode") == false)
        #expect(extractedText?.text.contains("lang=en") == true)

        // LOW-05: CLI requestTimeout honors >= 65s and macover_wait(timeoutMs: 60000) + grace.
        let runner = MCPCLIRunner()
        #expect(runner.effectiveRequestTimeoutSeconds(for: "macover_apps", arguments: [:]) >= 65.0)
        #expect(runner.effectiveRequestTimeoutSeconds(
            for: "macover_wait",
            arguments: ["timeoutMs": .int(60_000)]
        ) >= 70.0)

        // LOW-20: MCPAgentPluginExporter rejects destinations inside protectedBundleURL or sourceDir.
        let fakeBundle = tmpDir.appendingPathComponent("MacOver.app", isDirectory: true)
        let srcDir = fakeBundle.appendingPathComponent(
            "Contents/Resources/AgentPlugin/macover-cover-use",
            isDirectory: true
        )
        try fm.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: srcDir.appendingPathComponent("plugin.json"))

        #expect(throws: MCPCLIError.self) {
            try MCPAgentPluginExporter.export(
                from: srcDir,
                to: fakeBundle.appendingPathComponent("Contents/Resources/Exported", isDirectory: true),
                executablePath: "/usr/local/bin/macover-mcp",
                protectedBundleURL: fakeBundle
            )
        }
        #expect(throws: MCPCLIError.self) {
            try MCPAgentPluginExporter.export(
                from: srcDir,
                to: srcDir.appendingPathComponent("nested", isDirectory: true),
                executablePath: "/usr/local/bin/macover-mcp",
                protectedBundleURL: nil
            )
        }
    }

    @Test
    func wave2LoopbackAdmissionControlAndParentDirHardening() async throws {
        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
            .appendingPathComponent("macover-mcp-wave2-ipc-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(
            at: tmpDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fm.removeItem(at: tmpDir) }

        // MED-06 (MCP2-16): MCPDaemonSessionFile.read rejects permissive 0755 parent dir and symlink parent dir.
        let sessionURL = tmpDir.appendingPathComponent("daemon.json")
        let dummySession = MCPDaemonSession(port: 12345, token: "tok", pid: getpid(), version: "1.0.10")
        try MCPDaemonSessionFile.write(dummySession, to: sessionURL)
        #expect(Darwin.chmod(tmpDir.path, 0o755) == 0)
        #expect(throws: MCPDaemonSessionFileError.self) {
            _ = try MCPDaemonSessionFile.read(from: sessionURL)
        }
        #expect(Darwin.chmod(tmpDir.path, 0o700) == 0)

        let symParent = fm.temporaryDirectory
            .appendingPathComponent("macover-mcp-symparent-\(UUID().uuidString)", isDirectory: true)
        try fm.createSymbolicLink(at: symParent, withDestinationURL: tmpDir)
        defer { try? fm.removeItem(at: symParent) }
        #expect(throws: MCPDaemonSessionFileError.self) {
            _ = try MCPDaemonSessionFile.read(from: symParent.appendingPathComponent("daemon.json"))
        }

        // MED-06 (MCP2-13): 16 idle TCP connections cannot starve MCPLoopbackServer or MCPBridgeHub.
        let server = MCPLoopbackServer { toolName, _ in
            MCPToolCallResult.text("alive:\(toolName)")
        }
        let (port, token) = try server.start()
        defer { server.stop() }

        var idleLoopbackFDs: [Int32] = []
        defer {
            for fd in idleLoopbackFDs {
                Darwin.close(fd)
            }
        }
        for _ in 0..<16 {
            let idleFD = try MCPFramedSocketIO.connectLoopback(port: port, timeoutSeconds: 2.0)
            idleLoopbackFDs.append(idleFD)
        }
        let liveSession = MCPDaemonSession(port: port, token: token, pid: getpid(), version: "1.0.10")
        let reply = try MCPLoopbackClient.call(
            session: liveSession,
            toolName: "macover_apps",
            arguments: ["op": .string("list")],
            timeoutSeconds: 5.0
        )
        #expect(reply.content == [.text("alive:macover_apps")])

        let hub = MCPBridgeHub()
        let bridgePort = try hub.start()
        defer { hub.stop() }
        let launchToken = hub.issueLaunchToken(for: "com.example.starve", ttlSeconds: 10)

        var idleBridgeFDs: [Int32] = []
        defer {
            for fd in idleBridgeFDs {
                Darwin.close(fd)
            }
        }
        for _ in 0..<16 {
            let idleFD = try MCPFramedSocketIO.connectLoopback(port: bridgePort, timeoutSeconds: 2.0)
            idleBridgeFDs.append(idleFD)
        }
        let realFD = try MCPFramedSocketIO.connectLoopback(port: bridgePort, timeoutSeconds: 5.0)
        defer { Darwin.close(realFD) }
        let hello = try JSONEncoder().encode(MCPJSONValue.object([
            "type": .string("hello"),
            "token": .string(launchToken),
            "bundleID": .string("com.example.starve"),
            "pid": .int(Int(getpid())),
            "logicalWidth": .double(1280),
            "logicalHeight": .double(800)
        ]))
        try MCPFramedSocketIO.writeFrame(hello, to: realFD)
        let ackData = try MCPFramedSocketIO.readFrame(from: realFD)
        let ack = ackData.flatMap { try? JSONDecoder().decode(MCPJSONValue.self, from: $0) }
        #expect(ack?.objectValue?.bool("ok") == true)
    }

    private func makeCraftedZIP64(z64Offset: UInt64) -> Data {
        var data = Data()
        // ZIP64 EOCD Locator (20 bytes)
        appendLE32(&data, 0x0706_4B50)
        appendLE32(&data, 0)
        appendLE64(&data, z64Offset)
        appendLE32(&data, 1)
        // Standard EOCD (22 bytes) with 0xFFFF/0xFFFFFFFF ZIP64 sentinels
        appendLE32(&data, 0x0605_4B50)
        appendLE16(&data, 0)
        appendLE16(&data, 0)
        appendLE16(&data, 0xFFFF)
        appendLE16(&data, 0xFFFF)
        appendLE32(&data, 0xFFFF_FFFF)
        appendLE32(&data, 0xFFFF_FFFF)
        appendLE16(&data, 0)
        return data
    }

    private func makeCraftedZIP64WithOverflowCD(cdOffset: UInt64, cdSize: UInt64) -> Data {
        var data = Data()
        // ZIP64 EOCD at offset 0 (56 bytes)
        appendLE32(&data, 0x0606_4B50)
        appendLE64(&data, 44)
        appendLE16(&data, 45)
        appendLE16(&data, 45)
        appendLE32(&data, 0)
        appendLE32(&data, 0)
        appendLE64(&data, 1)
        appendLE64(&data, 1)
        appendLE64(&data, cdSize)
        appendLE64(&data, cdOffset)
        // ZIP64 EOCD Locator pointing to offset 0 (20 bytes)
        appendLE32(&data, 0x0706_4B50)
        appendLE32(&data, 0)
        appendLE64(&data, 0)
        appendLE32(&data, 1)
        // Standard EOCD (22 bytes)
        appendLE32(&data, 0x0605_4B50)
        appendLE16(&data, 0)
        appendLE16(&data, 0)
        appendLE16(&data, 0xFFFF)
        appendLE16(&data, 0xFFFF)
        appendLE32(&data, 0xFFFF_FFFF)
        appendLE32(&data, 0xFFFF_FFFF)
        appendLE16(&data, 0)
        return data
    }

    private func appendLE16(_ data: inout Data, _ val: UInt16) {
        var le = val.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private func appendLE32(_ data: inout Data, _ val: UInt32) {
        var le = val.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private func appendLE64(_ data: inout Data, _ val: UInt64) {
        var le = val.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
