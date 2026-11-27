//
//  ProgressVM.swift
//  PlayCover
//
//  Created by TheMoonThatRises on 1/13/23.
//

import Foundation
import Observation
import Synchronization

@MainActor
@Observable
open class ProgressVM<
    Steps: RawRepresentable & Equatable & Sendable
> where Steps.RawValue == String {
    public var progress = 0.0
    public var inProgress = false
    public var status: Steps
    public private(set) var currentStepRange: ClosedRange<Double> = 0.0...1.0

    @ObservationIgnored private let starting: Steps
    @ObservationIgnored private let ends: [Steps]
    @ObservationIgnored private let endDismissTask = Mutex<Task<Void, Never>?>(nil)

    /// - Parameters:
    ///     - start: The initial starting value
    ///     - ends: Ending conditions
    public init(start: Steps, ends: [Steps]) {
        self.status = start
        self.starting = start
        self.ends = ends
    }

    deinit {
        endDismissTask.withLock { $0?.cancel() }
    }

    nonisolated open func next(_ step: Steps, _ startProgress: Double, _ stopProgress: Double) {
        let clampedStart = min(max(startProgress, 0.0), 1.0)
        let clampedStop = min(max(stopProgress, clampedStart), 1.0)
        let apply = { @MainActor [weak self] in
            guard let self else { return }
            self.currentStepRange = clampedStart...clampedStop
            self.progress = clampedStart
            self.status = step

            let dismissalTask: Task<Void, Never>?
            if step == self.starting {
                self.inProgress = true
                dismissalTask = nil
            } else if self.ends.contains(step) {
                self.progress = 1.0
                dismissalTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard !Task.isCancelled, let self else { return }
                    self.inProgress = false
                }
            } else {
                dismissalTask = nil
            }

            self.endDismissTask.withLock { current in
                current?.cancel()
                current = dismissalTask
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

    nonisolated public func updateProgress(_ value: Double) {
        let clamped = min(max(value, 0.0), 1.0)
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.progress = clamped
            }
        } else {
            Task { @MainActor [weak self] in
                self?.progress = clamped
            }
        }
    }

    nonisolated public func updateStepProgress(_ fraction: Double) {
        let clampedFraction = min(max(fraction, 0.0), 1.0)
        let apply = { @MainActor [weak self] in
            guard let self else { return }
            let span = self.currentStepRange.upperBound - self.currentStepRange.lowerBound
            let mapped = self.currentStepRange.lowerBound + span * clampedFraction
            self.progress = max(self.progress, min(max(mapped, 0.0), 1.0))
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
}
