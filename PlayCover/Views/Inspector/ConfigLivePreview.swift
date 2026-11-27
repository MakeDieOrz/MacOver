//
//  ConfigLivePreview.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

struct ConfigLivePreview: View {
    @Environment(AppNavigationState.self) var navState
    @Environment(\.locale) private var locale

    var app: PlayApp
    var settings: AppSettings

    private var targetAspectRatio: CGFloat {
        let data = settings.settings
        if data.effectiveResolution == 6 {
            switch data.resizableAspectRatioType {
            case 2: return 4.0 / 3.0
            case 3: return 16.0 / 9.0
            case 4: return 16.0 / 10.0
            case 1 where data.resizableAspectRatioWidth > 0 && data.resizableAspectRatioHeight > 0:
                return CGFloat(data.resizableAspectRatioWidth) / CGFloat(data.resizableAspectRatioHeight)
            default:
                return 16.0 / 10.0
            }
        }
        let width = max(CGFloat(data.effectiveWindowWidth), 1)
        let height = max(CGFloat(data.effectiveWindowHeight), 1)
        return width / height
    }

    private var frameRateLabelKey: String {
        switch settings.settings.frameRateTargetMode {
        case .adaptive: return "display.frameRate.adaptive"
        case .fixed120: return "display.frameRate.fixed120"
        case .fixed60: return "display.frameRate.fixed60"
        case .fixed30: return "display.frameRate.fixed30"
        }
    }

    private var isTopRestartBannerVisible: Bool {
        navState.configTargetID == app.id
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    Text("inspector.previewTitle")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    if settings.settings.strictEmulationMode {
                        AppStatusPill(kind: .strict, compact: true)
                    }
                }

                windowSchematic

                metadataList

                if navState.activeConfigPane != .display {
                    Divider()

                    PixelBudgetMeter(
                        budget: settings.settings.pixelBudget,
                        compact: true,
                        onFitToBudget: settings.settings.strictEmulationMode ? nil : { fitted in
                            settings.update { $0.customScaler = fitted }
                        }
                    )
                }

                if app.isRunning && !app.restartRequiredChanges.isEmpty {
                    Divider()
                    pendingRestartSection
                }
            }
            .padding(16)
        }
    }

    private var metadataList: some View {
        let data = settings.settings
        let scalerText = String(format: "%.1f×", data.effectiveCustomScaler)
        let isPhone = DeviceProfileOption.isIPhone(data.effectiveIOSDeviceModel)

        return VStack(alignment: .leading, spacing: 10) {
            if data.strictEmulationMode {
                let orientKey = data.strictViewportOrientation == .portrait
                    ? "strict.orientation.portrait"
                    : "strict.orientation.landscape"
                let scaleKey = data.strictViewportScaleMode == .native1x
                    ? "strict.scaleMode.native1xShort"
                    : "strict.scaleMode.fitScreenShort"
                let orientText = ConfigLabelFormatter.localized(orientKey, locale: locale)
                let scaleText = ConfigLabelFormatter.localized(scaleKey, locale: locale)
                previewRow("strict.section.title") {
                    Text("\(orientText) · \(scaleText)")
                        .foregroundStyle(Color.accentColor)
                }
            }

            previewRow("settings.picker.iosDevice") {
                Text(DeviceProfileOption.displayName(for: data.effectiveIOSDeviceModel))
            }

            previewRow("settings.picker.adaptiveRes") {
                Text("\(data.effectiveWindowWidth)×\(data.effectiveWindowHeight) @ \(scalerText)")
                    .monospacedDigit()
            }

            previewRow("display.frameRate.title") {
                Text(LocalizedStringKey(frameRateLabelKey))
            }

            previewRow("device.layoutTitle") {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: isPhone ? "iphone" : "ipad.landscape")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(LocalizedStringKey(isPhone ? "device.layout.compact" : "device.layout.regular"))
                }
            }
        }
    }

    private func previewRow<Value: View>(
        _ titleKey: String,
        @ViewBuilder value: () -> Value
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ConfigLabelFormatter.clean(titleKey, locale: locale))
                .font(.caption)
                .foregroundStyle(.secondary)
            value()
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var windowSchematic: some View {
        let clampedAppAspect = min(max(targetAspectRatio, 0.45), 2.5)

        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )

            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.20))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                )
                .overlay {
                    AppIconView(app: app, size: 28, cornerRadius: 7)
                }
                .aspectRatio(clampedAppAspect, contentMode: .fit)
                .padding(14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 148)
    }

    private var pendingRestartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("inspector.pendingRestart")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)

            ForEach(app.restartRequiredChanges, id: \.self) { field in
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(LocalizedStringKey(field.localizedKey))
                        .font(.caption)
                }
            }

            if !isTopRestartBannerVisible {
                Button {
                    Task { await app.restart() }
                } label: {
                    Label("action.restart", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
        }
    }
}
