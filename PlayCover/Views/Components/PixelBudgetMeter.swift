//
//  PixelBudgetMeter.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

struct PixelBudgetMeter: View {
    @Environment(\.locale) private var locale

    let budget: PixelBudget
    var titleKey: LocalizedStringKey = "budget.title"
    var compact: Bool = false
    var onFitToBudget: ((Double) -> Void)?

    private var tintColor: Color {
        switch budget.level {
        case .ok: return .green
        case .caution: return .orange
        case .over: return .red
        }
    }

    private var levelTitleKey: LocalizedStringKey {
        switch budget.level {
        case .ok: return "budget.healthy"
        case .caution: return "budget.caution"
        case .over: return "budget.over"
        }
    }

    private var normalizedProgress: Double {
        min(max(budget.ratio, 0), 1)
    }

    private var weightedMegapixels: Double {
        budget.weightedPixels / 1_000_000.0
    }

    private var limitMegapixels: Double {
        budget.adaptiveLimit / 1_000_000.0
    }

    private var readoutText: String {
        String(
            format: ConfigLabelFormatter.localized("budget.readout", locale: locale),
            locale: locale,
            weightedMegapixels,
            limitMegapixels
        )
    }

    private var renderedDetailsText: String {
        String(
            format: ConfigLabelFormatter.localized("budget.renderedDetails", locale: locale),
            locale: locale,
            budget.renderedWidth,
            budget.renderedHeight,
            budget.memoryTier.label
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 6) {
            headerRow

            ProgressView(value: normalizedProgress)
                .tint(tintColor)

            detailsRow

            if budget.level == .over, let onFitToBudget {
                suggestedFitRow(onFitToBudget: onFitToBudget)
            }
        }
    }

    private var headerRow: some View {
        AdaptiveLeadingTrailingLayout(horizontalSpacing: 6, verticalSpacing: 2) {
            headerLeadingLabels
            readoutLabel
        }
    }

    private var headerLeadingLabels: some View {
        HStack(spacing: 6) {
            if !compact {
                Text(titleKey)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(levelTitleKey)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tintColor)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var readoutLabel: some View {
        Text(readoutText)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var detailsRow: some View {
        AdaptiveLeadingTrailingLayout(horizontalSpacing: 6, verticalSpacing: 4) {
            renderedDetailsLabel
            textureEdgeBadge
        }
    }

    private var renderedDetailsLabel: some View {
        Text(renderedDetailsText)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var textureEdgeBadge: some View {
        if budget.exceedsMaxTextureEdge {
            Label("budget.textureEdgeWarning", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.16)))
                .fixedSize()
                .help("budget.textureEdgeWarning.help")
        }
    }

    private func suggestedFitRow(onFitToBudget: @escaping (Double) -> Void) -> some View {
        AdaptiveLeadingTrailingLayout(horizontalSpacing: 8, verticalSpacing: 6) {
            suggestedScalerLabel
            fitButton(onFitToBudget: onFitToBudget)
        }
    }

    private var suggestedScalerLabel: some View {
        HStack(spacing: 3) {
            Text("pixelBudget.suggestedScaler")
            Text(String(format: "%.1f×", budget.fittedScaler))
                .monospacedDigit()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func fitButton(onFitToBudget: @escaping (Double) -> Void) -> some View {
        Button("budget.fit") {
            onFitToBudget(budget.fittedScaler)
        }
        .controlSize(.small)
        .buttonStyle(.borderedProminent)
        .tint(.accentColor)
        .fixedSize()
    }
}
