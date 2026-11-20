//
//  URLExtensions.swift
//  PlayCover
//

import AppKit
import CryptoKit
import Foundation
import SwiftUI

public extension String {
    var esc: String {
        let esc = ["\\", "\"", "'", " ", "(", ")", "[", "]", "{", "}", "&", "|",
                   ";", "<", ">", "`", "$", "!", "*", "?", "#", "~", "="]
        var str = self
        for char in esc {
            str = str.replacingOccurrences(of: char, with: "\\" + char)
        }
        return str
    }

    func copyToClipBoard() {
        let pasteBoard = NSPasteboard.general
        pasteBoard.clearContents()
        pasteBoard.setString(self, forType: .string)
    }
}

public extension URL {
    var esc: String {
        path.esc
    }

    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    var sha256: String? {
        do {
            let handle = try FileHandle(forReadingFrom: self)
            defer { try? handle.close() }

            var hasher = SHA256()
            let chunkSize = 4 * 1024 * 1024
            while true {
                let shouldContinue = try autoreleasepool { () -> Bool in
                    guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                        return false
                    }
                    hasher.update(data: chunk)
                    return true
                }
                if !shouldContinue {
                    break
                }
            }
            return hasher.finalize()
                .map { String(format: "%02hhx", $0) }
                .joined()
        } catch {
            return nil
        }
    }

    func openInFinder() {
        if isDirectory {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        } else {
            showInFinderAndSelectLastComponent()
        }
    }

    func showInFinder() {
        if isDirectory {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([self])
        }
    }

    func showInFinderAndSelectLastComponent() {
        NSWorkspace.shared.activateFileViewerSelecting([self])
    }

    func fixExecutable() throws {
        var attributes = [FileAttributeKey: Any]()
        attributes[.posixPermissions] = 0o755
        try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
    }

    // Wraps NSFileEnumerator since the geniuses at corelibs-foundation decided it should be completely untyped
    func enumerateContents(blocking: Bool = true,
                           includingPropertiesForKeys keys: [URLResourceKey]? = nil,
                           options: FileManager.DirectoryEnumerationOptions? = nil,
                           _ callback: @escaping (URL, URLResourceValues) throws -> Void) {
        let resourceKeys = keys ?? [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: self,
            includingPropertiesForKeys: resourceKeys,
            options: options ?? [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return
        }

        let queue = OperationQueue()
        queue.name = "io.playcover.PlayCover.URLExtension"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 15

        let keySet = Set(resourceKeys)
        for case let fileURL as URL in enumerator {
            queue.addOperation {
                do {
                    try callback(fileURL, fileURL.resourceValues(forKeys: keySet))
                } catch {
                    // Don't show error, as there could be many files within the folder
                    // that would fail the callback
                    print(error)
                }
            }
        }

        if blocking {
            queue.waitUntilAllOperationsAreFinished()
        }
    }

    func appendingEscapedPathComponent(_ pathComponent: String) -> URL {
        let esc = [("/", ":")]

        var newPathComponent = pathComponent

        for (find, replace) in esc {
            newPathComponent = newPathComponent.replacingOccurrences(of: find, with: replace)
        }

        return self.appendingPathComponent(newPathComponent)
    }

    func setBinaryPosixPermissions(_ permissions: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
    }
}
