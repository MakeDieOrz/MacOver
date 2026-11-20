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
        PixelBudget.limit / 1_000_000.0
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
