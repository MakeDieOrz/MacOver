//
//  LibrarySidebar.swift
//  PlayCover
//

import SwiftUI

struct LibrarySidebar: View {
    @Environment(AppsVM.self) var appsVM
    @Environment(StoreVM.self) var storeVM
    @Environment(AppNavigationState.self) var navState

    @State private var showSources = true

    private var runningApps: [PlayApp] {
        appsVM.apps.filter(\.isRunning)
    }

    var body: some View {
        @Bindable var navState = navState
        List(selection: $navState.sidebarDestination) {
            Section("sidebar.section.library") {
                Label("sidebar.appLibrary", systemImage: "square.grid.2x2")
                    .badge(appsVM.apps.count)
                    .tag(SidebarDestination.library)

                Label("sidebar.ipaLibrary", systemImage: "arrow.down.circle")
                    .tag(SidebarDestination.storeAll)
            }

            if !runningApps.isEmpty {
                Section("sidebar.section.running") {
                    ForEach(runningApps) { app in
                        SidebarRunningAppRow(app: app)
                    }
                }
            }

            let enabledSources = storeVM.getEnabledSources()
            if !enabledSources.isEmpty {
                Section(isExpanded: $showSources) {
                    ForEach(enabledSources, id: \.id) { source in
                        Label(source.name, systemImage: "folder")
                            .badge(source.data.count)
                            .tag(SidebarDestination.storeSource(source.id))
                    }
                } header: {
                    Text("sidebar.section.sources")
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $navState.searchText, placement: .sidebar)
    }
}

private struct SidebarRunningAppRow: View {
    @Environment(AppNavigationState.self) var navState
    var app: PlayApp

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(app: app, size: 20, cornerRadius: 5)
            Text(app.name)
                .lineLimit(1)
            Spacer(minLength: 4)
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
                .symbolEffect(.pulse, value: app.isRunning)
            Button {
                Task { await app.terminate() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("sidebar.quit")
        }
        .contentShape(Rectangle())
        .onTapGesture {
            navState.openConfiguration(for: app, pane: .overview)
        }
    }
}
