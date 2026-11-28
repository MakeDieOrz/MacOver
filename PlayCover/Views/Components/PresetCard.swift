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

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: preset.systemImage)
                        .font(.title3)
                        .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    Spacer(minLength: 4)
                    if isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }

                Text(LocalizedStringKey(preset.titleKey))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(LocalizedStringKey(preset.subtitleKey))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        isActive
                            ? Color.accentColor.opacity(0.14)
                            : Color.secondary.opacity(isHovered ? 0.12 : 0.08)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isActive
                            ? Color.accentColor.opacity(0.55)
                            : Color.secondary.opacity(isHovered ? 0.30 : 0.18),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help(LocalizedStringKey(preset.subtitleKey))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
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
        case preparing(AppLaunchStage)
        case launching
        case running
        case runningActive
        case terminating
        case strict
        case noPlayTools

        var titleKey: LocalizedStringKey {
            switch self {
            case .preparing(let stage): return LocalizedStringKey(stage.localizationKey)
            case .launching: return "app.state.launching"
            case .running: return "sidebar.runningBadge"
            case .runningActive: return "app.state.runningActive"
            case .terminating: return "app.state.terminating"
            case .strict: return "strict.pill"
            case .noPlayTools: return "library.status.noPlayTools"
            }
        }

        var systemImage: String {
            switch self {
            case .preparing, .launching, .terminating: return "hourglass"
            case .running, .runningActive: return "circle.fill"
            case .strict: return "lock.shield.fill"
            case .noPlayTools: return "exclamationmark.triangle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .preparing, .launching: return .accentColor
            case .running, .runningActive: return .green
            case .terminating: return .orange
            case .strict: return .accentColor
            case .noPlayTools: return .orange
            }
        }

        var helpKey: LocalizedStringKey {
            switch self {
            case .preparing(let stage): return LocalizedStringKey(stage.localizationKey)
            case .launching: return "app.state.launching"
            case .running: return "sidebar.runningBadge"
            case .runningActive: return "app.state.runningActive"
            case .terminating: return "app.state.terminating"
            case .strict: return "strict.banner.title"
            case .noPlayTools: return "settings.noPlayTools"
            }
        }

        var showsSpinner: Bool {
            switch self {
            case .preparing, .launching, .terminating:
                return true
            case .running, .runningActive, .strict, .noPlayTools:
                return false
            }
        }
    }

    let kind: Kind
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            if kind.showsSpinner {
                ProgressView()
                    .controlSize(.mini)
                    .tint(kind.tint)
            } else {
                Image(systemName: kind.systemImage)
                    .imageScale(.small)
            }
            Text(kind.titleKey)
        }
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
        AdaptiveLeadingTrailingLayout(horizontalSpacing: 10, verticalSpacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                icon
                texts
            }
            actionButton
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

/// Deterministic inline-or-stacked layout for a leading/trailing pair that avoids
/// swapping view identities (which triggers AppKit constraint-update loops in split views).
struct AdaptiveLeadingTrailingLayout: Layout {
    var horizontalSpacing: CGFloat = 10
    var verticalSpacing: CGFloat = 8
    var inlineAlignment: VerticalAlignment = .center

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        if subviews.isEmpty {
            return .zero
        }
        if subviews.count == 1 {
            return subviews[0].sizeThatFits(proposal)
        }
        let leading = subviews[0]
        let trailing = subviews[1]
        let lIdeal = leading.sizeThatFits(.unspecified)
        let tIdeal = trailing.sizeThatFits(.unspecified)
        if proposal.width == 0 {
            return CGSize(
                width: 0,
                height: lIdeal.height + verticalSpacing + tIdeal.height
            )
        }
        guard let width = proposal.width, width.isFinite else {
            return CGSize(
                width: lIdeal.width + horizontalSpacing + tIdeal.width,
                height: max(lIdeal.height, tIdeal.height)
            )
        }
        if lIdeal.width + horizontalSpacing + tIdeal.width <= width {
            return CGSize(width: width, height: max(lIdeal.height, tIdeal.height))
        }
        let lWrapped = leading.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let tWrapped = trailing.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(
            width: width,
            height: lWrapped.height + verticalSpacing + tWrapped.height
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        if subviews.isEmpty {
            return
        }
        if subviews.count == 1 {
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
            )
            return
        }
        let leading = subviews[0]
        let trailing = subviews[1]
        let width = bounds.width
        let lIdeal = leading.sizeThatFits(.unspecified)
        let tIdeal = trailing.sizeThatFits(.unspecified)

