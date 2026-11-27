//
//  DownloadVM.swift
//  PlayCover
//
//  Created by Isaac Marovitz on 01/10/2022.
//

import Foundation
import Observation
import PlayCoverUI

enum DownloadStepsNative: String, Sendable {
    case downloading = "playapp.download.downloading",
         integrity = "playapp.download.integrityCheck",
         finish = "playapp.progress.finished",
         failed = "playapp.progress.failed",
         canceled = "playapp.progress.canceled"
}

@Observable
final class DownloadVM: @unchecked Sendable {
    @ObservationIgnored private let tracker = ProgressVM<DownloadStepsNative>(
        start: .downloading,
        ends: [.finish, .failed, .canceled]
    )

    var storeAppData: SourceAppsData?

    var progress: Double {
        get { tracker.progress }
        set { tracker.progress = newValue }
    }

    var inProgress: Bool {
        get { tracker.inProgress }
        set { tracker.inProgress = newValue }
    }

    var status: DownloadStepsNative {
        get { tracker.status }
        set { tracker.status = newValue }
    }

    func next(_ step: DownloadStepsNative, _ startProgress: Double, _ stopProgress: Double) {
        tracker.next(step, startProgress, stopProgress)
    }

    func updateProgress(_ value: Double) {
        tracker.updateProgress(value)
    }
}
