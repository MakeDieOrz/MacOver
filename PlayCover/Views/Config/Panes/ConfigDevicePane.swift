//
//  ConfigDevicePane.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

struct ConfigDevicePane: View {
    @Environment(\.locale) private var locale

    @Bindable var settings: AppSettings
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

    private var isEffectiveIPhone: Bool {
        DeviceProfileOption.isIPhone(effectiveModel)
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
                    legacyWarningBanner
                }
            }

            Section {
                Picker(
                    ConfigLabelFormatter.clean("settings.picker.iosDevice", locale: locale),
                    selection: $settings.settings.iosDeviceModel
                ) {
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

                layoutStatusRow

                if DeviceProfileOption.isMSeriesIPad(effectiveModel) {
                    Label("device.mSeriesNotice", systemImage: "cpu")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker(
                    ConfigLabelFormatter.clean("device.reportedIOS.title", locale: locale),
                    selection: $settings.settings.reportedIOSVersionMode
                ) {
                    Text("device.reportedIOS.automatic").tag(ReportedIOSVersionMode.automatic)
                    Text("device.reportedIOS.followHost").tag(ReportedIOSVersionMode.followHost)
                    Text("device.reportedIOS.compat18_3").tag(ReportedIOSVersionMode.compat18_3)
                    Text("device.reportedIOS.compat13_7").tag(ReportedIOSVersionMode.compat13_7)
                }
                .help("device.reportedIOS.help")

                Text("device.reportedIOS.help")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if isCompat13_7 {
                    if let minOS = settings.settings.originalMinimumOSVersion,
                       ReportedIOSVersionMode.isMinimumOSVersion(minOS, higherThan: 13, minor: 7) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .accessibilityHidden(true)
                            Text(String(
                                format: ConfigLabelFormatter.localized("device.ios13MinOSWarning", locale: locale),
                                minOS
                            ))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !DeviceProfileOption.supportsIOS13(currentModel) {
                        ios13MismatchBanner
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

    private var legacyWarningBanner: some View {
        let message = String(
            format: ConfigLabelFormatter.localized("device.legacyBanner", locale: locale),
            DeviceProfileOption.displayName(for: currentModel)
        )
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("device.upgradeToM1") {
                    settings.update { $0.iosDeviceModel = "iPad13,8" }
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("device.upgradeToM1") {
                    settings.update { $0.iosDeviceModel = "iPad13,8" }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var ios13MismatchBanner: some View {
        let message = String(
            format: ConfigLabelFormatter.localized("device.ios13ModelMismatch", locale: locale),
            DeviceProfileOption.displayName(for: currentModel)
        )
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("device.switchToIOS13Model") {
                    settings.update {
                        $0.iosDeviceModel = DeviceProfileOption.recommendedIOS13Model(isIPhone: isIPhone)
                    }
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("device.switchToIOS13Model") {
                    settings.update {
                        $0.iosDeviceModel = DeviceProfileOption.recommendedIOS13Model(isIPhone: isIPhone)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    private var layoutStatusRow: some View {
        LabeledContent(ConfigLabelFormatter.clean("device.layoutTitle", locale: locale)) {
            HStack(spacing: 6) {
                Image(systemName: isEffectiveIPhone ? "iphone" : "ipad.landscape")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(isEffectiveIPhone ? "device.layout.compact" : "device.layout.regular"))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            .font(.callout)
        }
    }
}
