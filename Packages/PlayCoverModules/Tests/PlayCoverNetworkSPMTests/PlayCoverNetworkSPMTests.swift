import Compression
import CryptoKit
import Foundation
import Network
import Security
import Synchronization
import Testing
@testable import PlayCoverCore
@testable import PlayCoverNetwork

@Suite
struct PlayCoverNetworkSPMTests {
    private func evaluateTrust(leafDER: Data, rootDER: Data?, hostname: String) throws -> Bool {
        let leafCert = try #require(SecCertificateCreateWithData(nil, leafDER as CFData))
        let policy = SecPolicyCreateSSL(true, hostname as CFString)
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(leafCert, policy, &trust)
        #expect(status == errSecSuccess)
        let unwrappedTrust = try #require(trust)
        if let rootDER {
            let rootCert = try #require(SecCertificateCreateWithData(nil, rootDER as CFData))
            SecTrustSetAnchorCertificates(unwrappedTrust, [rootCert] as CFArray)
            SecTrustSetAnchorCertificatesOnly(unwrappedTrust, false)
        }
        var error: CFError?
        return SecTrustEvaluateWithError(unwrappedTrust, &error)
    }

    @Test
    func generatedRootCAAndDynamicLeafVerifyCleanlyWithSecTrust() throws {
        let root = try X509CertificateGenerator.generateRootCA(commonName: "MacOver Test CA")
        let inspectedRoot = try X509CertificateInspector.inspect(
            der: root.certificateDER,
            label: "MacOver Test CA",
            source: .generatedBuiltIn
        )
        #expect(inspectedRoot.isCA)
        #expect(!inspectedRoot.isExpired)
        #expect(inspectedRoot.id.count == 64)

        let pem = X509CertificateInspector.exportPEM(der: root.certificateDER)
        let reparsed = try X509CertificateInspector.parseCertificates(from: Data(pem.utf8))
        #expect(reparsed == [root.certificateDER])

        let issuer = try X509LeafIssuer(
            rootCertificateDER: root.certificateDER,
            rootPrivateKeyDER: root.privateKeyDER
        )
        let apiLeafDER = try issuer.leafCertificateDER(for: "api.example.test")

        // Rejected without custom root anchor
        #expect(try !evaluateTrust(leafDER: apiLeafDER, rootDER: nil, hostname: "api.example.test"))
        // Trusted with custom root anchor for matching DNS hostname
        #expect(try evaluateTrust(leafDER: apiLeafDER, rootDER: root.certificateDER, hostname: "api.example.test"))
        // Rejected for mismatched hostname even with root anchor
        #expect(try !evaluateTrust(leafDER: apiLeafDER, rootDER: root.certificateDER, hostname: "wrong.example.test"))

        // IP literal SAN verification
        let ipLeafDER = try issuer.leafCertificateDER(for: "127.0.0.1")
        #expect(try evaluateTrust(leafDER: ipLeafDER, rootDER: root.certificateDER, hostname: "127.0.0.1"))
    }

