//
//  AppCardView.swift
//  PlayCover
//

import SwiftUI

struct PlayAppContextMenu: View {
    @Environment(PlayCoverDependencies.self) var dependencies
    @Environment(AppNavigationState.self) var navState

    var app: PlayApp
    let onClearPreferences: (PlayApp) -> Void
    let onClearPlayChain: (PlayApp) -> Void

    var body: some View {
        Button(app.isRunning ? "action.quit" : "action.launch",
               systemImage: app.isRunning ? "stop.fill" : "play.fill") {
            Task {
                if app.isRunning {
                    await app.terminate()
                } else if !app.isStarting {
                    await app.launch()
                }
            }
        }
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
        Button("playapp.settings", systemImage: "gear") {
            navState.openConfiguration(for: app, pane: .overview)
        }
        Button("playapp.keymap", systemImage: "keyboard") {
            navState.openConfiguration(for: app, pane: .input)
        }
        Divider()
        Button("playapp.openCache", systemImage: "folder") {
            app.openAppCache()
        }
        Button("playapp.showInFinder", systemImage: "finder") {
            app.showInFinder()
        }
        Divider()
        Button("playapp.clearCache", systemImage: "clear") {
            Task { await Uninstaller.clearCachePopup(app, dependencies: dependencies) }
        }
        Button("playapp.clearPreferences", systemImage: "clear") {
            onClearPreferences(app)
        }
        Button("playapp.clearPlayChain", systemImage: "clear") {
            onClearPlayChain(app)
        }
        Divider()
        Button("playapp.delete", systemImage: "trash", role: .destructive) {
            if navState.selectedAppID == app.id {
                navState.selectedAppID = nil
            }
            Task { await Uninstaller.uninstallPopup(app, dependencies: dependencies) }
        }
    }
}

struct AppCardView: View {
    @Environment(\.appearsActive) private var appearsActive
    @Environment(PlayCoverDependencies.self) var dependencies
    @Environment(AppNavigationState.self) var navState

    var app: PlayApp
    var settings: AppSettings

    let isSelected: Bool
    let onClearPreferences: (PlayApp) -> Void
    let onClearPlayChain: (PlayApp) -> Void

    @Namespace private var actionNamespace
    @State private var isHovered = false
    @State private var hasPlayTools = true

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                AppIconView(app: app, size: 76, cornerRadius: 18)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity)

                if app.isRunning {
                    Label("sidebar.runningBadge", systemImage: "circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.green.opacity(0.16)))
                        .overlay(Capsule().strokeBorder(Color.green.opacity(0.35), lineWidth: 0.5))
                        .symbolEffect(.pulse, value: app.isRunning)
                } else if !hasPlayTools {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(5)
                        .help("settings.noPlayTools")
                }
            }
            .overlay(alignment: .bottom) {
                if isHovered || app.isStarting {
                    hoverActionBar
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
            }

            VStack(spacing: 2) {
                Text(app.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                HStack(spacing: 3) {
                    if settings.settings.strictEmulationMode {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(Color.accentColor)
                            .help("strict.banner.title")
                    }
                    Text(app.info.bundleVersion)
                        .foregroundStyle(.secondary)
                }
                .font(.caption2)
                .lineLimit(1)
            }
        }
        .padding(10)
        .frame(width: 148, height: 152)
        .background(cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    isSelected && appearsActive ? Color.accentColor : Color.clear,
                    lineWidth: 2
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(app.name))
        .accessibilityValue(Text(accessibilityStatus))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            navState.selectedAppID = app.id
        }
        .accessibilityAction(named: Text(app.isRunning ? "action.quit" : "action.launch")) {
            Task(priority: .userInitiated) {
                if app.isRunning {
                    await app.terminate()
                } else if !app.isStarting {
                    await app.launch()
                }
            }
        }
        .accessibilityAction(named: Text("action.configure")) {
            navState.openConfiguration(for: app, pane: .overview)
        }
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.18)) {
                isHovered = hovering
            }
        }
        .gesture(TapGesture(count: 2).onEnded {
            Task(priority: .userInitiated) {
                if !app.isStarting {
                    await app.launch()
                }
            }
        })
        .simultaneousGesture(TapGesture().onEnded {
            navState.selectedAppID = app.id
        })
        .contextMenu {
            PlayAppContextMenu(
                app: app,
                onClearPreferences: onClearPreferences,
                onClearPlayChain: onClearPlayChain
            )
        }
        .task(id: app.url) {
            let executable = app.executable
            let installed = await Task.detached(priority: .background) {
                (try? PlayTools.installedInExec(atURL: executable)) ?? true
            }.value
            hasPlayTools = installed
        }
    }

    private var accessibilityStatus: String {
        var parts = [app.info.bundleVersion]
        if app.isRunning {
            parts.append(NSLocalizedString("sidebar.runningBadge", comment: ""))
        }
        if !hasPlayTools {
            parts.append(NSLocalizedString("settings.noPlayTools", comment: ""))
        }
        if settings.settings.strictEmulationMode {
            parts.append(NSLocalizedString("strict.banner.title", comment: ""))
        }
        return parts.joined(separator: ", ")
    }

    private var cardBackground: some View {
        let fillColor: Color
        if isSelected {
            fillColor = appearsActive ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.14)
        } else if isHovered {
            fillColor = Color.secondary.opacity(0.08)
        } else {
            fillColor = Color.clear
        }
        return RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fillColor)
    }

    private var hoverActionBar: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                if app.isStarting {
                    ProgressView()
                        .controlSize(.small)
                        .padding(6)
                        .glassEffect(.regular, in: .capsule)
                } else if app.isRunning {
                    Button {
                        Task { await app.terminate() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .glassEffectID("primary", in: actionNamespace)
                    .help("action.quit")
                } else {
                    Button {
                        Task(priority: .userInitiated) {
                            await app.launch()
                        }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    .glassEffectID("primary", in: actionNamespace)
                    .help("action.launch")
                }

                Button {
                    navState.openConfiguration(for: app, pane: .overview)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("action.configure")
            }
        }
        .padding(.bottom, 2)
    }
}
