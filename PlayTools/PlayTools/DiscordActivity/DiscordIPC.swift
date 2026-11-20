//
//  DiscordIPC.swift
//  PlayTools
//
//  Created by 이승윤 on 2022/07/15.
//

import Darwin
import Foundation
import SwordRPC

class DiscordIPC {
    public static let shared = DiscordIPC()

    private let stateLock = NSLock()
    private var rpc: SwordRPC?
    private var termObserver: NSObjectProtocol?

    private static let defaultAppID = "996108521680678993"

    func initialize() {
        let custom = PlaySettings.shared.discordActivity
        guard custom.enable else { return }

        let appId = custom.applicationID.isEmpty ? Self.defaultAppID : custom.applicationID
        let details = custom.details
        let state = custom.state
        let image = custom.image

        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            guard Self.hasLiveDiscordSocket() else { return }

            let activity = await self.createActivity(
                details: details,
                state: state,
                image: image
            )
            // Re-verify right before creating SwordRPC / SwiftNIO event loop threads
            guard Self.hasLiveDiscordSocket() else { return }

            let ipc = SwordRPC(appId: appId)
            ipc.connect()
            ipc.setPresence(activity)

            self.setActiveRPC(ipc)
        }
    }

    private func setActiveRPC(_ ipc: SwordRPC) {
        stateLock.lock()
        rpc = ipc
        installTerminationObserverLocked()
        stateLock.unlock()
    }

    func shutdown() {
        stateLock.lock()
        let activeRPC = rpc
        rpc = nil
        if let observer = termObserver {
            NotificationCenter.default.removeObserver(observer)
            termObserver = nil
        }
        stateLock.unlock()
        activeRPC?.clearPresence()
    }

    private func installTerminationObserverLocked() {
        guard termObserver == nil else { return }
        termObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name(rawValue: "NSApplicationWillTerminateNotification"),
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.shutdown()
        }
    }

    /// Lightweight POSIX socket probe so SwiftNIO EventLoopGroups and SwordRPC
    /// are never constructed when Discord is not running.
    private static func hasLiveDiscordSocket() -> Bool {
        let tempDir = FileManager.default.temporaryDirectory.path
        for port in 0..<10 {
            let socketPath = "\(tempDir)/discord-ipc-\(port)"
            var st = Darwin.stat()
            guard stat(socketPath, &st) == 0,
                  (st.st_mode & S_IFMT) == S_IFSOCK else {
                continue
            }
            if canConnectUnixSocket(at: socketPath) {
                return true
            }
        }
        return false
    }

    private static func canConnectUnixSocket(at path: String) -> Bool {
        var addr = sockaddr_un()
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        let utf8 = path.utf8CString
        guard utf8.count > 0, utf8.count <= maxPathLen else { return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            utf8.withUnsafeBytes { src in
                buf.copyMemory(from: src)
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.offset(of: \.sun_path)! + utf8.count)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, addrLen)
            }
        }
        return rc == 0 || errno == EINPROGRESS
    }

    func createActivity(details: String, state: String, image: String) async -> RichPresence {
        var activity = RichPresence()

        if details.isEmpty {
            let name = Bundle.main.infoDictionary?["CFBundleName"] as? String ?? ""
            let displayName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String ?? name
            activity.details = "Playing \(displayName)"
        } else {
            activity.details = details.count == 1 ? "\(details) " : details
        }

        let poweredStr = "Powered by PlayCover"
        if state.isEmpty {
            activity.state = poweredStr
        } else {
            activity.state = state.count == 1 ? "\(state) " : state
            activity.assets.smallText = poweredStr
            activity.assets.largeText = poweredStr
        }

        let logo = "https://raw.githubusercontent.com/PlayCover/PlaySite/master/src/assets/square-logo.png"
        if image.isEmpty {
            let bundleID = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
            if let appImage = await loadImage(bundleID: bundleID) {
                activity.assets.largeImage = appImage
                activity.assets.largeText = nil
                activity.assets.smallImage = logo
            } else {
                activity.assets.largeImage = logo
            }
        } else {
            activity.assets.largeImage = image
            activity.assets.largeText = nil
            activity.assets.smallImage = logo
        }

        activity.timestamps.start = Date()

        activity.buttons = [
            RichPresence.Button(label: "Download PlayCover",
                                url: "https://github.com/PlayCover/PlayCover/releases")
        ]

        return activity
    }

    func loadImage(bundleID: String) async -> String? {
        guard !bundleID.isEmpty,
              let encoded = bundleID.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://itunes.apple.com/lookup?bundleId=\(encoded)") else {
            return nil
        }

        do {
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url))
            let decoder = JSONDecoder()
            let jsonResult: ITunesResponse = try decoder.decode(ITunesResponse.self, from: data)
            if jsonResult.resultCount > 0, let first = jsonResult.results.first {
                return first.artworkUrl512 ?? first.artworkUrl100
            }
            return nil
        } catch {
            return nil
        }
    }
}

struct ITunesResult: Decodable {
    var artworkUrl512: String?
    var artworkUrl100: String?
}

struct ITunesResponse: Decodable {
    var resultCount: Int
    var results: [ITunesResult]
}
