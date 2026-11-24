//
//  AppTableView.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

struct AppTableView: View {
    @EnvironmentObject var appsVM: AppsVM
    @EnvironmentObject var navState: AppNavigationState

    let apps: [PlayApp]
    let onClearPreferences: (PlayApp) -> Void
    let onClearPlayChain: (PlayApp) -> Void

    @State private var sortOrder: [KeyPathComparator<PlayApp>] = [
        KeyPathComparator(\PlayApp.sortRunningRank),
        KeyPathComparator(\PlayApp.sortName)
    ]

    private var sortedApps: [PlayApp] {
        apps.sorted(using: sortOrder)
    }

    var body: some View {
        Table(sortedApps, selection: $navState.selectedAppID, sortOrder: $sortOrder) {
            TableColumn("library.table.app", value: \.sortName) { app in
                TableAppNameCell(app: app)
            }
            .width(min: 180, ideal: 240)

            TableColumn("library.table.version", value: \.sortVersion) { app in
                Text(app.info.bundleVersion)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 95)

            TableColumn("library.table.device", value: \.sortDevice) { app in
                TableAppDeviceCell(settings: app.settings)
            }
            .width(min: 140, ideal: 190)

            TableColumn("library.table.pixelLoad", value: \.sortPixelRatio) { app in
                TableAppLoadCell(settings: app.settings)
            }
            .width(min: 110, ideal: 140)

            TableColumn("library.table.status", value: \.sortRunningRank) { app in
                TableAppStatusCell(app: app)
            }
            .width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: PlayApp.ID.self) { selectedIDs in
            if let firstID = selectedIDs.first,
               let target = apps.first(where: { $0.id == firstID }) {
                PlayAppContextMenu(
                    app: target,
                    onClearPreferences: onClearPreferences,
                    onClearPlayChain: onClearPlayChain
                )
            }
        } primaryAction: { selectedIDs in
            guard let firstID = selectedIDs.first,
                  let target = apps.first(where: { $0.id == firstID }),
                  !target.isStarting else { return }
            Task(priority: .userInitiated) {
                await target.launch()
            }
        }
    }
}

private struct TableAppNameCell: View {
    @ObservedObject var app: PlayApp

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(app: app, size: 28, cornerRadius: 7)
            Text(app.name)
                .fontWeight(.medium)
                .lineLimit(1)
            if app.isStarting {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

private struct TableAppDeviceCell: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Text(DeviceProfileOption.displayName(for: settings.settings.effectiveIOSDeviceModel))
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct TableAppLoadCell: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        let budget = settings.settings.pixelBudget
        let tint: Color = switch budget.level {
        case .ok: .green
        case .caution: .orange
        case .over: .red
        }
        HStack(spacing: 6) {
            ProgressView(value: min(max(budget.ratio, 0), 1))
                .tint(tint)
                .frame(width: 56)
            Text(String(format: "%.0f%%", budget.ratio * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct TableAppStatusCell: View {
    @ObservedObject var app: PlayApp
    @State private var hasPlayTools = true

    var body: some View {
        Group {
            if app.isRunning {
                Label("sidebar.runningBadge", systemImage: "circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            } else if !hasPlayTools {
                Label("library.status.noPlayTools", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            } else {
                Text("library.status.ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: app.url) {
            let executable = app.executable
            let installed = await Task.detached(priority: .background) {
                (try? PlayTools.installedInExec(atURL: executable)) ?? true
            }.value
            hasPlayTools = installed
        }
    }
}
