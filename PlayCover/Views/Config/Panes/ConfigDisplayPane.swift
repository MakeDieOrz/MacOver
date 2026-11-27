//
//  ConfigDisplayPane.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

struct ConfigDisplayPane: View {
    @Environment(\.locale) private var locale

    @Bindable var settings: AppSettings
    var onOpenStrictMode: (() -> Void)?

    @State private var customWidth = 1920
    @State private var customHeight = 1080
    @State private var customAspectWidth = 16
    @State private var customAspectHeight = 9

    private var isStrictMode: Bool {
        settings.settings.strictEmulationMode
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = 16_384
        return formatter
    }()

    private static let scalerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 1
        formatter.minimum = 0.25
        formatter.maximum = 8.0
        formatter.decimalSeparator = "."
        return formatter
    }()

    var body: some View {
        Form {
            if isStrictMode {
                strictModeBannerSection
            }
            resolutionSection
            scalerAndBudgetSection
            frameRateAndCompatSection
            windowBehaviorSection
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onAppear {
            customWidth = max(1, settings.settings.windowWidth)
            customHeight = max(1, settings.settings.windowHeight)
            if settings.settings.resizableAspectRatioType == 1,
               settings.settings.resizableAspectRatioWidth > 0,
               settings.settings.resizableAspectRatioHeight > 0 {
                customAspectWidth = settings.settings.resizableAspectRatioWidth
                customAspectHeight = settings.settings.resizableAspectRatioHeight
            }
        }
        .onChange(of: settings.settings.windowWidth) { _, newWidth in
            if settings.settings.resolution == 5, customWidth != newWidth, newWidth > 0 {
                customWidth = newWidth
            }
        }
        .onChange(of: settings.settings.windowHeight) { _, newHeight in
            if settings.settings.resolution == 5, customHeight != newHeight, newHeight > 0 {
                customHeight = newHeight
            }
        }
        .onChange(of: settings.settings.resolution) {
            applyComputedDimensions()
        }
        .onChange(of: settings.settings.aspectRatio) {
            applyComputedDimensions()
        }
        .onChange(of: customWidth) { _, newWidth in
            let clamped = max(1, newWidth)
            if !isStrictMode, settings.settings.resolution == 5, settings.settings.windowWidth != clamped {
                applyComputedDimensions()
            }
        }
        .onChange(of: customHeight) { _, newHeight in
            let clamped = max(1, newHeight)
            if !isStrictMode, settings.settings.resolution == 5, settings.settings.windowHeight != clamped {
                applyComputedDimensions()
            }
        }
        .onChange(of: settings.settings.resizableAspectRatioType) {
            syncResizableRatioPresets()
        }
        .onChange(of: customAspectWidth) { _, newValue in
            let clamped = max(1, newValue)
            if !isStrictMode,
               settings.settings.resizableAspectRatioType == 1,
               settings.settings.resizableAspectRatioWidth != clamped {
                settings.update { $0.resizableAspectRatioWidth = clamped }
            }
        }
        .onChange(of: customAspectHeight) { _, newValue in
            let clamped = max(1, newValue)
            if !isStrictMode,
               settings.settings.resizableAspectRatioType == 1,
               settings.settings.resizableAspectRatioHeight != clamped {
                settings.update { $0.resizableAspectRatioHeight = clamped }
            }
        }
    }

    private var strictModeBannerSection: some View {
        Section {
            ConfigStateCallout(
                style: .strict,
                titleKey: "strict.banner.title",
                noteKey: "strict.banner.displayNote",
                actionKey: onOpenStrictMode == nil ? nil : "strict.openAdvanced",
                action: onOpenStrictMode
            )
        }
    }

    private var resolutionSection: some View {
        Section {
            Picker(
                ConfigLabelFormatter.clean("settings.picker.adaptiveRes", locale: locale),
                selection: Binding(
                    get: { settings.settings.effectiveResolution },
                    set: { newValue in
                        guard !isStrictMode else { return }
                        settings.settings.resolution = newValue
                    }
                )
            ) {
                Text("settings.picker.adaptiveRes.0").tag(0)
                Text("settings.picker.adaptiveRes.1").tag(1)
                Text("1080p").tag(2)
                Text("1440p").tag(3)
                Text("4K").tag(4)
                Text("settings.picker.adaptiveRes.5").tag(5)
                Text("settings.picker.adaptiveRes.6").tag(6)
            }
            .help("settings.picker.adaptiveRes.help")
            .disabled(isStrictMode)

            if isStrictMode {
                let data = settings.settings
                let spec = data.strictDeviceDisplaySpec
                let px = spec.pixelSize(orientation: data.strictViewportOrientation)
                LabeledContent(ConfigLabelFormatter.clean("strict.display.logicalPoints", locale: locale)) {
                    Text("\(data.effectiveWindowWidth) × \(data.effectiveWindowHeight) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent(ConfigLabelFormatter.clean("strict.display.nativePixels", locale: locale)) {
                    Text("\(px.width) × \(px.height) px · \(spec.maxFrameRateHz) Hz")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent(ConfigLabelFormatter.clean("strict.scaleMode.title", locale: locale)) {
                    let key = data.strictViewportScaleMode == .native1x
                        ? "strict.scaleMode.native1x"
                        : "strict.scaleMode.fitScreen"
                    Text(LocalizedStringKey(key))
                        .foregroundStyle(.secondary)
                }
            } else if settings.settings.resolution == 1 {
                let autoRes = AppSettings.autoResolution()
                LabeledContent(ConfigLabelFormatter.clean("settings.text.detectedResolution", locale: locale)) {
                    Text("\(autoRes.width) × \(autoRes.height)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else if settings.settings.resolution >= 2 && settings.settings.resolution <= 4 {
                Picker(
                    ConfigLabelFormatter.clean("settings.picker.aspectRatio", locale: locale),
                    selection: $settings.settings.aspectRatio
                ) {
                    Text("4:3").tag(0)
                    Text("16:9").tag(1)
                    Text("16:10").tag(2)
                }
                .pickerStyle(.segmented)
            } else if settings.settings.resolution == 5 {
                LabeledContent(ConfigLabelFormatter.clean("settings.text.customWidth", locale: locale)) {
                    HStack(spacing: 6) {
                        TextField("", value: $customWidth, formatter: Self.integerFormatter)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                        Stepper("", value: $customWidth, in: 320...7680, step: 16)
                            .labelsHidden()
                    }
                }
                LabeledContent(ConfigLabelFormatter.clean("settings.text.customHeight", locale: locale)) {
                    HStack(spacing: 6) {
                        TextField("", value: $customHeight, formatter: Self.integerFormatter)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                        Stepper("", value: $customHeight, in: 240...4320, step: 16)
                            .labelsHidden()
                    }
                }
            } else if settings.settings.resolution == 6 {
                Picker(
                    ConfigLabelFormatter.clean("settings.picker.aspectRatio", locale: locale),
                    selection: $settings.settings.resizableAspectRatioType
                ) {
                    Text("settings.picker.aspectRatio.free").tag(0)
                    Text("settings.picker.aspectRatio.custom").tag(1)
                    Text("4:3").tag(2)
                    Text("16:9").tag(3)
                    Text("16:10").tag(4)
                }
                .pickerStyle(.menu)

                if settings.settings.resizableAspectRatioType == 1 {
                    LabeledContent(ConfigLabelFormatter.clean("settings.picker.aspectRatio.custom", locale: locale)) {
                        HStack(spacing: 6) {
                            TextField("", value: $customAspectWidth, formatter: Self.integerFormatter)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                            Text(":")
                                .foregroundStyle(.secondary)
                            TextField("", value: $customAspectHeight, formatter: Self.integerFormatter)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 72)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private var scalerAndBudgetSection: some View {
        let scalerBinding = Binding<Double>(
            get: { settings.settings.effectiveCustomScaler },
            set: { newValue in
                guard !isStrictMode, newValue.isFinite else { return }
                let clamped = min(8.0, max(0.25, newValue))
                settings.settings.customScaler = (clamped * 100.0).rounded() / 100.0
            }
        )
        let budget = settings.settings.pixelBudget
        return Section {
            LabeledContent(ConfigLabelFormatter.clean("settings.picker.scaler", locale: locale)) {
                HStack(spacing: 6) {
                    TextField("", value: scalerBinding, formatter: Self.scalerFormatter)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                    Stepper("", value: scalerBinding, in: 0.25...8.0, step: 0.1)
                        .labelsHidden()
                }
            }
            .disabled(isStrictMode)

            PixelBudgetMeter(
                budget: budget,
                onFitToBudget: isStrictMode ? nil : { fitted in
                    settings.update { $0.customScaler = fitted }
                }
            )

            if budget.exceedsMaxTextureEdge {
                Label("budget.textureEdgeWarning.help", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var frameRateAndCompatSection: some View {
        Section {
            Picker(
                ConfigLabelFormatter.clean("display.frameRate.title", locale: locale),
                selection: $settings.settings.frameRateTargetMode
            ) {
                Text("display.frameRate.adaptive").tag(FrameRateTarget.adaptive)
                Text("display.frameRate.fixed120").tag(FrameRateTarget.fixed120)
                Text("display.frameRate.fixed60").tag(FrameRateTarget.fixed60)
                Text("display.frameRate.fixed30").tag(FrameRateTarget.fixed30)
            }
            .help("display.frameRate.help")

            Picker(
                ConfigLabelFormatter.clean("display.windowCompat.title", locale: locale),
                selection: Binding(
                    get: { settings.settings.effectiveWindowCompatibility },
                    set: { newValue in
                        guard !isStrictMode else { return }
                        settings.settings.windowCompatibility = newValue
                    }
                )
            ) {
                Text("display.windowCompat.standard").tag(WindowCompatibilityMode.standard)
                Text("display.windowCompat.invertedMetrics").tag(WindowCompatibilityMode.invertedMetrics)
                Text("display.windowCompat.invertedLegacyResize")
                    .tag(WindowCompatibilityMode.invertedLegacyResize)
            }
            .help("display.windowCompat.help")
            .disabled(isStrictMode)

            Picker(
                ConfigLabelFormatter.clean("settings.settings.displayRotation", locale: locale),
                selection: Binding(
                    get: { settings.settings.effectiveDisplayRotation },
                    set: { newValue in
                        guard !isStrictMode else { return }
                        settings.settings.displayRotation = newValue
                    }
                )
            ) {
                Text("settings.settings.displayRotation.default").tag(0)
                Text("settings.settings.displayRotation.portrait").tag(1)
                Text("settings.settings.displayRotation.landscapeRight").tag(2)
                Text("settings.settings.displayRotation.portraitUpsideDown").tag(3)
                Text("settings.settings.displayRotation.flipFix").tag(4)
            }
            .disabled(isStrictMode)
        }
    }

    private var windowBehaviorSection: some View {
        Section {
            Toggle("settings.toggle.disableDisplaySleep", isOn: $settings.settings.disableTimeout)
                .help("settings.toggle.disableDisplaySleep.help")
            Toggle("settings.toggle.quitOnWindowClose", isOn: $settings.settings.quitOnWindowClose)
                .help("settings.toggle.quitOnWindowClose.help")
            Toggle("settings.toggle.hideTitleBar", isOn: $settings.settings.hideTitleBar)
            Toggle("settings.toggle.floatingWindow", isOn: $settings.settings.floatingWindow)
        }
    }

    private func applyComputedDimensions() {
        guard !isStrictMode else { return }
        let dims = AppSettingsData.computedDimensions(
            resolution: settings.settings.resolution,
            aspectRatio: settings.settings.aspectRatio,
            customWidth: customWidth,
            customHeight: customHeight
        )
        settings.update { updated in
            updated.windowWidth = dims.width
            updated.windowHeight = dims.height
        }
    }

    private func syncResizableRatioPresets() {
        guard !isStrictMode else { return }
        let pair: (width: Int, height: Int)
        switch settings.settings.resizableAspectRatioType {
        case 0: pair = (0, 0)
        case 1: pair = (max(1, customAspectWidth), max(1, customAspectHeight))
        case 2: pair = (4, 3)
        case 3: pair = (16, 9)
        case 4: pair = (16, 10)
        default: pair = (16, 9)
        }
        settings.update { updated in
            updated.resizableAspectRatioWidth = pair.width
            updated.resizableAspectRatioHeight = pair.height
        }
    }
}
