//
//  AppQuickInspector.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

struct AppQuickInspector: View {
    @EnvironmentObject var navState: AppNavigationState

    @ObservedObject var app: PlayApp
    @ObservedObject var settings: AppSettings

    @State private var keymapURLs: [URL] = []
    @State private var defaultKeymapURL: URL?

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

                Divider()

                presetsSection

                Divider()

                quickTogglesSection

                Divider()

                defaultKeymapSection

                Divider()

                PixelBudgetMeter(
                    budget: settings.settings.pixelBudget,
                    compact: true,
                    onFitToBudget: { fitted in
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if app.isRunning {
                        Text("ui51.sidebar.runningBadge")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.green.opacity(0.16)))
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var actionButtonsSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                if app.isRunning {
                    Button {
                        Task { await app.terminate() }
                    } label: {
                        Label("ui51.action.quit", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                } else {
                    Button {
                        Task(priority: .userInitiated) {
                            if !app.isStarting {
                                await app.launch()
                            }
                        }
                    } label: {
                        Label("ui51.action.launch", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(app.isStarting)
                }

                Menu {
                    Button("ui51.action.launchSafeMode", systemImage: "shield.lefthalf.filled") {
                        Task {
                            if app.isRunning {
                                await app.restart(safeModeOneShot: true)
                            } else if !app.isStarting {
                                await app.launch(safeModeOneShot: true)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .buttonStyle(.bordered)
                .menuIndicator(.hidden)
            }

            Button {
                navState.openConfiguration(for: app, pane: .overview)
            } label: {
                Label("ui51.action.configure", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
    }

    private var restartCallout: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
            Text(String(
                format: NSLocalizedString("ui51.restart.bannerTitle", comment: ""),
                app.restartRequiredChanges.count
            ))
            .font(.caption)
            Spacer(minLength: 4)
            Button("ui51.action.restart") {
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
            Text("ui51.preset.section")
                .font(.subheadline.weight(.medium))
            LazyVGrid(columns: presetColumns, spacing: 8) {
                ForEach(PlayAppSettingsPreset.allCases) { preset in
                    let active = preset.matches(settings.settings)
                    Button {
                        settings.update { preset.apply(to: &$0) }
                    } label: {
                        Label(LocalizedStringKey(preset.titleKey), systemImage: preset.systemImage)
                            .font(.caption.weight(.medium))
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
                }
            }
        }
    }

    private var quickTogglesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ui51.inspector.quickControls")
                .font(.subheadline.weight(.medium))
            Toggle("settings.toggle.km", isOn: $settings.settings.keymapping)
            Toggle("settings.playChain.enable", isOn: $settings.settings.playChain)
            Toggle("settings.toggle.jbBypass", isOn: $settings.settings.bypass)
            Toggle("settings.network.enable", isOn: $settings.settings.enableNetworkRules)
            Toggle("settings.toggle.disableDisplaySleep", isOn: $settings.settings.disableTimeout)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var defaultKeymapSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ui51.inspector.defaultKeymap")
                .font(.subheadline.weight(.medium))
            if keymapURLs.isEmpty {
                Text("ui51.inspector.none")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("ui51.inspector.defaultKeymap", selection: Binding(
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
