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
                TableAppDeviceCell(settings: app.settings)
            }
            .width(min: 205, ideal: 250)

            TableColumn("library.table.pixelLoad", value: \.sortPixelRatio) { app in
                TableAppLoadCell(settings: app.settings)
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
            if target.isRunning,
               let running = NSRunningApplication.runningApplications(
                   withBundleIdentifier: target.info.bundleIdentifier
               ).first(where: { !$0.isTerminated }) {
                _ = running.activate()
                return
            }
            guard !target.isStarting else { return }
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
            if app.isStarting {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }
}

private struct TableAppDeviceCell: View {
    var settings: AppSettings

    var body: some View {
        let deviceName = DeviceProfileOption.displayName(for: settings.settings.effectiveIOSDeviceModel)
        HStack(spacing: 4) {
            if settings.settings.strictEmulationMode {
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
    var settings: AppSettings

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
    var app: PlayApp
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
