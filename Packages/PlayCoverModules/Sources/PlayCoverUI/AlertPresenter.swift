import Foundation
import PlayCoverCore
import SwiftUI

public enum PlayCoverAlertStyle: Equatable, Sendable {
    case informational
    case warning
    case critical
}

public struct PlayCoverAlertButton: Identifiable, Equatable, Sendable {
    public let id: Int
    public let title: String
    public let isDestructive: Bool
    public let isCancel: Bool

    public init(id: Int = 0, title: String, isDestructive: Bool = false, isCancel: Bool = false) {
        self.id = id
        self.title = title
        self.isDestructive = isDestructive
        self.isCancel = isCancel
    }
}

public struct PlayCoverAlertResponse: Equatable, Sendable {
    public let buttonIndex: Int
    public let suppressionChecked: Bool

    public init(buttonIndex: Int, suppressionChecked: Bool = false) {
        self.buttonIndex = buttonIndex
        self.suppressionChecked = suppressionChecked
    }
}

public struct PlayCoverAlertRequest: Identifiable {
    public let id = UUID()
    public let title: String
    public let message: String
    public let style: PlayCoverAlertStyle
    public let buttons: [PlayCoverAlertButton]
    public let suppressionTitle: String?
    public let defaultSuppressionValue: Bool
    public let iconSystemName: String?
    public let defaultCancelIndex: Int

    public init(
        title: String,
        message: String,
        style: PlayCoverAlertStyle = .informational,
        buttons: [PlayCoverAlertButton],
        suppressionTitle: String? = nil,
        defaultSuppressionValue: Bool = false,
        iconSystemName: String? = nil,
        defaultCancelIndex: Int? = nil
    ) {
        self.title = title
        self.message = message
        self.style = style
        self.buttons = buttons.enumerated().map { idx, btn in
            PlayCoverAlertButton(
                id: idx,
                title: btn.title,
                isDestructive: btn.isDestructive,
                isCancel: btn.isCancel
            )
        }
        self.suppressionTitle = suppressionTitle
        self.defaultSuppressionValue = defaultSuppressionValue
        self.iconSystemName = iconSystemName
        if let explicitCancel = defaultCancelIndex {
            self.defaultCancelIndex = explicitCancel
        } else if let cancelIdx = self.buttons.firstIndex(where: { $0.isCancel }) {
            self.defaultCancelIndex = cancelIdx
        } else {
            self.defaultCancelIndex = max(0, self.buttons.count - 1)
        }
    }
}

@MainActor
public final class AlertPresenter: ObservableObject {
    @Published public var activeRequest: PlayCoverAlertRequest?
    public var testHandler: ((PlayCoverAlertRequest) -> PlayCoverAlertResponse)?
    private let bypassUnitTestAutoResolve: Bool

    private var queuedRequests: [PlayCoverAlertRequest] = []
    private var continuations: [UUID: CheckedContinuation<PlayCoverAlertResponse, Never>] = [:]

    nonisolated public init(bypassUnitTestAutoResolve: Bool = false) {
        self.bypassUnitTestAutoResolve = bypassUnitTestAutoResolve
    }

    @discardableResult
    public func present(_ request: PlayCoverAlertRequest) async -> PlayCoverAlertResponse {
        if let testHandler {
            return testHandler(request)
        }
        if ProcessInfo.isRunningUnitTests && !bypassUnitTestAutoResolve {
            return PlayCoverAlertResponse(buttonIndex: request.defaultCancelIndex, suppressionChecked: false)
        }

        return await withCheckedContinuation { continuation in
            continuations[request.id] = continuation
            if activeRequest == nil {
                activeRequest = request
            } else {
                queuedRequests.append(request)
            }
        }
    }

    public func enqueueNotice(
        title: String,
        message: String,
        style: PlayCoverAlertStyle = .informational,
        okTitle: String = NSLocalizedString("button.OK", comment: "")
    ) {
        if ProcessInfo.isRunningUnitTests, testHandler == nil {
            return
        }
        let req = PlayCoverAlertRequest(
            title: title,
            message: message,
            style: style,
            buttons: [PlayCoverAlertButton(title: okTitle)],
            defaultCancelIndex: 0
        )
        if let testHandler {
            _ = testHandler(req)
            return
        }
        if activeRequest == nil {
            activeRequest = req
        } else {
            queuedRequests.append(req)
        }
    }

    public func resolveActive(with response: PlayCoverAlertResponse) {
        guard let currentReq = activeRequest else { return }
        let continuation = continuations.removeValue(forKey: currentReq.id)
        if queuedRequests.isEmpty {
            activeRequest = nil
        } else {
            activeRequest = queuedRequests.removeFirst()
        }
        continuation?.resume(returning: response)
    }

    public func handleDismissed(requestID: UUID) {
        guard let continuation = continuations.removeValue(forKey: requestID) else {
            if activeRequest?.id == requestID {
                if queuedRequests.isEmpty {
                    activeRequest = nil
                } else {
                    activeRequest = queuedRequests.removeFirst()
                }
            }
            return
        }
        let fallbackIndex: Int
        if activeRequest?.id == requestID {
            fallbackIndex = activeRequest?.defaultCancelIndex ?? 0
            if queuedRequests.isEmpty {
                activeRequest = nil
            } else {
                activeRequest = queuedRequests.removeFirst()
            }
        } else {
            fallbackIndex = 0
        }
        continuation.resume(returning: PlayCoverAlertResponse(buttonIndex: fallbackIndex, suppressionChecked: false))
    }
}

public struct PlayCoverAlertSheet: View {
    public let request: PlayCoverAlertRequest
    public let onResolve: (PlayCoverAlertResponse) -> Void

    @State private var suppressionChecked: Bool

    public init(request: PlayCoverAlertRequest, onResolve: @escaping (PlayCoverAlertResponse) -> Void) {
        self.request = request
        self.onResolve = onResolve
        self._suppressionChecked = State(initialValue: request.defaultSuppressionValue)
    }

    private var effectiveIconName: String {
        if let iconSystemName = request.iconSystemName, !iconSystemName.isEmpty {
            return iconSystemName
        }
        switch request.style {
        case .informational:
            return "info.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .critical:
            return "xmark.octagon.fill"
        }
    }

    private var effectiveIconColor: Color {
        switch request.style {
        case .informational:
            return .accentColor
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: effectiveIconName)
                    .font(.system(size: 30))
                    .foregroundColor(effectiveIconColor)
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.title)
                        .font(.headline)
                    if !request.message.isEmpty {
                        ScrollView {
                            Text(request.message)
                                .font(.body)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 200)
                    }
                }
            }

            if let suppressionTitle = request.suppressionTitle {
                Toggle(suppressionTitle, isOn: $suppressionChecked)
                    .toggleStyle(.checkbox)
            }

            HStack {
                Spacer()
                ForEach(request.buttons.reversed()) { button in
                    if button.id == 0 {
                        alertButton(button)
                            .keyboardShortcut(.defaultAction)
                    } else {
                        alertButton(button)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 380, maxWidth: 480)
    }

    @ViewBuilder
    private func alertButton(_ button: PlayCoverAlertButton) -> some View {
        Button(
            button.title,
            role: button.isDestructive ? .destructive : (button.isCancel ? .cancel : nil)
        ) {
            onResolve(PlayCoverAlertResponse(
                buttonIndex: button.id,
                suppressionChecked: suppressionChecked
            ))
        }
    }
}
