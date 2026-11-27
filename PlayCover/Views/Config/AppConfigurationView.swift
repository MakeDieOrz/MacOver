//
//  AppConfigurationView.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

enum ConfigBlockingTask: Equatable {
    case none
    case playTools
    case introspection
    case iosFrameworks
    case applicationCategoryType
}

enum ConfigLabelFormatter {
    /// Resolves `key` in the `.lproj` matching the SwiftUI `\.locale` environment.
    /// `String(localized:bundle:locale:)` only applies `locale` to format arguments,
    /// so it would silently fall back to the process language instead.
    static func localized(_ key: String, locale: Locale) -> String {
        localizationBundle(for: locale).localizedString(forKey: key, value: nil, table: nil)
    }

    private static func localizationBundle(for locale: Locale) -> Bundle {
        let main = Bundle.main
        guard let language = Bundle.preferredLocalizations(
            from: main.localizations,
            forPreferences: [locale.identifier]
        ).first,
            language != main.preferredLocalizations.first,
            let path = main.path(forResource: language, ofType: "lproj"),
            let bundle = Bundle(path: path) else {
            return main
        }
        return bundle
    }

    /// Trims legacy trailing ASCII/fullwidth colons so grouped Form and Inspector labels
    /// stay visually uniform across English and Simplified Chinese.
    static func clean(_ key: String, locale: Locale) -> String {
        var text = localized(key, locale: locale)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(":") || text.hasSuffix("：") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}

struct ConfigAsyncToggleStyle: ToggleStyle {
    @Binding var activeTask: ConfigBlockingTask
    let role: ConfigBlockingTask

    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            if activeTask == role {
                ProgressView()
                    .controlSize(.small)
            } else {
                Toggle("", isOn: configuration.$isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        } label: {
            configuration.label
        }
    }
}

struct AppConfigurationView: View {
    @Environment(AppNavigationState.self) var navState
    @Environment(\.locale) private var locale

    var app: PlayApp
    var settings: AppSettings

    @State private var hasPlayTools = true
    @State private var blockingTask: ConfigBlockingTask = .none
    @State private var showResetConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            if app.isRunning && !app.restartRequiredChanges.isEmpty {
                restartBanner
            }

            if blockingTask == .playTools {
                playToolsBusyBanner
            }

            if !hasPlayTools {
                noPlayToolsBanner
            }

            Group {
                switch navState.activeConfigPane {
                case .overview:
                    ConfigOverviewPane(
                        app: app,
                        settings: settings,
                        hasPlayTools: hasPlayTools,
                        onOpenStrictMode: { navState.activeConfigPane = .advanced },
                        onRequestReset: { showResetConfirm = true }
                    )
                case .display:
                    ConfigDisplayPane(
                        settings: settings,
                        onOpenStrictMode: { navState.activeConfigPane = .advanced }
                    )
                        .disabled(!hasPlayTools)
                case .device:
                    ConfigDevicePane(
                        settings: settings,
                        onOpenStrictMode: { navState.activeConfigPane = .advanced }
                    )
                        .disabled(!hasPlayTools)
                case .input:
                    ConfigInputPane(app: app, settings: settings)
                        .disabled(!hasPlayTools)
                case .network:
                    ConfigNetworkPane(app: app, settings: settings)
                        .disabled(!hasPlayTools)
                case .plugins:
                    ConfigPluginsPane(
                        app: app,
                        hasPlayTools: $hasPlayTools,
                        blockingTask: $blockingTask
                    )
                case .advanced:
                    ConfigAdvancedPane(
                        app: app,
                        settings: settings,
                        hasPlayTools: hasPlayTools,
                        blockingTask: $blockingTask
                    )
                case .info:
                    ConfigInfoPane(
                        app: app,
                        hasPlayTools: hasPlayTools,
                        blockingTask: $blockingTask
                    )
                }
            }
            .disabled(blockingTask != .none)
        }
        .navigationTitle(
            "\(app.name) — \(ConfigLabelFormatter.localized(navState.activeConfigPane.titleKey, locale: locale))"
        )
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    app.settings.flush()
                    navState.closeConfiguration()
                } label: {
                    Label("sidebar.backToLibrary", systemImage: "chevron.left")
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
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
                    Label(
                        app.isRunning ? "action.quit" : "action.launch",
                        systemImage: app.isRunning ? "stop.fill" : "play.fill"
                    )
                }
                .tint(app.isRunning ? .red : .accentColor)
                .disabled(app.isBusy)

                Menu {
                    Button("action.launchSafeMode", systemImage: "shield.lefthalf.filled") {
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
                    Button("settings.resetSettings", systemImage: "arrow.counterclockwise", role: .destructive) {
                        showResetConfirm = true
                    }
                } label: {
                    Label("action.moreActions", systemImage: "ellipsis")
                }
                .menuIndicator(.hidden)
                .help("action.moreActions")
                .accessibilityLabel("action.moreActions")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItem(placement: .primaryAction) {
                Button {
                    navState.showInspector.toggle()
                } label: {
                    Label("inspector.toggle", systemImage: "sidebar.right")
                }
                .help("inspector.toggle")
            }
        }
        .task(id: app.url) {
            hasPlayTools = app.hasPlayToolsCached
        }
        .onDisappear {
            app.settings.flush()
        }
        .alert("config.resetTitle", isPresented: $showResetConfirm) {
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

    private var restartBanner: some View {
        AdaptiveLeadingTrailingLayout(horizontalSpacing: 10, verticalSpacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                restartBannerIcon
                restartBannerTexts
            }
            restartBannerActions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }

    private var restartBannerIcon: some View {
        Image(systemName: "arrow.clockwise.circle.fill")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
    }

    private var restartBannerTexts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(String(
                format: ConfigLabelFormatter.localized("restart.bannerTitle", locale: locale),
                app.restartRequiredChanges.count
            ))
            .font(.callout.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)

            let fieldTitles = app.restartRequiredChanges
                .prefix(4)
                .map { ConfigLabelFormatter.localized($0.localizedKey, locale: locale) }
                .joined(separator: " · ")
            Text(fieldTitles)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var restartBannerActions: some View {
        HStack(spacing: 8) {
            Button("action.restartSafeMode") {
                Task { await app.restart(safeModeOneShot: true) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()

            Button("action.restart") {
                Task { await app.restart() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
            .fixedSize()
        }
    }

    private var playToolsBusyBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("config.playtools.busyBanner")
                .font(.callout.weight(.medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10))
    }

    private var noPlayToolsBanner: some View {
        ConfigStateCallout(
            style: .noPlayTools,
            titleKey: "settings.noPlayTools",
            noteKey: navState.activeConfigPane == .plugins ? nil : "inspector.noPlayToolsNote",
            actionKey: navState.activeConfigPane == .plugins ? nil : "config.pane.plugins",
            action: { navState.activeConfigPane = .plugins }
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.10))
    }
}
