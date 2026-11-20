//
//  PresetCard.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI

struct PresetCard: View {
    let preset: PlayAppSettingsPreset
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: preset.systemImage)
                        .font(.title3)
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    Spacer()
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(LocalizedStringKey(preset.titleKey))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(LocalizedStringKey(preset.subtitleKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isActive ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.18),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

struct RestartFieldBadge: View {
    var body: some View {
        Text("restart.badge")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.orange.opacity(0.16)))
    }
}

extension PlayCoverRestartField {
    var localizedKey: String {
        "restart.field.\(rawValue)"
    }
}
