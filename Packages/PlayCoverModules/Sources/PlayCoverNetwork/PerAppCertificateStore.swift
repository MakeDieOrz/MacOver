import Foundation

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

    public func appDirectoryURL(for bundleID: String) throws -> URL {
        let sanitized = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty,
              !sanitized.contains("/"),
              !sanitized.contains(".."),
              !sanitized.contains("\\") else {
            throw CertificateStoreError.invalidBundleIdentifier(bundleID)
        }
        return certificatesBaseURL.appendingPathComponent(sanitized, isDirectory: true)
    }

    public func runtimeBundleURL(for bundleID: String) throws -> URL {
        _ = try appDirectoryURL(for: bundleID)
        return appSettingsBaseURL.appendingPathComponent("\(bundleID).plist.certs")
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
           let certDER = try? Data(contentsOf: dir.appendingPathComponent("\(existing.id).der")),
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
            try? fm.removeItem(at: dir.appendingPathComponent("\(old.id).der"))
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

        let certURL = dir.appendingPathComponent("\(record.id).der")
        try generated.certificateDER.write(to: certURL, options: .atomic)

        // Private key NEVER leaves host Certificates/<bundleID>/ and uses strict 0600 permissions.
        let keyURL = dir.appendingPathComponent("mitm-root-key.der")
        try generated.privateKeyDER.write(to: keyURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: keyURL.path)

        records.insert(record, at: 0)
        try saveRecords(records, in: dir)
        return (record, generated.certificateDER, generated.privateKeyDER)
    }

    public func setCertificateEnabled(id: String, enabled: Bool, for bundleID: String) throws {
        let dir = try ensureAppDirectory(for: bundleID)
        var records = listCertificates(for: bundleID)
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            throw CertificateStoreError.certificateNotFound(id)
        }
        records[idx].enabled = enabled
        try saveRecords(records, in: dir)
    }

    public func deleteCertificate(id: String, for bundleID: String) throws {
        let dir = try appDirectoryURL(for: bundleID)
        let fm = FileManager.default
        var records = listCertificates(for: bundleID)
        guard let idx = records.firstIndex(where: { $0.id == id }) else {
            throw CertificateStoreError.certificateNotFound(id)
        }
        let removed = records.remove(at: idx)
        try? fm.removeItem(at: dir.appendingPathComponent("\(removed.id).der"))
        if removed.source == .generatedBuiltIn {
            try? fm.removeItem(at: dir.appendingPathComponent("mitm-root-key.der"))
        }
        try saveRecords(records, in: dir)
    }

    public func certificateDER(id: String, for bundleID: String) throws -> Data {
        let dir = try appDirectoryURL(for: bundleID)
        let derURL = dir.appendingPathComponent("\(id).der")
        guard FileManager.default.fileExists(atPath: derURL.path) else {
            throw CertificateStoreError.certificateNotFound(id)
        }
        return try Data(contentsOf: derURL)
    }

    /// Writes `<appSettingsBaseURL>/<bundleID>.plist.certs` containing ONLY enabled public DER certificates.
    /// Private keys are never written to `appSettingsBaseURL` or inside app containers.
    public func syncRuntimeCertificates(for bundleID: String, enabled: Bool) throws {
        let bundleURL = try runtimeBundleURL(for: bundleID)
        let fm = FileManager.default
        if !enabled {
            try? fm.removeItem(at: bundleURL)
            return
        }

        let dir = try appDirectoryURL(for: bundleID)
        let records = listCertificates(for: bundleID).filter(\.enabled)
        var derBlobs: [Data] = []
        for record in records {
            let derURL = dir.appendingPathComponent("\(record.id).der")
            if let data = try? Data(contentsOf: derURL),
               SecCertificateCreateWithData(nil, data as CFData) != nil {
                derBlobs.append(data)
            }
        }

        if derBlobs.isEmpty {
            try? fm.removeItem(at: bundleURL)
            return
        }

        try fm.createDirectory(at: appSettingsBaseURL, withIntermediateDirectories: true)
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
    }

    private func ensureAppDirectory(for bundleID: String) throws -> URL {
        let dir = try appDirectoryURL(for: bundleID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