        if lIdeal.width + horizontalSpacing + tIdeal.width <= width {
            let rowHeight = max(lIdeal.height, tIdeal.height)
            let lY = inlineY(rowOriginY: bounds.minY, rowHeight: rowHeight, itemHeight: lIdeal.height)
            let tY = inlineY(rowOriginY: bounds.minY, rowHeight: rowHeight, itemHeight: tIdeal.height)
            leading.place(
                at: CGPoint(x: bounds.minX, y: lY),
                anchor: .topLeading,
                proposal: ProposedViewSize(lIdeal)
            )
            trailing.place(
                at: CGPoint(x: bounds.maxX - tIdeal.width, y: tY),
                anchor: .topLeading,
                proposal: ProposedViewSize(tIdeal)
            )
        } else {
            let lWrapped = leading.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let tWrapped = trailing.sizeThatFits(ProposedViewSize(width: width, height: nil))
            leading.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: width, height: lWrapped.height)
            )
            trailing.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + lWrapped.height + verticalSpacing),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: min(tWrapped.width, width), height: tWrapped.height)
            )
        }
    }

    private func inlineY(rowOriginY: CGFloat, rowHeight: CGFloat, itemHeight: CGFloat) -> CGFloat {
        switch inlineAlignment {
        case .top:
            return rowOriginY
        case .bottom:
            return rowOriginY + rowHeight - itemHeight
        default:
            return rowOriginY + (rowHeight - itemHeight) * 0.5
        }
    }
}

/// Deterministic wrapping flow row that keeps NSButton identities intact across resizes.
struct AdaptiveWrappingRowLayout: Layout {
    var horizontalSpacing: CGFloat = 10
    var verticalSpacing: CGFloat = 8
    var pinLastToTrailingWhenSingleRow: Bool = false

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        if proposal.width == 0 {
            let maxW = sizes.map(\.width).max() ?? 0
            let totalH = sizes.map(\.height).reduce(0, +)
                + verticalSpacing * CGFloat(max(0, sizes.count - 1))
            return CGSize(width: maxW, height: totalH)
        }
        guard let width = proposal.width, width.isFinite else {
            let totalW = sizes.map(\.width).reduce(0, +)
                + horizontalSpacing * CGFloat(max(0, sizes.count - 1))
            let maxH = sizes.map(\.height).max() ?? 0
            return CGSize(width: totalW, height: maxH)
        }
        let rows = computeRows(availableWidth: width, sizes: sizes)
        let totalH = rows.reduce(CGFloat.zero) { acc, row in
            let rowH = row.map(\.size.height).max() ?? 0
            return acc + rowH
        } + verticalSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: totalH)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = computeRows(availableWidth: bounds.width, sizes: sizes)

        var y = bounds.minY
        let shouldPinLast = rows.count == 1 && pinLastToTrailingWhenSingleRow && subviews.count > 1

        for row in rows {
            let rowHeight = row.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for (posInRow, item) in row.enumerated() {
                let isPinnedTrailing = shouldPinLast && posInRow == row.count - 1
                let itemWidth = min(item.size.width, bounds.width)
                let placeX = isPinnedTrailing ? max(bounds.minX, bounds.maxX - itemWidth) : x
                let placeY = y + (rowHeight - item.size.height) * 0.5
                subviews[item.index].place(
                    at: CGPoint(x: placeX, y: placeY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: itemWidth, height: item.size.height)
                )
                x += itemWidth + horizontalSpacing
            }
            y += rowHeight + verticalSpacing
        }
    }

    private func computeRows(
        availableWidth: CGFloat,
        sizes: [CGSize]
    ) -> [[(index: Int, size: CGSize)]] {
        var rows: [[(index: Int, size: CGSize)]] = []
        var currentRow: [(index: Int, size: CGSize)] = []
        var currentWidth: CGFloat = 0

        for (idx, size) in sizes.enumerated() {
            let effectiveWidth = min(size.width, availableWidth)
            let neededWidth = currentRow.isEmpty ? effectiveWidth : (currentWidth + horizontalSpacing + effectiveWidth)
            if !currentRow.isEmpty && neededWidth > availableWidth {
                rows.append(currentRow)
                currentRow = [(index: idx, size: size)]
                currentWidth = effectiveWidth
            } else {
                currentRow.append((index: idx, size: size))
                currentWidth = neededWidth
            }
        }
        if !currentRow.isEmpty {
            rows.append(currentRow)
        }
        return rows
    }
}
