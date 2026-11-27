//
//  ConfigInputPane.swift
//  PlayCover
//

import SwiftUI

enum KeymapNameValidation {
    case malformed, duplicate, empty, valid
}

struct ConfigInputPane: View {
    @Environment(\.locale) private var locale

    var app: PlayApp
    @Bindable var settings: AppSettings

    @State private var keymapVM: KeymapViewVM

    @State private var newKeymapName = ""
    @State private var renamingURL: URL?
    @State private var renameText = ""
    @State private var keymapPendingReset: String?
    @State private var keymapPendingDelete: String?

    init(app: PlayApp, settings: AppSettings) {
        self.app = app
        self.settings = settings
        _keymapVM = State(initialValue: KeymapViewVM(app: app, loadCacheImmediately: false))
    }

    private func validateKeymapName(_ candidate: String) -> KeymapNameValidation {
        if candidate.esc != candidate {
            return .malformed
        }
        if candidate.isEmpty {
            return .empty
        }
        if app.keymapping.hasKeymap(name: candidate) {
            return .duplicate
        }
        return .valid
    }

    var body: some View {
        let newValidation = validateKeymapName(newKeymapName)
        Form {
            Section("settings.tab.km") {
                Toggle("settings.toggle.km", isOn: $settings.settings.keymapping)
                    .help("settings.toggle.km.help")
                Toggle("settings.toggle.autoKM", isOn: $settings.settings.noKMOnInput)
                    .help("settings.toggle.autoKM.help")
                Toggle("settings.toggle.enableScrollWheel", isOn: $settings.settings.enableScrollWheel)
                    .help("settings.toggle.enableScrollWheel.help")
                Toggle("settings.toggle.rightClickLongPress", isOn: $settings.settings.rightClickLongPress)
                    .help("settings.toggle.rightClickLongPress.help")
                Toggle("settings.toggle.disableBuiltinMouse", isOn: $settings.settings.disableBuiltinMouse)
                    .help("settings.toggle.disableBuiltinMouse.help")

                LabeledContent {
                    Slider(value: $settings.settings.sensitivity, in: 0...100)
                        .frame(maxWidth: 260)
                        .disabled(!settings.settings.keymapping)
                } label: {
                    Text(String(
                        format: ConfigLabelFormatter.localized("settings.slider.mouseSensitivity", locale: locale),
                        settings.settings.sensitivity
                    ))
                    .monospacedDigit()
                }
            }

            Section("playapp.keymap") {
                HStack(spacing: 8) {
                    TextField("", text: $newKeymapName, prompt: Text("input.newKeymapPlaceholder"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if newValidation == .valid {
                                createKeymap()
                            }
                        }

                    validationIndicator(for: newValidation)

                    Button("input.create") {
                        createKeymap()
                    }
                    .disabled(newValidation != .valid)

                    Button("input.importNamed") {
                        importKeymap()
                    }
                    .disabled(newValidation != .valid)
                }

                ForEach(keymapVM.keymapURLS, id: \.self) { keymapURL in
                    keymapRow(for: keymapURL)
                }
                .onMove { src, dst in
                    keymapVM.keymapURLS.move(fromOffsets: src, toOffset: dst)
                }
            }
        }
        .formStyle(.grouped)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onAppear {
            keymapVM.ensureLoaded()
        }
        .onChange(of: app.url) {
            keymapVM.reloadKeymapCache()
            renamingURL = nil
            renameText = ""
            keymapPendingReset = nil
            keymapPendingDelete = nil
        }
        .alert(
            "confirm.resetKeymap.title",
            isPresented: Binding(
                get: { keymapPendingReset != nil },
                set: { if !$0 { keymapPendingReset = nil } }
            )
        ) {
            Button("button.Cancel", role: .cancel) {
                keymapPendingReset = nil
            }
            Button("button.Reset", role: .destructive) {
                if let name = keymapPendingReset {
                    app.keymapping.reset(name: name)
                }
                keymapPendingReset = nil
            }
        } message: {
            if let name = keymapPendingReset {
                Text(name)
            }
        }
        .alert(
            "confirm.deleteKeymap.title",
            isPresented: Binding(
                get: { keymapPendingDelete != nil },
                set: { if !$0 { keymapPendingDelete = nil } }
            )
        ) {
            Button("button.Cancel", role: .cancel) {
                keymapPendingDelete = nil
            }
            Button("settings.deleteKm", role: .destructive) {
                if let name = keymapPendingDelete {
                    deleteKeymap(name: name)
                }
                keymapPendingDelete = nil
            }
        } message: {
            if let name = keymapPendingDelete {
                Text(name)
            }
        }
    }

    @ViewBuilder
    private func keymapRow(for keymapURL: URL) -> some View {
        let name = keymapURL.deletingPathExtension().lastPathComponent
        if renamingURL == keymapURL {
            renameKeymapRow(prevName: name)
        } else {
            displayKeymapRow(keymapURL: keymapURL, name: name)
        }
    }

    private func renameKeymapRow(prevName: String) -> some View {
        let renameValidation = validateKeymapName(renameText)
        return HStack(spacing: 8) {
            TextField("", text: $renameText, prompt: Text("keymap.sheet.name"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if renameValidation == .valid {
                        commitRename(prevName: prevName)
                    }
                }
            validationIndicator(for: renameValidation)
            Button {
                commitRename(prevName: prevName)
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .disabled(renameValidation != .valid)
            .accessibilityLabel("button.OK")

            Button {
                renamingURL = nil
                renameText = ""
            } label: {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("button.Cancel")
        }
    }

    private func displayKeymapRow(keymapURL: URL, name: String) -> some View {
        let isDefault = keymapURL == keymapVM.defaultKm
        return HStack(spacing: 8) {
            Text(name)
                .fontWeight(isDefault ? .semibold : .regular)
            if isDefault {
                Text("keymap.default")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
            }
            Spacer()
            keymapRowButtons(keymapURL: keymapURL, name: name, isDefault: isDefault)
        }
    }

    private func keymapRowButtons(keymapURL: URL, name: String, isDefault: Bool) -> some View {
        Group {
            if !isDefault {
                Button("settings.defaultKm") { keymapVM.setDefaultKeymap(keymap: keymapURL) }
                    .controlSize(.small)
            }
            Button {
                renamingURL = keymapURL
                renameText = name
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("settings.renameKm")
            .accessibilityLabel("settings.renameKm")

            Button { app.keymapping.exportKeymap(name: name) } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("playapp.exportKm")
            .accessibilityLabel("playapp.exportKm")

            Button {
                keymapPendingReset = name
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("settings.resetKm")
            .accessibilityLabel("settings.resetKm")

            if !isDefault {
                Button(role: .destructive) {
                    keymapPendingDelete = name
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("settings.deleteKm")
                .accessibilityLabel("settings.deleteKm")
            }
        }
    }

    private func deleteKeymap(name: String) {
        if !app.keymapping.deleteKeymap(name: name) {
            PlayCoverDiagnostics.reportError(
                String(
                    format: ConfigLabelFormatter.localized("settings.deleteKmFailed", locale: locale),
                    arguments: [name]
                )
            )
        }
        keymapVM.reloadKeymapCache()
    }

    @ViewBuilder
    private func validationIndicator(for state: KeymapNameValidation) -> some View {
        switch state {
        case .empty:
            EmptyView()
        case .valid:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .help("preferences.popover.valid.keymap")
                .accessibilityLabel("preferences.popover.valid.keymap")
        case .duplicate:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
                .help("preferences.popover.duplicate.keymap")
                .accessibilityLabel("preferences.popover.duplicate.keymap")
        case .malformed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .help("preferences.popover.malformed.keymap")
                .accessibilityLabel("preferences.popover.malformed.keymap")
        }
    }

    private func createKeymap() {
        if app.keymapping.createEmptyKeymap(name: newKeymapName) {
            newKeymapName = ""
            keymapVM.reloadKeymapCache()
        } else {
            PlayCoverDiagnostics.reportError(ConfigLabelFormatter.localized("alert.errorKmCreated", locale: locale))
        }
    }

    private func importKeymap() {
        let targetName = newKeymapName
        app.keymapping.importKeymap(name: targetName) { success in
            keymapVM.reloadKeymapCache()
            if success {
                newKeymapName = ""
            } else {
                PlayCoverDiagnostics.reportError(ConfigLabelFormatter.localized("alert.errorImportKm", locale: locale))
            }
        }
    }

    private func commitRename(prevName: String) {
        let nextName = renameText
        renamingURL = nil
        renameText = ""
        if app.keymapping.renameKeymap(prevName: prevName, newName: nextName) {
            keymapVM.reloadKeymapCache()
        } else {
            PlayCoverDiagnostics.reportError(ConfigLabelFormatter.localized("alert.errorRenameKm", locale: locale))
        }
    }
}
