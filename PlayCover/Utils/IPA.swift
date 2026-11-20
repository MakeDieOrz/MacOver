//
//  IPA.swift
//  PlayCover
//

import Foundation
import SwiftSoup

public class IPA {
    public let url: URL
    public private(set) var tmpDir: URL?

    public init(url: URL) {
        self.url = url
    }

    public func allocateTempDir() throws {
        releaseTempDir()
        tmpDir = try FileManager.default.url(for: .itemReplacementDirectory,
                                             in: .userDomainMask,
                                             appropriateFor: FileManager.default.temporaryDirectory,
                                             create: true)
    }

    public func releaseTempDir() {
        guard let workDir = tmpDir else {
            return
        }

        FileManager.default.delete(at: workDir)

        tmpDir = nil
    }

    public func removeQuarantine(_ execUrl: URL) throws {
        _ = try? Shell.run(print: false, "/usr/bin/xattr", "-cr", execUrl.path)
        _ = try? Shell.run(print: false, "/usr/bin/xattr", "-r", "-d", "com.apple.quarantine", execUrl.path)
    }

    public func unzip() throws -> BaseApp {
        guard let workDir = tmpDir else {
            throw PlayCoverError.appCorrupted
        }
        _ = try Shell.run(print: false, "/usr/bin/unzip", "-oq", url.path, "-d", workDir.path)
        return try Installer.fromIPA(detectingAppNameInFolder: workDir.appendingPathComponent("Payload"))
    }

    func packIPABack(app: URL) throws -> URL {
        let payload = app.deletingLastPathComponent()
        let workDir = payload.deletingLastPathComponent()
        let name = app.deletingPathExtension().lastPathComponent

        let newIpa = getDocumentsDirectory()
            .appendingEscapedPathComponent(name)
            .appendingPathExtension("ipa")

        if FileManager.default.fileExists(atPath: newIpa.path) {
            try FileManager.default.removeItem(at: newIpa)
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = workDir
        process.arguments = ["-r", "-y", newIpa.path, payload.lastPathComponent]
        process.standardOutput = pipe
        process.standardError = pipe
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }

        try process.run()
        let output = try pipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            try? FileManager.default.removeItem(at: newIpa)
            throw PlayCoverError.shellExecutionFailed(
                binary: "/usr/bin/zip",
                status: process.terminationStatus,
                output: String(data: output, encoding: .utf8) ?? "Failed to pack IPA"
            )
        }

        return newIpa
    }

    private func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        return documentsDirectory
    }

    enum Application {
        case base(BaseApp)
        case store(SourceAppsData)
    }

    private func checkMacOSCompatibility(appID: Int) async -> Bool {
        let urlString = "https://apps.apple.com/us/app/id\(appID)"
        guard let url = URL(string: urlString) else {
            return false
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return false
            }

            guard let htmlString = String(data: data, encoding: .utf8) else {
                return false
            }
            let document = try SwiftSoup.parse(htmlString)
            let elements = try document.getElementsByClass("information-list__item__definition__item__definition")
            for element in elements {
                let text = try element.text()
                if text.contains("macOS") {
                    return true
                }
            }
        } catch {
            return false
        }

        return false
    }

    @MainActor
    func checkOfficialMacOS(
        app: Application,
        alertPresenter: AlertPresenter? = nil,
        installPreferences: InstallPreferences? = nil
    ) async -> Bool {
        let bundleID: String
        let appID: Int
        switch app {
        case .base(let base):
            bundleID = base.info.bundleIdentifier
            let urlString = "https://itunes.apple.com/lookup?bundleId=\(bundleID)"
            let itunes: ITunesResponse? = await getITunesData(urlString)
            appID = itunes?.results.first?.trackId ?? 0
        case .store(let store):
            bundleID = store.bundleID
            let appLookup = store.itunesLookup
            let stringArray = appLookup.components(separatedBy: CharacterSet.decimalDigits.inverted)
            appID = Int(stringArray.last ?? "0") ?? 0
        }
        let supportMacOS: Bool = await checkMacOSCompatibility(appID: appID)
        let prefs = installPreferences ?? InstallPreferences()
        let showAlert = prefs.showAppStorePopup
        if showAlert && supportMacOS {
            let presenter = alertPresenter ?? AlertPresenter()
            let response = await presenter.present(
                PlayCoverAlertRequest(
                    title: NSLocalizedString("alert.appstore", comment: ""),
                    message: String(format: NSLocalizedString("macos.version", comment: "")),
                    style: .informational,
                    buttons: [
                        PlayCoverAlertButton(title: NSLocalizedString("alert.install.anyway", comment: "")),
                        PlayCoverAlertButton(title: NSLocalizedString("alert.open.appstore", comment: "")),
                        PlayCoverAlertButton(title: NSLocalizedString("button.Cancel", comment: ""), isCancel: true)
                    ],
                    suppressionTitle: NSLocalizedString("alert.supression", comment: "String"),
                    defaultCancelIndex: 2
                )
            )
            switch response.buttonIndex {
            case 0:
                if response.suppressionChecked {
                    prefs.showAppStorePopup = false
                }
                return false
            case 1:
                if appID != 0 {
                    guard let urlApp = URL(string: "itms-apps://apps.apple.com/app/id\(appID)") else {
                        return true
                    }
                    await MainActor.run {
                        NSWorkspace.shared.open(urlApp)
                    }
                }
                return true
            default:
                return true
            }
        }
        return false
    }
}
