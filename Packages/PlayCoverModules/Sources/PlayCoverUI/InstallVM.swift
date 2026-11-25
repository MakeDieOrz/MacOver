//
//  InstallSteps.swift
//  PlayCover
//

import Foundation
import PlayCoverCore

public enum InstallStepsNative: String, Sendable {
    case unzip = "playapp.install.unzip",
         wrapper = "playapp.install.createWrapper",
         playtools = "playapp.install.installPlayTools",
         sign = "playapp.install.signing",
         library = "playapp.install.addToLib",
         begin = "playapp.install.copy",
         finish = "playapp.progress.finished",
         failed = "playapp.progress.failed"
}

public class InstallVM: ProgressVM<InstallStepsNative>, @unchecked Sendable {

    public init() {
        super.init(start: .begin, ends: [.finish, .failed])
    }

}
