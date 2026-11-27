//
//  URIHandler.swift
//  PlayCover
//
//  Created by Venti on 14/02/2023.
//

import Foundation
import Observation

enum URLTypes: Int, Equatable {
    case source
    case keymap
    case app
}

enum URLAction: Int, Equatable {
    case add
    case remove
    case update
    case install
    case open
}

@MainActor
@Observable
final class URLObservable {
    var url: String?
    var type: URLTypes?
    var action: URLAction?
}

@MainActor
final class URLHandler {
    weak var dependencies: PlayCoverDependencies?

    init(dependencies: PlayCoverDependencies? = nil) {
        self.dependencies = dependencies
    }

    func processURL(url: URL) {
        guard let urlComponenents = NSURLComponents(url: url, resolvingAgainstBaseURL: false),
              let uriHost = urlComponenents.host,
              let params = urlComponenents.queryItems else {
                // Fall back to old url handler (for files)
                if url.pathExtension == "ipa" {
                    let deps = dependencies
                    Installer.install(
                        ipaUrl: url,
                        export: false,
                        dependencies: deps,
                        returnCompletion: { finalURL in
                            Task { @MainActor in
                                deps?.appsVM.fetchApps()
                                if finalURL != nil {
                                    deps?.notifyService.notify(
                                        NSLocalizedString("notification.appInstalled", comment: ""),
                                        NSLocalizedString("notification.appInstalled.message", comment: "")
                                    )
                                }
                            }
                        }
                    )
                }
                return
            }
        // URI format: playcoverapp://<object>?action=<action>&<param>=<value>
        // Example: playcoverapp://source?action=add&url=https://homebrew.playcover.io
        // Switch case for main uri path
        switch uriHost {
        case "source":
            processSourceURL(params: params)
        default:
            // Print URL to log and break
            NSLog("Unknown URL: \(url)")
        }
    }

    func processSourceURL(params: [URLQueryItem]) {
        // Make dang sure we have the params we need and they match expected query items
        guard params.count == 2,
              params[0].name == "action",
              params[1].name == "url" else {
            // Print params to logs and break
            NSLog("Unknown source URL params: \(params)")
            return
        }

        if let actionParam = params[0].value {
            dependencies?.urlObservable.type = .source
            switch actionParam {
            case "add":
                // Add source
                if let url = params[1].value {
                    dependencies?.urlObservable.url = url
                    dependencies?.urlObservable.action = .add
                }
            case "remove":
                // Remove source
                if let url = params[1].value {
                    dependencies?.urlObservable.url = url
                    dependencies?.urlObservable.action = .remove
                }
            case "update":
                // Update source
                if let url = params[1].value {
                    dependencies?.urlObservable.url = url
                    dependencies?.urlObservable.action = .update
                }
            default:
                // Print params to console and break
                print("Unknown source URL params: \(params)")
            }
        }
    }
}
