//
//  Logger.swift
//  PlayCover
//

import Foundation
import SwiftUI

class Log: ObservableObject {

    private weak var alertPresenter: AlertPresenter?

    init(alertPresenter: AlertPresenter? = nil) {
        self.alertPresenter = alertPresenter
    }

    func error(_ err: Error) {
        error(err.localizedDescription)
    }

    func error(_ message: String) {
        if ProcessInfo.isRunningUnitTests {
            self.log(message, isError: true)
            return
        }
        Task { @MainActor in
            self.dialog(
                question: NSLocalizedString("alert.error", comment: ""),
                text: message,
                style: NSAlert.Style.critical)
        }
    }

    func error(localized str: String, args: [String] = []) {
        error(String(format: NSLocalizedString(str, comment: ""), arguments: args))
    }

    func msg(_ msg: String) {
        if ProcessInfo.isRunningUnitTests {
            self.log(msg)
            return
        }
        Task { @MainActor in
            self.log(msg)
            self.dialog(
                question: NSLocalizedString("alert.success", comment: ""),
                text: msg,
                style: NSAlert.Style.informational)
        }
    }

    var logdata = "\(ProcessInfo.processInfo.operatingSystemVersionString)\n"

    func log(_ str: String, isError: Bool = false) {
        print(str)
        if isError {
            logdata.append("ERROR: ")
        }
        logdata.append(str)
        logdata.append("\n")
    }

    @MainActor
    private func dialog(question: String, text: String, style: NSAlert.Style) {
        guard !ProcessInfo.isRunningUnitTests else { return }
        let mappedStyle: PlayCoverAlertStyle
        switch style {
        case .critical:
            mappedStyle = .critical
        case .warning:
            mappedStyle = .warning
        default:
            mappedStyle = .informational
        }
        alertPresenter?.enqueueNotice(
            title: question,
            message: text,
            style: mappedStyle
        )
    }

    required init() { }
}
