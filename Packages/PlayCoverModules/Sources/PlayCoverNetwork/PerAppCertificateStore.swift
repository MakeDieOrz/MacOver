import Foundation
import PlayCoverCore

public enum CertificateStoreError: Error, LocalizedError, Sendable {
    case invalidBundleIdentifier(String)
    case certificateNotFound(String)
    case builtInPrivateKeyMissing(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidBundleIdentifier(id):
            return "Invalid bundle identifier: \(id)"
        case let .certificateNotFound(id):
            return "Certificate not found: \(id)"
        case let .builtInPrivateKeyMissing(bundleID):
            return "Built-in MITM Root CA private key is missing for \(bundleID)."
        }
    }
}

public struct PerAppCertificateStore: Sendable {
    public let certificatesBaseURL: URL
    public let appSettingsBaseURL: URL

    public init(certificatesBaseURL: URL, appSettingsBaseURL: URL) {
        self.certificatesBaseURL = certificatesBaseURL
        self.appSettingsBaseURL = appSettingsBaseURL
    }

    public static func isValidCertificateID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 64 else {
            return false
        }
        return id.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 0x30 && v <= 0x39)
                || (v >= 0x41 && v <= 0x5A)
                || (v >= 0x61 && v <= 0x7A)
                || v == 0x2D // -
                || v == 0x5F // _
        }
    }

    public func appDirectoryURL(for bundleID: String) throws -> URL {
        let sanitized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard sanitized == bundleID,
              Shell.isValidBundleIdentifier(sanitized) else {
            throw CertificateStoreError.invalidBundleIdentifier(bundleID)
        }
        let dir = certificatesBaseURL.appendingPathComponent(sanitized, isDirectory: true)
        guard dir.standardizedFileURL.deletingLastPathComponent() == certificatesBaseURL.standardizedFileURL else {
            throw CertificateStoreError.invalidBundleIdentifier(bundleID)
        }
        return dir
    }

    private func validatedDERURL(id: String, in dir: URL) throws -> URL {
        guard Self.isValidCertificateID(id) else {
            throw CertificateStoreError.certificateNotFound(id)
        }
        let url = dir.appendingPathComponent("\(id).der")
        guard url.standardizedFileURL.deletingLastPathComponent() == dir.standardizedFileURL else {
            throw CertificateStoreError.certificateNotFound(id)
        }
        return url
    }

    public func runtimeBundleURL(for bundleID: String) throws -> URL {
        let dir = try appDirectoryURL(for: bundleID)
        return dir.appendingPathComponent("runtime.certs")
    }

    private func legacyRuntimeBundleURL(for bundleID: String) throws -> URL {
        _ = try appDirectoryURL(for: bundleID)
        let sanitized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return appSettingsBaseURL.appendingPathComponent("\(sanitized).plist.certs")
    }

    public func builtInRootCAMaterial(
        for bundleID: String
    ) -> (record: AppCertificateRecord, certificateDER: Data, privateKeyDER: Data)? {
        guard let dir = try? appDirectoryURL(for: bundleID) else { return nil }
        let keyURL = dir.appendingPathComponent("mitm-root-key.der")
        let records = listCertificates(for: bundleID)
        guard let existing = records.first(where: { $0.source == .generatedBuiltIn }),
              let certURL = try? validatedDERURL(id: existing.id, in: dir),
              let certDER = try? Data(contentsOf: certURL),
              let keyDER = try? Data(contentsOf: keyURL) else {
            return nil
        }
        return (existing, certDER, keyDER)
    }

    public func enabledCustomAnchorDERs(for bundleID: String) -> [Data] {
        guard let dir = try? appDirectoryURL(for: bundleID) else { return [] }
        let records = listCertificates(for: bundleID).filter { $0.enabled && $0.source == .imported }
        var anchors: [Data] = []
        for record in records {
            guard let derURL = try? validatedDERURL(id: record.id, in: dir),
                  let data = try? Data(contentsOf: derURL),
                  SecCertificateCreateWithData(nil, data as CFData) != nil else {
                continue
            }
            anchors.append(data)
        }
        return anchors
    }

    public func listCertificates(for bundleID: String) -> [AppCertificateRecord] {
        guard let dir = try? appDirectoryURL(for: bundleID) else { return [] }
        let indexURL = dir.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([AppCertificateRecord].self, from: data)) ?? []
    }

    @discardableResult
    public func importCertificates(from fileURL: URL, for bundleID: String) throws -> [AppCertificateRecord] {
        let data = try Data(contentsOf: fileURL)
        let defaultLabel = fileURL.deletingPathExtension().lastPathComponent
        return try importCertificateData(data, label: defaultLabel, for: bundleID)
    }

    @discardableResult
    public func importCertificateData(
        _ data: Data,
        label: String? = nil,
        for bundleID: String
    ) throws -> [AppCertificateRecord] {
        let parsedDERs = try X509CertificateInspector.parseCertificates(from: data)
        let dir = try ensureAppDirectory(for: bundleID)
        var records = listCertificates(for: bundleID)
        var added: [AppCertificateRecord] = []

        for (index, der) in parsedDERs.enumerated() {
            let labelHint: String? = {
                guard let label else { return nil }
                return parsedDERs.count > 1 ? "\(label) (\(index + 1))" : label
            }()
            var record = try X509CertificateInspector.inspect(
                der: der,
                label: labelHint,
                source: .imported,
                enabled: true
            )
            let derURL = dir.appendingPathComponent("\(record.id).der")
            try der.write(to: derURL, options: .atomic)

            if let existingIdx = records.firstIndex(where: { $0.id == record.id }) {
                record.enabled = true
                records[existingIdx] = record
            } else {
                records.append(record)
            }
            added.append(record)
        }

        try saveRecords(records, in: dir)
        return added
    }

    @discardableResult
    public func ensureBuiltInRootCA(
        for bundleID: String
    ) throws -> (record: AppCertificateRecord, certificateDER: Data, privateKeyDER: Data) {
        let dir = try ensureAppDirectory(for: bundleID)
        let keyURL = dir.appendingPathComponent("mitm-root-key.der")
        let records = listCertificates(for: bundleID)

        if let existing = records.first(where: { $0.source == .generatedBuiltIn }),
           let existingCertURL = try? validatedDERURL(id: existing.id, in: dir),
           let certDER = try? Data(contentsOf: existingCertURL),
           let keyDER = try? Data(contentsOf: keyURL),
           !existing.isExpired {
            return (existing, certDER, keyDER)
        }

        return try regenerateBuiltInRootCA(for: bundleID)
    }

    @discardableResult
    public func regenerateBuiltInRootCA(
        for bundleID: String
    ) throws -> (record: AppCertificateRecord, certificateDER: Data, privateKeyDER: Data) {
        let dir = try ensureAppDirectory(for: bundleID)
        let fm = FileManager.default
        var records = listCertificates(for: bundleID)

        // Remove previous built-in CA entry + DER file so only one active built-in root exists per app.
        for old in records where old.source == .generatedBuiltIn {
            if let oldCertURL = try? validatedDERURL(id: old.id, in: dir) {
                try? fm.removeItem(at: oldCertURL)
            }
        }
        records.removeAll { $0.source == .generatedBuiltIn }

        let generated = try X509CertificateGenerator.generateRootCA(
            commonName: "MacOver MITM CA (\(bundleID))"
        )
        let record = try X509CertificateInspector.inspect(
            der: generated.certificateDER,
            label: "MacOver MITM Root CA",
            source: .generatedBuiltIn,
            enabled: true
        )

        let certURL = try validatedDERURL(id: record.id, in: dir)
        try generated.certificateDER.write(to: certURL, options: .atomic)

        // Private key NEVER leaves host Certificates/<bundleID>/ and is created atomically with 0600 permissions.
        let keyURL = dir.appendingPathComponent("mitm-root-key.der")
        try SecureFileWriter.writeSecretFileAtomically(
            generated.privateKeyDER,
            to: keyURL,
            directoryPermissions: 0o700,
            filePermissions: 0o600
        )

        records.insert(record, at: 0)
        try saveRecords(records, in: dir)
        return (record, generated.certificateDER, generated.privateKeyDER)
    }

    public func setCertificateEnabled(id: String, enabled: Bool, for bundleID: String) throws {
        guard Self.isValidCertificateID(id) else {
            throw CertificateStoreError.certificateNotFound(id)
        }
        let dir = try ensureAppDirectory(for: bundleID)
        var records = listCertificates(for: bundleID)
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            throw CertificateStoreError.certificateNotFound(id)
        }
        records[idx].enabled = enabled
        try saveRecords(records, in: dir)
    }

    public func deleteCertificate(id: String, for bundleID: String) throws {
        guard Self.isValidCertificateID(id) else {
            throw CertificateStoreError.certificateNotFound(id)
        }
        let dir = try appDirectoryURL(for: bundleID)
        let fm = FileManager.default
        var records = listCertificates(for: bundleID)
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            throw CertificateStoreError.certificateNotFound(id)
        }
        let removed = records.remove(at: idx)
        if let derURL = try? validatedDERURL(id: removed.id, in: dir) {
            try? fm.removeItem(at: derURL)
        }
        if removed.source == .generatedBuiltIn {
            try? fm.removeItem(at: dir.appendingPathComponent("mitm-root-key.der"))
        }
        try saveRecords(records, in: dir)
    }

    public func certificateDER(id: String, for bundleID: String) throws -> Data {
        let dir = try appDirectoryURL(for: bundleID)
        let derURL = try validatedDERURL(id: id, in: dir)
        guard FileManager.default.fileExists(atPath: derURL.path) else {
            throw CertificateStoreError.certificateNotFound(id)
        }
        return try Data(contentsOf: derURL)
    }

    /// Writes `<certificatesBaseURL>/<bundleID>/runtime.certs` containing ONLY enabled public DER certificates.
    /// Private keys are never included in `runtime.certs` or inside app containers.
    public func syncRuntimeCertificates(for bundleID: String, enabled: Bool) throws {
        let bundleURL = try runtimeBundleURL(for: bundleID)
        let fm = FileManager.default
        if let legacyURL = try? legacyRuntimeBundleURL(for: bundleID),
           fm.fileExists(atPath: legacyURL.path) {
            try? fm.removeItem(at: legacyURL)
        }
        if !enabled {
            try? fm.removeItem(at: bundleURL)
            return
        }

        let dir = try appDirectoryURL(for: bundleID)
        let records = listCertificates(for: bundleID).filter(\.enabled)
        var derBlobs: [Data] = []
        for record in records {
            if let derURL = try? validatedDERURL(id: record.id, in: dir),
               let data = try? Data(contentsOf: derURL),
               SecCertificateCreateWithData(nil, data as CFData) != nil {
                derBlobs.append(data)
            }
        }

        if derBlobs.isEmpty {
            try? fm.removeItem(at: bundleURL)
            return
        }

        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let plistDict: [String: Any] = ["certificates": derBlobs]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plistDict,
            format: .binary,
            options: 0
        )
        try plistData.write(to: bundleURL, options: .atomic)
    }

    public func removeAllData(for bundleID: String) {
        let fm = FileManager.default
        if let dir = try? appDirectoryURL(for: bundleID) {
            try? fm.removeItem(at: dir)
        }
        if let runtimeURL = try? runtimeBundleURL(for: bundleID) {
            try? fm.removeItem(at: runtimeURL)
        }
        if let legacyURL = try? legacyRuntimeBundleURL(for: bundleID) {
            try? fm.removeItem(at: legacyURL)
        }
    }

    private func ensureAppDirectory(for bundleID: String) throws -> URL {
        let dir = try appDirectoryURL(for: bundleID)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return dir
    }

    private func saveRecords(_ records: [AppCertificateRecord], in dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)
        try data.write(to: dir.appendingPathComponent("index.json"), options: .atomic)
    }
}
