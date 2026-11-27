//
//  AppQuickInspector.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

private struct InspectorSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Solid tinted capsule for the inspector's primary Launch/Quit CTA, at an exact height so it
/// lines up with the adjacent `…` menu capsule.
private struct InspectorProminentCapsuleStyle: ButtonStyle {
    let tint: Color
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(height: height)
            .background(Capsule().fill(tint.gradient))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

struct AppQuickInspector: View {
    @Environment(PlayCoverDependencies.self) var dependencies
    @Environment(AppNavigationState.self) var navState

    var app: PlayApp
    @Bindable var settings: AppSettings

    @State private var keymapURLs: [URL] = []
    @State private var defaultKeymapURL: URL?

    private var hasPlayTools: Bool { app.hasPlayToolsCached }

    private let presetColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                actionButtonsSection

                if app.isRunning && !app.restartRequiredChanges.isEmpty {
                    restartCallout
                }

                if !hasPlayTools {
                    ConfigStateCallout(
                        style: .noPlayTools,
                        titleKey: "settings.noPlayTools",
                        noteKey: "inspector.noPlayToolsNote",
                        actionKey: "config.pane.plugins",
                        action: { navState.openConfiguration(for: app, pane: .plugins) }
                    )
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.orange.opacity(0.10))
                    )
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    presetsSection
                        .disabled(!hasPlayTools || settings.settings.strictEmulationMode)
                    if settings.settings.strictEmulationMode {
                        StrictLockedNote(
                            textKey: "strict.banner.overviewNote",
                            onOpenStrictMode: { navState.openConfiguration(for: app, pane: .advanced) }
                        )
                    }
                }

                Divider()

                quickTogglesSection

                Divider()

                defaultKeymapSection

                Divider()

                PixelBudgetMeter(
                    budget: settings.settings.pixelBudget,
                    compact: true,
                    onFitToBudget: settings.settings.strictEmulationMode ? nil : { fitted in
                        settings.update { $0.customScaler = fitted }
                    }
                )
            }
            .padding(16)
        }
        .task(id: app.url) {
            app.keymapping.reloadKeymapCache()
            keymapURLs = app.keymapping.keymapConfig.keymapOrder
            defaultKeymapURL = app.keymapping.keymapConfig.defaultKm
        }
    }

    private var headerSection: some View {
        HStack(spacing: 12) {
            AppIconView(app: app, size: 48, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(app.info.bundleVersion)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    switch app.runState {
                    case .preparing(let stage):
                        AppStatusPill(kind: .preparing(stage), compact: true)
                    case .launching:
                        AppStatusPill(kind: .launching, compact: true)
                    case .running(let isActive):
                        AppStatusPill(kind: isActive ? .runningActive : .running, compact: true)
                    case .terminating:
                        AppStatusPill(kind: .terminating, compact: true)
                    case .idle:
                        EmptyView()
                    }
                    if settings.settings.strictEmulationMode {
                        AppStatusPill(kind: .strict, compact: true)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// The CTA, `…` menu and Configure button all draw an exact `actionRowHeight` capsule.
    /// (macOS `Menu` ignores glass button styles and control sizes, so system bezels drift.)
    private let actionRowHeight: CGFloat = 34

    private var actionButtonsSection: some View {
        VStack(spacing: 8) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    primaryActionButton
                    moreActionsMenu
                }
            }

            Button {
                navState.openConfiguration(for: app, pane: .overview)
            } label: {
                Label("action.configure", systemImage: "slider.horizontal.3")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: actionRowHeight)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
    }

    private var primaryActionButton: some View {
        Button {
            if app.isRunning {
                Task { await app.terminate() }
            } else {
                Task(priority: .userInitiated) {
                    if !app.isBusy {
                        await app.launch()
                    }
                }
            }
        } label: {
            Group {
                switch app.runState {
                case .preparing(let stage):
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text(LocalizedStringKey(stage.localizationKey))
                    }
                case .launching:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("app.state.launching")
                    }
                case .terminating:
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                        Text("app.state.terminating")
                    }
                case .running:
                    Label("action.quit", systemImage: "stop.fill")
                case .idle:
                    Label("action.launch", systemImage: "play.fill")
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(InspectorProminentCapsuleStyle(
            tint: (app.isRunning || app.isTerminating) ? .red : .accentColor,
            height: actionRowHeight
        ))
        .disabled(app.isBusy)
    }

    private var moreActionsMenu: some View {
        Menu {
            if app.isRunning {
                Button("action.bringToFront", systemImage: "arrow.up.forward.app") {
                    _ = app.activateRunningApplication()
                }
            }

            Button(
                app.isRunning ? "action.restartSafeMode" : "action.launchSafeMode",
                systemImage: "shield.lefthalf.filled"
            ) {
                Task {
                    if app.isRunning {
                        await app.restart(safeModeOneShot: true)
                    } else if !app.isBusy {
                        await app.launch(safeModeOneShot: true)
                    }
                }
            }
            .disabled(app.isBusy)

            Divider()

            Button("action.configure", systemImage: "slider.horizontal.3") {
                navState.openConfiguration(for: app, pane: .overview)
            }
            Button("action.manageKeymaps", systemImage: "keyboard") {
                navState.openConfiguration(for: app, pane: .input)
            }

            Divider()

            Button("playapp.openCache", systemImage: "folder") {
                app.openAppCache()
            }
            Button("menubar.log.copy", systemImage: "doc.on.doc") {
                dependencies.log.logdata.copyToClipBoard()
                dependencies.toastVM.showToast(
                    toastType: .notice,
                    toastDetails: NSLocalizedString("toast.logsCopied", comment: "")
                )
            }
            Button("playapp.showInFinder", systemImage: "finder") {
                app.showInFinder()
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 40, height: actionRowHeight)
                .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .capsule)
        .frame(width: 40, height: actionRowHeight)
        .help("action.moreActions")
        .accessibilityLabel(Text("action.moreActions"))
    }

    private var restartCallout: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
            Text(String(
                format: NSLocalizedString("restart.bannerTitle", comment: ""),
                app.restartRequiredChanges.count
            ))
            .font(.caption)
            Spacer(minLength: 4)
            Button("action.restart") {
                Task { await app.restart() }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("preset.section")
                .font(.subheadline.weight(.medium))
            LazyVGrid(columns: presetColumns, spacing: 8) {
                ForEach(PlayAppSettingsPreset.allCases) { preset in
                    let active = preset.matches(settings.settings)
                    Button {
                        settings.update { preset.apply(to: &$0) }
                    } label: {
                        Label(LocalizedStringKey(preset.titleKey), systemImage: preset.systemImage)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(active ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(active ? Color.accentColor : Color.clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(LocalizedStringKey(preset.subtitleKey))
                    .accessibilityLabel(Text(LocalizedStringKey(preset.titleKey)))
                    .accessibilityHint(Text(LocalizedStringKey(preset.subtitleKey)))
                    .accessibilityAddTraits(active ? .isSelected : [])
                }
            }
        }
    }

    private var quickTogglesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("inspector.quickControls")
                .font(.subheadline.weight(.medium))
            Toggle("settings.toggle.km", isOn: $settings.settings.keymapping)
                .help("settings.toggle.km.help")
            Toggle("settings.playChain.enable", isOn: $settings.settings.playChain)
            Toggle(
                "settings.toggle.jbBypass",
                isOn: Binding(
                    get: { settings.settings.effectiveBypass },
                    set: { newValue in
                        guard !settings.settings.strictEmulationMode else { return }
                        settings.settings.bypass = newValue
                    }
                )
            )
            .help("settings.toggle.jbBypass.help")
            .disabled(!hasPlayTools || settings.settings.strictEmulationMode)
            Toggle("settings.network.enable", isOn: $settings.settings.enableNetworkRules)
            Toggle("settings.toggle.disableDisplaySleep", isOn: $settings.settings.disableTimeout)
                .help("settings.toggle.disableDisplaySleep.help")
            if settings.settings.strictEmulationMode {
                StrictLockedNote(textKey: "strict.lockedByMode.bypasses")
            }
        }
        .toggleStyle(InspectorSwitchToggleStyle())
        .disabled(!hasPlayTools)
    }

    private var defaultKeymapSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("inspector.defaultKeymap")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 4)
                Button("action.manageKeymaps") {
                    navState.openConfiguration(for: app, pane: .input)
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(!hasPlayTools)
            }
            if keymapURLs.isEmpty {
                Text("inspector.none")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("inspector.defaultKeymap", selection: Binding(
                    get: { defaultKeymapURL ?? keymapURLs.first ?? app.keymapping.keymapConfig.defaultKm },
                    set: { nextURL in
                        defaultKeymapURL = nextURL
                        app.keymapping.keymapConfig.defaultKm = nextURL
                    }
                )) {
                    ForEach(keymapURLs, id: \.self) { url in
                        Text(url.deletingPathExtension().lastPathComponent).tag(url)
                    }
                }
                .labelsHidden()
            }
        }
    }
}
