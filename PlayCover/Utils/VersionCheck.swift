//
//  VersionCheck.swift
//  PlayCover
//
//  Created by Edoardo C. on 30/04/25.
//

@MainActor
final class VersionCheck {
    weak var dependencies: PlayCoverDependencies?

    init(dependencies: PlayCoverDependencies? = nil) {
        self.dependencies = dependencies
    }

    @MainActor
    func checkUpdateAlert(app: SourceAppsData) async -> Bool {
        let presenter = dependencies?.alertPresenter ?? AlertPresenter()
        let response = await presenter.present(
            PlayCoverAlertRequest(
                title: NSLocalizedString("alert.version.title", comment: ""),
                message: String(format: NSLocalizedString("alert.version.text", comment: ""), "\(app.name)"),
                style: .informational,
                buttons: [
                    PlayCoverAlertButton(title: NSLocalizedString("alert.start.anyway", comment: "")),
                    PlayCoverAlertButton(title: NSLocalizedString("ipaLibrary.download", comment: "")),
                    PlayCoverAlertButton(title: NSLocalizedString("button.Cancel", comment: ""), isCancel: true)
                ],
                iconSystemName: "square.and.arrow.down.fill",
                defaultCancelIndex: 2
            )
        )
        switch response.buttonIndex {
        case 0:
            return false
        case 1:
            if let url = URL(string: app.link) {
                if dependencies?.downloadVM.inProgress == true {
                    PlayCoverDiagnostics.reportError(PlayCoverError.waitDownload)
                } else {
                    let resolvedURL = await RedirectHandler.resolveDirectDownloadURL(for: url)
                    DownloadApp(url: resolvedURL, app: app, warning: nil, dependencies: dependencies).start()
                }
            }
            return true
        default:
            return true
        }
    }

    func checkNewVersion(myApp: PlayApp) async -> Bool {
        guard let storeApp = dependencies?.storeVM.sourcesApps else { return false }
        if let app = storeApp.first(where: { $0.bundleID == myApp.info.bundleIdentifier }) {
            if myApp.info.bundleVersion.compare(app.version, options: .numeric) == .orderedAscending {
                return await checkUpdateAlert(app: app)
            }
        }
        return false
    }
}
