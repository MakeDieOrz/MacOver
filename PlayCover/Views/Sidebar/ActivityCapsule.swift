//
//  ActivityCapsule.swift
//  PlayCover
//

import PlayCoverSandbox
import SwiftUI

struct ActivityCapsule: View {
    @Environment(InstallVM.self) var installVM
    @Environment(DownloadVM.self) var downloadVM
    @Environment(PlayCoverDependencies.self) var dependencies
    @Environment(AppNavigationState.self) var navState
    @Environment(\.locale) private var locale

    private var isBusy: Bool {
        installVM.inProgress || downloadVM.inProgress
    }

    private var activeProgress: Double {
        let raw: Double
        if installVM.inProgress {
            raw = installVM.progress
        } else if downloadVM.inProgress {
            raw = downloadVM.progress
        } else {
            raw = 0
        }
        return min(max(raw, 0), 1)
    }

    private var activePercentageText: String {
        "\(Int((activeProgress * 100).rounded()))%"
    }

    private var activeLabel: String {
        if installVM.inProgress {
            return ConfigLabelFormatter.localized(installVM.status.rawValue, locale: locale)
        }
        if downloadVM.inProgress {
            let name = downloadVM.storeAppData?.name ?? ""
            let base = ConfigLabelFormatter.localized(downloadVM.status.rawValue, locale: locale)
            return name.isEmpty ? base : "\(base) \(name)"
        }
        return ConfigLabelFormatter.localized("activity.idle", locale: locale)
    }

    var body: some View {
        @Bindable var navState = navState
        Button {
            navState.isActivityPopoverShown.toggle()
        } label: {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView(value: activeProgress)
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                } else {
                    Image(systemName: "tray.full")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("activity.title")
                        .font(.caption.weight(.semibold))
                    Text(activeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if isBusy {
                    Text(activePercentageText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("activity.title"))
        .accessibilityValue(isBusy ? Text("\(activeLabel), \(activePercentageText)") : Text(activeLabel))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isBusy ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
        )
        .popover(isPresented: $navState.isActivityPopoverShown, arrowEdge: .trailing) {
            ActivityCenterView()
                .environment(installVM)
                .environment(downloadVM)
                .environment(dependencies)
        }
    }
}

private struct SigningBadgeDisplay {
    let titleKey: String
    let icon: String
    let color: Color
}

struct SigningStatusCapsule: View {
    @Environment(AppNavigationState.self) var navState

    @State private var status: PrivilegePreFlightStatus?

    private var badgeInfo: SigningBadgeDisplay {
        guard let status else {
            return SigningBadgeDisplay(
                titleKey: "signing.capsule.playchain",
                icon: "lock.shield.fill",
                color: .green
            )
        }
        if status.sipDisabled && status.amfiDisabledInRunningOS {
            return SigningBadgeDisplay(
                titleKey: "signing.capsule.native",
                icon: "checkmark.shield.fill",
                color: .blue
            )
        }
        if status.sipDisabled && status.amfiDisabledInNVRAM {
            return SigningBadgeDisplay(
                titleKey: "signing.capsule.reboot",
                icon: "arrow.triangle.2.circlepath",
                color: .orange
            )
        }
        return SigningBadgeDisplay(
            titleKey: "signing.capsule.playchain",
            icon: "lock.shield.fill",
            color: .green
        )
    }

    var body: some View {
        let info = badgeInfo
        Button {
            navState.isSigningSetupShown = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: info.icon)
                    .foregroundStyle(info.color)
                Text(LocalizedStringKey(info.titleKey))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(info.titleKey)))
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .task(id: navState.isSigningSetupShown) {
            let latest = await Task.detached(priority: .utility) {
                SystemConfig.preFlightStatus()
            }.value
            status = latest
        }
    }
}
