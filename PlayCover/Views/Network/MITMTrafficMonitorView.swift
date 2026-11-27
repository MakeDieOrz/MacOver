import AppKit
import PlayCoverNetwork
import SwiftUI
import UniformTypeIdentifiers

struct MITMTrafficMonitorView: View {
    let bundleID: String
    @Environment(MITMProxyCoordinator.self) var mitmCoordinator
    @Environment(\.locale) private var locale

    @State private var searchText = ""
    @State private var dispositionFilter: DispositionFilter = .all
    @State private var selectedEntryID: UUID?
    @State private var inspectorTab: InspectorTab = .request
    @State private var showRawHex = false
    @State private var showClearConfirm = false

    enum DispositionFilter: String, CaseIterable, Identifiable {
        case all
        case decrypted
        case blocked
        case tunnel
        case error

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .all: return "mitm.monitor.filter.all"
            case .decrypted: return "mitm.monitor.filter.decrypted"
            case .blocked: return "mitm.monitor.filter.blocked"
            case .tunnel: return "mitm.monitor.filter.tunnel"
            case .error: return "mitm.monitor.filter.error"
            }
        }
    }

    enum InspectorTab: String, CaseIterable, Identifiable {
        case request
        case response

        var id: String { rawValue }

        var titleKey: LocalizedStringKey {
            switch self {
            case .request: return "mitm.monitor.tab.request"
            case .response: return "mitm.monitor.tab.response"
            }
        }
    }

    private var entries: [MITMCaptureEntry] {
        mitmCoordinator.entries(for: bundleID)
    }

    private var filteredEntries: [MITMCaptureEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            switch dispositionFilter {
            case .all:
                break
            case .decrypted:
                guard entry.disposition == .decrypted || entry.disposition == .forwarded else { return false }
            case .blocked:
                guard entry.disposition == .blocked || entry.disposition == .mocked200 else { return false }
            case .tunnel:
                guard entry.disposition == .tunnel else { return false }
            case .error:
                guard entry.disposition == .error else { return false }
            }
            guard !query.isEmpty else { return true }
            if entry.urlString.localizedCaseInsensitiveContains(query) ||
                entry.method.localizedCaseInsensitiveContains(query) {
                return true
            }
            if let code = entry.statusCode, String(code).contains(query) {
                return true
            }
            return false
        }
    }

    private var selectedEntry: MITMCaptureEntry? {
        guard let selectedEntryID else { return nil }
        return filteredEntries.first { $0.id == selectedEntryID }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            HSplitView {
                trafficListPane
                    .frame(minWidth: 320, idealWidth: 420)
                inspectorPane
                    .frame(minWidth: 360)
            }
        }
        .frame(minWidth: 780, minHeight: 500)
        .navigationTitle(
            "\(bundleID) — \(ConfigLabelFormatter.localized("mitm.monitor.title", locale: locale))"
        )
        .toolbar {
            ToolbarItem(placement: .status) {
                statusPill
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    exportHAR()
                } label: {
                    Label("mitm.monitor.exportHAR", systemImage: "square.and.arrow.up")
                }
                .disabled(entries.isEmpty)
                .help("mitm.monitor.exportHAR")

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label("mitm.monitor.clear", systemImage: "trash")
                }
                .disabled(entries.isEmpty)
                .help("mitm.monitor.clear")
            }
        }
        .alert("confirm.clearCaptures.title", isPresented: $showClearConfirm) {
            Button("button.Cancel", role: .cancel) {}
            Button("mitm.monitor.clear", role: .destructive) {
                selectedEntryID = nil
                mitmCoordinator.clearCaptures(for: bundleID)
            }
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if let activePort = mitmCoordinator.activePorts[bundleID] {
            Label("127.0.0.1:\(activePort)", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.14)))
        } else {
            Label("mitm.monitor.inactive", systemImage: "pause.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
        }
    }

    private var filterBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                searchField
                    .frame(minWidth: 200, maxWidth: 280)
                dispositionPicker
                    .fixedSize()
                Spacer(minLength: 8)
                entryCountBadge
            }

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    searchField
                    entryCountBadge
                }
                HStack {
                    dispositionPicker
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("", text: $searchText, prompt: Text("mitm.monitor.search"))
                .labelsHidden()
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("mitm.monitor.clear")
                .accessibilityLabel("mitm.monitor.clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    private var dispositionPicker: some View {
        Picker("", selection: $dispositionFilter) {
            ForEach(DispositionFilter.allCases) { item in
                Text(item.titleKey).tag(item)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var entryCountBadge: some View {
        Text("\(filteredEntries.count)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private var trafficListPane: some View {
        Group {
            if filteredEntries.isEmpty {
                ContentUnavailableView(
                    "mitm.monitor.emptyTitle",
                    systemImage: "network",
                    description: Text("mitm.monitor.emptySubtitle")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredEntries, selection: $selectedEntryID) { entry in
                    TrafficEntryRow(entry: entry)
                        .tag(entry.id)
                }
                .listStyle(.inset)
            }
        }
    }

    private var inspectorPane: some View {
        Group {
            if let entry = selectedEntry {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.urlString)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        HStack(spacing: 12) {
                            Text("\(entry.method) · \(entry.disposition.rawValue.uppercased())")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            if let statusCode = entry.statusCode {
                                Text("HTTP \(statusCode)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(statusColor(for: statusCode))
                            }
                            Text(String(format: "%.1f ms", entry.durationMs))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)

                    Picker("", selection: $inspectorTab) {
                        ForEach(InspectorTab.allCases) { tab in
                            Text(tab.titleKey).tag(tab)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if inspectorTab == .request {
                                headersSection(entry.requestHeaders)
                                bodySection(
                                    data: entry.requestBody,
                                    headers: entry.requestHeaders,
                                    truncated: entry.requestBodyTruncated
                                )
                            } else {
                                if let err = entry.errorDescription, !err.isEmpty {
                                    Text(err)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.red)
                                }
                                headersSection(entry.responseHeaders)
                                bodySection(
                                    data: entry.responseBody,
                                    headers: entry.responseHeaders,
                                    truncated: entry.responseBodyTruncated
                                )
                            }
                        }
                        .padding(12)
                    }
                }
            } else {
                ContentUnavailableView(
                    "mitm.monitor.selectTitle",
                    systemImage: "doc.text.magnifyingglass"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func headersSection(_ headers: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("mitm.monitor.headers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if headers.isEmpty {
                Text("mitm.monitor.none")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(headers.keys.sorted(), id: \.self) { key in
                        GridRow {
                            Text(key)
                                .font(.system(.caption, design: .monospaced).weight(.semibold))
                                .foregroundStyle(.secondary)
                                .gridColumnAlignment(.trailing)
                            Text(headers[key] ?? "")
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .gridColumnAlignment(.leading)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func bodySection(data: Data?, headers: [String: String], truncated: Bool) -> some View {
        let formatted = data.flatMap { !$0.isEmpty ? HTTPBodyDecoder.formatDisplayText($0, headers: headers) : nil }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("mitm.monitor.body")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let data {
                    let wireCount = ByteCountFormatter.string(
                        fromByteCount: Int64(data.count),
                        countStyle: .binary
                    )
                    if let formatted, !formatted.decoded.appliedEncodings.isEmpty {
                        let decodedCount = ByteCountFormatter.string(
                            fromByteCount: Int64(formatted.decoded.data.count),
                            countStyle: .binary
                        )
                        Text("(\(wireCount) → \(decodedCount))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    } else {
                        Text("(\(wireCount))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                if let formatted, !formatted.decoded.appliedEncodings.isEmpty {
                    Text(formatted.decoded.appliedEncodings.joined(separator: " → "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.blue.opacity(0.12)))
                }
                if let formatted, formatted.decoded.decodingFailed,
                   let rawEnc = HTTPBodyDecoder.headerValue(named: "content-encoding", in: headers) {
                    Text(rawEnc)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.orange.opacity(0.12)))
                }
                if truncated || (formatted?.decoded.outputTruncated == true) {
                    Text("mitm.monitor.truncated")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let data, !data.isEmpty {
                    Spacer()
                    Picker("", selection: $showRawHex) {
                        Text("mitm.monitor.body.decoded").tag(false)
                        Text("mitm.monitor.body.rawHex").tag(true)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                }
            }
            if let data, !data.isEmpty, let formatted {
                Text(showRawHex ? HTTPBodyDecoder.hexString(for: data) : formatted.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
            } else {
                Text("mitm.monitor.emptyBody")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func statusColor(for code: Int) -> Color {
        switch code {
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        default: return .red
        }
    }

    private func exportHAR() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(bundleID)-traffic.har"
        if let harType = UTType(filenameExtension: "har") {
            panel.allowedContentTypes = [harType, .json]
        } else {
            panel.allowedContentTypes = [.json]
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data = try mitmCoordinator.exportHAR(for: bundleID)
                try data.write(to: url, options: .atomic)
            } catch {
                PlayCoverDiagnostics.reportError(error)
            }
        }
    }
}

private struct TrafficEntryRow: View {
    let entry: MITMCaptureEntry

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.method)
                .font(.caption2.monospaced().weight(.bold))
                .frame(width: 56, alignment: .leading)

            statusBadge
                .frame(minWidth: 52, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.host + (entry.port == 443 || entry.port == 80 ? "" : ":\(entry.port)"))
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(entry.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Text(String(format: "%.0f ms", entry.durationMs))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        let label = entry.statusCode.flatMap { $0 > 0 ? String($0) : nil } ?? entry.disposition.rawValue.uppercased()
        let tint: Color = {
            switch entry.disposition {
            case .blocked: return .red
            case .mocked200: return .orange
            case .tunnel: return .purple
            case .error: return .red
            case .decrypted, .forwarded:
                guard let code = entry.statusCode else { return .secondary }
                if (200..<300).contains(code) { return .green }
                if (300..<400).contains(code) { return .blue }
                return .orange
            }
        }()
        Text(label)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}
