//
//  ToastVM.swift
//  PlayCover
//
//  Created by Isaac Marovitz on 08/08/2022.
//

import Foundation
import Synchronization

public enum ToastType: Hashable, Sendable {
    case notice, error, network
}

public struct ToastInfo: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let toastType: ToastType
    public let toastDetails: String
    public let timeRemaining: UInt64

    public init(id: UUID = UUID(), toastType: ToastType, toastDetails: String, timeRemaining: UInt64 = 2) {
        self.id = id
        self.toastType = toastType
        self.toastDetails = toastDetails
        self.timeRemaining = timeRemaining
    }
}

public final class ToastVM: ObservableObject, @unchecked Sendable {
    @Published public var toasts: [ToastInfo] = []
    @Published public var isShown: Bool = true

    private let activeTypesByID = Mutex<[UUID: ToastType]>([:])

    public init() {}

    public func hasToast(ofType type: ToastType) -> Bool {
        activeTypesByID.withLock { $0.values.contains(type) }
    }

    @discardableResult
    public func showToast(toastType: ToastType, toastDetails: String, timeRemaining: UInt64 = 2) -> UUID {
        let toast = ToastInfo(toastType: toastType, toastDetails: toastDetails, timeRemaining: timeRemaining)
        activeTypesByID.withLock { $0[toast.id] = toastType }
        if Thread.isMainThread {
            toasts.append(toast)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.toasts.append(toast)
            }
        }
        return toast.id
    }

    public func dismiss(id: UUID) {
        activeTypesByID.withLock { _ = $0.removeValue(forKey: id) }
        if Thread.isMainThread {
            toasts.removeAll { $0.id == id }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.toasts.removeAll { $0.id == id }
            }
        }
    }
}
