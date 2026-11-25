//
//  DownloadVM.swift
//  PlayCover
//
//  Created by Isaac Marovitz on 01/10/2022.
//

import Foundation

enum DownloadStepsNative: String, Sendable {
    case downloading = "playapp.download.downloading",
         integrity = "playapp.download.integrityCheck",
         finish = "playapp.progress.finished",
         failed = "playapp.progress.failed",
         canceled = "playapp.progress.canceled"
}

class DownloadVM: ProgressVM<DownloadStepsNative>, @unchecked Sendable {
    @Published var storeAppData: SourceAppsData?

    init() {
        super.init(start: .downloading, ends: [.finish, .failed, .canceled])
    }

}
