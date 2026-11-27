//
//  IPASourceSettings.swift
//  PlayCover
//
//  Created by Isaac Marovitz on 20/09/2022.
//

import SwiftUI

struct SourceData: Identifiable, Hashable {
    var id: UUID
    var source: String
    var status: SourceValidation
    var isEnabled: Bool

}

extension SourceData: Codable {
    init(source: String, isEnabled: Bool) {
        self.id = UUID()
        self.source = source
        self.status = .checking
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            source: try container.decode(String.self, forKey: .source),
            status: .checking,
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        )
    }
}

struct IPASourceSettings: View {
    @State var selected = Set<UUID>()
    @State var addSourceSheet = false
    @Environment(StoreVM.self) var storeVM
    @Environment(URLObservable.self) var urlObservable

    private var hasSelection: Bool {
        !selected.isEmpty
    }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    List(storeVM.sourcesList, id: \.id, selection: $selected) { source in
                        SourceView(source: source, isEnabled: source.isEnabled)
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    .frame(minHeight: 240)

                    VStack(spacing: 8) {
                        Button {
                            addSourceSheet = true
                        } label: {
                            Text("preferences.button.addSource")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(role: .destructive) {
                            storeVM.deleteSource(&selected)
                        } label: {
                            Text("preferences.button.deleteSource")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!hasSelection)

                        Divider()
                            .padding(.vertical, 4)

                        Button {
                            storeVM.moveSourceUp(&selected)
                        } label: {
                            Text("preferences.button.moveSourceUp")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!hasSelection)

                        Button {
                            storeVM.moveSourceDown(&selected)
                        } label: {
                            Text("preferences.button.moveSourceDown")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!hasSelection)

                        Divider()
                            .padding(.vertical, 4)

                        Button {
                            storeVM.resolveSources()
                        } label: {
                            Text("playapp.refreshSources")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(width: 148)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $addSourceSheet) {
            AddSourceView(addSourceSheet: $addSourceSheet)
                .environment(storeVM)
                .environment(urlObservable)
        }
    }
}

struct SourceView: View {
    var source: SourceData
    @State var isEnabled: Bool
    @State var showingPopover = false
    @Environment(StoreVM.self) var storeVM

    var body: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $isEnabled) {
                Text(source.source)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .toggleStyle(.checkbox)
            .foregroundStyle(isEnabled ? .primary : .secondary)
            .help("state.enabled")
            Spacer(minLength: 8)
            switch source.status {
            case .badjson:
                StatusBadgeView(imageName: "xmark.circle.fill",
                                imageColor: .red,
                                popoverText: "preferences.popover.badjson",
                                showingPopover: $showingPopover)
            case .badurl:
                StatusBadgeView(imageName: "xmark.circle.fill",
                                imageColor: .red,
                                popoverText: "preferences.popover.badurl",
                                showingPopover: $showingPopover)
            case .checking:
                ProgressView()
                    .controlSize(.small)
                    .help("preferences.popover.checking")
            case .duplicate:
                StatusBadgeView(imageName: "exclamationmark.triangle.fill",
                                imageColor: .orange,
                                popoverText: "preferences.popover.duplicate",
                                showingPopover: $showingPopover)
            case .empty:
                EmptyView()
            case .valid:
                if isEnabled {
                    StatusBadgeView(imageName: "checkmark.circle.fill",
                                    imageColor: .green,
                                    popoverText: "preferences.popover.valid",
                                    showingPopover: $showingPopover)
                } else {
                    StatusBadgeView(imageName: "checkmark.circle.badge.xmark.fill",
                                    imageColor: .gray,
                                    popoverText: "state.disabled",
                                    showingPopover: $showingPopover)
                }
            }
        }
        .onChange(of: source.isEnabled) { _, newValue in
            if isEnabled != newValue {
                isEnabled = newValue
            }
        }
        .onChange(of: isEnabled) { _, value in
            storeVM.enableSourceToggle(source: source, value: value)
            storeVM.updateSourcesApps()
        }
    }
}

struct StatusBadgeView: View {
    var imageName: String
    var imageColor: Color
    var popoverText: String
    @Binding var showingPopover: Bool

    var body: some View {
        Button {
            showingPopover.toggle()
        } label: {
            Image(systemName: imageName)
                .foregroundStyle(imageColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(LocalizedStringKey(popoverText)))
        .popover(isPresented: $showingPopover) {
            Text(NSLocalizedString(popoverText, comment: ""))
                .padding(10)
        }
    }
}

enum SourceValidation: Codable {
    case badjson, badurl, checking, duplicate, valid, empty
}

struct AddSourceView: View {
    @State var newSource = ""
    @State var newSourceURL: URL?
    @State var sourceValidationState = SourceValidation.empty
    @Binding var addSourceSheet: Bool
    @Environment(StoreVM.self) var storeVM
    @Environment(URLObservable.self) var urlObservable

    @State var checkTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("preferences.button.addSource")
                .font(.headline)

            TextField("preferences.textfield.url", text: $newSource)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                validationStatusView
                Spacer(minLength: 12)
                Button("button.Cancel") {
                    addSourceSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("button.OK") {
                    if sourceValidationState == .valid, let sourceURL = newSourceURL?.absoluteString {
                        storeVM.addSource(SourceData(source: sourceURL, isEnabled: true))
                        addSourceSheet = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(sourceValidationState != .valid)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: newSource) { _, source in
            checkTask?.cancel()
            validateSource(source)
        }
        .onAppear {
            if urlObservable.type == .source {
                newSource = urlObservable.url ?? ""
            }
        }
        .onDisappear {
            checkTask?.cancel()
            urlObservable.url = nil
            urlObservable.type = nil
            urlObservable.action = nil
        }
    }

    @ViewBuilder
    private var validationStatusView: some View {
        switch sourceValidationState {
        case .badjson:
            Label("preferences.popover.badjson", systemImage: "xmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
        case .badurl:
            Label("preferences.popover.badurl", systemImage: "xmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("preferences.popover.checking")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .duplicate:
            Label("preferences.popover.duplicate", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
        case .empty:
            EmptyView()
        case .valid:
            Label("preferences.popover.valid", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
        }
    }

    func validateSource(_ source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            newSourceURL = nil
            sourceValidationState = .empty
            return
        }

        guard let url = StoreVM.normalizeSourceURL(trimmed) else {
            newSourceURL = nil
            sourceValidationState = .badurl
            return
        }

        newSourceURL = url

        let normalized = url.absoluteString
        let isAlreadyAdded = storeVM.sourcesList.contains { existing in
            existing.source == normalized || StoreVM.normalizeSourceURL(existing.source)?.absoluteString == normalized
        }
        if isAlreadyAdded {
            sourceValidationState = .duplicate
            return
        }

        sourceValidationState = .checking
        let existingSources = storeVM.sourcesList.map(\.source)

        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }

            let (_, validation) = await StoreVM.fetchAndValidateSource(url: url)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                if validation == .valid {
                    let duplicate = existingSources.contains { existing in
                        existing == normalized
                            || StoreVM.normalizeSourceURL(existing)?.absoluteString == normalized
                    }
                    sourceValidationState = duplicate ? .duplicate : .valid
                } else {
                    sourceValidationState = validation
                }
            }
        }
    }
}

struct IPASourceSettings_Previews: PreviewProvider {
    static var previews: some View {
        IPASourceSettings()
    }
}
