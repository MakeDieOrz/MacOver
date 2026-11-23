//
//  ConfigAdvancedPane.swift
//  PlayCover
//

import SwiftUI

struct ConfigAdvancedPane: View {
    @ObservedObject var app: PlayApp
    @ObservedObject var settings: AppSettings
    let hasPlayTools: Bool
    @Binding var blockingTask: ConfigBlockingTask

    @State private var hasIntrospection: Bool
    @State private var hasIosFrameworks: Bool
    @State private var troubleshootingExpanded = false

    init(
        app: PlayApp,
        settings: AppSettings,
        hasPlayTools: Bool,
        blockingTask: Binding<ConfigBlockingTask>
    ) {
        self.app = app
        self.settings = settings
        self.hasPlayTools = hasPlayTools
        self._blockingTask = blockingTask
        let lsEnv = app.info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? ""
        _hasIntrospection = State(initialValue: lsEnv.contains(PlayApp.introspection))
        _hasIosFrameworks = State(initialValue: lsEnv.contains(PlayApp.iosFrameworks))
    }

    private var troubleshootingCount: Int {
        settings.settings.activeTroubleshootingCount(
            hasIntrospection: hasIntrospection,
            hasIosFrameworks: hasIosFrameworks,
            openWithLLDB: settings.openWithLLDB
        )
    }

    var body: some View {
        Form {
            Section("settings.tab.bypasses") {
                Toggle("settings.playChain.enable", isOn: $settings.settings.playChain)
                    .help("settings.playChain.help")
                    .disabled(!hasPlayTools)

                Toggle("settings.toggle.jbBypass", isOn: $settings.settings.bypass)
                    .help("settings.toggle.jbBypass.help")
                    .disabled(!hasPlayTools)

                rowWithRestartBadge {
                    Toggle("settings.toggle.interceptInlineSyscalls",
                           isOn: $settings.settings.interceptInlineSyscalls)
                        .help("settings.toggle.interceptInlineSyscalls.help")
                        .disabled(!hasPlayTools)
                }

                if settings.settings.interceptInlineSyscalls {
                    Text("settings.toggle.interceptInlineSyscalls.warning")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("settings.toggle.discord") {
                Toggle("settings.toggle.discord", isOn: $settings.settings.discordActivity.enable)
                    .disabled(!hasPlayTools)

                if settings.settings.discordActivity.enable {
                    TextField("settings.text.applicationID", text: $settings.settings.discordActivity.applicationID)
                    TextField("settings.text.details", text: $settings.settings.discordActivity.details)
                        .help("settings.text.details.help")
                    TextField("settings.text.state", text: $settings.settings.discordActivity.state)
                        .help("settings.text.state.help")
                    TextField("settings.text.image", text: $settings.settings.discordActivity.image)
                        .help("settings.text.image.help")
                    Button("settings.button.clearActivity") {
                        settings.update { $0.discordActivity = DiscordActivity() }
                    }
                }
            }

            Section {
                DisclosureGroup(isExpanded: $troubleshootingExpanded) {
                    troubleshootingRows
                } label: {
                    let title = troubleshootingCount > 0
                        ? String(format: NSLocalizedString("advanced.troubleshooting", comment: ""),
                                 troubleshootingCount)
                        : NSLocalizedString("advanced.troubleshootingZero", comment: "")
                    Text(title)
                        .font(.headline)
                }
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onChange(of: app.url) {
            syncDyldStates()
        }
    }

    private func syncDyldStates() {
        let lsEnv = app.info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? ""
        hasIntrospection = lsEnv.contains(PlayApp.introspection)
        hasIosFrameworks = lsEnv.contains(PlayApp.iosFrameworks)
    }

    private func dyldBinding(
        for path: String,
        role: ConfigBlockingTask,
        value: Binding<Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue },
            set: { enabled in
                let currentInPlist = (app.info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? "").contains(path)
                guard blockingTask == .none, enabled != currentInPlist else {
                    syncDyldStates()
                    return
                }
                value.wrappedValue = enabled
                blockingTask = role
                Task {
                    _ = await app.changeDyldLibraryPath(set: enabled, path: path)
                    await MainActor.run {
                        syncDyldStates()
                        blockingTask = .none
                    }
                }
            }
        )
    }

    @ViewBuilder
    private var troubleshootingRows: some View {
        rowWithRestartBadge {
            Toggle("settings.playChain.debugging", isOn: $settings.settings.playChainDebugging)
                .disabled(!settings.settings.playChain || !hasPlayTools)
        }

        rowWithRestartBadge {
            Toggle(
                "settings.toggle.introspection",
                isOn: dyldBinding(
                    for: PlayApp.introspection,
                    role: .introspection,
                    value: $hasIntrospection
                )
            )
            .help("settings.toggle.introspection.help")
            .toggleStyle(ConfigAsyncToggleStyle(activeTask: $blockingTask, role: .introspection))
            .disabled(!hasPlayTools)
        }

        rowWithRestartBadge {
            Toggle(
                "settings.toggle.iosFrameworks",
                isOn: dyldBinding(
                    for: PlayApp.iosFrameworks,
                    role: .iosFrameworks,
                    value: $hasIosFrameworks
                )
            )
            .help("settings.toggle.iosFrameworks.help")
            .toggleStyle(ConfigAsyncToggleStyle(activeTask: $blockingTask, role: .iosFrameworks))
            .disabled(!hasPlayTools)
        }

        Toggle("settings.toggle.checkMicPermissionSync", isOn: $settings.settings.checkMicPermissionSync)
            .help("settings.toggle.checkMicPermissionSync.help")
            .disabled(!hasPlayTools)

        rowWithRestartBadge {
            Toggle("settings.toggle.blockSleepSpamming", isOn: $settings.settings.blockSleepSpamming)
                .help("settings.toggle.blockSleepSpamming.help")
                .disabled(!hasPlayTools)
        }

        rowWithRestartBadge {
            Toggle("settings.toggle.rootWorkDir", isOn: $settings.settings.rootWorkDir)
                .help("settings.toggle.rootWorkDir.help")
                .disabled(!hasPlayTools)
        }

        Toggle("settings.toggle.limitMotionUpdateFrequency", isOn: $settings.settings.limitMotionUpdateFrequency)
            .help("settings.toggle.limitMotionUpdateFrequency.help")
            .disabled(!hasPlayTools)

        rowWithRestartBadge {
            Toggle("settings.toggle.ignoreUnityKeyboardInitializationError",
                   isOn: $settings.settings.ignoreUnityKeyboardInitializationError)
                .help("settings.toggle.ignoreUnityKeyboardInitializationError.help")
                .disabled(!hasPlayTools)
        }

        rowWithRestartBadge {
            Toggle("settings.toggle.hud", isOn: $settings.settings.metalHUD)
        }

        Toggle("settings.toggle.lldb", isOn: $settings.openWithLLDB)
        Toggle("settings.toggle.lldbWithTerminal", isOn: $settings.openLLDBWithTerminal)
            .disabled(!settings.openWithLLDB)
    }

    private func rowWithRestartBadge<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            content()
            Spacer(minLength: 8)
            RestartFieldBadge()
        }
    }
}
