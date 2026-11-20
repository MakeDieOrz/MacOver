//
//  ConfigNetworkPane.swift
//  PlayCover
//

import PlayCoverCore
import SwiftUI
import UniformTypeIdentifiers

private struct NetworkRuleStats {
    var block = 0
    var allow = 0
    var disabled = 0
}

struct ConfigNetworkPane: View {
    @ObservedObject var settings: AppSettings

    @State private var newPattern = ""
    @State private var searchText = ""
    @State private var editingIndex: Int?
    @State private var editingText = ""

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

    private var filteredRules: [(offset: Int, element: String)] {
        let enumerated = Array(settings.settings.blockedURLPatterns.enumerated())
        guard !trimmedQuery.isEmpty else { return enumerated }
        return enumerated.filter { $0.element.localizedCaseInsensitiveContains(trimmedQuery) }
    }

    var body: some View {
        let stats = ruleStats
        Form {
            Section {
                Toggle("settings.network.enable", isOn: $settings.settings.enableNetworkRules)
                Toggle("settings.network.mock200", isOn: $settings.settings.networkBlockMock200)
                    .disabled(!settings.settings.enableNetworkRules)
                LabeledContent("ui51.config.pane.network") {
                    Text(String(
                        format: NSLocalizedString("settings.network.stats", comment: ""),
                        stats.block,
                        stats.allow,
                        stats.disabled
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

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
    }

    private var addRuleBar: some View {
        let canAdd = !newPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 8) {
            TextField("", text: $newPattern, prompt: Text("settings.network.placeholder"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit {
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
    }

    private var searchAndActionsBar: some View {
        HStack(spacing: 8) {
            TextField("", text: $searchText, prompt: Text("settings.network.search"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
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
                    editingIndex = nil
                    settings.update { $0.blockedURLPatterns.removeAll() }
                }
                .disabled(settings.settings.blockedURLPatterns.isEmpty)
            } label: {
                Label("settings.network.actions", systemImage: "ellipsis.circle")
            }
            .fixedSize()
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
        if editingIndex == idx { editingIndex = nil }
        settings.update { updated in
            if idx >= 0 && idx < updated.blockedURLPatterns.count {
                updated.blockedURLPatterns.remove(at: idx)
            }
        }
    }

    private func commitEdit(at idx: Int) {
        defer {
            editingIndex = nil
            editingText = ""
        }
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, NetworkRuleParser.isImportableRuleLine(trimmed) else { return }
        settings.update { updated in
            guard idx >= 0 && idx < updated.blockedURLPatterns.count else { return }
            updated.blockedURLPatterns[idx] = trimmed
        }
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
            let header = "# PlayCover Network Rules for \(bundleID)\n"
            let content = header + patterns.joined(separator: "\n") + "\n"
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

private struct NetworkRuleRowView: View {
    let rule: String
    let isEditing: Bool
    @Binding var editingText: String
    let onToggleEnabled: (Bool) -> Void
    let onStartEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let meta = NetworkRuleParser.classifyRule(rule)
        HStack(spacing: 8) {
            if isEditing {
                editingRow()
            } else {
                displayRow(meta: meta)
            }
        }
    }

    @ViewBuilder
    private func editingRow() -> some View {
        TextField("", text: $editingText)
            .font(.system(.caption, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .onSubmit { onCommitEdit() }
        Button(action: onCommitEdit) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.borderless)
        Button(action: onCancelEdit) {
            Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private func displayRow(meta: NetworkRuleParser.RuleMeta) -> some View {
        Toggle("", isOn: Binding(get: { meta.isEnabled }, set: onToggleEnabled))
            .toggleStyle(.checkbox)
            .labelsHidden()

        Text(NSLocalizedString(
            !meta.isEnabled
                ? "settings.network.badge.disabled"
                : (meta.isAllow ? "settings.network.badge.allow" : "settings.network.badge.block"),
            comment: ""
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

        Text(NSLocalizedString(meta.kindKey, comment: ""))
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
            Image(systemName: "pencil").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)

        Button(role: .destructive, action: onDelete) {
            Image(systemName: "trash").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
    }
}
