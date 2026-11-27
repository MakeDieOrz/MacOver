//
//  AppIntegrity.swift
//  PlayCover
//

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
            if let url = AppIntegrity.appUrl {
                FileManager.default.delete(at: AppIntegrity.expectedUrl)
                try FileManager.default.copyItem(at: url, to: AppIntegrity.expectedUrl)
                URL(fileURLWithPath: AppIntegrity.expectedUrl.path).openInFinder()
                FileManager.default.delete(at: url)
                exit(0)
            }
        } catch {
            PlayCoverDiagnostics.reportError(error)
        }
    }

    private static var appUrl: URL? {
        Bundle.main.resourceURL?.deletingLastPathComponent().deletingLastPathComponent()
    }

    private static let expectedUrl = URL(fileURLWithPath: "/Applications/MacOver.app")

    private static var insideAppsFolder: Bool {
        if let url = appUrl {
            return url.path.contains("Xcode") || url.path.contains(expectedUrl.path)
        }
        return false
    }

}
