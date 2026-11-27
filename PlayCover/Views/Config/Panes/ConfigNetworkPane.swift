//
//  ConfigNetworkPane.swift
//  PlayCover
//

import AppKit
import PlayCoverCore
import PlayCoverNetwork
import SwiftUI
import UniformTypeIdentifiers

private struct NetworkRuleStats {
    var block = 0
    var allow = 0
    var disabled = 0
}

struct ConfigNetworkPane: View {
    var app: PlayApp
    @Bindable var settings: AppSettings
    @Environment(MITMProxyCoordinator.self) var mitmCoordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.locale) private var locale

    @State private var newPattern = ""
    @State private var newMitmHost = ""
    @State private var searchText = ""
    @State private var editingIndex: Int?
    @State private var editingText = ""
    @State private var certificates: [AppCertificateRecord] = []
    @State private var showClearRulesConfirm = false

    private var bundleID: String {
        app.info.bundleIdentifier
    }

    private var proxyModeBinding: Binding<NetworkProxyMode> {
        Binding(
            get: { NetworkProxyMode(rawValue: settings.settings.networkProxyMode) ?? .direct },
            set: { newMode in
                settings.update { $0.networkProxyMode = newMode.rawValue }
                mitmCoordinator.syncCertificates(for: bundleID, settings: settings.settings)
            }
        )
    }

    private var externalProtocolBinding: Binding<ExternalProxyProtocol> {
        Binding(
            get: { ExternalProxyProtocol(rawValue: settings.settings.externalProxyProtocol) ?? .http },
            set: { newProto in
                settings.update { $0.externalProxyProtocol = newProto.rawValue }
            }
        )
    }

    private var customCertsEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.settings.enableCustomCertificates },
            set: { newValue in
                settings.update { $0.enableCustomCertificates = newValue }
                mitmCoordinator.syncCertificates(for: bundleID, settings: settings.settings)
            }
        )
    }

    private static let proxyPortFormatter: NumberFormatter = {
        let fmt = NumberFormatter()
        fmt.numberStyle = .none
        fmt.minimum = 1
        fmt.maximum = 65_535
        return fmt
    }()

    private static let mitmPortFormatter: NumberFormatter = {
        let fmt = NumberFormatter()
        fmt.numberStyle = .none
        fmt.minimum = 0
        fmt.maximum = 65_535
        return fmt
    }()

    private var ruleStats: NetworkRuleStats {
        var stats = NetworkRuleStats()
        for rule in settings.settings.blockedURLPatterns {
            let meta = NetworkRuleParser.classifyRule(rule)
            if !meta.isEnabled {
                stats.disabled += 1
            } else if meta.isAllow {
                stats.allow += 1
            } else {
                stats.block += 1
            }
        }
        return stats
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNewPattern: String {
        newPattern.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isNewPatternInvalid: Bool {
        guard !trimmedNewPattern.isEmpty else { return false }
        let lines = trimmedNewPattern
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return lines.isEmpty || !lines.allSatisfy { NetworkRuleParser.isImportableRuleLine($0) }
    }

    private var filteredRules: [(offset: Int, element: String)] {
        let enumerated = Array(settings.settings.blockedURLPatterns.enumerated())
        guard !trimmedQuery.isEmpty else { return enumerated }
        return enumerated.filter { $0.element.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    var body: some View {
        let stats = ruleStats
        Form {
            proxyAndMITMSection
            customCertificatesSection
            rulesToggleSection(stats: stats)

            Section {
                addRuleBar
                searchAndActionsBar
            }

            Section {
                ForEach(filteredRules, id: \.offset) { idx, rule in
                    NetworkRuleRowView(
                        rule: rule,
                        isEditing: editingIndex == idx,
                        editingText: $editingText,
                        onToggleEnabled: { setRuleEnabled(at: idx, enabled: $0) },
                        onStartEdit: {
                            editingIndex = idx
                            editingText = rule
                        },
                        onCommitEdit: { commitEdit(at: idx) },
                        onCancelEdit: {
                            editingIndex = nil
                            editingText = ""
                        },
                        onDelete: { deleteRule(at: idx) }
                    )
                    .moveDisabled(!trimmedQuery.isEmpty)
                }
                .onMove { src, dst in
                    guard trimmedQuery.isEmpty else { return }
                    settings.update { $0.blockedURLPatterns.move(fromOffsets: src, toOffset: dst) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onAppear { reloadCertificates() }
        .onChange(of: mitmCoordinator.certificateRevisions[bundleID] ?? 0) { _, _ in
            reloadCertificates()
        }
        .alert("confirm.clearNetworkRules.title", isPresented: $showClearRulesConfirm) {
            Button("button.Cancel", role: .cancel) {}
            Button("settings.network.clear", role: .destructive) {
                editingIndex = nil
                editingText = ""
                settings.update { $0.blockedURLPatterns.removeAll() }
            }
        }
    }

    private var proxyAndMITMSection: some View {
        let mode = proxyModeBinding.wrappedValue
        let certsOrMITMActive = mode == .builtInMITM || settings.settings.enableCustomCertificates

        return Section {
            Picker("settings.network.proxyMode", selection: proxyModeBinding) {
                Text("settings.network.proxyMode.direct").tag(NetworkProxyMode.direct)
                Text("settings.network.proxyMode.external").tag(NetworkProxyMode.external)
                Text("settings.network.proxyMode.builtInMITM").tag(NetworkProxyMode.builtInMITM)
            }

            if mode == .external {
                Picker("settings.network.externalProtocol", selection: externalProtocolBinding) {
                    Text("HTTP / HTTPS").tag(ExternalProxyProtocol.http)
                    Text("SOCKS5").tag(ExternalProxyProtocol.socks5)
                }
                LabeledContent("settings.network.proxyHost") {
                    TextField("", text: $settings.settings.externalProxyHost)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                }
                LabeledContent("settings.network.proxyPort") {
                    TextField("", value: $settings.settings.externalProxyPort, formatter: Self.proxyPortFormatter)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 84)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                }
            }

            if mode == .builtInMITM {
                LabeledContent("settings.network.mitmPort") {
                    HStack(spacing: 6) {
                        TextField("", value: $settings.settings.mitmPort, formatter: Self.mitmPortFormatter)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 84)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                        Text("settings.network.mitmPortAutoHint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("settings.network.mitmStatus") {
                    HStack(spacing: 8) {
                        if let port = mitmCoordinator.activePorts[bundleID] {
                            Label("127.0.0.1:\(port)", systemImage: "dot.radiowaves.left.and.right")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                        } else {
                            Text("settings.network.mitmIdle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("settings.network.openMonitor") {
                            openWindow(id: "mitm-monitor", value: bundleID)
                        }
                    }
                }

                Toggle("settings.network.captureBodies", isOn: $settings.settings.mitmCaptureBodies)
            }

            if certsOrMITMActive {
                Toggle("settings.network.mitmAllHosts", isOn: $settings.settings.mitmAllHosts)

                if !settings.settings.mitmAllHosts {
                    mitmHostsEditor
                }
            }

            if mode != .direct {
                Toggle(isOn: $settings.settings.hideProxyFromApp) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.network.hideProxy")
                        Text("settings.network.hideProxy.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if certsOrMITMActive {
                Toggle(isOn: $settings.settings.mitmAllowPinningBypass) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.network.allowPinningBypass")
                        Text("settings.network.allowPinningBypass.help")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if settings.settings.strictEmulationMode {
                Text("settings.network.strictModeIndependentNote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("settings.network.section.proxyMITM")
        }
    }

    private var mitmHostsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("", text: $newMitmHost, prompt: Text("settings.network.mitmHostPlaceholder"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addMITMHostPattern() }
                Button("settings.network.addHost") {
                    addMITMHostPattern()
                }
                .disabled(newMitmHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if settings.settings.mitmHostPatterns.isEmpty {
                Text("config.network.mitmHostsEmpty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settings.settings.mitmHostPatterns, id: \.self) { hostPattern in
                    HStack {
                        Text(hostPattern)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button(role: .destructive) {
                            settings.update { updated in
                                updated.mitmHostPatterns.removeAll { $0 == hostPattern }
                            }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(hostPattern)
                    }
                }
            }
        }
    }

    private var customCertificatesSection: some View {
        let mode = proxyModeBinding.wrappedValue
        let hasBuiltInCA = certificates.contains { $0.source == .generatedBuiltIn }

        return Section {
            Toggle("settings.network.enableCustomCerts", isOn: customCertsEnabledBinding)
                .disabled(mode == .builtInMITM)

            HStack(spacing: 8) {
                Button("settings.network.importCert") {
                    importCertificateFiles()
                }
                Button(hasBuiltInCA ? "settings.network.regenerateCA" : "settings.network.generateCA") {
                    generateBuiltInCA(forceRegenerate: hasBuiltInCA)
                }
            }

            if certificates.isEmpty {
                Text("settings.network.noCerts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(certificates) { cert in
                    certificateRow(cert)
                }
            }

            Text("settings.network.certIsolationNote")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("settings.network.section.certificates")
        }
    }

    @ViewBuilder
    private func certificateRow(_ cert: AppCertificateRecord) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { cert.enabled },
                set: { toggleCertificate(cert, enabled: $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(cert.label)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(cert.label)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Text(ConfigLabelFormatter.localized(
                        cert.source == .generatedBuiltIn
                            ? "settings.network.certBadge.builtIn"
                            : "settings.network.certBadge.imported",
                        locale: locale
                    ))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(cert.source == .generatedBuiltIn ? .blue : .teal)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    if cert.isExpired {
                        Text("settings.network.certBadge.expired")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.red.opacity(0.14)))
                            .overlay(Capsule().strokeBorder(Color.red.opacity(0.32), lineWidth: 0.5))
                    }
                }
                HStack(spacing: 8) {
                    Text(cert.shortFingerprint)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    if let notAfter = cert.notAfter {
                        Text(notAfter.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 4)

            Button {
                exportCertificatePEM(cert)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("settings.network.exportCert")
            .accessibilityLabel("settings.network.exportCert")

            Button(role: .destructive) {
                deleteCertificate(cert)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(cert.label)
        }
    }

    private func rulesToggleSection(stats: NetworkRuleStats) -> some View {
        Section {
            Toggle("settings.network.enable", isOn: $settings.settings.enableNetworkRules)
            Toggle("settings.network.mock200", isOn: $settings.settings.networkBlockMock200)
                .disabled(!settings.settings.enableNetworkRules)
            LabeledContent("config.pane.network") {
                Text(String(
                    format: ConfigLabelFormatter.localized("settings.network.stats", locale: locale),
                    stats.block,
                    stats.allow,
                    stats.disabled
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private func reloadCertificates() {
        certificates = mitmCoordinator.certificateStore.listCertificates(for: bundleID)
    }

    private func addMITMHostPattern() {
        let trimmed = newMitmHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        settings.update { updated in
            if !updated.mitmHostPatterns.contains(trimmed) {
                updated.mitmHostPatterns.append(trimmed)
            }
        }
        newMitmHost = ""
    }

    private func importCertificateFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        var types: [UTType] = [.x509Certificate, .data]
        for ext in ["pem", "cer", "crt", "der"] {
            if let ut = UTType(filenameExtension: ext) {
                types.append(ut)
            }
        }
        panel.allowedContentTypes = types
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                do {
                    for url in urls {
                        _ = try mitmCoordinator.certificateStore.importCertificates(from: url, for: bundleID)
                    }
                    if !settings.settings.enableCustomCertificates {
                        settings.update { $0.enableCustomCertificates = true }
                    }
                    mitmCoordinator.syncCertificates(for: bundleID, settings: settings.settings)
                    reloadCertificates()
                } catch {
                    PlayCoverDiagnostics.reportError(error)
                }
            }
        }
    }

    private func generateBuiltInCA(forceRegenerate: Bool) {
        do {
            if forceRegenerate {
                _ = try mitmCoordinator.certificateStore.regenerateBuiltInRootCA(for: bundleID)
            } else {
                _ = try mitmCoordinator.certificateStore.ensureBuiltInRootCA(for: bundleID)
            }
            mitmCoordinator.syncCertificates(for: bundleID, settings: settings.settings)
            reloadCertificates()
        } catch {
            PlayCoverDiagnostics.reportError(error)
        }
    }

    private func toggleCertificate(_ cert: AppCertificateRecord, enabled: Bool) {
        do {
            try mitmCoordinator.certificateStore.setCertificateEnabled(
                id: cert.id,
                enabled: enabled,
                for: bundleID
            )
            mitmCoordinator.syncCertificates(for: bundleID, settings: settings.settings)
            reloadCertificates()
        } catch {
            PlayCoverDiagnostics.reportError(error)
        }
    }

    private func exportCertificatePEM(_ cert: AppCertificateRecord) {
        guard let der = try? mitmCoordinator.certificateStore.certificateDER(id: cert.id, for: bundleID) else {
            return
        }
        let pem = X509CertificateInspector.exportPEM(der: der)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(bundleID)-\(cert.id.prefix(8)).pem"
        if let pemType = UTType(filenameExtension: "pem") {
            panel.allowedContentTypes = [pemType, .plainText]
        } else {
            panel.allowedContentTypes = [.plainText]
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? pem.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func deleteCertificate(_ cert: AppCertificateRecord) {
        do {
            try mitmCoordinator.certificateStore.deleteCertificate(id: cert.id, for: bundleID)
            mitmCoordinator.syncCertificates(for: bundleID, settings: settings.settings)
            reloadCertificates()
        } catch {
            PlayCoverDiagnostics.reportError(error)
        }
    }

    private var addRuleBar: some View {
        let canAdd = !trimmedNewPattern.isEmpty && !isNewPatternInvalid
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("", text: $newPattern, prompt: Text("settings.network.placeholder"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        guard canAdd else { return }
                        addPatterns(from: newPattern)
                        newPattern = ""
                    }
                Button("settings.network.add") {
                    addPatterns(from: newPattern)
                    newPattern = ""
                }
                .disabled(!canAdd)

                Button("settings.network.addAllow") {
                    addPatterns(from: newPattern, forceAllow: true)
                    newPattern = ""
                }
                .disabled(!canAdd)
            }

            if isNewPatternInvalid {
                Label("config.network.invalidRule", systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var searchAndActionsBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("", text: $searchText, prompt: Text("settings.network.search"))
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

            Menu {
                Button("settings.network.paste") {
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        addPatterns(from: pasted)
                    }
                }
                Button("settings.network.copyAll") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(
                        settings.settings.blockedURLPatterns.joined(separator: "\n"),
                        forType: .string
                    )
                }
                .disabled(settings.settings.blockedURLPatterns.isEmpty)
                Divider()
                Button("settings.network.importFile") { importFromFile() }
                Button("settings.network.exportFile") { exportToFile() }
                    .disabled(settings.settings.blockedURLPatterns.isEmpty)
                Divider()
                Button("settings.network.clear", role: .destructive) {
                    showClearRulesConfirm = true
                }
                .disabled(settings.settings.blockedURLPatterns.isEmpty)
            } label: {
                Label("settings.network.actions", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("settings.network.actions")
        }
    }

    private func addPatterns(from rawText: String, forceAllow: Bool = false) {
        let lines = rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { NetworkRuleParser.isImportableRuleLine($0) }
        guard !lines.isEmpty else { return }
        settings.update { updated in
            var existingActive = Set(updated.blockedURLPatterns.map { NetworkRuleParser.activeBody($0) })
            for rawLine in lines {
                let line = forceAllow ? NetworkRuleParser.normalizedAllowRule(rawLine) : rawLine
                let active = NetworkRuleParser.activeBody(line)
                if !active.isEmpty && !existingActive.contains(active) {
                    updated.blockedURLPatterns.append(line)
                    existingActive.insert(active)
                }
            }
        }
    }

    private func setRuleEnabled(at idx: Int, enabled: Bool) {
        settings.update { updated in
            guard idx >= 0 && idx < updated.blockedURLPatterns.count else { return }
            let body = NetworkRuleParser.activeBody(updated.blockedURLPatterns[idx])
            guard !body.isEmpty else { return }
            updated.blockedURLPatterns[idx] = enabled ? body : (NetworkRuleParser.disabledPrefix + body)
        }
    }

    private func deleteRule(at idx: Int) {
        if editingIndex == idx {
            editingIndex = nil
            editingText = ""
        }
        settings.update { updated in
            if idx >= 0 && idx < updated.blockedURLPatterns.count {
                updated.blockedURLPatterns.remove(at: idx)
            }
        }
    }

    private func commitEdit(at idx: Int) {
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, NetworkRuleParser.isImportableRuleLine(trimmed) else { return }
        settings.update { updated in
            guard idx >= 0 && idx < updated.blockedURLPatterns.count else { return }
            updated.blockedURLPatterns[idx] = trimmed
        }
        editingIndex = nil
        editingText = ""
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        var types: [UTType] = [.plainText, .text, .data]
        if let confType = UTType(filenameExtension: "conf") { types.append(confType) }
        if let listType = UTType(filenameExtension: "list") { types.append(listType) }
        panel.allowedContentTypes = types
        panel.begin { response in
            guard response == .OK, let url = panel.url,
                  let content = try? String(contentsOf: url, encoding: .utf8) else { return }
            Task { @MainActor in
                addPatterns(from: content)
            }
        }
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(settings.info.bundleIdentifier)-network-rules.conf"
        var types: [UTType] = [.plainText]
        if let confType = UTType(filenameExtension: "conf") { types.insert(confType, at: 0) }
        panel.allowedContentTypes = types
        let bundleID = settings.info.bundleIdentifier
        let patterns = settings.settings.blockedURLPatterns
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let header = "# MacOver Network Rules for \(bundleID)\n"
            let content = header + patterns.joined(separator: "\n") + "\n"
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

private struct NetworkRuleRowView: View {
    @Environment(\.locale) private var locale

    let rule: String
    let isEditing: Bool
    @Binding var editingText: String
    let onToggleEnabled: @MainActor @Sendable (Bool) -> Void
    let onStartEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onDelete: () -> Void

    private var trimmedEdit: String {
        editingText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isEditInvalid: Bool {
        !trimmedEdit.isEmpty && !NetworkRuleParser.isImportableRuleLine(trimmedEdit)
    }

    private var canCommitEdit: Bool {
        !trimmedEdit.isEmpty && NetworkRuleParser.isImportableRuleLine(trimmedEdit)
    }

    var body: some View {
        let meta = NetworkRuleParser.classifyRule(rule)
        if isEditing {
            editingRow()
        } else {
            HStack(spacing: 8) {
                displayRow(meta: meta)
            }
        }
    }

    @ViewBuilder
    private func editingRow() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                TextField("", text: $editingText)
                    .labelsHidden()
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        if canCommitEdit {
                            onCommitEdit()
                        }
                    }
                Button(action: onCommitEdit) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
                .disabled(!canCommitEdit)
                .accessibilityLabel("button.OK")

                Button(action: onCancelEdit) {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("button.Cancel")
            }

            if isEditInvalid {
                Label("config.network.invalidRule", systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private func displayRow(meta: NetworkRuleParser.RuleMeta) -> some View {
        Toggle("", isOn: Binding(get: { meta.isEnabled }, set: onToggleEnabled))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .accessibilityLabel(meta.body)

        Text(ConfigLabelFormatter.localized(
            !meta.isEnabled
                ? "settings.network.badge.disabled"
                : (meta.isAllow ? "settings.network.badge.allow" : "settings.network.badge.block"),
            locale: locale
        ))
        .font(.caption2.weight(.semibold))
        .foregroundStyle(!meta.isEnabled ? Color.secondary : (meta.isAllow ? Color.green : Color.red))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(
                !meta.isEnabled
                    ? Color.gray.opacity(0.16)
                    : (meta.isAllow ? Color.green.opacity(0.16) : Color.red.opacity(0.16))
            )
        )

        Text(ConfigLabelFormatter.localized(meta.kindKey, locale: locale))
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))

        Text(meta.body)
            .font(.system(.caption, design: .monospaced))
            .strikethrough(!meta.isEnabled)
            .foregroundStyle(meta.isEnabled ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(rule)
            .onTapGesture(count: 2, perform: onStartEdit)

        Spacer(minLength: 4)

        Button(action: onStartEdit) {
            Image(systemName: "pencil")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(meta.body)

        Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(meta.body)
    }
}
