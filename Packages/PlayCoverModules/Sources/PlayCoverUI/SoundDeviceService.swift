//
//  SoundDeviceService.swift
//  PlayCover
//

import CoreAudio
import Foundation
import PlayCoverCore
import SwiftUI

public class SoundDeviceService {

    private let startupAlerts: StartupAlertCenter

    public init(startupAlerts: StartupAlertCenter = StartupAlertCenter()) {
        self.startupAlerts = startupAlerts
    }

    private func getAudioPropertyAddress(
        selector: AudioObjectPropertySelector
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func getAudioPropertyData<T>(
        _ objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        result: inout T
    ) -> OSStatus {
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &result) { result in
            AudioObjectGetPropertyData(objectID, &address, UInt32(0), nil, &size, result)
        }
    }

    private func setAudioPropertyData<T>(
        _ objectID: AudioObjectID,
        address: inout AudioObjectPropertyAddress,
        value: inout T)
    -> OSStatus {
        let size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { value in
            AudioObjectSetPropertyData(objectID, &address, UInt32(0), nil, size, value)
        }
    }

    private func getSoundDevice() -> AudioDeviceID? {
        var address = getAudioPropertyAddress(selector: kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID()
        let objectID = AudioObjectID(kAudioObjectSystemObject)
        if getAudioPropertyData(objectID, address: &address, result: &deviceID) != noErr {
            return nil
        } else {
            return deviceID
        }
    }

    private func getSampleRate(_ deviceID: AudioObjectID) -> Float64? {
        var result = Float64(0.0)
        var address = getAudioPropertyAddress(selector: kAudioDevicePropertyNominalSampleRate)
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        if getAudioPropertyData(deviceID, address: &address, result: &result) != noErr {
            return nil
        } else {
            return result
        }
    }

    private func setSampleRate(_ deviceID: AudioObjectID, sampleRate: Float64) -> OSStatus {
        var value = sampleRate
        var address = getAudioPropertyAddress(selector: kAudioDevicePropertyNominalSampleRate)
        return setAudioPropertyData(deviceID, address: &address, value: &value)
    }

    public func prepareSoundDevice() {
        guard !ProcessInfo.isRunningUnitTests else { return }
        Task.detached(priority: .utility) { [weak self] in
            guard let self, let device = self.getSoundDevice() else { return }
            let sampleRate = self.getSampleRate(device)
            if let sampleRate, sampleRate == 48000.0 || sampleRate == 44100.0 {
                return
            }
            await MainActor.run {
                self.startupAlerts.enqueue(
                    .audioSampleRate(deviceID: device, currentSampleRate: sampleRate ?? 0.0)
                )
            }
        }
    }

    public func applyDefaultSampleRate(for deviceID: AudioDeviceID) {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            if self.setSampleRate(deviceID, sampleRate: 48000) == noErr {
                PlayCoverDiagnostics.reportMessage(NSLocalizedString("soundAlert.successText", comment: ""))
            } else {
                PlayCoverDiagnostics.reportError(NSLocalizedString("soundAlert.failureText", comment: ""))
            }
        }
    }
}
