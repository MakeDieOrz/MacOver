//
//  AppIconView.swift
//  PlayCover
//

import SwiftUI

struct AppIconView: View {
    @Environment(PlayCoverDependencies.self) var dependencies

    let app: PlayApp
    var size: CGFloat = 64
    var cornerRadius: CGFloat = 15

    @State private var appIcon: NSImage?

    var body: some View {
        Group {
            if let image = appIcon {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.fill.quaternary)
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
        .task(id: app.url) {
            let bundleIdentifier = app.info.bundleIdentifier
            let bundleVersion = app.info.bundleVersion
            if let cached = dependencies.cacher.getCachedMemoryIcon(
                bundleIdentifier: bundleIdentifier,
                bundleVersion: bundleVersion
            ) {
                appIcon = cached
                return
            }
            let cacher = dependencies.cacher
            let appURL = app.url
            let primaryIconName = app.info.primaryIconName
            let iconData = await Task.detached(priority: .utility) {
                cacher.resolveLocalIconData(
                    at: appURL,
                    bundleIdentifier: bundleIdentifier,
                    bundleVersion: bundleVersion,
                    primaryIconName: primaryIconName
                )
            }.value
            appIcon = iconData.flatMap(NSImage.init(data:))
        }
    }
}

struct StoreAppIconView: View {
    @Environment(PlayCoverDependencies.self) var dependencies

    let app: SourceAppsData
    var size: CGFloat = 64
    var cornerRadius: CGFloat = 15

    @State private var onlineIcon: String?
    @State private var loadedRemoteImage: NSImage?
    @State private var localIcon: NSImage?
    @State private var finishedFallbackWait = false

    private var placeholderView: some View {
        Group {
            if let localIcon {
                Image(nsImage: localIcon)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.fill.quaternary)
                    .overlay {
                        if finishedFallbackWait {
                            Image(systemName: "app.dashed")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                    .task(id: app.bundleID) {
                        finishedFallbackWait = false
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        finishedFallbackWait = true
                    }
            }
        }
    }

    var body: some View {
        Group {
            if let loadedRemoteImage {
                Image(nsImage: loadedRemoteImage)
                    .resizable()
                    .scaledToFit()
            } else {
                placeholderView
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
        .task(id: app.itunesLookup) {
            loadedRemoteImage = nil
            let cache = dependencies.cacher.cache
            if !cache.hasData(forKey: app.itunesLookup) {
                await dependencies.cacher.resolveITunesData(app.itunesLookup)
            }
            if let response: ITunesResponse = try? cache.readCodable(forKey: app.itunesLookup),
               let artwork = response.results.first?.artworkUrl512 {
                onlineIcon = artwork
                loadedRemoteImage = await dependencies.cacher.loadRemoteImage(from: artwork)
            } else {
                localIcon = dependencies.cacher.getLocalIcon(bundleId: app.bundleID)
            }
        }
    }
}
