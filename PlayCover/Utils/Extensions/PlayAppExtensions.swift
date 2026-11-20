//
//  PlayAppExtensions.swift
//  PlayCover
//
//  Created by TheMoonThatRises on 10/2/23.
//

import Darwin
import Foundation

extension PlayApp {
    private static func isUnixSocketAcceptingConnections(at path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK else {
            return false
        }
        let sock = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        let flags = Darwin.fcntl(sock, F_GETFL, 0)
        if flags >= 0 {
            _ = Darwin.fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        }

        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let utf8 = Array(path.utf8)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard utf8.count < maxLen else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            rawBuf.initializeMemory(as: UInt8.self, repeating: 0)
            for (idx, byte) in utf8.enumerated() {
                rawBuf[idx] = byte
            }
        }

        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(sock, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc == 0 {
            return true
        }
        return errno == EINPROGRESS
    }

    func loadDiscordIPC() {
        guard self.container.doesExist() else { return }

        releaseDiscordIPC()

        guard self.settings.settings.discordActivity.enable else {
            return
        }

        let appTmp = self.container.containerUrl
            .appendingPathComponent("Data")
            .appendingPathComponent("tmp")

        do {
            try FileManager.default.createDirectory(at: appTmp, withIntermediateDirectories: true)
        } catch {
            print("failed to create discord ipc directory: \(error)")
            return
        }

        let userTmpURL = FileManager.default.temporaryDirectory
        var linkedCount = 0

        for ipcPort in 0..<10 {
            let socketPath = userTmpURL.appendingPathComponent("discord-ipc-\(ipcPort)").path
            guard Self.isUnixSocketAcceptingConnections(at: socketPath) else {
                continue
            }
            let targetPath = appTmp.appendingPathComponent("discord-ipc-\(ipcPort)").path
            do {
                try FileManager.default.createSymbolicLink(
                    atPath: targetPath,
                    withDestinationPath: socketPath
                )
                linkedCount += 1
            } catch {
                print(error)
            }
        }

        if linkedCount > 0 {
            print("Successfully linked \(linkedCount) discordipc socket(s) for \(self.info.bundleIdentifier)")
        } else {
            print("Unable to link discordipc for \(self.info.bundleIdentifier)")
        }
    }

    func releaseDiscordIPC() {
        guard self.container.doesExist() else { return }

        let appTmp = self.container.containerUrl
            .appendingPathComponent("Data")
            .appendingPathComponent("tmp")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: appTmp,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }

        for url in entries where url.lastPathComponent.range(
            of: "^discord-ipc-[0-9]+$",
            options: .regularExpression
        ) != nil {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                print("failed to remove discord ipc: \(error)")
            }
        }
    }

    func ensureAliasUpToDate() {
        let fm = FileManager.default
        if let existingTarget = try? fm.destinationOfSymbolicLink(atPath: aliasURL.path),
           existingTarget == url.path {
            return
        }
        createAlias()
    }

    func createAlias() {
        do {
            try FileManager.default.createDirectory(atPath: PlayApp.aliasDirectory.path,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
            if FileManager.default.fileExists(atPath: aliasURL.path) {
                try? FileManager.default.removeItem(at: aliasURL)
            }
            try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: url)
        } catch {
            PlayCoverDiagnostics.log(error.localizedDescription)
        }
    }

    func removeAlias() {
        FileManager.default.delete(at: aliasURL)
    }
}
