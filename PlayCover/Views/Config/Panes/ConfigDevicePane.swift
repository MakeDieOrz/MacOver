//
//  ConfigDevicePane.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

struct ConfigDevicePane: View {
    @ObservedObject var settings: AppSettings
    var onOpenStrictMode: (() -> Void)?

    private var currentModel: String {
        settings.settings.iosDeviceModel
    }

    private var effectiveModel: String {
        settings.settings.effectiveIOSDeviceModel
    }

    private var isStrictMode: Bool {
        settings.settings.strictEmulationMode
    }

    private var isLegacy: Bool {
        DeviceProfileOption.isLegacyModel(currentModel)
    }

    private var isIPhone: Bool {
        DeviceProfileOption.isIPhone(currentModel)
    }

    private var isCompat13_7: Bool {
        settings.settings.reportedIOSVersionMode == .compat13_7
    }

    private var isCurrentModelInPicker: Bool {
        let shown = isCompat13_7
            ? DeviceProfileOption.allModern + DeviceProfileOption.ios13CompatibleModels
            : DeviceProfileOption.allModern
        return shown.contains(where: { $0.model == currentModel })
    }

    var body: some View {
        Form {
            if isLegacy && !isCompat13_7 {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(String(
                            format: NSLocalizedString("device.legacyBanner", comment: ""),
                            DeviceProfileOption.displayName(for: currentModel)
                        ))
                        .font(.callout)
                        Spacer()
                        Button("device.upgradeToM1") {
                            settings.update { $0.iosDeviceModel = "iPad13,8" }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }

            Section {
                Picker("settings.picker.iosDevice", selection: $settings.settings.iosDeviceModel) {
                    Section("device.modernGroup") {
                        ForEach(DeviceProfileOption.modernIPads) { option in
                            Text(option.label).tag(option.model)
                        }
                    }
                    Section("device.iphoneGroup") {
                        ForEach(DeviceProfileOption.modernIPhones) { option in
                            Text(option.label).tag(option.model)
                        }
                    }
                    if isCompat13_7 {
                        Section("device.ios13Group") {
                            ForEach(DeviceProfileOption.ios13CompatibleModels) { option in
                                Text(option.label).tag(option.model)
                            }
                        }
                    }
                    if !isCurrentModelInPicker {
                        Divider()
                        Text(DeviceProfileOption.displayName(for: currentModel)).tag(currentModel)
                    }
                }

                layoutComparisonRow

                if DeviceProfileOption.isMSeriesIPad(effectiveModel) {
                    Label("device.mSeriesNotice", systemImage: "cpu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("device.reportedIOS.title", selection: $settings.settings.reportedIOSVersionMode) {
                    Text("device.reportedIOS.automatic").tag(ReportedIOSVersionMode.automatic)
                    Text("device.reportedIOS.followHost").tag(ReportedIOSVersionMode.followHost)
                    Text("device.reportedIOS.compat18_3").tag(ReportedIOSVersionMode.compat18_3)
                    Text("device.reportedIOS.compat13_7").tag(ReportedIOSVersionMode.compat13_7)
                }
                .help("device.reportedIOS.help")

                Text("device.reportedIOS.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if isCompat13_7 {
                    if let minOS = settings.settings.originalMinimumOSVersion,
                       ReportedIOSVersionMode.isMinimumOSVersion(minOS, higherThan: 13, minor: 7) {
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(String(
                                format: NSLocalizedString("device.ios13MinOSWarning", comment: ""),
                                minOS
                            ))
                            .font(.callout)
                        }
                    }

                    if !DeviceProfileOption.supportsIOS13(currentModel) {
                        HStack(spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(.orange)
                            Text(String(
                                format: NSLocalizedString("device.ios13ModelMismatch", comment: ""),
                                DeviceProfileOption.displayName(for: currentModel)
                            ))
                            .font(.callout)
                            Spacer()
                            Button("device.switchToIOS13Model") {
                                settings.update {
                                    $0.iosDeviceModel = DeviceProfileOption.recommendedIOS13Model(isIPhone: isIPhone)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }

                Toggle(
                    "restart.field.notch",
                    isOn: Binding(
                        get: { settings.settings.effectiveNotch },
                        set: { newValue in
                            guard !isStrictMode else { return }
                            settings.settings.notch = newValue
                        }
                    )
                )
                .disabled(isStrictMode)

                if isStrictMode {
                    StrictLockedNote(textKey: "strict.notchLockedNote", onOpenStrictMode: onOpenStrictMode)
                }
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private var layoutComparisonRow: some View {
        LabeledContent("device.layoutTitle") {
            HStack(spacing: 10) {
                layoutPill(
                    titleKey: "device.layout.regular",
                    icon: "ipad.landscape",
                    isSelected: !isIPhone
                )
                layoutPill(
                    titleKey: "device.layout.compact",
                    icon: "iphone",
                    isSelected: isIPhone
                )
            }
        }
    }

    private func layoutPill(titleKey: String, icon: String, isSelected: Bool) -> some View {
        Label(LocalizedStringKey(titleKey), systemImage: icon)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
            )
    }
}
