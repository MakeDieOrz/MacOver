//
//  PixelBudgetMeter.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

struct PixelBudgetMeter: View {
    let budget: PixelBudget
    var compact: Bool = false
    var onFitToBudget: ((Double) -> Void)?

    private var tintColor: Color {
        switch budget.level {
        case .ok: return .green
        case .caution: return .orange
        case .over: return .red
        }
    }

    private var levelTitleKey: String {
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

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            HStack(spacing: 6) {
                if !compact {
                    Text("budget.title")
                        .font(.subheadline.weight(.medium))
                }
                Text(LocalizedStringKey(levelTitleKey))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tintColor)
                Spacer()
                Text(String(
                    format: NSLocalizedString("budget.readout", comment: ""),
                    weightedMegapixels,
                    limitMegapixels
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            ProgressView(value: normalizedProgress)
                .tint(tintColor)

            HStack(spacing: 6) {
                Text(String(
                    format: NSLocalizedString("budget.renderedDetails", comment: ""),
                    budget.renderedWidth,
                    budget.renderedHeight,
                    budget.memoryTier.label
                ))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Spacer(minLength: 4)

                if budget.exceedsMaxTextureEdge {
                    Label("budget.textureEdgeWarning", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.16)))
                        .help("budget.textureEdgeWarning.help")
                }
            }

            if budget.level == .over, let onFitToBudget {
                HStack {
                    Text(String(format: "%.1f×", budget.fittedScaler))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("budget.fit") {
                        onFitToBudget(budget.fittedScaler)
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.accentColor)
                }
            }
        }
    }
}
