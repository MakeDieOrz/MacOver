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

struct ConfigAsyncToggleStyle: ToggleStyle {
    @Binding var activeTask: ConfigBlockingTask
    let role: ConfigBlockingTask

    func makeBody(configuration: Configuration) -> some View {
        if activeTask == role {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                configuration.label
            }
        } else {
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
        }
    }
}

struct AppConfigurationView: View {
    @EnvironmentObject var navState: AppNavigationState

    @ObservedObject var app: PlayApp
    @ObservedObject var settings: AppSettings

    @State private var hasPlayTools = true
    @State private var blockingTask: ConfigBlockingTask = .none
    @State private var showResetConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            if app.isRunning && !app.restartRequiredChanges.isEmpty {
                restartBanner
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
                        onOpenStrictMode: { navState.activeConfigPane = .advanced }
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
        .navigationTitle("\(app.name) — \(NSLocalizedString(navState.activeConfigPane.titleKey, comment: ""))")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    app.settings.flush()
                    navState.closeConfiguration()
                } label: {
                    Label("sidebar.backToLibrary", systemImage: "chevron.left")
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if app.isRunning {
                    Button {
                        Task { await app.terminate() }
                    } label: {
                        Label("action.quit", systemImage: "stop.fill")
                    }
                    .tint(.red)
                } else {
                    Button {
                        Task(priority: .userInitiated) {
                            if !app.isStarting {
                                await app.launch()
                            }
                        }
                    } label: {
                        Label("action.launch", systemImage: "play.fill")
                    }
                    .tint(.accentColor)
                    .disabled(app.isStarting)
                }

                Menu {
                    Button("action.launchSafeMode", systemImage: "shield.lefthalf.filled") {
                        Task {
                            if app.isRunning {
                                await app.restart(safeModeOneShot: true)
                            } else if !app.isStarting {
                                await app.launch(safeModeOneShot: true)
                            }
                        }
                    }
                    Divider()
                    Button("settings.resetSettings", systemImage: "arrow.counterclockwise", role: .destructive) {
                        showResetConfirm = true
                    }
                } label: {
                    Label("action.moreActions", systemImage: "ellipsis.circle")
                }
                .help("action.moreActions")
            }

            ToolbarSpacer(.fixed, placement: .primaryAction)

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    navState.showInspector.toggle()
                } label: {
                    Label("inspector.toggle", systemImage: "sidebar.right")
                }
                .help("inspector.toggle")
            }
        }
        .task(id: app.url) {
            let executable = app.executable
            let installed = await Task.detached(priority: .background) {
                (try? PlayTools.installedInExec(atURL: executable)) ?? true
            }.value
            hasPlayTools = installed
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
                    toastDetails: NSLocalizedString("settings.resetSettingsCompleted", comment: "")
                )
            }
        } message: {
            Text(String(format: NSLocalizedString("config.resetMessage", comment: ""), app.name))
        }
    }

    private var restartBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(
                    format: NSLocalizedString("restart.bannerTitle", comment: ""),
                    app.restartRequiredChanges.count
                ))
                .font(.callout.weight(.semibold))
                let fieldTitles = app.restartRequiredChanges
                    .prefix(4)
                    .map { NSLocalizedString($0.localizedKey, comment: "") }
                    .joined(separator: " · ")
                Text(fieldTitles)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("action.restartSafeMode") {
                Task { await app.restart(safeModeOneShot: true) }
            }
            .buttonStyle(.bordered)

            Button("action.restart") {
                Task { await app.restart() }
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
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
