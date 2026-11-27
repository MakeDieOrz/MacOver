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
                } else if !app.isBusy {
                    await app.launch()
                }
            }
        }
        .disabled(app.isBusy)
        if app.isRunning {
            Button("action.bringToFront", systemImage: "arrow.up.forward.app") {
                _ = app.activateRunningApplication()
            }
        }
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

    let isSelected: Bool
    let onClearPreferences: (PlayApp) -> Void
    let onClearPlayChain: (PlayApp) -> Void

    @Namespace private var actionNamespace
    @FocusState private var isFocused: Bool
    @State private var isHovered = false

    private var showsHeaderActions: Bool {
        isHovered || app.isBusy
    }

    private var statusPillKind: AppStatusPill.Kind? {
        switch app.runState {
        case .preparing(let stage):
            return .preparing(stage)
        case .launching:
            return .launching
        case .running(let isActive):
            return isActive ? .runningActive : .running
        case .terminating:
            return .terminating
        case .idle:
            return nil
        }
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
                } else if !app.isBusy {
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
        .animation(.snappy(duration: 0.18), value: app.runState)
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
    }

    private var headerBand: some View {
        HStack(spacing: 4) {
            if let statusPillKind {
                AppStatusPill(kind: statusPillKind, compact: true)
            } else if !app.hasPlayToolsCached {
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
                if app.strictEmulationModeCached {
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
        if app.isRunning, app.activateRunningApplication() {
            return
        }
        Task(priority: .userInitiated) {
            if !app.isBusy {
                await app.launch()
            }
        }
    }

    private var accessibilityStatus: String {
        var parts = [app.info.bundleVersion]
        if app.isRunning {
            parts.append(NSLocalizedString("sidebar.runningBadge", comment: ""))
        } else if app.isBusy {
            parts.append(NSLocalizedString("app.state.launching", comment: ""))
        }
        if !app.hasPlayToolsCached {
            parts.append(NSLocalizedString("settings.noPlayTools", comment: ""))
        }
        if app.strictEmulationModeCached {
            parts.append(NSLocalizedString("strict.banner.title", comment: ""))
        }
        return parts.joined(separator: ", ")
    }

    private var cardBackground: some View {
        let fillColor: Color
        if isSelected {
            fillColor = appearsActive ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.13)
        } else if app.isRunning {
            fillColor = Color.green.opacity(app.runState.isActive ? 0.11 : 0.06)
        } else if app.isBusy {
            fillColor = Color.accentColor.opacity(0.08)
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
        } else if app.isRunning {
            strokeColor = Color.green.opacity(app.runState.isActive ? 0.55 : 0.35)
            lineWidth = 1.25
        } else if app.isBusy {
            strokeColor = Color.accentColor.opacity(0.45)
            lineWidth = 1.25
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
                if app.isBusy {
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
