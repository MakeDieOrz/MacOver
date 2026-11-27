//
//  ConfigOverviewPane.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

struct ConfigOverviewPane: View {
    @Environment(\.locale) private var locale

    var app: PlayApp
    var settings: AppSettings
    let hasPlayTools: Bool
    var onOpenStrictMode: (() -> Void)?
    var onRequestReset: (() -> Void)?

    @State private var showLocalResetConfirm = false

    private let presetColumns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    private var frameRateKey: String {
        switch settings.settings.frameRateTargetMode {
        case .adaptive: return "display.frameRate.adaptive"
        case .fixed120: return "display.frameRate.fixed120"
        case .fixed60: return "display.frameRate.fixed60"
        case .fixed30: return "display.frameRate.fixed30"
        }
    }

    private var reportedIOSKey: String {
        switch settings.settings.reportedIOSVersionMode {
        case .automatic: return "device.reportedIOS.automatic"
        case .followHost: return "device.reportedIOS.followHost"
        case .compat18_3: return "device.reportedIOS.compat18_3"
        case .compat13_7: return "device.reportedIOS.compat13_7"
        }
    }

    private var windowCompatKey: String {
        switch settings.settings.effectiveWindowCompatibility {
        case .standard: return "display.windowCompat.standard"
        case .invertedMetrics: return "display.windowCompat.invertedMetrics"
        case .invertedLegacyResize: return "display.windowCompat.invertedLegacyResize"
        }
    }

    private var hasStatusPills: Bool {
        app.isRunning || settings.settings.strictEmulationMode || !hasPlayTools
    }

    var body: some View {
        Form {
            Section {
                heroBanner
            }

            if settings.settings.strictEmulationMode {
                Section {
                    ConfigStateCallout(
                        style: .strict,
                        titleKey: "strict.banner.title",
                        noteKey: "strict.banner.overviewNote",
                        actionKey: onOpenStrictMode == nil ? nil : "strict.openAdvanced",
                        action: onOpenStrictMode
                    )
                }
            }

            Section("preset.section") {
                LazyVGrid(columns: presetColumns, spacing: 10) {
                    ForEach(PlayAppSettingsPreset.allCases) { preset in
                        PresetCard(
                            preset: preset,
                            isActive: preset.matches(settings.settings),
                            action: {
                                settings.update { preset.apply(to: &$0) }
                            }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .disabled(!hasPlayTools || settings.settings.strictEmulationMode)

            Section("config.overview.summary") {
                let data = settings.settings
                if data.strictEmulationMode {
                    LabeledContent(ConfigLabelFormatter.clean("strict.mode.toggle", locale: locale)) {
                        let orientKey = data.strictViewportOrientation == .portrait
                            ? "strict.orientation.portrait"
                            : "strict.orientation.landscape"
                        let scaleKey = data.strictViewportScaleMode == .native1x
                            ? "strict.scaleMode.native1xShort"
                            : "strict.scaleMode.fitScreenShort"
                        let orientText = ConfigLabelFormatter.localized(orientKey, locale: locale)
                        let scaleText = ConfigLabelFormatter.localized(scaleKey, locale: locale)
                        Text("\(orientText) · \(scaleText)")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                LabeledContent(ConfigLabelFormatter.clean("settings.picker.iosDevice", locale: locale)) {
                    Text(DeviceProfileOption.displayName(for: data.effectiveIOSDeviceModel))
                        .foregroundStyle(.secondary)
                }
                LabeledContent(ConfigLabelFormatter.clean("settings.picker.adaptiveRes", locale: locale)) {
                    let scalerStr = String(format: "%.1f×", data.effectiveCustomScaler)
                    Text("\(data.effectiveWindowWidth)×\(data.effectiveWindowHeight) · \(scalerStr)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent(ConfigLabelFormatter.clean("display.frameRate.title", locale: locale)) {
                    Text(LocalizedStringKey(frameRateKey))
                        .foregroundStyle(.secondary)
                }
                LabeledContent(ConfigLabelFormatter.clean("device.reportedIOS.title", locale: locale)) {
                    Text(LocalizedStringKey(reportedIOSKey))
                        .foregroundStyle(.secondary)
                }
                LabeledContent(ConfigLabelFormatter.clean("display.windowCompat.title", locale: locale)) {
                    Text(LocalizedStringKey(windowCompatKey))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                quickActionsBar
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .alert("config.resetTitle", isPresented: $showLocalResetConfirm) {
            Button("button.Cancel", role: .cancel) {}
            Button("settings.resetSettings", role: .destructive) {
                app.settings.reset()
                PlayCoverDiagnostics.showToast(
                    toastType: .notice,
                    toastDetails: ConfigLabelFormatter.localized("settings.resetSettingsCompleted", locale: locale)
                )
            }
        } message: {
            Text(String(format: ConfigLabelFormatter.localized("config.resetMessage", locale: locale), app.name))
        }
    }

    private var quickActionsBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                safeModeButton(expanded: false)
                    .fixedSize()
                openCacheButton(expanded: false)
                    .fixedSize()
                showInFinderButton(expanded: false)
                    .fixedSize()
                Spacer(minLength: 8)
                resetButton(expanded: false)
                    .fixedSize()
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    safeModeButton(expanded: true)
                    openCacheButton(expanded: true)
                }
                GridRow {
                    showInFinderButton(expanded: true)
                    resetButton(expanded: true)
                }
            }
        }
    }

    private func safeModeButton(expanded: Bool) -> some View {
        Button {
            Task {
                if app.isRunning {
                    await app.restart(safeModeOneShot: true)
                } else if !app.isStarting {
                    await app.launch(safeModeOneShot: true)
                }
            }
        } label: {
            Label("action.launchSafeMode", systemImage: "shield.lefthalf.filled")
                .lineLimit(1)
                .frame(maxWidth: expanded ? .infinity : nil)
        }
        .disabled(!app.isRunning && app.isStarting)
    }

    private func openCacheButton(expanded: Bool) -> some View {
        Button {
            app.openAppCache()
        } label: {
            Text("playapp.openCache")
                .lineLimit(1)
                .frame(maxWidth: expanded ? .infinity : nil)
        }
    }

    private func showInFinderButton(expanded: Bool) -> some View {
        Button {
            app.showInFinder()
        } label: {
            Text("playapp.showInFinder")
                .lineLimit(1)
                .frame(maxWidth: expanded ? .infinity : nil)
        }
    }

    private func resetButton(expanded: Bool) -> some View {
        Button(role: .destructive) {
            if let onRequestReset {
                onRequestReset()
            } else {
                showLocalResetConfirm = true
            }
        } label: {
            Text("settings.resetSettings")
                .lineLimit(1)
                .frame(maxWidth: expanded ? .infinity : nil)
        }
    }

    private var heroBanner: some View {
        HStack(alignment: .center, spacing: 16) {
            AppIconView(app: app, size: 72, cornerRadius: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name)
                    .font(.title2.bold())
                    .lineLimit(2)
                Text("\(app.info.bundleIdentifier) · \(app.info.bundleVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if hasStatusPills {
                    HStack(spacing: 6) {
                        if app.isRunning {
                            AppStatusPill(kind: .running)
                        }
                        if settings.settings.strictEmulationMode {
                            AppStatusPill(kind: .strict)
                        }
                        if !hasPlayTools {
                            AppStatusPill(kind: .noPlayTools)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.18), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .backgroundExtensionEffect()
        }
    }
}
