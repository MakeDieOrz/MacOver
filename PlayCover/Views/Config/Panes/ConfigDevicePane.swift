//
//  ConfigDevicePane.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

struct ConfigDevicePane: View {
    @ObservedObject var settings: AppSettings

    private var currentModel: String {
        settings.settings.iosDeviceModel
    }

    private var isLegacy: Bool {
        DeviceProfileOption.isLegacyModel(currentModel)
    }

    private var isIPhone: Bool {
        DeviceProfileOption.isIPhone(currentModel)
    }

    var body: some View {
        Form {
            if isLegacy {
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
                    if !DeviceProfileOption.allModern.contains(where: { $0.model == currentModel }) {
                        Divider()
                        Text(DeviceProfileOption.displayName(for: currentModel)).tag(currentModel)
                    }
                }

                layoutComparisonRow
            }

            Section {
                Picker("device.reportedIOS.title", selection: $settings.settings.reportedIOSVersionMode) {
                    Text("device.reportedIOS.automatic").tag(ReportedIOSVersionMode.automatic)
                    Text("device.reportedIOS.followHost").tag(ReportedIOSVersionMode.followHost)
                    Text("device.reportedIOS.compat18_3").tag(ReportedIOSVersionMode.compat18_3)
                }
                .help("device.reportedIOS.help")

                Text("device.reportedIOS.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Notch", isOn: $settings.settings.notch)
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
