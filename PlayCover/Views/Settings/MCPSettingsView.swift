import AppKit
import PlayCoverMCP
import SwiftUI

struct MCPSettingsView: View {
    @Environment(MCPHostCoordinator.self) private var mcpCoordinator
    @Environment(MCPPreferences.self) private var mcpPreferences

    @State private var copiedConfig = false
    @State private var exportMessage: String?
    @State private var copyFeedbackResetTask: Task<Void, Never>?

    var body: some View {
        @Bindable var prefs = mcpPreferences

        Form {
            Section("settings.mcp.serverSection") {
                Toggle("settings.mcp.enableServer", isOn: Binding(
                    get: { prefs.isEnabled },
                    set: { mcpCoordinator.setEnabled($0) }
                ))

                LabeledContent("settings.mcp.statusLabel") {
                    if mcpCoordinator.isRunning, let port = mcpCoordinator.daemonPort {
                        Text("127.0.0.1:\(port)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.green)
                    } else {
                        Text("settings.mcp.statusStopped")
                            .foregroundStyle(.secondary)
                    }
                }

                if !mcpCoordinator.connectedBridgeBundleIDs.isEmpty {
                    LabeledContent("settings.mcp.connectedBridges") {
                        Text(mcpCoordinator.connectedBridgeBundleIDs.joined(separator: ", "))
                            .font(.callout.monospaced())
                            .foregroundStyle(.blue)
                    }
                }

                if let error = mcpCoordinator.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Text("settings.mcp.serverNote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.mcp.accessibilitySection") {
                LabeledContent("settings.mcp.axPermission") {
                    HStack(spacing: 10) {
                        Text(mcpCoordinator.axTrusted ? "settings.mcp.axGranted" : "settings.mcp.axNotGranted")
                            .fontWeight(.medium)
                            .foregroundStyle(mcpCoordinator.axTrusted ? .green : .orange)

                        if !mcpCoordinator.axTrusted {
                            Button("settings.mcp.grantAX") {
                                _ = mcpCoordinator.refreshAXTrustStatus(prompt: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }

                        Button("settings.mcp.refresh") {
                            _ = mcpCoordinator.refreshAXTrustStatus(prompt: false)
                        }
                        .controlSize(.small)
                    }
                }

                Button("settings.mcp.openSystemSettings") {
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)

                Text("settings.mcp.axNote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.mcp.securitySection") {
                Toggle("settings.mcp.allowSensitiveHeaders", isOn: $prefs.allowSensitiveHeaders)
                Text("settings.mcp.securityNote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.mcp.integrationSection") {
                HStack(spacing: 12) {
                    Button {
                        copyMCPConfigToPasteboard()
                    } label: {
                        Label(
                            copiedConfig ? "settings.mcp.copied" : "settings.mcp.copyConfig",
                            systemImage: copiedConfig ? "checkmark" : "doc.on.doc"
                        )
                    }

                    Button {
                        exportAgentPlugin()
                    } label: {
                        Label("settings.mcp.exportPlugin", systemImage: "square.and.arrow.up")
                    }
                }

                if let exportMessage {
                    Text(exportMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            _ = mcpCoordinator.refreshAXTrustStatus(prompt: false)
        }
        .onDisappear {
            copyFeedbackResetTask?.cancel()
            copyFeedbackResetTask = nil
        }
    }

    private func mcpCliExecutablePath() -> String {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/macover-mcp")
        if FileManager.default.fileExists(atPath: bundled.path) {
            return bundled.path
        }
        return "/Applications/MacOver.app/Contents/MacOS/macover-mcp"
    }

    private func copyMCPConfigToPasteboard() {
        let payload: [String: Any] = [
            "mcpServers": [
                "macover": [
                    "command": mcpCliExecutablePath(),
                    "args": []
                ]
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(json, forType: .string)
            copyFeedbackResetTask?.cancel()
            copiedConfig = true
            copyFeedbackResetTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                copiedConfig = false
            }
        }
    }

    private func exportAgentPlugin() {
        guard let sourceDir = Bundle.main.resourceURL?
            .appendingPathComponent("AgentPlugin", isDirectory: true)
            .appendingPathComponent("macover-cover-use", isDirectory: true),
              FileManager.default.fileExists(atPath: sourceDir.path) else {
            exportMessage = NSLocalizedString(
                "settings.mcp.exportPluginMissing",
                value: "Built-in agent plugin directory not found in MacOver.app Resources.",
                comment: ""
            )
            return
        }

        let executablePath = mcpCliExecutablePath()
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "macover-cover-use"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                try MCPAgentPluginExporter.export(
                    from: sourceDir,
                    to: destination,
                    executablePath: executablePath,
                    protectedBundleURL: Bundle.main.bundleURL
                )
                exportMessage = destination.path
            } catch {
                exportMessage = error.localizedDescription
            }
        }
    }
}
