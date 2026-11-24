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
            .fixedSize()
            .help("restart.badge")
    }
}

/// Unified capsule language for per-app state across library, config and inspectors.
/// Running = green, Strict Emulation = accent (locked/authentic), PlayTools missing = orange (actionable).
struct AppStatusPill: View {
    enum Kind {
        case running
        case strict
        case noPlayTools

        var titleKey: LocalizedStringKey {
            switch self {
            case .running: return "sidebar.runningBadge"
            case .strict: return "strict.pill"
            case .noPlayTools: return "library.status.noPlayTools"
            }
        }

        var systemImage: String {
            switch self {
            case .running: return "circle.fill"
            case .strict: return "lock.shield.fill"
            case .noPlayTools: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .running: return .green
            case .strict: return .accentColor
            case .noPlayTools: return .orange
            }
        }

        var helpKey: LocalizedStringKey {
            switch self {
            case .running: return "sidebar.runningBadge"
            case .strict: return "strict.banner.title"
            case .noPlayTools: return "settings.noPlayTools"
            }
        }
    }

    let kind: Kind
    var compact = false

    var body: some View {
        Label {
            Text(kind.titleKey)
        } icon: {
            Image(systemName: kind.systemImage)
                .imageScale(.small)
        }
        .labelStyle(.titleAndIcon)
        .font((compact ? Font.caption2 : Font.caption).weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(kind.tint)
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 1 : 2)
        .background(Capsule().fill(kind.tint.opacity(0.14)))
        .overlay(Capsule().strokeBorder(kind.tint.opacity(0.32), lineWidth: 0.5))
        .fixedSize()
        .help(kind.helpKey)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(kind.helpKey))
    }
}

/// Shared callout used at the top of config panes and inspectors to explain why controls are
/// read-only. Strict Emulation uses calm accent styling; missing PlayTools uses actionable orange.
struct ConfigStateCallout: View {
    enum Style {
        case strict
        case noPlayTools
    }

    let style: Style
    let titleKey: LocalizedStringKey
    var noteKey: LocalizedStringKey?
    var actionKey: LocalizedStringKey?
    var action: (() -> Void)?

    private var tint: Color {
        style == .strict ? .accentColor : .orange
    }

    private var systemImage: String {
        style == .strict ? "lock.shield.fill" : "exclamationmark.triangle.fill"
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 10) {
                icon
                texts
                Spacer(minLength: 8)
                actionButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    icon
                    texts
                }
                actionButton
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.title3)
            .foregroundStyle(tint)
            .accessibilityHidden(true)
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titleKey)
                .font(.callout.weight(.semibold))
            if let noteKey {
                Text(noteKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var actionButton: some View {
        if let actionKey, let action {
            Button(actionKey, action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
        }
    }
}

/// Inline caption explaining that the controls directly above are locked by Strict Emulation Mode.
struct StrictLockedNote: View {
    let textKey: LocalizedStringKey
    var onOpenStrictMode: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(textKey, systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let onOpenStrictMode {
                Button("strict.openAdvanced", action: onOpenStrictMode)
                    .buttonStyle(.link)
                    .font(.caption)
                    .fixedSize()
            }
        }
    }
}

extension PlayCoverRestartField {
    var localizedKey: String {
        "restart.field.\(rawValue)"
    }
}
