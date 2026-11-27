//
//  ConfigSidebar.swift
//  PlayCover
//

import SwiftUI

struct ConfigSidebar: View {
    @Environment(AppNavigationState.self) var navState

    var app: PlayApp
    var settings: AppSettings

    @State private var isBackHovered = false

    private var troubleshootingCount: Int {
        let lsEnv = app.info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? ""
        return settings.settings.activeTroubleshootingCount(
            hasIntrospection: lsEnv.contains(PlayApp.introspection) || settings.settings.storedHasIntrospection,
            hasIosFrameworks: lsEnv.contains(PlayApp.iosFrameworks) || settings.settings.storedHasIosFrameworks,
            openWithLLDB: settings.openWithLLDB
        )
    }

    var body: some View {
        @Bindable var navState = navState
        VStack(alignment: .leading, spacing: 10) {
            Button {
                app.settings.flush()
                navState.closeConfiguration()
            } label: {
                Label("sidebar.backToLibrary", systemImage: "chevron.left")
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(isBackHovered ? Color.secondary.opacity(0.14) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.snappy(duration: 0.14)) {
                    isBackHovered = hovering
                }
            }
            .help("sidebar.backToLibrary")
            .padding(.horizontal, 10)
            .padding(.top, 8)

            HStack(spacing: 10) {
                AppIconView(app: app, size: 36, cornerRadius: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(app.info.bundleVersion)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if settings.settings.strictEmulationMode {
                    Image(systemName: "lock.shield.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .help("strict.banner.title")
                        .accessibilityLabel(Text("strict.banner.title"))
                }
                if app.isRunning {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.green)
                        .symbolEffect(.pulse, value: app.isRunning)
                        .help("sidebar.runningBadge")
                        .accessibilityLabel(Text("sidebar.runningBadge"))
                }
            }
            .padding(.horizontal, 14)

            List(ConfigPane.allCases, selection: $navState.activeConfigPane) { pane in
                Label {
                    HStack(spacing: 4) {
                        Text(LocalizedStringKey(pane.titleKey))
                        if isLockedByStrictMode(pane) {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help("strict.lockedPane.help")
                                .accessibilityLabel(Text("strict.lockedPane.help"))
                        }
                    }
                } icon: {
                    Image(systemName: pane.systemImage)
                }
                .badge(badgeValue(for: pane))
                .tag(pane)
            }
            .listStyle(.sidebar)
        }
    }

    private func isLockedByStrictMode(_ pane: ConfigPane) -> Bool {
        guard settings.settings.strictEmulationMode else { return false }
        switch pane {
        case .overview, .display, .device, .advanced:
            return true
        default:
            return false
        }
    }

    private func badgeValue(for pane: ConfigPane) -> Int {
        switch pane {
        case .network:
            return settings.settings.enableNetworkRules ? settings.settings.blockedURLPatterns.count : 0
        case .advanced:
            return troubleshootingCount
        default:
            return 0
        }
    }
}
