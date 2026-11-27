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
        appsVM.apps.filter { $0.isRunning || $0.isBusy }
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

    private var isSelectedInLibrary: Bool {
        navState.configTargetID == nil
            && (navState.sidebarDestination ?? .library) == .library
            && navState.selectedAppID == app.id
    }

    var body: some View {
        HStack(spacing: 8) {
            AppIconView(app: app, size: 20, cornerRadius: 5)
            Text(app.name)
                .fontWeight(isSelectedInLibrary ? .semibold : .regular)
                .lineLimit(1)
            Spacer(minLength: 4)
            if app.isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.green)
                    .symbolEffect(.pulse, value: app.runState.isActive)
                    .accessibilityHidden(true)
                Button {
                    _ = app.activateRunningApplication()
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("action.bringToFront")
                .accessibilityLabel(Text("action.bringToFront"))
            }
            Button {
                Task { await app.terminate() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(app.isTerminating)
            .help("sidebar.quit")
            .accessibilityLabel(Text("sidebar.quit"))
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelectedInLibrary ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            navState.closeConfiguration()
            navState.sidebarDestination = .library
            navState.selectedAppID = app.id
        }
        .contextMenu {
            if app.isRunning {
                Button("action.bringToFront", systemImage: "arrow.up.forward.app") {
                    _ = app.activateRunningApplication()
                }
            }
            Button("action.configure", systemImage: "slider.horizontal.3") {
                navState.openConfiguration(for: app, pane: .overview)
            }
            Button("action.quit", systemImage: "stop.fill", role: .destructive) {
                Task { await app.terminate() }
            }
            .disabled(app.isTerminating)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(app.name))
    }
}
