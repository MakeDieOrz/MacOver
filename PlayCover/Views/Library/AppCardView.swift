//
//  AppCardView.swift
//  PlayCover
//

import AppKit
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
            Task {
                let didUninstall = await Uninstaller.uninstallPopup(app, dependencies: dependencies)
                if didUninstall && navState.selectedAppID == app.id {
                    navState.selectedAppID = nil
                }
            }
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
    @FocusState private var isFocused: Bool
    @State private var isHovered = false
    @State private var hasPlayTools = true

    private var showsHeaderActions: Bool {
        isHovered || app.isStarting
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBand
                .frame(height: 24)

            Spacer(minLength: 6)

            AppIconView(app: app, size: 76, cornerRadius: 18)

            Spacer(minLength: 8)

            footerBand
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 168)
        .background(cardBackground)
        .overlay(cardBorder)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Only the selected card takes key focus, so macOS' automatic initial focus can
        // never highlight a second, unselected card alongside the selection.
        .focusable(isSelected)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(.return) {
            launchOrActivateApp()
            return .handled
        }
        .onKeyPress(.space) {
            navState.selectedAppID = app.id
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(app.name))
        .accessibilityValue(Text(accessibilityStatus))
        .accessibilityHint(Text(app.isRunning ? "action.quit" : "action.launch"))
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
            withAnimation(.snappy(duration: 0.16)) {
                isHovered = hovering
            }
        }
        .animation(.snappy(duration: 0.16), value: isSelected)
        .gesture(TapGesture(count: 2).onEnded {
            navState.selectedAppID = app.id
            launchOrActivateApp()
        })
        .simultaneousGesture(TapGesture().onEnded {
            navState.selectedAppID = app.id
            DispatchQueue.main.async { isFocused = true }
        })
        .contextMenu {
            PlayAppContextMenu(
                app: app,
                onClearPreferences: onClearPreferences,
                onClearPlayChain: onClearPlayChain
            )
        }
        .onAppear {
            // Give the selected card key focus on appear so Return launches it immediately.
            guard isSelected else { return }
            DispatchQueue.main.async { isFocused = true }
        }
        .task(id: app.url) {
            let executable = app.executable
            let installed = await Task.detached(priority: .background) {
                (try? PlayTools.installedInExec(atURL: executable)) ?? true
            }.value
            hasPlayTools = installed
        }
    }

    private var headerBand: some View {
        HStack(spacing: 4) {
            if app.isRunning {
                AppStatusPill(kind: .running, compact: true)
            } else if !hasPlayTools {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("settings.noPlayTools")
            }

            Spacer(minLength: 4)

            hoverActionBar
                .opacity(showsHeaderActions ? 1 : 0)
                .allowsHitTesting(showsHeaderActions)
        }
    }

    private var footerBand: some View {
        VStack(spacing: 2) {
            Text(app.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
            HStack(spacing: 3) {
                if settings.settings.strictEmulationMode {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(Color.accentColor)
                        .help("strict.banner.title")
                }
                Text(app.info.bundleVersion)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.caption2)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func launchOrActivateApp() {
        if app.isRunning,
           let running = NSRunningApplication.runningApplications(
               withBundleIdentifier: app.info.bundleIdentifier
           ).first(where: { !$0.isTerminated }) {
            _ = running.activate()
            return
        }
        Task(priority: .userInitiated) {
            if !app.isStarting {
                await app.launch()
            }
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
            fillColor = appearsActive ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.13)
        } else if isHovered || isFocused {
            fillColor = Color.secondary.opacity(0.08)
        } else {
            fillColor = Color.clear
        }
        return RoundedRectangle(cornerRadius: 16, style: .continuous).fill(fillColor)
    }

    private var cardBorder: some View {
        let strokeColor: Color
        let lineWidth: CGFloat
        if isSelected {
            strokeColor = appearsActive ? Color.accentColor : Color.secondary.opacity(0.30)
            lineWidth = appearsActive ? 2 : 1
        } else if isFocused {
            strokeColor = Color.accentColor.opacity(0.55)
            lineWidth = 1.5
        } else if isHovered {
            strokeColor = Color.primary.opacity(0.08)
            lineWidth = 1
        } else {
            strokeColor = Color.clear
            lineWidth = 1
        }
        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(strokeColor, lineWidth: lineWidth)
    }

    private var hoverActionBar: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                if app.isStarting {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 22, height: 22)
                        .glassEffect(.regular, in: .circle)
                } else if app.isRunning {
                    Button {
                        Task { await app.terminate() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.red)
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("primary", in: actionNamespace)
                    .help("action.quit")
                    .accessibilityLabel(Text("action.quit"))
                } else {
                    Button {
                        Task(priority: .userInitiated) {
                            await app.launch()
                        }
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("primary", in: actionNamespace)
                    .help("action.launch")
                    .accessibilityLabel(Text("action.launch"))
                }

                Button {
                    navState.openConfiguration(for: app, pane: .overview)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 22, height: 22)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("action.configure")
                .accessibilityLabel(Text("action.configure"))
            }
        }
    }
}
