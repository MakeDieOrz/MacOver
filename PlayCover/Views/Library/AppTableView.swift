//
//  AppTableView.swift
//  PlayCover
//

import AppKit
import PlayCoverCore
import SwiftUI

struct AppTableView: View {
    @Environment(AppsVM.self) var appsVM
    @Environment(AppNavigationState.self) var navState

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
        @Bindable var navState = navState
        Table(sortedApps, selection: $navState.selectedAppID, sortOrder: $sortOrder) {
            TableColumn("library.table.app", value: \.sortName) { app in
                TableAppNameCell(app: app)
            }
            .width(min: 150, ideal: 180, max: 240)

            TableColumn("library.table.version", value: \.sortVersion) { app in
                Text(app.info.bundleVersion)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 60, ideal: 72, max: 90)

            TableColumn("library.table.device", value: \.sortDevice) { app in
                TableAppDeviceCell(app: app)
            }
            .width(min: 205, ideal: 250)

            TableColumn("library.table.pixelLoad", value: \.sortPixelRatio) { app in
                TableAppLoadCell(app: app)
            }
            .width(min: 96, ideal: 112, max: 130)

            TableColumn("library.table.status", value: \.sortRunningRank) { app in
                TableAppStatusCell(app: app)
            }
            .width(min: 76, ideal: 90, max: 120)
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
                  let target = apps.first(where: { $0.id == firstID }) else { return }
            if target.isRunning, target.activateRunningApplication() {
                return
            }
            guard !target.isBusy else { return }
            Task(priority: .userInitiated) {
                await target.launch()
            }
        }
    }
}

private struct TableAppNameCell: View {
    var app: PlayApp

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(app: app, size: 28, cornerRadius: 7)
            Text(app.name)
                .fontWeight(.medium)
                .lineLimit(1)
            if app.isBusy {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

private struct TableAppDeviceCell: View {
    var app: PlayApp

    var body: some View {
        let deviceName = DeviceProfileOption.displayName(for: app.effectiveIOSDeviceModelCached)
        HStack(spacing: 4) {
            if app.strictEmulationModeCached {
                Image(systemName: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .help("strict.banner.title")
                    .accessibilityLabel(Text("strict.banner.title"))
            }
            Text(deviceName)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(deviceName)
    }
}

private struct TableAppLoadCell: View {
    var app: PlayApp

    var body: some View {
        let ratio = app.pixelBudgetRatioCached
        let tint: Color = if ratio >= 1.0 {
            .red
        } else if ratio >= 0.75 {
            .orange
        } else {
            .green
        }
        HStack(spacing: 6) {
            ProgressView(value: min(max(ratio, 0), 1))
                .tint(tint)
                .frame(width: 56)
            Text(String(format: "%.0f%%", ratio * 100))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct TableAppStatusCell: View {
    var app: PlayApp

    var body: some View {
        switch app.runState {
        case .preparing(let stage):
            Label(LocalizedStringKey(stage.localizationKey), systemImage: "hourglass")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
        case .launching:
            Label("app.state.launching", systemImage: "hourglass")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
        case .terminating:
            Label("app.state.terminating", systemImage: "hourglass")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        case .running(let isActive):
            Label(isActive ? "app.state.runningActive" : "sidebar.runningBadge", systemImage: "circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .idle:
            if !app.hasPlayToolsCached {
                Label("library.status.noPlayTools", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            } else {
                Text("library.status.ready")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
