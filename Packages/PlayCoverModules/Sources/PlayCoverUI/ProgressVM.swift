//
//  ProgressVM.swift
//  PlayCover
//
//  Created by TheMoonThatRises on 1/13/23.
//

import Foundation

open class ProgressVM<Steps: RawRepresentable & Equatable>: ObservableObject where Steps.RawValue == String {
    @Published public var progress = 0.0
    @Published public var inProgress = false
    @Published public var status: Steps

    private let starting: Steps
    private let ends: [Steps]
    private var endDismissTask: Task<Void, Never>?

    /// - Parameters:
    ///     - start: The initial starting value
    ///     - ends: Ending conditions
    public init(start: Steps, ends: [Steps]) {
        self.status = start
        self.starting = start
        self.ends = ends
    }

    deinit {
        endDismissTask?.cancel()
    }

    open func next(_ step: Steps, _ startProgress: Double, _ stopProgress: Double) {
        let apply = { @MainActor [weak self] in
            guard let self else { return }
            self.endDismissTask?.cancel()
            self.endDismissTask = nil

            self.progress = startProgress
            self.status = step

            if step == self.starting {
                self.inProgress = true
            } else if self.ends.contains(step) {
                self.progress = 1.0
                self.endDismissTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.inProgress = false
                }
            }
        }

        if Thread.isMainThread {
            MainActor.assumeIsolated {
                apply()
            }
        } else {
            Task { @MainActor in
                apply()
            }
        }
    }

    public func updateProgress(_ value: Double) {
        let clamped = min(max(value, 0.0), 1.0)
        if Thread.isMainThread {
            progress = clamped
        } else {
            Task { @MainActor [weak self] in
                self?.progress = clamped
            }
        }
    }
}
