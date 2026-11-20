//
//  ConfigSidebar.swift
//  PlayCover
//

import SwiftUI

struct ConfigSidebar: View {
    @EnvironmentObject var navState: AppNavigationState

    @ObservedObject var app: PlayApp
    @ObservedObject var settings: AppSettings

    private var troubleshootingCount: Int {
        let lsEnv = app.info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? ""
        return settings.settings.activeTroubleshootingCount(
            hasIntrospection: lsEnv.contains(PlayApp.introspection),
            hasIosFrameworks: lsEnv.contains(PlayApp.iosFrameworks),
            openWithLLDB: settings.openWithLLDB
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                app.settings.flush()
                navState.closeConfiguration()
            } label: {
                Label("sidebar.backToLibrary", systemImage: "chevron.left")
                    .font(.callout.weight(.medium))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("[", modifiers: .command)
            .padding(.horizontal, 14)
            .padding(.top, 8)

            HStack(spacing: 10) {
                AppIconView(app: app, size: 36, cornerRadius: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(app.info.bundleVersion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if app.isRunning {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 14)

            List(ConfigPane.allCases, selection: $navState.activeConfigPane) { pane in
                Label(LocalizedStringKey(pane.titleKey), systemImage: pane.systemImage)
                    .badge(badgeValue(for: pane))
                    .tag(pane)
            }
            .listStyle(.sidebar)
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
