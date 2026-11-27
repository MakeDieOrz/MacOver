//
//  ConfigLivePreview.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

struct ConfigLivePreview: View {
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 6) {
                    Text("inspector.previewTitle")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 4)
                    if settings.settings.strictEmulationMode {
                        AppStatusPill(kind: .strict, compact: true)
                    }
                }

                windowSchematic

                VStack(alignment: .leading, spacing: 6) {
                    let data = settings.settings
                    if data.strictEmulationMode {
                        LabeledContent("strict.section.title") {
                            let orientKey = data.strictViewportOrientation == .portrait
                                ? "strict.orientation.portrait"
                                : "strict.orientation.landscape"
                            let scaleKey = data.strictViewportScaleMode == .native1x
                                ? "strict.scaleMode.native1xShort"
                                : "strict.scaleMode.fitScreenShort"
                            Text("\(NSLocalizedString(orientKey, comment: "")) · "
                                 + "\(NSLocalizedString(scaleKey, comment: ""))")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    LabeledContent("settings.picker.iosDevice") {
                        Text(DeviceProfileOption.displayName(for: data.effectiveIOSDeviceModel))
                            .font(.caption)
                            .lineLimit(1)
                    }
                    LabeledContent("settings.picker.adaptiveRes") {
                        let scalerText = String(format: "%.1f×", data.effectiveCustomScaler)
                        Text("\(data.effectiveWindowWidth)×\(data.effectiveWindowHeight) @ \(scalerText)")
                            .font(.caption.monospacedDigit())
                    }
                    LabeledContent("display.frameRate.title") {
                        Text(LocalizedStringKey(frameRateLabelKey))
                            .font(.caption)
                    }
                    LabeledContent("device.layoutTitle") {
                        let isPhone = DeviceProfileOption.isIPhone(data.effectiveIOSDeviceModel)
                        Label(
                            LocalizedStringKey(isPhone ? "device.layout.compact" : "device.layout.regular"),
                            systemImage: isPhone ? "iphone" : "ipad.landscape"
                        )
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                    }
                }

                Divider()

                PixelBudgetMeter(
                    budget: settings.settings.pixelBudget,
                    compact: true,
                    onFitToBudget: settings.settings.strictEmulationMode ? nil : { fitted in
                        settings.update { $0.customScaler = fitted }
                    }
                )

                if app.isRunning && !app.restartRequiredChanges.isEmpty {
                    Divider()
                    pendingRestartSection
                }
            }
            .padding(16)
        }
    }

    private var windowSchematic: some View {
        let hostAspect: CGFloat = {
            let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 16, height: 10)
            return max(frame.width / max(frame.height, 1), 1.0)
        }()
        let clampedAppAspect = min(max(targetAspectRatio, 0.45), 2.5)

        return ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                )
                .aspectRatio(hostAspect, contentMode: .fit)

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
    }

    private var pendingRestartSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("inspector.pendingRestart")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)

            ForEach(app.restartRequiredChanges, id: \.self) { field in
                HStack {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.orange)
                    Text(LocalizedStringKey(field.localizedKey))
                        .font(.caption)
                }
            }

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
