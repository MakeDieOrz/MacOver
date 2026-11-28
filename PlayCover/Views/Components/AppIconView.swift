//
//  AppIconView.swift
//  PlayCover
//

import SwiftUI

private struct LoadedAppIcon {
    let key: String
    let image: NSImage
}

struct AppIconView: View {
    @Environment(PlayCoverDependencies.self) var dependencies

    let app: PlayApp
    var size: CGFloat = 64
    var cornerRadius: CGFloat = 15

    @State private var loadedIcon: LoadedAppIcon?
    @State private var completedLoadKey: String?

    private var iconKey: String {
        "\(app.url.path)|\(app.info.bundleIdentifier)|\(app.info.bundleVersion)"
    }

    private var displayedIcon: NSImage? {
        if let loadedIcon, loadedIcon.key == iconKey {
            return loadedIcon.image
        }
        return dependencies.cacher.getCachedMemoryIcon(
            bundleIdentifier: app.info.bundleIdentifier,
            bundleVersion: app.info.bundleVersion
        )
    }

    var body: some View {
        Group {
            if let image = displayedIcon {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.fill.quaternary)
                    .overlay {
                        if completedLoadKey == iconKey {
                            Image(systemName: "app.dashed")
                                .font(.system(size: max(12, size * 0.34)))
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 2, y: 1)
        .task(id: iconKey) {
            let currentKey = iconKey
            let bundleIdentifier = app.info.bundleIdentifier
            let bundleVersion = app.info.bundleVersion
            if let cached = dependencies.cacher.getCachedMemoryIcon(
                bundleIdentifier: bundleIdentifier,
                bundleVersion: bundleVersion
            ) {
                loadedIcon = LoadedAppIcon(key: currentKey, image: cached)
                completedLoadKey = currentKey
                return
            }
            let cacher = dependencies.cacher
            let appURL = app.url
            let primaryIconName = app.info.primaryIconName
            let iconCG = await cacher.loadLocalIcon(
                at: appURL,
                bundleIdentifier: bundleIdentifier,
                bundleVersion: bundleVersion,
                primaryIconName: primaryIconName
            )
            guard !Task.isCancelled else { return }
            if let iconCG {
                let image = NSImage(cgImage: iconCG, size: NSSize(width: iconCG.width, height: iconCG.height))
                loadedIcon = LoadedAppIcon(key: currentKey, image: image)
            }
            completedLoadKey = currentKey
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

    private var taskKey: String {
        "\(app.bundleID)|\(app.itunesLookup)"
    }

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
                    .task(id: taskKey) {
                        finishedFallbackWait = false
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        guard !Task.isCancelled else { return }
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
        .task(id: taskKey) {
            onlineIcon = nil
            loadedRemoteImage = nil
            localIcon = nil
            finishedFallbackWait = false

            let cacher = dependencies.cacher
            let cache = cacher.cache
            let lookup = app.itunesLookup.trimmingCharacters(in: .whitespacesAndNewlines)
            if !lookup.isEmpty {
                let hasCachedLookup = await Task.detached(priority: .utility) {
                    cache.hasData(forKey: lookup)
                }.value
                if !hasCachedLookup {
                    await cacher.resolveITunesData(lookup)
                }
                guard !Task.isCancelled else { return }
                let artwork = await Task.detached(priority: .utility) { () -> String? in
                    let response: ITunesResponse? = try? cache.readCodable(forKey: lookup)
                    return response?.results.first?.artworkUrl512
                }.value
                guard !Task.isCancelled else { return }
                if let artwork {
                    onlineIcon = artwork
                    let remote = await cacher.loadRemoteImage(from: artwork)
                    guard !Task.isCancelled else { return }
                    if let remote {
                        loadedRemoteImage = remote
                        return
                    }
                }
            }

            let bundleID = app.bundleID
            if let installed = dependencies.appsVM.apps.first(where: { $0.info.bundleIdentifier == bundleID }) {
                if let cached = cacher.getCachedMemoryIcon(
                    bundleIdentifier: installed.info.bundleIdentifier,
                    bundleVersion: installed.info.bundleVersion
                ) {
                    localIcon = cached
                    return
                }
                let iconCG = await cacher.loadLocalIcon(
                    at: installed.url,
                    bundleIdentifier: installed.info.bundleIdentifier,
                    bundleVersion: installed.info.bundleVersion,
                    primaryIconName: installed.info.primaryIconName
                )
                guard !Task.isCancelled else { return }
                if let iconCG {
                    localIcon = NSImage(cgImage: iconCG, size: NSSize(width: iconCG.width, height: iconCG.height))
                    return
                }
            } else if !bundleID.isEmpty {
                let diskCG = await Task.detached(priority: .utility) { () -> CGImage? in
                    let data = cache.readData(forKey: "icon-data:\(bundleID)")
                        ?? cache.readData(forKey: bundleID)
                    guard let data else { return nil }
                    return Cacher.downsampleCGImage(from: data, maxPixelSize: 256)
                }.value
                guard !Task.isCancelled else { return }
                if let diskCG {
                    localIcon = NSImage(cgImage: diskCG, size: NSSize(width: diskCG.width, height: diskCG.height))
                    return
                }
            }

            finishedFallbackWait = true
        }
    }
}
