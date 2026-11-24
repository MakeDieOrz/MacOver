//
//  ConfigOverviewPane.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

struct ConfigOverviewPane: View {
    @ObservedObject var app: PlayApp
    @ObservedObject var settings: AppSettings
    let hasPlayTools: Bool
    var onOpenStrictMode: (() -> Void)?

    @State private var showResetConfirm = false

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
                    LabeledContent("strict.mode.toggle") {
                        let orientKey = data.strictViewportOrientation == .portrait
                            ? "strict.orientation.portrait"
                            : "strict.orientation.landscape"
                        let scaleKey = data.strictViewportScaleMode == .native1x
                            ? "strict.scaleMode.native1xShort"
                            : "strict.scaleMode.fitScreenShort"
                        Text("\(NSLocalizedString(orientKey, comment: "")) · "
                             + "\(NSLocalizedString(scaleKey, comment: ""))")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                LabeledContent("settings.picker.iosDevice") {
                    Text(DeviceProfileOption.displayName(for: data.effectiveIOSDeviceModel))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("settings.picker.adaptiveRes") {
                    let scalerStr = String(format: "%.1f×", data.effectiveCustomScaler)
                    Text("\(data.effectiveWindowWidth)×\(data.effectiveWindowHeight) · \(scalerStr)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("display.frameRate.title") {
                    Text(LocalizedStringKey(frameRateKey))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("device.reportedIOS.title") {
                    Text(LocalizedStringKey(reportedIOSKey))
                        .foregroundStyle(.secondary)
                }
                LabeledContent("display.windowCompat.title") {
                    Text(LocalizedStringKey(windowCompatKey))
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack(spacing: 10) {
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
                    }

                    Button("playapp.openCache") {
                        app.openAppCache()
                    }
                    Button("playapp.showInFinder") {
                        app.showInFinder()
                    }
                    Spacer()
                    Button("settings.resetSettings", role: .destructive) {
                        showResetConfirm = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .alert("config.resetTitle", isPresented: $showResetConfirm) {
            Button("button.Cancel", role: .cancel) {}
            Button("settings.resetSettings", role: .destructive) {
                app.settings.reset()
                PlayCoverDiagnostics.showToast(
                    toastType: .notice,
                    toastDetails: NSLocalizedString("settings.resetSettingsCompleted", comment: "")
                )
            }
        } message: {
            Text(String(format: NSLocalizedString("config.resetMessage", comment: ""), app.name))
        }
    }

    private var heroBanner: some View {
        HStack(spacing: 16) {
            AppIconView(app: app, size: 72, cornerRadius: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(app.name)
                        .font(.title2.bold())
                        .lineLimit(2)
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
                Text("\(app.info.bundleIdentifier) · \(app.info.bundleVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
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
