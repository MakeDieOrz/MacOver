import Foundation

public struct MCPToolDescriptor: Equatable, Sendable, Codable {
    public let name: String
    public let description: String
    public let inputSchema: MCPJSONValue

    public init(name: String, description: String, inputSchema: MCPJSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum MCPToolRegistry {
    public static let maxToolsSchemaTokenBudget = 1_600

    public static let tools: [MCPToolDescriptor] = [
        MCPToolDescriptor(
            name: "macover_apps",
            description: "Manage iOS apps or inspect IPA/app binaries.",
            inputSchema: schema(
                props: [
                    "op": enumProp(["list", "launch", "stop", "restart", "focus", "inspect_ipa"]),
                    "bundleID": strProp(),
                    "path": strProp(),
                    "bridge": boolProp(),
                    "safeMode": boolProp(),
                    "debugTrace": boolProp(),
                    "enableMITM": boolProp()
                ],
                required: ["op"]
            )
        ),
        MCPToolDescriptor(
            name: "macover_settings",
            description: "Read or patch per-app MacOver settings.",
            inputSchema: schema(
                props: [
                    "op": enumProp(["get", "patch"]),
                    "bundleID": strProp(),
                    "keys": strArrayProp(),
                    "nonDefaultOnly": boolProp(),
                    "patch": objProp()
                ],
                required: ["op", "bundleID"]
            )
        ),
        MCPToolDescriptor(
            name: "macover_ui_snapshot",
            description: "Capture compact AX-DSL tree or incremental diff.",
            inputSchema: schema(
                props: [
                    "bundleID": strProp(),
                    "source": enumProp(["auto", "ax", "bridge"]),
                    "interactiveOnly": boolProp(),
                    "viewportOnly": boolProp(),
                    "query": strProp(),
                    "roles": strArrayProp(),
                    "scopeRef": strProp(),
                    "maxNodes": intProp(),
                    "maxDepth": intProp(),
                    "bounds": enumProp(["none", "center", "rect"]),
                    "diff": boolProp(),
                    "sinceRev": intProp()
                ],
                required: ["bundleID"]
            )
        ),
        MCPToolDescriptor(
            name: "macover_act",
            description: "Run AX semantic or Bridge touch action(s) and return diff.",
            inputSchema: schema(
                props: [
                    "bundleID": strProp(),
                    "action": enumProp([
                        "press", "set_value", "input", "scroll_to", "menu",
                        "increment", "decrement", "tap", "long_press", "swipe", "drag", "pinch"
                    ]),
                    "ref": strProp(),
                    "rev": intProp(),
                    "x": numProp(),
                    "y": numProp(),
                    "nx": numProp(),
                    "ny": numProp(),
                    "toX": numProp(),
                    "toY": numProp(),
                    "toNx": numProp(),
                    "toNy": numProp(),
                    "text": strProp(),
                    "clear": boolProp(),
                    "durationMs": intProp(),
                    "scale": numProp(),
                    "steps": .object(["type": .string("array"), "items": .object(["type": .string("object")])]),
                    "source": enumProp(["auto", "ax", "bridge"]),
                    "settleMs": intProp(),
                    "observe": enumProp(["diff", "snapshot", "none"])
                ],
                required: ["bundleID"]
            )
        ),
        MCPToolDescriptor(
            name: "macover_wait",
            description: "Wait locally in host for UI, app, or MITM traffic condition.",
            inputSchema: schema(
                props: [
                    "bundleID": strProp(),
                    "condition": enumProp([
                        "textAppears", "textDisappears", "refExists", "networkMatch", "appReady"
                    ]),
                    "value": strProp(),
                    "host": strProp(),
                    "path": strProp(),
                    "status": intProp(),
                    "timeoutMs": intProp(),
                    "pollMs": intProp(),
                    "observe": enumProp(["diff", "snapshot", "none"])
                ],
                required: ["bundleID", "condition"]
            )
        ),
        MCPToolDescriptor(
            name: "macover_screenshot",
            description: "Visual fallback screenshot with crop and size limits.",
            inputSchema: schema(
                props: [
                    "bundleID": strProp(),
                    "source": enumProp(["auto", "bridge", "window"]),
                    "clipRef": strProp(),
                    "rev": intProp(),
                    "clipNorm": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "x": numProp(), "y": numProp(), "w": numProp(), "h": numProp()
                        ])
                    ]),
                    "maxDim": intProp(),
                    "format": enumProp(["jpeg", "png"]),
                    "quality": numProp(),
                    "overlayRefs": boolProp()
                ],
                required: ["bundleID"]
            )
        ),
        MCPToolDescriptor(
            name: "macover_network",
            description: "Inspect or clear built-in MITM captures.",
            inputSchema: schema(
                props: [
                    "bundleID": strProp(),
                    "op": enumProp(["list", "detail", "clear"]),
                    "id": strProp(),
                    "host": strProp(),
                    "path": strProp(),
                    "method": strProp(),
                    "status": intProp(),
                    "disposition": strProp(),
                    "limit": intProp(),
                    "maxBodyBytes": intProp(),
                    "jsonPath": strProp(),
                    "grep": strProp()
                ],
                required: ["bundleID", "op"]
            )
        ),
        MCPToolDescriptor(
            name: "macover_network_rules",
            description: "Get or live-update MITM proxy and URL block rules.",
            inputSchema: schema(
                props: [
                    "bundleID": strProp(),
                    "op": enumProp(["get", "add", "remove", "set"]),
                    "patterns": strArrayProp(),
                    "enableNetworkRules": boolProp(),
                    "networkBlockMock200": boolProp(),
                    "mitmAllHosts": boolProp(),
                    "mitmHostPatterns": strArrayProp()
                ],
                required: ["bundleID", "op"]
            )
        ),
        MCPToolDescriptor(
            name: "macover_diagnostics",
            description: "Read filtered runtime, Mach-O, Safe Mode, logs, or crashes.",
            inputSchema: schema(
                props: [
                    "bundleID": strProp(),
                    "sections": strArrayProp(),
                    "logLines": intProp(),
                    "logFilter": strProp()
                ],
                required: ["bundleID"]
            )
        ),
        MCPToolDescriptor(
            name: "macover_keymap",
            description: "List, read, write, or validate .playmap keymaps.",
            inputSchema: schema(
                props: [
                    "bundleID": strProp(),
                    "op": enumProp(["list", "get", "put", "validate"]),
                    "name": strProp(),
                    "keymap": objProp()
                ],
                required: ["bundleID", "op"]
            )
        )
    ]

    public static func toolsListPayload() -> MCPJSONValue {
        .object([
            "tools": .array(tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema
                ])
            })
        ])
    }

    public static func estimatedSchemaTokenCount() -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(toolsListPayload()) else {
            return Int.max
        }
        return Int(ceil(Double(data.count) / 3.5))
    }

    private static func schema(props: [String: MCPJSONValue], required: [String]) -> MCPJSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(props),
            "required": .array(required.map { .string($0) })
        ])
    }

    private static func strProp() -> MCPJSONValue {
        .object(["type": .string("string")])
    }

    private static func boolProp() -> MCPJSONValue {
        .object(["type": .string("boolean")])
    }

    private static func intProp() -> MCPJSONValue {
        .object(["type": .string("integer")])
    }

    private static func numProp() -> MCPJSONValue {
        .object(["type": .string("number")])
    }

    private static func objProp() -> MCPJSONValue {
        .object(["type": .string("object")])
    }

    private static func strArrayProp() -> MCPJSONValue {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")])
        ])
    }

    private static func enumProp(_ values: [String]) -> MCPJSONValue {
        .object([
            "type": .string("string"),
            "enum": .array(values.map { .string($0) })
        ])
    }
}
