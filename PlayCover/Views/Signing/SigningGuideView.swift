//
//  SigningGuideView.swift
//  PlayCover
//

import PlayCoverSandbox
import SwiftUI

struct SigningGuideView: View {
    @Binding var isSigningSetupShown: Bool

    @State private var sipEnabled = true
    @State private var amfiDisabledInNVRAM = false
    @State private var amfiDisabledInRunningOS = false
    @State private var isLoadingStatus = true
    @State private var isApplyingAMFI = false
    @State private var showWizard = false
    @State private var commandCopiedAlert = false
    @State private var amfiErrorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            headerSection

            modeComparisonCards

            statusSummarySection

            DisclosureGroup("signing.wizard.title", isExpanded: $showWizard) {
                wizardContent
                    .padding(.top, 8)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.fill.quaternary))

            footerButtons
        }
        .padding(20)
        .frame(width: 600)
        .presentationSizing(.form)
        .onExitCommand {
            isSigningSetupShown = false
        }
        .task {
            await refreshStatus()
        }
        .alert("configSigning.alert.copied", isPresented: $commandCopiedAlert) {
            Button("button.OK", role: .cancel) {}
        } message: {
            Text("configSigning.alert.info")
        }
        .alert("alert.error", isPresented: Binding(
            get: { amfiErrorMessage != nil },
            set: { if !$0 { amfiErrorMessage = nil } }
        )) {
            Button("button.OK", role: .cancel) { amfiErrorMessage = nil }
        } message: {
            Text(amfiErrorMessage ?? "")
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("signing.guide.title")
                .font(.title2.bold())
            Text("signing.guide.subtitle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var modeComparisonCards: some View {
        HStack(alignment: .top, spacing: 12) {
            SigningModeCard(
                titleKey: "signing.mode.playchain.title",
                badgeKey: "signing.mode.playchain.badge",
                descKey: "signing.mode.playchain.desc",
                icon: "lock.shield.fill",
                tint: .green,
                isActive: sipEnabled || !amfiDisabledInRunningOS
            )
            SigningModeCard(
                titleKey: "signing.mode.native.title",
                badgeKey: "signing.mode.native.badge",
                descKey: "signing.mode.native.desc",
                icon: "key.icloud.fill",
                tint: .blue,
                isActive: !sipEnabled && amfiDisabledInRunningOS
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statusSummarySection: some View {
        Group {
            if isLoadingStatus {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("signing.status.checking")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.fill.quaternary))
            } else {
                VStack(spacing: 8) {
                    HStack {
                        Text("configSigning.info.SIPHeader")
                            .fontWeight(.medium)
                        Spacer()
                        Text(sipEnabled ? "state.enabled" : "state.disabled")
                            .fontWeight(.semibold)
                            .foregroundStyle(sipEnabled ? .green : .orange)
                    }
                    Divider()
                    HStack {
                        Text("configSigning.info.AMFIHeader")
                            .fontWeight(.medium)
                        Spacer()
                        if amfiDisabledInNVRAM {
                            Text(amfiDisabledInRunningOS ? "state.disabled" : "state.pendingReboot")
                                .fontWeight(.semibold)
                                .foregroundStyle(amfiDisabledInRunningOS ? .blue : .orange)
                        } else {
                            Text("state.enabled")
                                .fontWeight(.semibold)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.fill.quaternary))
            }
        }
    }

    private var wizardContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("signing.wizard.step1")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text("signing.wizard.step2")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Text("signing.wizard.step3")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("configSigning.action.configureAutomatic") {
                    Task { @MainActor in
                        isApplyingAMFI = true
                        defer { isApplyingAMFI = false }
                        do {
                            try await SystemConfig.enablePlaySign()
                            await refreshStatus()
                        } catch {
                            amfiErrorMessage = error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sipEnabled || isApplyingAMFI)

                Button("configSigning.action.copyCommand") {
                    let disableCommand =
                        "sudo nvram boot-args=\"amfi_get_out_of_my_way=0x1 ipc_control_port_options=0\" && sudo reboot"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(disableCommand, forType: .string)
                    commandCopiedAlert = true
                }

                if isApplyingAMFI {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.top, 6)
        }
    }

    private var footerButtons: some View {
        HStack {
            Button("button.Help") {
                if let url = URL(string: "https://docs.playcover.io/getting_started/troubleshoot_login") {
                    NSWorkspace.shared.open(url)
                }
            }
            Spacer()
            Button("button.Done") {
                isSigningSetupShown = false
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func refreshStatus() async {
        let result = await Task.detached(priority: .userInitiated) {
            SystemConfig.preFlightStatus()
        }.value
        sipEnabled = !result.sipDisabled
        amfiDisabledInNVRAM = result.amfiDisabledInNVRAM
        amfiDisabledInRunningOS = result.amfiDisabledInRunningOS
        isLoadingStatus = false
    }
}

private struct SigningModeCard: View {
    let titleKey: String
    let badgeKey: String
    let descKey: String
    let icon: String
    let tint: Color
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(tint)
                Spacer()
                Text(LocalizedStringKey(badgeKey))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(tint.opacity(0.15)))
            }
            Text(LocalizedStringKey(titleKey))
                .font(.headline)
            Text(LocalizedStringKey(descKey))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? tint.opacity(0.08) : Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isActive ? tint.opacity(0.45) : Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }
}