    @Test
    func perAppCertificateStoreIsolationAndZeroPrivateKeyLeakage() throws {
        let fm = FileManager.default
        let rootDir = fm.temporaryDirectory.appendingPathComponent("cert-store-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: rootDir) }

        let certsDir = rootDir.appendingPathComponent("Certificates", isDirectory: true)
        let settingsDir = rootDir.appendingPathComponent("App Settings", isDirectory: true)
        let store = PerAppCertificateStore(certificatesBaseURL: certsDir, appSettingsBaseURL: settingsDir)

        let appA = "com.example.appA"
        let appB = "com.example.appB"

        let caA = try store.ensureBuiltInRootCA(for: appA)
        let externalCA = try X509CertificateGenerator.generateRootCA(commonName: "External Proxy CA")
        let importedB = try store.importCertificateData(
            Data(X509CertificateInspector.exportPEM(der: externalCA.certificateDER).utf8),
            label: "External CA",
            for: appB
        )
        #expect(importedB.count == 1)

        #expect(store.listCertificates(for: appA).map(\.id) == [caA.record.id])
        #expect(store.listCertificates(for: appB).map(\.id) == [importedB[0].id])

        // Private key stays inside Certificates/<bundleID>/ with 0600 permissions
        let privKeyURL = certsDir.appendingPathComponent(appA).appendingPathComponent("mitm-root-key.der")
        let attrs = try fm.attributesOfItem(atPath: privKeyURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)

        // Runtime certs live inside Certificates/<bundleID>/runtime.certs with ONLY public DER certs
        // and clean up any legacy App Settings/<bundleID>.plist.certs file
        try fm.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        let legacyCertsURL = settingsDir.appendingPathComponent("\(appA).plist.certs")
        try Data("legacy".utf8).write(to: legacyCertsURL)

        try store.syncRuntimeCertificates(for: appA, enabled: true)
        try store.syncRuntimeCertificates(for: appB, enabled: true)

        let runtimeAURL = try store.runtimeBundleURL(for: appA)
        #expect(runtimeAURL.path.hasSuffix("Certificates/\(appA)/runtime.certs"))
        #expect(!fm.fileExists(atPath: legacyCertsURL.path))
        let runtimeAData = try Data(contentsOf: runtimeAURL)
        let plistA = try PropertyListSerialization.propertyList(from: runtimeAData, format: nil) as? [String: Any]
        let certsA = try #require(plistA?["certificates"] as? [Data])
        #expect(certsA == [caA.certificateDER])
        #expect(runtimeAData.range(of: caA.privateKeyDER) == nil)

        // Disabling the cert or disabling custom CA injection removes runtime bundle
        try store.setCertificateEnabled(id: caA.record.id, enabled: false, for: appA)
        try store.syncRuntimeCertificates(for: appA, enabled: true)
        #expect(!fm.fileExists(atPath: runtimeAURL.path))

        try store.setCertificateEnabled(id: caA.record.id, enabled: true, for: appA)
        try store.syncRuntimeCertificates(for: appA, enabled: false)
        #expect(!fm.fileExists(atPath: runtimeAURL.path))

        store.removeAllData(for: appA)
        #expect(store.listCertificates(for: appA).isEmpty)
        #expect(store.listCertificates(for: appB).count == 1)
    }

    @Test
    func trafficCaptureStoreAndHARExporter() throws {
        let store = TrafficCaptureStore(bundleID: "com.example.har", maxEntries: 3, maxBodyBytes: 1024)
        for idx in 1...5 {
            store.append(MITMCaptureEntry(
                bundleID: "com.example.har",
                method: "POST",
                scheme: "https",
                host: "api.example.test",
                port: 443,
                path: "/v1/item/\(idx)",
                urlString: "https://api.example.test/v1/item/\(idx)",
                requestHeaders: ["Content-Type": "application/json"],
                requestBody: Data("{\"i\":\(idx)}".utf8),
                statusCode: 200,
                responseHeaders: ["Content-Type": "application/json"],
                responseBody: Data("{\"ok\":true}".utf8),
                durationMs: 12.5,
                disposition: .decrypted
            ))
        }
        let entries = store.entries()
        #expect(entries.count == 3)
        #expect(entries.first?.path == "/v1/item/3")
        #expect(entries.last?.path == "/v1/item/5")

        let harData = try store.exportHAR()
        let json = try #require(JSONSerialization.jsonObject(with: harData) as? [String: Any])
        let log = try #require(json["log"] as? [String: Any])
        #expect(log["version"] as? String == "1.2")
        let harEntries = try #require(log["entries"] as? [[String: Any]])
        #expect(harEntries.count == 3)
    }

    @Test
    func localMITMProxyServerEndToEndDecryptAndMockRules() async throws {
        let mitmCA = try X509CertificateGenerator.generateRootCA(commonName: "MacOver Live MITM CA")
        let originCA = try X509CertificateGenerator.generateRootCA(commonName: "Origin CA")
        let originIssuer = try X509LeafIssuer(
            rootCertificateDER: originCA.certificateDER,
            rootPrivateKeyDER: originCA.privateKeyDER
        )
        let originIdentity = try originIssuer.makeSecIdentity(for: "origin.example.test")

        // Start a minimal HTTPS origin server on 127.0.0.1:0
        let originTLS = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(originTLS.securityProtocolOptions, originIdentity)
        sec_protocol_options_add_tls_application_protocol(originTLS.securityProtocolOptions, "http/1.1")
        let originParams = NWParameters(tls: originTLS, tcp: .init())
        originParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

        let originListener = try NWListener(using: originParams)
        let originQueue = DispatchQueue(label: "test.origin.server")
        originListener.newConnectionHandler = { conn in
            conn.start(queue: originQueue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let raw = String(data: data ?? Data(), encoding: .utf8) ?? ""
                let body = raw.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
                let respBody = "{\"echo\":\"\(body)\"}"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" +
                    "Content-Length: \(respBody.utf8.count)\r\nConnection: close\r\n\r\n\(respBody)"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
        let originPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            let settled = Mutex(false)
            originListener.stateUpdateHandler = { state in
                guard !settled.withLock({ $0 }) else { return }
                if case .ready = state, let p = originListener.port?.rawValue {
                    settled.withLock { $0 = true }
                    cont.resume(returning: p)
                } else if case let .failed(err) = state {
                    settled.withLock { $0 = true }
                    cont.resume(throwing: err)
                }
            }
            originListener.start(queue: originQueue)
        }
        defer { originListener.cancel() }

        let captureStore = TrafficCaptureStore(bundleID: "com.example.mitmtest")
        let serverConfig = MITMServerConfiguration(
            bundleID: "com.example.mitmtest",
            listenPort: 0,
            mitmAllHosts: false,
            mitmHostPatterns: ["origin.example.test", "blocked.example.test"],
            enableNetworkRules: true,
            networkBlockMock200: true,
            blockedURLPatterns: ["||blocked.example.test"],
            captureBodies: true,
            hostOverrides: [
                "origin.example.test": "127.0.0.1",
                "tunnel.example.test": "127.0.0.1"
            ]
        )
        let proxyServer = try LocalMITMProxyServer(
            rootCertificateDER: mitmCA.certificateDER,
            rootPrivateKeyDER: mitmCA.privateKeyDER,
            configuration: serverConfig,
            captureStore: captureStore,
            upstreamTrustOverrideDER: originCA.certificateDER
        )
        let proxyPort = try await proxyServer.start()
        defer { Task { await proxyServer.stop() } }

        final class MITMTestDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
            let rootDER: Data
            init(rootDER: Data) { self.rootDER = rootDER }
            private func handle(
                _ challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
            ) {
                guard let trust = challenge.protectionSpace.serverTrust,
                      let anchor = SecCertificateCreateWithData(nil, rootDER as CFData) else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, false)
                var err: CFError?
                if SecTrustEvaluateWithError(trust, &err) {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
            func urlSession(
                _ session: URLSession,
                didReceive challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
            ) {
                handle(challenge, completionHandler: completionHandler)
            }
            func urlSession(
                _ session: URLSession,
                task: URLSessionTask,
                didReceive challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
            ) {
                handle(challenge, completionHandler: completionHandler)
            }
        }

        let sessionCfg = URLSessionConfiguration.ephemeral
        sessionCfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(proxyPort),
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: Int(proxyPort)
        ]
        let delegate = MITMTestDelegate(rootDER: mitmCA.certificateDER)
        let session = URLSession(configuration: sessionCfg, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        // 1. Live HTTPS MITM decrypt roundtrip
        let echoURL = try #require(URL(string: "https://origin.example.test:\(originPort)/v1/ping"))
        var request = URLRequest(url: echoURL)
        request.httpMethod = "POST"
        request.httpBody = Data("hello-mitm".utf8)
        let (respData, respObj) = try await session.data(for: request)
        let httpResp = try #require(respObj as? HTTPURLResponse)
        #expect(httpResp.statusCode == 200)
        #expect(String(data: respData, encoding: .utf8) == "{\"echo\":\"hello-mitm\"}")

        // 2. Blocked rule returns Mock 200 without upstream connection
        let blockedURL = try #require(URL(string: "https://blocked.example.test/telemetry"))
        let (mockData, mockObj) = try await session.data(from: blockedURL)
        let mockResp = try #require(mockObj as? HTTPURLResponse)
        #expect(mockResp.statusCode == 200)
        #expect(String(data: mockData, encoding: .utf8) == "{}")

        // 3. Unmatched host tunnels cleanly (originCA fails MITM-only trust while proxy logs .tunnel)
        let tunnelURL = try #require(URL(string: "https://tunnel.example.test:\(originPort)/tunnel"))
        await #expect(throws: (any Error).self) {
            _ = try await session.data(from: tunnelURL)
        }

        let entries = captureStore.entries()
        #expect(entries.count == 3)
        let decryptedEntry = try #require(entries.first { $0.path == "/v1/ping" })
        #expect(decryptedEntry.disposition == .decrypted)
        #expect(decryptedEntry.requestBody == Data("hello-mitm".utf8))
        #expect(decryptedEntry.responseBody == Data("{\"echo\":\"hello-mitm\"}".utf8))

        let mockedEntry = try #require(entries.first { $0.host == "blocked.example.test" })
        #expect(mockedEntry.disposition == .mocked200)

        let tunnelEntry = try #require(entries.first { $0.host == "tunnel.example.test" })
        #expect(tunnelEntry.disposition == .tunnel)
    }

    @Test
    func localMITMProxyServerHTTP11FramingExpectContinueAndNoDuplicateLeafCert() async throws {
        let mitmCA = try X509CertificateGenerator.generateRootCA(commonName: "MacOver Framing MITM CA")
        let originCA = try X509CertificateGenerator.generateRootCA(commonName: "Framing Origin CA")
        let originIssuer = try X509LeafIssuer(
            rootCertificateDER: originCA.certificateDER,
            rootPrivateKeyDER: originCA.privateKeyDER
        )
        let originIdentity = try originIssuer.makeSecIdentity(for: "framing.example.test")

        let originTLS = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(originTLS.securityProtocolOptions, originIdentity)
        sec_protocol_options_add_tls_application_protocol(originTLS.securityProtocolOptions, "http/1.1")
        let originParams = NWParameters(tls: originTLS, tcp: .init())
        originParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

        let capturedOriginHeaders = Mutex<[String]>([])
        let originListener = try NWListener(using: originParams)
        let originQueue = DispatchQueue(label: "test.framing.origin")
        originListener.newConnectionHandler = { conn in
            conn.start(queue: originQueue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let raw = String(data: data ?? Data(), encoding: .utf8) ?? ""
                capturedOriginHeaders.withLock { $0.append(raw) }
                let firstLine = raw.components(separatedBy: "\r\n").first ?? ""
                let resp: String
                if firstLine.contains("/no-content") {
                    resp = "HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n"
                } else {
                    let body = "{\"ok\":true}"
                    resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" +
                        "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                }
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
        let originPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            let settled = Mutex(false)
            originListener.stateUpdateHandler = { state in
                guard !settled.withLock({ $0 }) else { return }
                if case .ready = state, let port = originListener.port?.rawValue {
                    settled.withLock { $0 = true }
                    cont.resume(returning: port)
                } else if case let .failed(err) = state {
                    settled.withLock { $0 = true }
                    cont.resume(throwing: err)
                }
            }
            originListener.start(queue: originQueue)
        }
        defer { originListener.cancel() }

        let captureStore = TrafficCaptureStore(bundleID: "com.example.framingtest")
        let proxyServer = try LocalMITMProxyServer(
            rootCertificateDER: mitmCA.certificateDER,
            rootPrivateKeyDER: mitmCA.privateKeyDER,
            configuration: MITMServerConfiguration(
                bundleID: "com.example.framingtest",
                listenPort: 0,
                mitmAllHosts: true,
                hostOverrides: ["framing.example.test": "127.0.0.1"]
            ),
            captureStore: captureStore,
            upstreamTrustOverrideDER: originCA.certificateDER
        )
        let proxyPort = try await proxyServer.start()
        defer { Task { await proxyServer.stop() } }

        final class ChainInspectDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
            let rootDER: Data
            let observedChainCounts = Mutex<[Int]>([])
            init(rootDER: Data) { self.rootDER = rootDER }
            func urlSession(
                _ session: URLSession,
                didReceive challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
            ) {
                guard let trust = challenge.protectionSpace.serverTrust,
                      let anchor = SecCertificateCreateWithData(nil, rootDER as CFData) else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                if let chain = SecTrustCopyCertificateChain(trust) {
                    observedChainCounts.withLock { $0.append(CFArrayGetCount(chain)) }
                }
                SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, false)
                var err: CFError?
                if SecTrustEvaluateWithError(trust, &err) {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(proxyPort),
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: Int(proxyPort)
        ]
        let delegate = ChainInspectDelegate(rootDER: mitmCA.certificateDER)
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        // 1. Empty-body POST must emit Content-Length: 0 and verify non-duplicated leaf chain (count == 2)
        let emptyPostURL = try #require(
            URL(string: "https://framing.example.test:\(originPort)/empty-post")
        )
        var postReq = URLRequest(url: emptyPostURL)
        postReq.httpMethod = "POST"
        let (postData, postResp) = try await session.data(for: postReq)
        #expect((postResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: postData, encoding: .utf8) == "{\"ok\":true}")
        #expect(delegate.observedChainCounts.withLock { $0 }.allSatisfy { $0 == 2 })
        let originPostHeaders = capturedOriginHeaders.withLock { $0.first ?? "" }.lowercased()
        #expect(originPostHeaders.contains("content-length: 0"))

        // 2. 204 No Content must succeed cleanly
        let noContentURL = try #require(URL(string: "https://framing.example.test:\(originPort)/no-content"))
        let (noContentData, noContentResp) = try await session.data(from: noContentURL)
        #expect((noContentResp as? HTTPURLResponse)?.statusCode == 204)
        #expect(noContentData.isEmpty)

        // 3. Plain HTTP client sending Expect: 100-continue receives HTTP/1.1 100 Continue
        let plainParams = NWParameters.tcp
        plainParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let plainOrigin = try NWListener(using: plainParams)
        let plainQueue = DispatchQueue(label: "test.plain.origin")
        plainOrigin.newConnectionHandler = { conn in
            conn.start(queue: plainQueue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                let raw = String(data: data ?? Data(), encoding: .utf8) ?? ""
                let body = raw.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
                let reply = "HTTP/1.1 200 OK\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
        let plainPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            let settled = Mutex(false)
            plainOrigin.stateUpdateHandler = { state in
                guard !settled.withLock({ $0 }) else { return }
                if case .ready = state, let port = plainOrigin.port?.rawValue {
                    settled.withLock { $0 = true }
                    cont.resume(returning: port)
                } else if case let .failed(err) = state {
                    settled.withLock { $0 = true }
                    cont.resume(throwing: err)
                }
            }
            plainOrigin.start(queue: plainQueue)
        }
        defer { plainOrigin.cancel() }

        let tcpConn = NWConnection(
            host: "127.0.0.1",
            port: try #require(NWEndpoint.Port(rawValue: proxyPort)),
            using: .tcp
        )
        let rawQueue = DispatchQueue(label: "test.expect100.client")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let settled = Mutex(false)
            tcpConn.stateUpdateHandler = { state in
                guard !settled.withLock({ $0 }) else { return }
                if case .ready = state {
                    settled.withLock { $0 = true }
                    cont.resume()
                } else if case let .failed(err) = state {
                    settled.withLock { $0 = true }
                    cont.resume(throwing: err)
                }
            }
            tcpConn.start(queue: rawQueue)
        }
        defer { tcpConn.cancel() }

        let putHead = "PUT http://framing.example.test:\(plainPort)/upload HTTP/1.1\r\n" +
            "Host: framing.example.test:\(plainPort)\r\n" +
            "Expect: 100-continue\r\nContent-Length: 5\r\n\r\n"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            tcpConn.send(content: Data(putHead.utf8), completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
        let interimData: Data = try await withCheckedThrowingContinuation { cont in
            tcpConn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, err in
                if let err { cont.resume(throwing: err) } else { cont.resume(returning: data ?? Data()) }
            }
        }
        #expect((String(data: interimData, encoding: .utf8) ?? "").contains("HTTP/1.1 100 Continue"))
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            tcpConn.send(content: Data("hello".utf8), completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
        let finalData: Data = try await withCheckedThrowingContinuation { cont in
            tcpConn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, err in
                if let err { cont.resume(throwing: err) } else { cont.resume(returning: data ?? Data()) }
            }
        }
        let finalText = String(data: finalData, encoding: .utf8) ?? ""
        #expect(finalText.contains("200 OK") && finalText.contains("hello"))
        tcpConn.cancel()
    }

    @Test
    func localMITMProxyServerKeepAlivePlainHTTPAndErrorCapture() async throws {
        let mitmCA = try X509CertificateGenerator.generateRootCA(commonName: "MacOver ErrorKeepAlive CA")

        // Upstream plain HTTP origin keeping one connection open across 2 requests
        let plainParams = NWParameters.tcp
        plainParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let plainOrigin = try NWListener(using: plainParams)
        let plainQueue = DispatchQueue(label: "test.keepalive.origin")
        plainOrigin.newConnectionHandler = { conn in
            conn.start(queue: plainQueue)
            @Sendable func serveNext() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, isComplete, _ in
                    guard let data, !data.isEmpty else {
                        conn.cancel()
                        return
                    }
                    let text = String(data: data, encoding: .utf8) ?? ""
                    let body = text.contains("/second") ? "two" : "one"
                    let resp = "HTTP/1.1 200 OK\r\n" +
                        "Content-Length: \(body.utf8.count)\r\nConnection: keep-alive\r\n\r\n\(body)"
                    conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
                        if isComplete {
                            conn.cancel()
                        } else {
                            serveNext()
                        }
                    })
                }
            }
            serveNext()
        }
        let plainPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            let settled = Mutex(false)
            plainOrigin.stateUpdateHandler = { state in
                guard !settled.withLock({ $0 }) else { return }
                if case .ready = state, let port = plainOrigin.port?.rawValue {
                    settled.withLock { $0 = true }
                    cont.resume(returning: port)
                } else if case let .failed(err) = state {
                    settled.withLock { $0 = true }
                    cont.resume(throwing: err)
                }
            }
            plainOrigin.start(queue: plainQueue)
        }
        defer { plainOrigin.cancel() }

        let captureStore = TrafficCaptureStore(bundleID: "com.example.keepalive")
        let proxyServer = try LocalMITMProxyServer(
            rootCertificateDER: mitmCA.certificateDER,
            rootPrivateKeyDER: mitmCA.privateKeyDER,
            configuration: MITMServerConfiguration(
                bundleID: "com.example.keepalive",
                listenPort: 0,
                mitmAllHosts: true,
                hostOverrides: ["keepalive.example.test": "127.0.0.1"]
            ),
            captureStore: captureStore
        )
        let proxyPort = try await proxyServer.start()
        defer { Task { await proxyServer.stop() } }

        // 1. Two consecutive plain HTTP requests on the same socket
        let tcpConn = NWConnection(
            host: "127.0.0.1",
            port: try #require(NWEndpoint.Port(rawValue: proxyPort)),
            using: .tcp
        )
        let rawQueue = DispatchQueue(label: "test.keepalive.client")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let settled = Mutex(false)
            tcpConn.stateUpdateHandler = { state in
                guard !settled.withLock({ $0 }) else { return }
                if case .ready = state {
                    settled.withLock { $0 = true }
                    cont.resume()
                } else if case let .failed(err) = state {
                    settled.withLock { $0 = true }
                    cont.resume(throwing: err)
                }
            }
            tcpConn.start(queue: rawQueue)
        }
        defer { tcpConn.cancel() }

        let firstReq = "GET http://keepalive.example.test:\(plainPort)/first HTTP/1.1\r\n" +
            "Host: keepalive.example.test:\(plainPort)\r\n\r\n"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            tcpConn.send(content: Data(firstReq.utf8), completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
        let firstRespData: Data = try await withCheckedThrowingContinuation { cont in
            tcpConn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, err in
                if let err { cont.resume(throwing: err) } else { cont.resume(returning: data ?? Data()) }
            }
        }
        #expect((String(data: firstRespData, encoding: .utf8) ?? "").contains("one"))

        let secondReq = "GET http://keepalive.example.test:\(plainPort)/second HTTP/1.1\r\n" +
            "Host: keepalive.example.test:\(plainPort)\r\nConnection: close\r\n\r\n"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            tcpConn.send(content: Data(secondReq.utf8), completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
        let secondRespData: Data = try await withCheckedThrowingContinuation { cont in
            tcpConn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, err in
                if let err { cont.resume(throwing: err) } else { cont.resume(returning: data ?? Data()) }
            }
        }
        #expect((String(data: secondRespData, encoding: .utf8) ?? "").contains("two"))
        tcpConn.cancel()

        // 2. Client rejecting MITM CA during TLS handshake must record a .error entry
        let untrustCfg = URLSessionConfiguration.ephemeral
        untrustCfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(proxyPort),
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: Int(proxyPort)
        ]
        let untrustSession = URLSession(configuration: untrustCfg)
        defer { untrustSession.invalidateAndCancel() }
        let untrustedURL = try #require(URL(string: "https://keepalive.example.test/pin-reject"))
        await #expect(throws: (any Error).self) {
            _ = try await untrustSession.data(from: untrustedURL)
        }

        // Wait briefly for server-side Task capture
        for _ in 0..<20 {
            if captureStore.entries().contains(where: { $0.disposition == .error }) {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        let captured = captureStore.entries()
        #expect(captured.contains { $0.path == "/first" && $0.disposition == .forwarded })
        #expect(captured.contains { $0.path == "/second" && $0.disposition == .forwarded })
        #expect(captured.contains {
            $0.host == "keepalive.example.test" && $0.disposition == .error && $0.method == "TLS"
        })
    }

    @Test
    func httpBodyDecoderDecompressesGzipDeflateBrotliAndHARExport() throws {
        let jsonString = #"{"hello":"world","count":42,"items":["a","b","c"]}"#
        let rawPayload = Data(jsonString.utf8)

        func compressWith(_ algorithm: compression_algorithm, data: Data) throws -> Data {
            try data.withUnsafeBytes { rawBuf in
                let srcPtr = try #require(rawBuf.bindMemory(to: UInt8.self).baseAddress)
                let dstCapacity = max(1024, data.count * 2 + 256)
                let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
                defer { dst.deallocate() }
                let written = compression_encode_buffer(dst, dstCapacity, srcPtr, data.count, nil, algorithm)
                #expect(written > 0)
                return Data(bytes: dst, count: written)
            }
        }

        func makeGzip(from uncompressed: Data, includeFName: Bool = false) throws -> Data {
            let compressedDeflate = try compressWith(COMPRESSION_ZLIB, data: uncompressed)
            var gzip = Data([0x1F, 0x8B, 0x08, includeFName ? 0x08 : 0x00, 0, 0, 0, 0, 0, 0xFF])
            if includeFName {
                gzip.append(contentsOf: "payload.json".utf8)
                gzip.append(0x00)
            }
            gzip.append(compressedDeflate)
            // RFC 1952 8-byte trailer (CRC32 placeholder + ISIZE LE)
            gzip.append(contentsOf: [0, 0, 0, 0])
            let isize = UInt32(truncatingIfNeeded: uncompressed.count).littleEndian
            withUnsafeBytes(of: isize) { gzip.append(contentsOf: $0) }
            return gzip
        }

        func makeZlib(from uncompressed: Data) throws -> Data {
            let compressedDeflate = try compressWith(COMPRESSION_ZLIB, data: uncompressed)
            var zlib = Data([0x78, 0x9C])
            zlib.append(compressedDeflate)
            zlib.append(contentsOf: [0, 0, 0, 0])
            return zlib
        }

        // 1. gzip with Content-Encoding & RFC 1952 FNAME header
        let gzipped = try makeGzip(from: rawPayload, includeFName: true)
        let gzipFmt = HTTPBodyDecoder.formatDisplayText(
            gzipped,
            headers: ["Content-Encoding": "gzip", "Content-Type": "application/json"]
        )
        #expect(!gzipFmt.isHex)
        #expect(gzipFmt.decoded.appliedEncodings == ["gzip"])
        #expect(!gzipFmt.decoded.decodingFailed)
        #expect(gzipFmt.text.contains("\"hello\" : \"world\""))

        // 2. gzip auto-detection by magic bytes without Content-Encoding header
        let gzipNoHeader = HTTPBodyDecoder.formatDisplayText(gzipped, headers: [:])
        #expect(!gzipNoHeader.isHex)
        #expect(gzipNoHeader.decoded.appliedEncodings == ["gzip"])
        #expect(gzipNoHeader.text.contains("\"count\" : 42"))

        // 3. deflate (RFC 1950 zlib-wrapped AND raw RFC 1951)
        let zlibData = try makeZlib(from: rawPayload)
        let zlibFmt = HTTPBodyDecoder.formatDisplayText(zlibData, headers: ["Content-Encoding": "deflate"])
        #expect(!zlibFmt.isHex)
        #expect(zlibFmt.decoded.appliedEncodings == ["deflate"])
        #expect(zlibFmt.text.contains("\"hello\" : \"world\""))

        let rawDeflate = try compressWith(COMPRESSION_ZLIB, data: rawPayload)
        let rawDeflateFmt = HTTPBodyDecoder.formatDisplayText(rawDeflate, headers: ["Content-Encoding": "deflate"])
        #expect(!rawDeflateFmt.isHex)
        #expect(rawDeflateFmt.text.contains("\"hello\" : \"world\""))

        // 4. Brotli & chained "gzip, br"
        let brotliData = try compressWith(COMPRESSION_BROTLI, data: rawPayload)
        let brotliFmt = HTTPBodyDecoder.formatDisplayText(brotliData, headers: ["Content-Encoding": "br"])
        #expect(!brotliFmt.isHex)
        #expect(brotliFmt.decoded.appliedEncodings == ["br"])
        #expect(brotliFmt.text.contains("\"hello\" : \"world\""))

        let chainedGzipThenBrotli = try compressWith(COMPRESSION_BROTLI, data: gzipped)
        let chainedFmt = HTTPBodyDecoder.formatDisplayText(
            chainedGzipThenBrotli,
            headers: ["Content-Encoding": "gzip, br"]
        )
        #expect(!chainedFmt.isHex)
        #expect(chainedFmt.decoded.appliedEncodings == ["br", "gzip"])
        #expect(chainedFmt.text.contains("\"hello\" : \"world\""))

        // 5. Max output truncation safety cap
        let largePlain = Data(repeating: 0x41, count: 4096)
        let largeGzip = try makeGzip(from: largePlain)
        let capped = HTTPBodyDecoder.decode(largeGzip, headers: ["Content-Encoding": "gzip"], maxOutputBytes: 1500)
        #expect(capped.outputTruncated)
        #expect(capped.data.count == 1500)

        // 6. Truly binary payload still formats as hex
        let binaryPayload = Data([0x08, 0x96, 0x01, 0x12, 0x00, 0xFF, 0xFE, 0xFD])
        let binaryFmt = HTTPBodyDecoder.formatDisplayText(binaryPayload, headers: [:])
        #expect(binaryFmt.isHex)
        #expect(binaryFmt.text.hasPrefix("08 96 01"))

        // 7. HARExporter writes decompressed JSON text without base64
        let harEntry = MITMCaptureEntry(
            bundleID: "com.example.har",
            method: "GET",
            scheme: "https",
            host: "api.example.test",
            port: 443,
            path: "/data",
            urlString: "https://api.example.test/data",
            statusCode: 200,
            responseHeaders: ["Content-Encoding": "gzip", "Content-Type": "application/json"],
            responseBody: gzipped,
            durationMs: 12.0,
            disposition: .decrypted
        )
        let harJSON = try HARExporter.export(entries: [harEntry])
        let harText = try #require(String(data: harJSON, encoding: .utf8))
        #expect(harText.contains("\\\"hello\\\":\\\"world\\\""))
        #expect(!harText.contains("\"encoding\" : \"base64\""))
    }

    @Test
    func localMITMProxyServerCoalescesConnectRefusesFastAndPreservesWebSocket101() async throws {
        let mitmCA = try X509CertificateGenerator.generateRootCA(commonName: "MacOver Regress MITM CA")
        let originCA = try X509CertificateGenerator.generateRootCA(commonName: "Regress Origin CA")
        let originIssuer = try X509LeafIssuer(
            rootCertificateDER: originCA.certificateDER,
            rootPrivateKeyDER: originCA.privateKeyDER
        )
        let originIdentity = try originIssuer.makeSecIdentity(for: "coalesce.example.test")

        let originTLS = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(originTLS.securityProtocolOptions, originIdentity)
        sec_protocol_options_add_tls_application_protocol(originTLS.securityProtocolOptions, "http/1.1")
        let originParams = NWParameters(tls: originTLS, tcp: .init())
        originParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)

        let originListener = try NWListener(using: originParams)
        let originQueue = DispatchQueue(label: "test.coalesce.origin")
        originListener.newConnectionHandler = { conn in
            conn.start(queue: originQueue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
                let resp = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
        let originPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            let settled = Mutex(false)
            originListener.stateUpdateHandler = { state in
                guard !settled.withLock({ $0 }) else { return }
                if case .ready = state, let port = originListener.port?.rawValue {
                    settled.withLock { $0 = true }
                    cont.resume(returning: port)
                } else if case let .failed(err) = state {
                    settled.withLock { $0 = true }
                    cont.resume(throwing: err)
                }
            }
            originListener.start(queue: originQueue)
        }
        defer { originListener.cancel() }

        // Allocate and immediately close a loopback TCP socket to obtain an unbound dead port
        let deadSock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #expect(deadSock >= 0)
        var deadAddr = sockaddr_in()
        deadAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        deadAddr.sin_family = sa_family_t(AF_INET)
        deadAddr.sin_port = 0
        deadAddr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindDeadRC = withUnsafePointer(to: &deadAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(deadSock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindDeadRC == 0)
        var boundDeadLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &deadAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(deadSock, $0, &boundDeadLen)
            }
        }
        let deadPort = UInt16(bigEndian: deadAddr.sin_port)
        Darwin.close(deadSock)
        #expect(deadPort > 0)

        // WebSocket 101 origin listener
        let wsParams = NWParameters.tcp
        wsParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let wsListener = try NWListener(using: wsParams)
        let wsQueue = DispatchQueue(label: "test.ws101.origin")
        wsListener.newConnectionHandler = { conn in
            conn.start(queue: wsQueue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
                let reply = "HTTP/1.1 101 Switching Protocols\r\n" +
                    "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: dummy\r\n\r\n"
                conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
        let wsPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            let settled = Mutex(false)
            wsListener.stateUpdateHandler = { state in
                guard !settled.withLock({ $0 }) else { return }
                if case .ready = state, let port = wsListener.port?.rawValue {
                    settled.withLock { $0 = true }
                    cont.resume(returning: port)
                } else if case let .failed(err) = state {
                    settled.withLock { $0 = true }
                    cont.resume(throwing: err)
                }
            }
            wsListener.start(queue: wsQueue)
        }
        defer { wsListener.cancel() }

        let captureStore = TrafficCaptureStore(bundleID: "com.example.mitmreg")
        let serverConfig = MITMServerConfiguration(
            bundleID: "com.example.mitmreg",
            listenPort: 0,
            mitmAllHosts: false,
            mitmHostPatterns: ["coalesce.example.test"],
            captureBodies: true,
            hostOverrides: [
                "coalesce.example.test": "127.0.0.1",
                "dead.example.test": "127.0.0.1",
                "ws.example.test": "127.0.0.1"
            ]
        )
        let proxyServer = try LocalMITMProxyServer(
            rootCertificateDER: mitmCA.certificateDER,
            rootPrivateKeyDER: mitmCA.privateKeyDER,
            configuration: serverConfig,
            captureStore: captureStore,
            upstreamTrustOverrideDER: originCA.certificateDER
        )
        let proxyPort = try await proxyServer.start()
        defer { Task { await proxyServer.stop() } }

        final class RegressDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
            let rootDER: Data
            init(rootDER: Data) { self.rootDER = rootDER }
            private func handle(
                _ challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
            ) {
                guard let trust = challenge.protectionSpace.serverTrust,
                      let anchor = SecCertificateCreateWithData(nil, rootDER as CFData) else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, false)
                completionHandler(.useCredential, URLCredential(trust: trust))
            }
            func urlSession(
                _ session: URLSession,
                didReceive challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
            ) { handle(challenge, completionHandler: completionHandler) }
            func urlSession(
                _ session: URLSession,
                task: URLSessionTask,
                didReceive challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
            ) { handle(challenge, completionHandler: completionHandler) }
        }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(proxyPort),
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: Int(proxyPort)
        ]
        let delegate = RegressDelegate(rootDER: mitmCA.certificateDER)
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        // 1. Concurrent CONNECT requests to the same host coalesce through pendingTerminators
        let targetURL = try #require(URL(string: "https://coalesce.example.test:\(originPort)/ping"))
        try await withThrowingTaskGroup(of: (Data, Int).self) { group in
            for _ in 0..<6 {
                group.addTask {
                    let (data, resp) = try await session.data(from: targetURL)
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                    return (data, code)
                }
            }
            for try await (data, code) in group {
                #expect(code == 200)
                #expect(String(data: data, encoding: .utf8) == "ok")
            }
        }

        // 2. Refused upstream loopback port fails fast instead of stalling
        let startFail = ContinuousClock.now
        let deadURL = try #require(URL(string: "http://dead.example.test:\(deadPort)/fail"))
        let (_, deadResp) = try await session.data(from: deadURL)
        #expect((deadResp as? HTTPURLResponse)?.statusCode == 502)
        #expect(startFail.duration(to: .now) < .seconds(5))

        // 3. WebSocket 101 Switching Protocols preserves Connection: Upgrade
        let wsClient = NWConnection(
            host: "127.0.0.1",
            port: try #require(NWEndpoint.Port(rawValue: proxyPort)),
            using: .tcp
        )
        let wsClientQueue = DispatchQueue(label: "test.ws101.client")
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let settled = Mutex(false)
            wsClient.stateUpdateHandler = { state in
                guard !settled.withLock({ $0 }) else { return }
                if case .ready = state {
                    settled.withLock { $0 = true }
                    cont.resume()
                } else if case let .failed(err) = state {
                    settled.withLock { $0 = true }
                    cont.resume(throwing: err)
                }
            }
            wsClient.start(queue: wsClientQueue)
        }
        defer { wsClient.cancel() }

        let wsReq = "GET http://ws.example.test:\(wsPort)/chat HTTP/1.1\r\n" +
            "Host: ws.example.test:\(wsPort)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            wsClient.send(content: Data(wsReq.utf8), completion: .contentProcessed { err in
                if let err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
        let wsRespData: Data = try await withCheckedThrowingContinuation { cont in
            wsClient.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, err in
                if let err { cont.resume(throwing: err) } else { cont.resume(returning: data ?? Data()) }
            }
        }
        let wsRespText = String(data: wsRespData, encoding: .utf8) ?? ""
        #expect(wsRespText.contains("101 Switching Protocols"))
        #expect(wsRespText.localizedCaseInsensitiveContains("Connection: Upgrade"))
        #expect(wsRespText.localizedCaseInsensitiveContains("Upgrade: websocket"))
    }

    @Test
    func localMITMProxyServerBlocksSelfLoopHandlesIPv6ClampsLeafExpiryAndRotatesCA() async throws {
        // IPv4/IPv6 literal detection & authority formatting
        #expect(LocalMITMProxyServer.isIPLiteral("127.0.0.1"))
        #expect(LocalMITMProxyServer.isIPLiteral("::1"))
        #expect(LocalMITMProxyServer.isIPLiteral("2001:db8::1"))
        #expect(!LocalMITMProxyServer.isIPLiteral("api.example.test"))
        #expect(LocalMITMProxyServer.formatAuthorityHost("::1") == "[::1]")
        #expect(LocalMITMProxyServer.formatAuthorityHost("[::1]") == "[::1]")
        #expect(LocalMITMProxyServer.formatAuthorityHost("127.0.0.1") == "127.0.0.1")

        // Leaf certificate notAfter must be clamped to a shorter-lived Root CA notAfter
        let shortCA = try X509CertificateGenerator.generateRootCA(commonName: "Short CA", validDays: 30)
        let shortInfo = try X509CertificateInspector.inspect(
            der: shortCA.certificateDER,
            label: "Short CA",
            source: .generatedBuiltIn
        )
        let shortIssuer = try X509LeafIssuer(
            rootCertificateDER: shortCA.certificateDER,
            rootPrivateKeyDER: shortCA.privateKeyDER
        )
        let leafDER = try shortIssuer.leafCertificateDER(for: "short.example.test")
        let leafInfo = try X509CertificateInspector.inspect(
            der: leafDER,
            label: "Leaf",
            source: .generatedBuiltIn
        )
        let leafNotAfter = try #require(leafInfo.notAfter)
        let shortNotAfter = try #require(shortInfo.notAfter)
        #expect(leafNotAfter <= shortNotAfter)

        // Live server: block self-proxy loop with 403 and hot-rotate Root CA via updateRootCA
        let ca1 = try X509CertificateGenerator.generateRootCA(commonName: "Rotate CA 1")
        let ca2 = try X509CertificateGenerator.generateRootCA(commonName: "Rotate CA 2")
        let originCA = try X509CertificateGenerator.generateRootCA(commonName: "Rotate Origin CA")
        let originIssuer = try X509LeafIssuer(
            rootCertificateDER: originCA.certificateDER,
            rootPrivateKeyDER: originCA.privateKeyDER
        )
        let originIdentity = try originIssuer.makeSecIdentity(for: "rotate.example.test")
        let originTLS = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(originTLS.securityProtocolOptions, originIdentity)
        sec_protocol_options_add_tls_application_protocol(originTLS.securityProtocolOptions, "http/1.1")
        let originParams = NWParameters(tls: originTLS, tcp: .init())
        originParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let originListener = try NWListener(using: originParams)
        let originQueue = DispatchQueue(label: "test.rotate.origin")
        originListener.newConnectionHandler = { conn in
            conn.start(queue: originQueue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { _, _, _, _ in
                let reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                conn.send(content: Data(reply.utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        let originPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            let settled = Mutex(false)
            originListener.stateUpdateHandler = { state in
                guard !settled.withLock({ $0 }) else { return }
                if case .ready = state, let port = originListener.port?.rawValue {
                    settled.withLock { $0 = true }
                    cont.resume(returning: port)
                } else if case let .failed(err) = state {
                    settled.withLock { $0 = true }
                    cont.resume(throwing: err)
                }
            }
            originListener.start(queue: originQueue)
        }
        defer { originListener.cancel() }

        let captureStore = TrafficCaptureStore(bundleID: "com.example.rotate")
        let proxyServer = try LocalMITMProxyServer(
            rootCertificateDER: ca1.certificateDER,
            rootPrivateKeyDER: ca1.privateKeyDER,
            configuration: MITMServerConfiguration(
                bundleID: "com.example.rotate",
                listenPort: 0,
                mitmAllHosts: true,
                hostOverrides: ["rotate.example.test": "127.0.0.1"]
            ),
            captureStore: captureStore,
            upstreamTrustOverrideDER: originCA.certificateDER
        )
        let proxyPort = try await proxyServer.start()
        defer { proxyServer.stopImmediately() }

        // Self-proxy loop request returns 403 Forbidden immediately
        let loopCfg = URLSessionConfiguration.ephemeral
        loopCfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(proxyPort)
        ]
        let loopSession = URLSession(configuration: loopCfg)
        defer { loopSession.invalidateAndCancel() }
        let loopURL = try #require(URL(string: "http://127.0.0.1:\(proxyPort)/loop"))
        let (_, loopResp) = try await loopSession.data(from: loopURL)
        #expect((loopResp as? HTTPURLResponse)?.statusCode == 403)

        // Hot-rotate Root CA from ca1 to ca2
        try await proxyServer.updateRootCA(certificateDER: ca2.certificateDER, privateKeyDER: ca2.privateKeyDER)

        final class SingleCADelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
            let rootDER: Data
            init(rootDER: Data) { self.rootDER = rootDER }
            private func handle(
                _ challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
            ) {
                guard let trust = challenge.protectionSpace.serverTrust,
                      let anchor = SecCertificateCreateWithData(nil, rootDER as CFData) else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                    return
                }
                SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
                SecTrustSetAnchorCertificatesOnly(trust, true)
                var err: CFError?
                if SecTrustEvaluateWithError(trust, &err) {
                    completionHandler(.useCredential, URLCredential(trust: trust))
                } else {
                    completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
            func urlSession(
                _ session: URLSession,
                didReceive challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
            ) { handle(challenge, completionHandler: completionHandler) }
            func urlSession(
                _ session: URLSession,
                task: URLSessionTask,
                didReceive challenge: URLAuthenticationChallenge,
                completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
            ) { handle(challenge, completionHandler: completionHandler) }
        }

        let httpsCfg = URLSessionConfiguration.ephemeral
        httpsCfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(proxyPort),
            kCFNetworkProxiesHTTPSEnable as String: true,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: Int(proxyPort)
        ]
        let ca2Session = URLSession(
            configuration: httpsCfg,
            delegate: SingleCADelegate(rootDER: ca2.certificateDER),
            delegateQueue: nil
        )
        defer { ca2Session.invalidateAndCancel() }
        let rotateURL = try #require(URL(string: "https://rotate.example.test:\(originPort)/check"))
        let (rotData, rotResp) = try await ca2Session.data(from: rotateURL)
        #expect((rotResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: rotData, encoding: .utf8) == "ok")
    }

    @Test
    func localMITMProxyServerStreamsLargeBodiesAndAbortsOnTruncatedOrMalformedUpstream() async throws {
        let mitmCA = try X509CertificateGenerator.generateRootCA(commonName: "MacOver Stream CA")
        let originParams = NWParameters.tcp
        originParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let originListener = try NWListener(using: originParams)
        let originQueue = DispatchQueue(label: "test.stream.origin")
        originListener.newConnectionHandler = { conn in
            conn.start(queue: originQueue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                let raw = String(data: data ?? Data(), encoding: .utf8) ?? ""
                let firstLine = raw.components(separatedBy: "\r\n").first ?? ""
                if firstLine.contains("/truncated") {
                    let partial = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n0123456789"
                    conn.send(content: Data(partial.utf8), completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                } else if firstLine.contains("/bad-chunk") {
                    let bad = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n" +
                        "Connection: close\r\n\r\n-5\r\nhello\r\n"
                    conn.send(content: Data(bad.utf8), completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                } else {
                    let payload = Data(repeating: 0x42, count: 65_536)
                    let hdr = "HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
                    var resp = Data(hdr.utf8)
                    resp.append(payload)
                    conn.send(content: resp, completion: .contentProcessed { _ in
                        conn.cancel()
                    })
                }
            }
        }
        let originPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            let settled = Mutex(false)
            originListener.stateUpdateHandler = { state in
                guard !settled.withLock({ $0 }) else { return }
                if case .ready = state, let port = originListener.port?.rawValue {
                    settled.withLock { $0 = true }
                    cont.resume(returning: port)
                } else if case let .failed(err) = state {
                    settled.withLock { $0 = true }
                    cont.resume(throwing: err)
                }
            }
            originListener.start(queue: originQueue)
        }
        defer { originListener.cancel() }

        let captureStore = TrafficCaptureStore(bundleID: "com.example.stream", maxEntries: 32, maxBodyBytes: 1024)
        let proxyServer = try LocalMITMProxyServer(
            rootCertificateDER: mitmCA.certificateDER,
            rootPrivateKeyDER: mitmCA.privateKeyDER,
            configuration: MITMServerConfiguration(
                bundleID: "com.example.stream",
                listenPort: 0,
                mitmAllHosts: true,
                captureBodies: true,
                hostOverrides: ["stream.example.test": "127.0.0.1"]
            ),
            captureStore: captureStore
        )
        let proxyPort = try await proxyServer.start()
        defer { proxyServer.stopImmediately() }

        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: Int(proxyPort)
        ]
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }

        // 1. Large body streams completely to client while TrafficCaptureStore caps capture at 1024 bytes
        let largeURL = try #require(URL(string: "http://stream.example.test:\(originPort)/large"))
        let (largeData, largeResp) = try await session.data(from: largeURL)
        #expect((largeResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(largeData.count == 65_536)
        let largeEntry = try #require(captureStore.entries().first { $0.path == "/large" })
        #expect(largeEntry.responseBody?.count == 1024)
        #expect(largeEntry.responseBodyTruncated)

        // 2. Truncated upstream Content-Length must abort client stream instead of succeeding with corrupt 200 OK
        let truncURL = try #require(URL(string: "http://stream.example.test:\(originPort)/truncated"))
        await #expect(throws: (any Error).self) {
            _ = try await session.data(from: truncURL)
        }

        // 3. Malformed negative chunk length must abort client stream
        let badChunkURL = try #require(URL(string: "http://stream.example.test:\(originPort)/bad-chunk"))
        await #expect(throws: (any Error).self) {
            _ = try await session.data(from: badChunkURL)
        }
    }

    @Test
    func perAppCertificateStoreRejectsTraversalAndExportsCustomAnchors() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CertStoreSec-\(UUID().uuidString)", isDirectory: true)
        let certsDir = root.appendingPathComponent("Certificates", isDirectory: true)
        let settingsDir = root.appendingPathComponent("App Settings", isDirectory: true)
        try FileManager.default.createDirectory(at: certsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: settingsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = PerAppCertificateStore(certificatesBaseURL: certsDir, appSettingsBaseURL: settingsDir)
        _ = try store.ensureBuiltInRootCA(for: "com.example.victim")

        // "." and traversal bundleIDs must be rejected and must never wipe sibling directories
        #expect(throws: (any Error).self) {
            _ = try store.appDirectoryURL(for: ".")
        }
        #expect(throws: (any Error).self) {
            _ = try store.appDirectoryURL(for: "..")
        }
        store.removeAllData(for: ".")
        #expect(store.builtInRootCAMaterial(for: "com.example.victim") != nil)

        // Malicious certificate IDs must be rejected
        #expect(throws: (any Error).self) {
            _ = try store.certificateDER(id: "../com.example.victim/mitm-root-key", for: "com.example.attacker")
        }
        #expect(throws: (any Error).self) {
            try store.deleteCertificate(id: "../com.example.victim/mitm-root-key", for: "com.example.attacker")
        }
        #expect(store.builtInRootCAMaterial(for: "com.example.victim") != nil)

        // enabledCustomAnchorDERs returns only enabled imported CAs, not built-in root or disabled certs
        let customCA = try X509CertificateGenerator.generateRootCA(commonName: "Corp Custom CA")
        let imported = try store.importCertificateData(
            customCA.certificateDER,
            label: "Corp",
            for: "com.example.victim"
        )
        #expect(imported.count == 1)
        #expect(store.enabledCustomAnchorDERs(for: "com.example.victim") == [customCA.certificateDER])

        try store.setCertificateEnabled(id: imported[0].id, enabled: false, for: "com.example.victim")
        #expect(store.enabledCustomAnchorDERs(for: "com.example.victim").isEmpty)
    }

    @Test
    func mitmProxyLoopbackCanonicalizationAuthAndDuplicateContentLength() async throws {
        // Loopback alias canonicalization
        #expect(LocalMITMProxyServer.isLoopbackHost("127.0.0.1"))
        #expect(LocalMITMProxyServer.isLoopbackHost("127.1"))
        #expect(LocalMITMProxyServer.isLoopbackHost("0x7f000001"))
        #expect(LocalMITMProxyServer.isLoopbackHost("localhost."))
        #expect(LocalMITMProxyServer.isLoopbackHost("api.localhost"))
        #expect(LocalMITMProxyServer.isLoopbackHost("::1"))
        #expect(LocalMITMProxyServer.isLoopbackHost("[::ffff:127.0.0.1]"))
        #expect(LocalMITMProxyServer.isLoopbackHost("[::ffff:7f00:1]"))
        #expect(LocalMITMProxyServer.isLoopbackHost("0.0.0.0"))
        #expect(!LocalMITMProxyServer.isLoopbackHost("example.com"))
        #expect(!LocalMITMProxyServer.isLoopbackHost("8.8.8.8"))

        let mitmCA = try X509CertificateGenerator.generateRootCA(commonName: "MITM Security Test CA")
        let proxyServer = try LocalMITMProxyServer(
            rootCertificateDER: mitmCA.certificateDER,
            rootPrivateKeyDER: mitmCA.privateKeyDER,
            configuration: MITMServerConfiguration(
                bundleID: "com.example.sec",
                listenPort: 0,
                mitmAllHosts: true,
                blockLoopbackTargets: true,
                requiredProxyAuthToken: "secret-proxy-token"
            )
        )
        let proxyPort = try await proxyServer.start()
        defer { proxyServer.stopImmediately() }

        func sendRawProxyRequest(_ raw: String) async throws -> String {
            let conn = NWConnection(
                host: NWEndpoint.Host("127.0.0.1"),
                port: try #require(NWEndpoint.Port(rawValue: proxyPort)),
                using: .tcp
            )
            let q = DispatchQueue(label: "mitm.sec.test.client")
            defer { conn.cancel() }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let settled = Mutex(false)
                conn.stateUpdateHandler = { state in
                    guard !settled.withLock({ $0 }) else { return }
                    if case .ready = state {
                        settled.withLock { $0 = true }
                        cont.resume()
                    } else if case let .failed(err) = state {
                        settled.withLock { $0 = true }
                        cont.resume(throwing: err)
                    }
                }
                conn.start(queue: q)
            }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.send(content: Data(raw.utf8), completion: .contentProcessed { err in
                    if let err { cont.resume(throwing: err) } else { cont.resume() }
                })
            }
            let data: Data = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { d, _, _, err in
                    if let err { cont.resume(throwing: err) } else { cont.resume(returning: d ?? Data()) }
                }
            }
            return String(data: data, encoding: .utf8) ?? ""
        }

        // 1. Missing Proxy-Authorization must return 407
        let unauthResp = try await sendRawProxyRequest(
            "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n"
        )
        #expect(unauthResp.hasPrefix("HTTP/1.1 407"))

        // 2. Authorized request targeting [::ffff:127.0.0.1] must return 403 Forbidden
        let loopbackResp = try await sendRawProxyRequest(
            "CONNECT [::ffff:127.0.0.1]:\(proxyPort) HTTP/1.1\r\n" +
            "Host: [::ffff:127.0.0.1]:\(proxyPort)\r\n" +
            "Proxy-Authorization: Bearer secret-proxy-token\r\n\r\n"
        )
        #expect(loopbackResp.hasPrefix("HTTP/1.1 403"))

        // 3. Conflicting duplicate Content-Length headers must return 400 Bad Request
        let conflictCLResp = try await sendRawProxyRequest(
            "POST http://example.com/submit HTTP/1.1\r\n" +
            "Host: example.com\r\n" +
            "Proxy-Authorization: Bearer secret-proxy-token\r\n" +
            "Content-Length: 4\r\n" +
            "content-length: 9\r\n\r\nbody"
        )
        #expect(conflictCLResp.hasPrefix("HTTP/1.1 400"))
    }

    @Test
    func harExporterRedactsSecretsByDefaultAndSupportsOptOut() throws {
        let entry = MITMCaptureEntry(
            bundleID: "com.example.harsec",
            method: "POST",
            scheme: "https",
            host: "api.example.test",
            port: 443,
            path: "/login",
            urlString: "https://user:pass@api.example.test/login?access_token=tok123&safe=1#code=frag9",
            requestHeaders: [
                "Authorization": "Bearer super-secret-jwt",
                "Cookie": "sid=abc123",
                "Content-Type": "application/json",
                "Accept": "application/json"
            ],
            requestBody: Data(
                #"{"password":"p@ss","redirect":"https://cb.example/x?token=innerTok","user":"alice"}"#.utf8
            ),
            statusCode: 200,
            responseHeaders: [
                "Set-Cookie": "session=xyz",
                "Location": "https://app.example/done?code=oauth99",
                "Content-Type": "application/json"
            ],
            responseBody: Data(#"{"api_key":"k-999","status":"ok"}"#.utf8),
            durationMs: 10,
            disposition: .decrypted
        )

        let redactedData = try HARExporter.export(entries: [entry])
        let redactedText = try #require(String(data: redactedData, encoding: .utf8))
        #expect(!redactedText.contains("super-secret-jwt"))
        #expect(!redactedText.contains("sid=abc123"))
        #expect(!redactedText.contains("session=xyz"))
        #expect(!redactedText.contains("tok123"))
        #expect(!redactedText.contains("p@ss"))
        #expect(!redactedText.contains("innerTok"))
        #expect(!redactedText.contains("k-999"))
        #expect(!redactedText.contains("oauth99"))
        #expect(redactedText.contains("[REDACTED]"))
        #expect(redactedText.contains("alice"))

        let unredactedData = try HARExporter.export(entries: [entry], redactSensitive: false)
        let unredactedText = try #require(String(data: unredactedData, encoding: .utf8))
        #expect(unredactedText.contains("super-secret-jwt"))
        #expect(unredactedText.contains("k-999"))
    }

    @Test
    func localMITMProxyServerWave3HardeningAndHARBinaryRedaction() async throws {
        // 1. R3-MED-07: Expanded loopback, 0.0.0.0/8, and link-local (IPv4 + IPv6) detection
        #expect(LocalMITMProxyServer.isLoopbackHost("0.0.0.1"))
        #expect(LocalMITMProxyServer.isLoopbackHost("0.42.0.1"))
        #expect(LocalMITMProxyServer.isLoopbackHost("[::ffff:0.0.0.1]"))
        #expect(LocalMITMProxyServer.isLoopbackHost("[::0.0.0.1]"))
        #expect(LocalMITMProxyServer.isLoopbackHost("169.254.169.254"))
        #expect(LocalMITMProxyServer.isLoopbackHost("[::ffff:169.254.169.254]"))
        #expect(LocalMITMProxyServer.isLoopbackHost("[fe80::1]"))
        #expect(LocalMITMProxyServer.isLoopbackHost("[fe80::1%en0]"))
        #expect(!LocalMITMProxyServer.isLoopbackHost("1.1.1.1"))
        #expect(!LocalMITMProxyServer.isLoopbackHost("169.253.0.1"))
        #expect(!LocalMITMProxyServer.isLoopbackHost("2001:4860:4860::8888"))

        // 2. R3-LOW-05b: Case-insensitive headerMap merging + duplicate Host header detection
        var headerMap: [String: String] = [:]
        LocalMITMProxyServer.appendHeaderMapValue("a.example", forName: "Host", into: &headerMap)
        LocalMITMProxyServer.appendHeaderMapValue("b.example", forName: "host", into: &headerMap)
        #expect(headerMap.count == 1)
        #expect(headerMap["Host"] == "a.example, b.example")
        #expect(LocalMITMProxyServer.hasDuplicateHostHeaders([
            (name: "Host", value: "a.example"),
            (name: "host", value: "b.example")
        ]))
        #expect(!LocalMITMProxyServer.hasDuplicateHostHeaders([(name: "Host", value: "a.example")]))

        // 3. R3-MED-07: Post-connect resolved remoteEndpoint blocks DNS rebinding to loopback
        let mitmCA = try X509CertificateGenerator.generateRootCA(commonName: "Wave3 Hardening CA")
        let dummyOriginParams = NWParameters.tcp
        dummyOriginParams.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let dummyOrigin = try NWListener(using: dummyOriginParams)
        let originQueue = DispatchQueue(label: "test.wave3.origin")
        dummyOrigin.newConnectionHandler = { conn in
            conn.start(queue: originQueue)
        }
        let originPort: UInt16 = try await withCheckedThrowingContinuation { cont in
            dummyOrigin.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume(returning: dummyOrigin.port?.rawValue ?? 0)
                case let .failed(err):
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            dummyOrigin.start(queue: originQueue)
        }
        defer { dummyOrigin.cancel() }

        let baseConfig = MITMServerConfiguration(
            bundleID: "com.example.wave3",
            listenPort: 0,
            mitmAllHosts: true,
            blockLoopbackTargets: true
        )
        let rebindServer = try LocalMITMProxyServer(
            rootCertificateDER: mitmCA.certificateDER,
            rootPrivateKeyDER: mitmCA.privateKeyDER,
            configuration: baseConfig
        )
        let rebindProxyPort = try await rebindServer.start()
        defer { Task { await rebindServer.stop() } }

        var blockedRebind = false
        do {
            let conn = try await rebindServer.connectTCP(
                targetHost: "rebind.example.test",
                connectHost: "127.0.0.1",
                port: originPort
            )
            conn.cancel()
        } catch MITMProxyError.upstreamConnectionFailed {
            blockedRebind = true
        }
        #expect(blockedRebind)

        // 4. R3-LOW-05b live proxy test: Duplicate Host headers receive 400 Bad Request
        func sendRaw(_ raw: String, to port: UInt16) async -> String {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return "" }
            let conn = NWConnection(
                host: "127.0.0.1",
                port: nwPort,
                using: .tcp
            )
            let q = DispatchQueue(label: "test.wave3.raw.\(UUID().uuidString)")
            defer { conn.cancel() }
            let ready: Bool = await withCheckedContinuation { cont in
                let resumed = Mutex(false)
                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if resumed.withLock({ let ok = !$0; $0 = true; return ok }) {
                            cont.resume(returning: true)
                        }
                    case .failed, .cancelled:
                        if resumed.withLock({ let ok = !$0; $0 = true; return ok }) {
                            cont.resume(returning: false)
                        }
                    default:
                        break
                    }
                }
                conn.start(queue: q)
            }
            guard ready else { return "" }
            let sent: Bool = await withCheckedContinuation { cont in
                conn.send(content: Data(raw.utf8), completion: .contentProcessed { err in
                    cont.resume(returning: err == nil)
                })
            }
            guard sent else { return "" }
            return await withCheckedContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    cont.resume(returning: String(data: data ?? Data(), encoding: .utf8) ?? "")
                }
            }
        }

        let dupHostResp = await sendRaw(
            "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\nhost: evil.com\r\n\r\n",
            to: rebindProxyPort
        )
        #expect(dupHostResp.hasPrefix("HTTP/1.1 400"))

        // 5. R3-MED-05: allowedClientAppBundleURL rejects non-matching processes and admits matching bundle path
        let rejectServer = try LocalMITMProxyServer(
            rootCertificateDER: mitmCA.certificateDER,
            rootPrivateKeyDER: mitmCA.privateKeyDER,
            configuration: baseConfig,
            allowedClientAppBundleURL: URL(fileURLWithPath: "/Applications/MacOverNonMatchingBundle.app")
        )
        let rejectPort = try await rejectServer.start()
        defer { Task { await rejectServer.stop() } }
        let rejectedResp = await sendRaw(
            "CONNECT 127.0.0.1:443 HTTP/1.1\r\nHost: 127.0.0.1:443\r\n\r\n",
            to: rejectPort
        )
        #expect(rejectedResp.isEmpty)

        var pathBuf = [CChar](repeating: 0, count: 4096)
        let pathLen = proc_pidpath(getpid(), &pathBuf, UInt32(pathBuf.count))
        let pathBytes = pathBuf.prefix(Int(max(0, pathLen))).map { UInt8(bitPattern: $0) }
        let currentExecPath = try #require(String(bytes: pathBytes, encoding: .utf8))
        let matchingDir = URL(fileURLWithPath: currentExecPath).deletingLastPathComponent()
        let admitServer = try LocalMITMProxyServer(
            rootCertificateDER: mitmCA.certificateDER,
            rootPrivateKeyDER: mitmCA.privateKeyDER,
            configuration: baseConfig,
            allowedClientAppBundleURL: matchingDir
        )
        let admitPort = try await admitServer.start()
        defer { Task { await admitServer.stop() } }
        let admittedResp = await sendRaw(
            "CONNECT 127.0.0.1:443 HTTP/1.1\r\nHost: 127.0.0.1:443\r\n\r\n",
            to: admitPort
        )
        #expect(admittedResp.hasPrefix("HTTP/1.1 403"))
        // Dynamic bundle-prefix admission must NOT permanently cache peerPID into static allowedClientPIDs.
        #expect(await admitServer.currentStaticAllowedClientPIDs == nil)

        // 5b. R4-MED-01 + R4-LOW-08: Apple networking helpers require matching responsible PID
        let webKitHelper =
            "/System/Volumes/Preboot/Cryptexes/OS/System/Library/Frameworks/WebKit.framework/" +
            "Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"
        #expect(LocalMITMProxyServer.isAppleSystemNetworkHelperPath(webKitHelper))
        #expect(LocalMITMProxyServer.isAppleSystemNetworkHelperPath("/usr/libexec/nsurlsessiond"))
        #expect(!LocalMITMProxyServer.isAppleSystemNetworkHelperPath("/tmp/com.apple.WebKit.Networking"))
        #expect(!LocalMITMProxyServer.isAppleSystemNetworkHelperPath("/usr/bin/curl"))

        let allowedPrefixes = ["/Users/test/Applications/com.example.game.app/"]
        let fakeExecPaths: [pid_t: String] = [
            101: "/Users/test/Applications/com.example.game.app/Wrapper/Game.app/Game",
            202: webKitHelper,
            203: "/usr/libexec/nsurlsessiond",
            303: "/Users/test/Applications/com.other.app/Other",
            404: "/usr/bin/curl"
        ]
        #expect(LocalMITMProxyServer.shouldAdmitDynamicPeer(
            peerPID: 101,
            bundlePrefixes: allowedPrefixes,
            executablePathLookup: { fakeExecPaths[$0] },
            responsiblePIDLookup: { _ in nil }
        ))
        #expect(LocalMITMProxyServer.shouldAdmitDynamicPeer(
            peerPID: 202,
            bundlePrefixes: allowedPrefixes,
            executablePathLookup: { fakeExecPaths[$0] },
            responsiblePIDLookup: { _ in 101 }
        ))
        #expect(LocalMITMProxyServer.shouldAdmitDynamicPeer(
            peerPID: 203,
            bundlePrefixes: allowedPrefixes,
            executablePathLookup: { fakeExecPaths[$0] },
            responsiblePIDLookup: { _ in 101 }
        ))
        #expect(!LocalMITMProxyServer.shouldAdmitDynamicPeer(
            peerPID: 202,
            bundlePrefixes: allowedPrefixes,
            executablePathLookup: { fakeExecPaths[$0] },
            responsiblePIDLookup: { _ in 303 }
        ))
        #expect(!LocalMITMProxyServer.shouldAdmitDynamicPeer(
            peerPID: 202,
            bundlePrefixes: allowedPrefixes,
            executablePathLookup: { fakeExecPaths[$0] },
            responsiblePIDLookup: { _ in nil }
        ))
        #expect(!LocalMITMProxyServer.shouldAdmitDynamicPeer(
            peerPID: 404,
            bundlePrefixes: allowedPrefixes,
            executablePathLookup: { fakeExecPaths[$0] },
            responsiblePIDLookup: { _ in 101 }
        ))

        // 6. R3-LOW-04: HARExporter redacts binary bodies and HTML/multiline embedded URLs by default
        let binaryEntry = MITMCaptureEntry(
            bundleID: "com.example.wave3har",
            method: "POST",
            scheme: "https",
            host: "api.example.test",
            port: 443,
            path: "/upload",
            urlString: "https://api.example.test/upload",
            requestHeaders: ["Content-Type": "application/octet-stream"],
            requestBody: Data([0x00, 0xFF, 0xFE, 0x10, 0x20]),
            statusCode: 200,
            responseHeaders: ["Content-Type": "application/octet-stream"],
            responseBody: Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00]),
            durationMs: 5,
            disposition: .decrypted
        )
        let htmlBody =
            "<a href=\"https://auth.example/cb?token=htmlSecret1\">link</a>\n" +
            "https://alice:pw99@api.example/x#code=frag88"
        let htmlEntry = MITMCaptureEntry(
            bundleID: "com.example.wave3har",
            method: "GET",
            scheme: "https",
            host: "web.example.test",
            port: 443,
            path: "/page",
            urlString: "https://web.example.test/page",
            statusCode: 200,
            responseHeaders: ["Content-Type": "text/html"],
            responseBody: Data(htmlBody.utf8),
            durationMs: 3,
            disposition: .decrypted
        )
        let redactedHAR = try HARExporter.export(entries: [binaryEntry, htmlEntry])
        let redactedHARText = try #require(String(data: redactedHAR, encoding: .utf8))
        #expect(!redactedHARText.contains(Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00]).base64EncodedString()))
        #expect(!redactedHARText.contains(Data([0x00, 0xFF, 0xFE, 0x10, 0x20]).base64EncodedString()))
        #expect(!redactedHARText.contains("htmlSecret1"))
        #expect(!redactedHARText.contains("pw99"))
        #expect(!redactedHARText.contains("frag88"))
        #expect(redactedHARText.contains("[REDACTED]"))

        let unredactedHAR = try HARExporter.export(entries: [binaryEntry], redactSensitive: false)
        let unredactedHARText = try #require(String(data: unredactedHAR, encoding: .utf8))
        #expect(unredactedHARText.contains(Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00]).base64EncodedString()))
    }
}
