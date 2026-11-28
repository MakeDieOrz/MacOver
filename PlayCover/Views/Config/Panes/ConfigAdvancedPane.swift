//
//  ConfigAdvancedPane.swift
//  PlayCover
//

import AppKit
import PlayCoverCore
import SwiftUI

struct ConfigAdvancedPane: View {
    @Environment(\.locale) private var locale

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

    private var isAppActiveOrBusy: Bool {
        app.isRunning || app.isBusy
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
        let plistHasIosFrameworks = lsEnv.contains(PlayApp.iosFrameworks)
        _hasIntrospection = State(initialValue: plistHasIntrospection || settings.settings.storedHasIntrospection)
        _hasIosFrameworks = State(initialValue: plistHasIosFrameworks || settings.settings.storedHasIosFrameworks)
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

                Toggle(
                    isOn: effectiveLockedBinding(
                        effective: settings.settings.effectiveInterceptInlineSyscalls,
                        stored: $settings.settings.interceptInlineSyscalls
                    )
                ) {
                    restartLabel("settings.toggle.interceptInlineSyscalls")
                }
                .help("settings.toggle.interceptInlineSyscalls.help")
                .disabled(!hasPlayTools || isStrictMode)

                if settings.settings.effectiveInterceptInlineSyscalls {
                    Text("settings.toggle.interceptInlineSyscalls.warning")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if isStrictMode {
                    StrictLockedNote(textKey: "strict.lockedByMode.bypasses")
                }
            }

            Section("settings.button.discord") {
                Toggle("settings.toggle.discord", isOn: $settings.settings.discordActivity.enable)
                    .disabled(!hasPlayTools)

                if settings.settings.discordActivity.enable {
                    TextField("settings.text.applicationID", text: $settings.settings.discordActivity.applicationID)
                        .textFieldStyle(.roundedBorder)
                    TextField("settings.text.details", text: $settings.settings.discordActivity.details)
                        .textFieldStyle(.roundedBorder)
                        .help("settings.text.details.help")
                    TextField("settings.text.state", text: $settings.settings.discordActivity.state)
                        .textFieldStyle(.roundedBorder)
                        .help("settings.text.state.help")
                    TextField("settings.text.image", text: $settings.settings.discordActivity.image)
                        .textFieldStyle(.roundedBorder)
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
                        ? String(
                            format: ConfigLabelFormatter.localized("advanced.troubleshooting", locale: locale),
                            troubleshootingCount
                        )
                        : ConfigLabelFormatter.localized("advanced.troubleshootingZero", locale: locale)
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
        let plistHasIosFrameworks = lsEnv.contains(PlayApp.iosFrameworks)
        hasIntrospection = plistHasIntrospection || settings.settings.storedHasIntrospection
        hasIosFrameworks = plistHasIosFrameworks || settings.settings.storedHasIosFrameworks
    }

    @ViewBuilder
    private var strictEmulationSection: some View {
        let data = settings.settings
        Section("strict.section.title") {
            Toggle(isOn: $settings.settings.strictEmulationMode) {
                restartLabel("strict.mode.toggle")
            }
            .disabled(!hasPlayTools && !isStrictMode)

            Text("strict.mode.desc")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isStrictMode {
                Picker(selection: $settings.settings.strictViewportOrientation) {
                    Text("strict.orientation.landscape").tag(StrictViewportOrientation.landscape)
                    Text("strict.orientation.portrait").tag(StrictViewportOrientation.portrait)
                } label: {
                    restartLabel("strict.orientation.title")
                }
                .pickerStyle(.segmented)
                .disabled(!hasPlayTools)

                Picker(selection: $settings.settings.strictViewportScaleMode) {
                    Text("strict.scaleMode.fitScreen").tag(StrictViewportScaleMode.fitScreen)
                    Text("strict.scaleMode.native1x").tag(StrictViewportScaleMode.native1x)
                } label: {
                    restartLabel("strict.scaleMode.title")
                }
                .disabled(!hasPlayTools)

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

        LabeledContent(ConfigLabelFormatter.clean("strict.display.targetHardware", locale: locale)) {
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
                    format: ConfigLabelFormatter.localized("strict.fitStatus.fitsNative", locale: locale),
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
                    format: ConfigLabelFormatter.localized("strict.fitStatus.fitScreenActive", locale: locale),
                    logical.width, logical.height, fittedW, fittedH, pct, usableWidth, usableHeight
                ),
                systemImage: "arrow.up.left.and.arrow.down.right.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            Label(
                String(
                    format: ConfigLabelFormatter.localized("strict.fitStatus.nativeExceeds", locale: locale),
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

        Toggle(
            isOn: effectiveLockedBinding(
                effective: settings.settings.effectivePlayChainDebugging,
                stored: $settings.settings.playChainDebugging
            )
        ) {
            restartLabel("settings.playChain.debugging")
        }
        .disabled(!settings.settings.playChain || !hasPlayTools || isStrictMode)

        if isAppActiveOrBusy {
            Label("config.runningLock.advancedNote", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }

        Toggle(
            isOn: Binding(
                get: {
                    settings.settings.effectiveHasIntrospection(hasIntrospection)
                },
                set: { enabled in
                    guard !isStrictMode, !isAppActiveOrBusy, blockingTask == .none else {
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
                    PlayApp.invalidateVerifiedBundleStamp(for: app.url)
                    Task {
                        guard !app.isRunning, !app.isBusy else {
                            await MainActor.run {
                                syncDyldStates()
                                blockingTask = .none
                            }
                            return
                        }
                        _ = await app.changeDyldLibraryPath(set: enabled, path: PlayApp.introspection)
                        PlayApp.invalidateVerifiedBundleStamp(for: app.url)
                        await MainActor.run {
                            syncDyldStates()
                            blockingTask = .none
                        }
                    }
                }
            )
        ) {
            restartLabel("settings.toggle.introspection")
        }
        .help("settings.toggle.introspection.help")
        .toggleStyle(ConfigAsyncToggleStyle(activeTask: $blockingTask, role: .introspection))
        .disabled(!hasPlayTools || isStrictMode || isAppActiveOrBusy)

        Toggle(
            isOn: Binding(
                get: {
                    settings.settings.effectiveHasIosFrameworks(hasIosFrameworks)
                },
                set: { enabled in
                    guard !isStrictMode, !isAppActiveOrBusy, blockingTask == .none else {
                        syncDyldStates()
                        return
                    }
                    settings.update { $0.storedHasIosFrameworks = enabled }
                    let currentInPlist = (app.info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? "")
                        .contains(PlayApp.iosFrameworks)
                    guard enabled != currentInPlist else {
                        syncDyldStates()
                        return
                    }
                    hasIosFrameworks = enabled
                    blockingTask = .iosFrameworks
                    PlayApp.invalidateVerifiedBundleStamp(for: app.url)
                    Task {
                        guard !app.isRunning, !app.isBusy else {
                            await MainActor.run {
                                syncDyldStates()
                                blockingTask = .none
                            }
                            return
                        }
                        _ = await app.changeDyldLibraryPath(set: enabled, path: PlayApp.iosFrameworks)
                        PlayApp.invalidateVerifiedBundleStamp(for: app.url)
                        await MainActor.run {
                            syncDyldStates()
                            blockingTask = .none
                        }
                    }
                }
            )
        ) {
            restartLabel("settings.toggle.iosFrameworks")
        }
        .help("settings.toggle.iosFrameworks.help")
        .toggleStyle(ConfigAsyncToggleStyle(activeTask: $blockingTask, role: .iosFrameworks))
        .disabled(!hasPlayTools || isStrictMode || isAppActiveOrBusy)

        Toggle("settings.toggle.checkMicPermissionSync", isOn: $settings.settings.checkMicPermissionSync)
            .help("settings.toggle.checkMicPermissionSync.help")
            .disabled(!hasPlayTools)

        Toggle(isOn: $settings.settings.blockSleepSpamming) {
            restartLabel("settings.toggle.blockSleepSpamming")
        }
        .help("settings.toggle.blockSleepSpamming.help")
        .disabled(!hasPlayTools)

        Toggle(
            isOn: effectiveLockedBinding(
                effective: settings.settings.effectiveRootWorkDir,
                stored: $settings.settings.rootWorkDir
            )
        ) {
            restartLabel("settings.toggle.rootWorkDir")
        }
        .help("settings.toggle.rootWorkDir.help")
        .disabled(!hasPlayTools || isStrictMode)

        Toggle("settings.toggle.limitMotionUpdateFrequency", isOn: $settings.settings.limitMotionUpdateFrequency)
            .help("settings.toggle.limitMotionUpdateFrequency.help")
            .disabled(!hasPlayTools)

        Toggle(isOn: $settings.settings.ignoreUnityKeyboardInitializationError) {
            restartLabel("settings.toggle.ignoreUnityKeyboardInitializationError")
        }
        .help("settings.toggle.ignoreUnityKeyboardInitializationError.help")
        .disabled(!hasPlayTools)

        Toggle(
            isOn: effectiveLockedBinding(
                effective: settings.settings.effectiveMetalHUD,
                stored: $settings.settings.metalHUD
            )
        ) {
            restartLabel("settings.toggle.hud")
        }
        .disabled(isStrictMode)

        Toggle(
            isOn: Binding(
                get: { settings.effectiveOpenWithLLDB },
                set: { newValue in
                    guard !isStrictMode else { return }
                    settings.openWithLLDB = newValue
                }
            )
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text("settings.toggle.lldb")
                Text("config.advanced.lldbSessionOnly")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(isStrictMode)

        Toggle("settings.toggle.lldbWithTerminal", isOn: $settings.openLLDBWithTerminal)
            .disabled(!settings.effectiveOpenWithLLDB || isStrictMode)
    }

    private func restartLabel(_ titleKey: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Text(titleKey)
            RestartFieldBadge()
        }
    }
}
