//
//  ToastVM.swift
//  PlayCover
//
//  Created by Isaac Marovitz on 08/08/2022.
//

import Foundation

public enum ToastType: Hashable {
    case notice, error, network
}

public struct ToastInfo: Identifiable, Hashable {
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

public final class ToastVM: ObservableObject {
    @Published public var toasts: [ToastInfo] = []
    @Published public var isShown: Bool = true

    private let activeTypesLock = NSLock()
    private var activeTypesByID: [UUID: ToastType] = [:]

    public init() {}

    public func hasToast(ofType type: ToastType) -> Bool {
        activeTypesLock.lock()
        let exists = activeTypesByID.values.contains(type)
        activeTypesLock.unlock()
        return exists
    }

    @discardableResult
    public func showToast(toastType: ToastType, toastDetails: String, timeRemaining: UInt64 = 2) -> UUID {
        let toast = ToastInfo(toastType: toastType, toastDetails: toastDetails, timeRemaining: timeRemaining)
        activeTypesLock.lock()
        activeTypesByID[toast.id] = toastType
        activeTypesLock.unlock()
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
        activeTypesLock.lock()
        activeTypesByID.removeValue(forKey: id)
        activeTypesLock.unlock()
        if Thread.isMainThread {
            toasts.removeAll { $0.id == id }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.toasts.removeAll { $0.id == id }
            }
        }
    }
}
