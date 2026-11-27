//
//  InspectorRouter.swift
//  PlayCover
//

import SwiftUI

struct InspectorRouter: View {
    @Environment(AppsVM.self) var appsVM
    @Environment(AppNavigationState.self) var navState

    private var configApp: PlayApp? {
        guard let targetID = navState.configTargetID else { return nil }
        return appsVM.apps.first(where: { $0.id == targetID })
    }

    private var selectedApp: PlayApp? {
        guard let selectedID = navState.selectedAppID else { return nil }
        return appsVM.apps.first(where: { $0.id == selectedID })
    }

    var body: some View {
        if let app = configApp {
            ConfigLivePreview(app: app, settings: app.settings)
        } else {
            switch navState.sidebarDestination ?? .library {
            case .library:
                if let app = selectedApp {
                    AppQuickInspector(app: app, settings: app.settings)
                } else {
                    emptyInspector
                }
            case .storeAll, .storeSource:
                if let storeApp = navState.selectedStoreApp {
                    StoreItemInspector(app: storeApp)
                } else {
                    emptyInspector
                }
            }
        }
    }

    private var emptyInspector: some View {
        ContentUnavailableView {
            Label("inspector.emptyTitle", systemImage: "sidebar.right")
        } description: {
            Text("inspector.emptySubtitle")
        }
    }
}
