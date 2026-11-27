//
//  ConfigDisplayPane.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

struct ConfigDisplayPane: View {
    @Bindable var settings: AppSettings
    var onOpenStrictMode: (() -> Void)?

    @State private var customWidth = 1920
    @State private var customHeight = 1080

    private var isStrictMode: Bool {
        settings.settings.strictEmulationMode
    }

    private static let integerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        return formatter
    }()

    private static let scalerFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 1
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
            customWidth = settings.settings.windowWidth
            customHeight = settings.settings.windowHeight
        }
        .onChange(of: settings.settings.windowWidth) { _, newWidth in
            if customWidth != newWidth {
                customWidth = newWidth
            }
        }
        .onChange(of: settings.settings.windowHeight) { _, newHeight in
            if customHeight != newHeight {
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
            if !isStrictMode, settings.settings.resolution == 5, settings.settings.windowWidth != newWidth {
                applyComputedDimensions()
            }
        }
        .onChange(of: customHeight) { _, newHeight in
            if !isStrictMode, settings.settings.resolution == 5, settings.settings.windowHeight != newHeight {
                applyComputedDimensions()
            }
        }
        .onChange(of: settings.settings.resizableAspectRatioType) {
            syncResizableRatioPresets()
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
                "settings.picker.adaptiveRes",
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
                LabeledContent("strict.display.logicalPoints") {
                    Text("\(data.effectiveWindowWidth) × \(data.effectiveWindowHeight) pt")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("strict.display.nativePixels") {
                    Text("\(px.width) × \(px.height) px · \(spec.maxFrameRateHz) Hz")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("strict.scaleMode.title") {
                    let key = data.strictViewportScaleMode == .native1x
                        ? "strict.scaleMode.native1x"
                        : "strict.scaleMode.fitScreen"
                    Text(LocalizedStringKey(key))
                        .foregroundStyle(.secondary)
                }
            } else if settings.settings.resolution == 1 {
                let autoRes = AppSettings.autoResolution()
                LabeledContent("settings.text.detectedResolution") {
                    Text("\(autoRes.width) × \(autoRes.height)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else if settings.settings.resolution >= 2 && settings.settings.resolution <= 4 {
                Picker("settings.picker.aspectRatio", selection: $settings.settings.aspectRatio) {
                    Text("4:3").tag(0)
                    Text("16:9").tag(1)
                    Text("16:10").tag(2)
                }
                .pickerStyle(.segmented)
            } else if settings.settings.resolution == 5 {
                LabeledContent("settings.text.customWidth") {
                    HStack(spacing: 6) {
                        TextField("", value: $customWidth, formatter: Self.integerFormatter)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $customWidth, in: 320...7680, step: 16)
                            .labelsHidden()
                    }
                }
                LabeledContent("settings.text.customHeight") {
                    HStack(spacing: 6) {
                        TextField("", value: $customHeight, formatter: Self.integerFormatter)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 72)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $customHeight, in: 240...4320, step: 16)
                            .labelsHidden()
                    }
                }
            } else if settings.settings.resolution == 6 {
                Picker("settings.picker.aspectRatio", selection: $settings.settings.resizableAspectRatioType) {
                    Text("settings.picker.aspectRatio.free").tag(0)
                    Text("settings.picker.aspectRatio.custom").tag(1)
                    Text("4:3").tag(2)
                    Text("16:9").tag(3)
                    Text("16:10").tag(4)
                }
                .pickerStyle(.segmented)

                if settings.settings.resizableAspectRatioType == 1 {
                    LabeledContent("settings.picker.aspectRatio.custom") {
                        HStack(spacing: 6) {
                            TextField("", value: $settings.settings.resizableAspectRatioWidth,
                                      formatter: Self.integerFormatter)
                                .frame(width: 72)
                                .multilineTextAlignment(.trailing)
                            Text(":")
                            TextField("", value: $settings.settings.resizableAspectRatioHeight,
                                      formatter: Self.integerFormatter)
                                .frame(width: 72)
                                .multilineTextAlignment(.trailing)
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
                guard !isStrictMode else { return }
                settings.settings.customScaler = newValue
            }
        )
        let budget = settings.settings.pixelBudget
        return Section {
            LabeledContent("settings.picker.scaler") {
                HStack(spacing: 6) {
                    TextField("", value: scalerBinding, formatter: Self.scalerFormatter)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .multilineTextAlignment(.trailing)
                    Stepper("", value: scalerBinding, in: 0.5...3.0, step: 0.1)
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
            Picker("display.frameRate.title", selection: $settings.settings.frameRateTargetMode) {
                Text("display.frameRate.adaptive").tag(FrameRateTarget.adaptive)
                Text("display.frameRate.fixed120").tag(FrameRateTarget.fixed120)
                Text("display.frameRate.fixed60").tag(FrameRateTarget.fixed60)
                Text("display.frameRate.fixed30").tag(FrameRateTarget.fixed30)
            }
            .help("display.frameRate.help")

            Picker(
                "display.windowCompat.title",
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
                "settings.settings.displayRotation",
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
        case 1:
            pair = (settings.settings.resizableAspectRatioWidth,
                    settings.settings.resizableAspectRatioHeight)
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
