//
//  ActivityCenterView.swift
//  PlayCover
//

import PlayCoverUI
import SwiftUI

struct ActivityCenterView: View {
    @Environment(InstallVM.self) var installVM
    @Environment(DownloadVM.self) var downloadVM
    @Environment(PlayCoverDependencies.self) var dependencies

    private static let installStages: [(step: InstallStepsNative, key: String)] = [
        (.unzip, "activity.stage.unzip"),
        (.playtools, "activity.stage.playtools"),
        (.sign, "activity.stage.sign"),
        (.library, "activity.stage.library"),
        (.finish, "activity.stage.finish")
    ]

    private var activeStageIndex: Int {
        switch installVM.status {
        case .begin, .unzip, .wrapper: return 0
        case .playtools: return 1
        case .sign: return 2
        case .library: return 3
        case .finish: return 4
        case .failed: return -1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("activity.title", systemImage: "tray.full.fill")
                    .font(.headline)
                Spacer()
            }

            if !downloadVM.inProgress && !installVM.inProgress {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text("activity.noTasks")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 10)
            }

            if downloadVM.inProgress {
                downloadCard
            }

            if installVM.inProgress {
                installCard
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var downloadCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(downloadVM.storeAppData?.name ?? NSLocalizedString("sidebar.ipaLibrary", comment: ""))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if downloadVM.status == .downloading {
                    Button {
                        DownloadApp(url: nil, app: nil, warning: nil, dependencies: dependencies).cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(NSLocalizedString(downloadVM.status.rawValue, comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: downloadVM.progress)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.fill.quaternary))
    }

    private var installCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString(installVM.status.rawValue, comment: ""))
                .font(.subheadline.weight(.semibold))
            ProgressView(value: installVM.progress)
                .tint(installVM.status == .failed ? .red : .accentColor)

            HStack(spacing: 6) {
                ForEach(Array(Self.installStages.enumerated()), id: \.offset) { idx, stage in
                    let isDone = activeStageIndex > idx || installVM.status == .finish
                    let isCurrent = activeStageIndex == idx && installVM.status != .finish
                    VStack(spacing: 4) {
                        Circle()
                            .fill(stageColor(isDone: isDone, isCurrent: isCurrent))
                            .frame(width: 8, height: 8)
                        Text(LocalizedStringKey(stage.key))
                            .font(.caption2)
                            .foregroundStyle(isCurrent || isDone ? .primary : .tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.fill.quaternary))
    }

    private func stageColor(isDone: Bool, isCurrent: Bool) -> Color {
        if installVM.status == .failed {
            return .red
        }
        if isDone {
            return .green
        }
        if isCurrent {
            return .accentColor
        }
        return .secondary.opacity(0.35)
    }
}
