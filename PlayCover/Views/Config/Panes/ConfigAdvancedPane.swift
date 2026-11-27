//
//  ConfigAdvancedPane.swift
//  PlayCover
//

import AppKit
import PlayCoverCore
import SwiftUI

struct ConfigAdvancedPane: View {
    var app: PlayApp
    @Bindable var settings: AppSettings
    let hasPlayTools: Bool
    @Binding var blockingTask: ConfigBlockingTask

    @State private var hasIntrospection: Bool
    @State private var hasIosFrameworks: Bool
    @State private var troubleshootingExpanded = false

    private var isStrictMode: Bool {
        settings.settings.strictEmulationMode
    }

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
        let plistHasIntrospection = lsEnv.contains(PlayApp.introspection)
        _hasIntrospection = State(initialValue: plistHasIntrospection || settings.settings.storedHasIntrospection)
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
            strictEmulationSection

            Section("settings.tab.bypasses") {
                Toggle("settings.playChain.enable", isOn: $settings.settings.playChain)
                    .help("settings.playChain.help")
                    .disabled(!hasPlayTools)

                Toggle(
                    "settings.toggle.jbBypass",
                    isOn: effectiveLockedBinding(
                        effective: settings.settings.effectiveBypass,
                        stored: $settings.settings.bypass
                    )
                )
                    .help("settings.toggle.jbBypass.help")
                    .disabled(!hasPlayTools || isStrictMode)

                rowWithRestartBadge {
                    Toggle(
                        "settings.toggle.interceptInlineSyscalls",
                        isOn: effectiveLockedBinding(
                            effective: settings.settings.effectiveInterceptInlineSyscalls,
                            stored: $settings.settings.interceptInlineSyscalls
                        )
                    )
                        .help("settings.toggle.interceptInlineSyscalls.help")
                        .disabled(!hasPlayTools || isStrictMode)
                }

                if settings.settings.effectiveInterceptInlineSyscalls {
                    Text("settings.toggle.interceptInlineSyscalls.warning")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isStrictMode {
                    StrictLockedNote(textKey: "strict.lockedByMode.bypasses")
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
        .onAppear {
            syncDyldStates()
        }
        .onChange(of: app.url) {
            syncDyldStates()
        }
        .onChange(of: settings.settings.strictEmulationMode) {
            syncDyldStates()
        }
    }

    private func syncDyldStates() {
        let lsEnv = app.info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? ""
        let plistHasIntrospection = lsEnv.contains(PlayApp.introspection)
        hasIntrospection = plistHasIntrospection || settings.settings.storedHasIntrospection
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
    private var strictEmulationSection: some View {
        let data = settings.settings
        Section("strict.section.title") {
            rowWithRestartBadge {
                Toggle("strict.mode.toggle", isOn: $settings.settings.strictEmulationMode)
                    .disabled(!hasPlayTools)
            }

            Text("strict.mode.desc")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isStrictMode {
                rowWithRestartBadge {
                    Picker("strict.orientation.title", selection: $settings.settings.strictViewportOrientation) {
                        Text("strict.orientation.landscape").tag(StrictViewportOrientation.landscape)
                        Text("strict.orientation.portrait").tag(StrictViewportOrientation.portrait)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!hasPlayTools)
                }

                rowWithRestartBadge {
                    Picker("strict.scaleMode.title", selection: $settings.settings.strictViewportScaleMode) {
                        Text("strict.scaleMode.fitScreen").tag(StrictViewportScaleMode.fitScreen)
                        Text("strict.scaleMode.native1x").tag(StrictViewportScaleMode.native1x)
                    }
                    .disabled(!hasPlayTools)
                }

                strictViewportDiagnostics(for: data)
            }
        }
    }

    @ViewBuilder
    private func strictViewportDiagnostics(for data: AppSettingsData) -> some View {
        let spec = data.strictDeviceDisplaySpec
        let logical = data.effectiveLogicalWindowSize
        let pixels = spec.pixelSize(orientation: data.strictViewportOrientation)
        let visibleSize = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size
            ?? CGSize(width: 1440, height: 900)
        let titleBarReserve: CGFloat = data.hideTitleBar ? 0 : 28
        let usableWidth = max(1, Int(visibleSize.width.rounded(.down)))
        let usableHeight = max(1, Int((visibleSize.height - titleBarReserve).rounded(.down)))
        let fitsAt1x = logical.width <= usableWidth && logical.height <= usableHeight

        LabeledContent("strict.display.targetHardware") {
            Text(
                "\(spec.model) · \(logical.width)×\(logical.height) pt @ "
                + "\(Int(spec.nativeScale))× (\(pixels.width)×\(pixels.height) px · \(spec.maxFrameRateHz) Hz)"
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }

        if fitsAt1x {
            Label(
                String(
                    format: NSLocalizedString("strict.fitStatus.fitsNative", comment: ""),
                    logical.width, logical.height, usableWidth, usableHeight
                ),
                systemImage: "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.green)
        } else if data.strictViewportScaleMode == .fitScreen {
            let ratio = min(
                Double(usableWidth) / Double(max(logical.width, 1)),
                Double(usableHeight) / Double(max(logical.height, 1))
            )
            let fittedW = max(1, Int((Double(logical.width) * ratio).rounded()))
            let fittedH = max(1, Int((Double(logical.height) * ratio).rounded()))
            let pct = max(1, Int((ratio * 100.0).rounded()))
            Label(
                String(
                    format: NSLocalizedString("strict.fitStatus.fitScreenActive", comment: ""),
                    logical.width, logical.height, fittedW, fittedH, pct, usableWidth, usableHeight
                ),
                systemImage: "arrow.up.left.and.arrow.down.right.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Label(
                String(
                    format: NSLocalizedString("strict.fitStatus.nativeExceeds", comment: ""),
                    logical.width, logical.height, usableWidth, usableHeight
                ),
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
        }
    }

    private func effectiveLockedBinding(
        effective: Bool,
        stored: Binding<Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { isStrictMode ? effective : stored.wrappedValue },
            set: { newValue in
                guard !isStrictMode else { return }
                stored.wrappedValue = newValue
            }
        )
    }

    @ViewBuilder
    private var troubleshootingRows: some View {
        if isStrictMode {
            StrictLockedNote(textKey: "strict.lockedByMode.troubleshooting")
        }

        rowWithRestartBadge {
            Toggle(
                "settings.playChain.debugging",
                isOn: effectiveLockedBinding(
                    effective: settings.settings.effectivePlayChainDebugging,
                    stored: $settings.settings.playChainDebugging
                )
            )
                .disabled(!settings.settings.playChain || !hasPlayTools || isStrictMode)
        }

        rowWithRestartBadge {
            Toggle(
                "settings.toggle.introspection",
                isOn: Binding(
                    get: {
                        settings.settings.effectiveHasIntrospection(hasIntrospection)
                    },
                    set: { enabled in
                        guard !isStrictMode, blockingTask == .none else {
                            syncDyldStates()
                            return
                        }
                        settings.update { $0.storedHasIntrospection = enabled }
                        let currentInPlist = (app.info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? "")
                            .contains(PlayApp.introspection)
                        guard enabled != currentInPlist else {
                            syncDyldStates()
                            return
                        }
                        hasIntrospection = enabled
                        blockingTask = .introspection
                        Task {
                            _ = await app.changeDyldLibraryPath(set: enabled, path: PlayApp.introspection)
                            await MainActor.run {
                                syncDyldStates()
                                blockingTask = .none
                            }
                        }
                    }
                )
            )
            .help("settings.toggle.introspection.help")
            .toggleStyle(ConfigAsyncToggleStyle(activeTask: $blockingTask, role: .introspection))
            .disabled(!hasPlayTools || isStrictMode)
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
            Toggle(
                "settings.toggle.rootWorkDir",
                isOn: effectiveLockedBinding(
                    effective: settings.settings.effectiveRootWorkDir,
                    stored: $settings.settings.rootWorkDir
                )
            )
                .help("settings.toggle.rootWorkDir.help")
                .disabled(!hasPlayTools || isStrictMode)
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
            Toggle(
                "settings.toggle.hud",
                isOn: effectiveLockedBinding(
                    effective: settings.settings.effectiveMetalHUD,
                    stored: $settings.settings.metalHUD
                )
            )
            .disabled(isStrictMode)
        }

        Toggle(
            "settings.toggle.lldb",
            isOn: Binding(
                get: { settings.effectiveOpenWithLLDB },
                set: { newValue in
                    guard !isStrictMode else { return }
                    settings.openWithLLDB = newValue
                }
            )
        )
        .disabled(isStrictMode)

        Toggle("settings.toggle.lldbWithTerminal", isOn: $settings.openLLDBWithTerminal)
            .disabled(!settings.effectiveOpenWithLLDB || isStrictMode)
    }

    private func rowWithRestartBadge<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            content()
            Spacer(minLength: 8)
            RestartFieldBadge()
        }
    }
}
