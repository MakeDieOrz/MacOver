//
//  StoreItemInspector.swift
//  PlayCover
//

import SwiftUI

struct StoreItemInspector: View {
    @Environment(PlayCoverDependencies.self) var dependencies
    @Environment(AppsVM.self) var appsVM
    @Environment(DownloadVM.self) var downloadVM

    let app: SourceAppsData

    @State private var isAvailable: Bool?

    private var installedApp: PlayApp? {
        appsVM.apps.first(where: { $0.info.bundleIdentifier == app.bundleID })
    }

    private var versionComparison: (key: String, tint: Color)? {
        guard let installed = installedApp else { return nil }
        switch app.version.compare(installed.info.bundleVersion, options: .numeric) {
        case .orderedAscending:
            return ("ipaLibrary.version.older", .orange)
        case .orderedSame:
            return ("ipaLibrary.version.same", .green)
        case .orderedDescending:
            return ("ipaLibrary.version.newer", .blue)
        }
    }

    private var isDownloadingThisApp: Bool {
        downloadVM.inProgress && downloadVM.storeAppData == app
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                actionSection

                if let comparison = versionComparison, let installed = installedApp {
                    versionBanner(comparison: comparison, installedVersion: installed.info.bundleVersion)
                }

                if isAvailable == false {
                    Label("ipaLibrary.info.notAvailable", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
                }

                Divider()

                metadataSection
            }
            .padding(16)
        }
        .task(id: app.link) {
            isAvailable = nil
            if let link = URL(string: app.link) {
                let (_, available) = await NetworkVM.isURLAccessible(url: link, popup: false)
                isAvailable = available
            } else {
                isAvailable = false
            }
        }
    }

    private var headerSection: some View {
        HStack(spacing: 12) {
            StoreAppIconView(app: app, size: 48, cornerRadius: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.headline)
                    .lineLimit(2)
                Text(app.version)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var actionSection: some View {
        Group {
            if isDownloadingThisApp {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: downloadVM.progress)
                    HStack {
                        Text(NSLocalizedString(downloadVM.status.rawValue, comment: ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if downloadVM.status == .downloading {
                            Button("button.Cancel") {
                                DownloadApp(url: nil, app: nil, warning: nil, dependencies: dependencies).cancel()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } else {
                Button {
                    triggerDownload()
                } label: {
                    Label("store.downloadInstall", systemImage: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 20)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .frame(minHeight: 34)
                .disabled(downloadVM.inProgress)
            }
        }
    }

    private var metadataSection: some View {
        let checksum = app.checksum?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let noneLabel = NSLocalizedString("ipaLibrary.info.checksum.none", comment: "")
        return VStack(alignment: .leading, spacing: 10) {
            copyableMetadataRow(
                labelKey: "settings.info.bundleIdentifier",
                value: app.bundleID,
                canCopy: !app.bundleID.isEmpty,
                monospaced: true
            )

            LabeledContent("settings.info.bundleVersion") {
                Text(app.version)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .font(.caption)

            copyableMetadataRow(
                labelKey: "ipaLibrary.info.checksum",
                value: checksum.isEmpty ? noneLabel : checksum,
                canCopy: !checksum.isEmpty,
                monospaced: !checksum.isEmpty
            )

            if let lookupURL = URL(string: app.itunesLookup) {
                Link(destination: lookupURL) {
                    Label("ipaLibrary.info.itunes", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            }
            if let downloadURL = URL(string: app.link) {
                Link(destination: downloadURL) {
                    Label("settings.info.url", systemImage: "link")
                        .font(.caption)
                }
            }
        }
    }

    private func copyableMetadataRow(
        labelKey: LocalizedStringKey,
        value: String,
        canCopy: Bool,
        monospaced: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(labelKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if canCopy {
                    Button {
                        copyToClipboard(value)
                    } label: {
                        Label("action.copy", systemImage: "doc.on.doc")
                            .font(.caption)
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("action.copy")
                    .accessibilityLabel(Text("action.copy"))
                }
            }
            Text(value)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundStyle(canCopy ? .primary : .secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func copyToClipboard(_ value: String) {
        value.copyToClipBoard()
        let preview = value.count > 28 ? "\(value.prefix(24))…" : value
        dependencies.toastVM.showToast(
            toastType: .notice,
            toastDetails: "\(NSLocalizedString("action.copy", comment: "")): \(preview)"
        )
    }

    private func versionBanner(
        comparison: (key: String, tint: Color),
        installedVersion: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(comparison.key))
                .font(.caption.weight(.semibold))
                .foregroundStyle(comparison.tint)
            Text(String(
                format: NSLocalizedString("store.installedVersion", comment: ""),
                installedVersion,
                app.version
            ))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(comparison.tint.opacity(0.12)))
    }

    private func triggerDownload() {
        guard let url = URL(string: app.link) else { return }
        if downloadVM.inProgress {
            PlayCoverDiagnostics.reportError(PlayCoverError.waitDownload)
            return
        }
        let warningKey = versionComparison?.key
        let deps = dependencies
        Task {
            let resolvedURL = await RedirectHandler.resolveDirectDownloadURL(for: url)
            await MainActor.run {
                DownloadApp(url: resolvedURL, app: app, warning: warningKey, dependencies: deps).start()
            }
        }
    }
}
