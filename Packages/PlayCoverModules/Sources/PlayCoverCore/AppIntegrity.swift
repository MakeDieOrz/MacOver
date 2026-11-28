//
//  AppIntegrity.swift
//  PlayCover
//

import AppKit
import Foundation
import Observation

@MainActor
@Observable
public final class AppIntegrity {

    public var integrityOff: Bool = !AppIntegrity.insideAppsFolder

    public init() {}

    public func verifyAppIntegrity() {
        integrityOff = !AppIntegrity.insideAppsFolder
    }

    public func moveToApps() {
        do {
            guard let sourceURL = AppIntegrity.appUrl else { return }
            guard !AppIntegrity.isURLInsideApplications(sourceURL) else {
                integrityOff = false
                return
            }

            let fm = FileManager.default
            let destinationURL = AppIntegrity.expectedUrl
            let applicationsDir = destinationURL.deletingLastPathComponent()

            // Stage a complete copy in a sibling directory before touching /Applications/MacOver.app
            // so a copy failure or case-insensitive alias can never destroy the existing bundle.
            let stagingDir = applicationsDir.appendingPathComponent(
                ".MacOver.staging-\(UUID().uuidString)",
                isDirectory: true
            )
            try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: stagingDir) }

            let stagedAppURL = stagingDir.appendingPathComponent(destinationURL.lastPathComponent, isDirectory: true)
            try fm.copyItem(at: sourceURL, to: stagedAppURL)

            if fm.fileExists(atPath: destinationURL.path) {
                _ = try fm.replaceItemAt(
                    destinationURL,
                    withItemAt: stagedAppURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fm.moveItem(at: stagedAppURL, to: destinationURL)
            }

            destinationURL.openInFinder()
            if !Self.refersToSameFile(sourceURL, destinationURL) {
                fm.delete(at: sourceURL)
            }
            NSApplication.shared.terminate(nil)
        } catch {
            PlayCoverDiagnostics.reportError(error)
        }
    }

    private static var appUrl: URL? {
        Bundle.main.resourceURL?.deletingLastPathComponent().deletingLastPathComponent()
    }

    nonisolated public static let expectedUrl = URL(fileURLWithPath: "/Applications/MacOver.app")
    nonisolated public static let applicationsDirUrl = URL(fileURLWithPath: "/Applications", isDirectory: true)

    nonisolated public static func refersToSameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if let lhsID = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           let rhsID = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier {
            return lhsID.isEqual(rhsID)
        }
        return lhs.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
            == rhs.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }

    nonisolated public static func isURLInsideApplications(
        _ url: URL,
        expectedAppURL: URL = expectedUrl,
        applicationsDirURL: URL = applicationsDirUrl
    ) -> Bool {
        if url.path.contains("Xcode") {
            return true
        }
        if refersToSameFile(url, expectedAppURL) {
            return true
        }
        let parentDir = url.deletingLastPathComponent()
        if refersToSameFile(parentDir, applicationsDirURL) {
            return true
        }
        let canonicalParent = parentDir.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let canonicalApps = applicationsDirURL.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        return canonicalParent == canonicalApps
    }

    private static var insideAppsFolder: Bool {
        guard let url = appUrl else { return false }
        return isURLInsideApplications(url)
    }

}
