//
//  GoogleDrive.swift
//  PlayCover
//
//  Created by Edoardo C. on 16/05/24.
//

import Foundation
import Synchronization

nonisolated final class RedirectHandler: NSObject, URLSessionTaskDelegate {
    private let redirectedGoogleDriveURL = Mutex<URL?>(nil)

    static func resolveDirectDownloadURL(
        for url: URL,
        session: URLSession? = nil,
        timeout: TimeInterval = 5
    ) async -> URL {
        if url.absoluteString.contains("drive.google.com") {
            if let converted = convertGoogleDriveLink(url.absoluteString) {
                return await scrapeDownloadLink(from: converted, session: session, timeout: timeout) ?? url
            }
            return url
        }
        if url.absoluteString.contains("drive.usercontent.google.com") {
            return await scrapeDownloadLink(from: url, session: session, timeout: timeout) ?? url
        }

        let handler = RedirectHandler()
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let ownedSession = session == nil
        let activeSession = session ?? URLSession(configuration: configuration, delegate: handler, delegateQueue: nil)
        defer {
            if ownedSession {
                activeSession.finishTasksAndInvalidate()
            }
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        _ = try? await activeSession.data(for: request)

        if let redirected = handler.takeRedirectedGoogleDriveURL() {
            return await scrapeDownloadLink(from: redirected, session: session, timeout: timeout) ?? url
        }
        return url
    }

    static func convertGoogleDriveLink(_ originalLink: String) -> URL? {
        guard let fileIdRange = originalLink.range(of: "/file/d/") else {
            return nil
        }
        let startIndex = fileIdRange.upperBound
        guard let endIndex = originalLink[startIndex...].firstIndex(of: "/") else {
            return nil
        }
        let fileId = originalLink[startIndex..<endIndex]
        guard !fileId.isEmpty else {
            return nil
        }
        let newLink = "https://drive.usercontent.google.com/download?id=\(fileId)&export=download&authuser=0"
        return URL(string: newLink)
    }

    static func extractDownloadLink(from htmlContent: String) -> URL? {
        guard let formRange = findDownloadFormRange(in: htmlContent) else {
            return nil
        }
        let openingFormTag = String(htmlContent[formRange.openingTag])
        guard let actionRaw = htmlAttributeValue(named: "action", inTag: openingFormTag),
              !actionRaw.isEmpty else {
            return nil
        }
        let action = decodeHTMLEntities(actionRaw)
        let formBody = htmlContent[formRange.body]

        var inputs: [String: String] = [:]
        let inputPattern = /<(?i:input)\b[^>]*>/
        for match in formBody.matches(of: inputPattern) {
            let tag = String(match.output)
            guard let name = htmlAttributeValue(named: "name", inTag: tag) else {
                continue
            }
            let normalizedName = decodeHTMLEntities(name).lowercased()
            if normalizedName == "id" || normalizedName == "confirm" || normalizedName == "uuid" {
                let value = htmlAttributeValue(named: "value", inTag: tag).map(decodeHTMLEntities) ?? ""
                inputs[normalizedName] = value
            }
        }

        let id = inputs["id"] ?? ""
        let confirm = inputs["confirm"] ?? ""
        let uuid = inputs["uuid"] ?? ""
        return URL(string: "\(action)?id=\(id)&confirm=\(confirm)&uuid=\(uuid)")
    }

    private static func findDownloadFormRange(
        in html: String
    ) -> (openingTag: Range<String.Index>, body: Range<String.Index>)? {
        let formStartPattern = /<(?i:form)\b[^>]*>/
        for match in html.matches(of: formStartPattern) {
            let tag = String(match.output)
            guard let idValue = htmlAttributeValue(named: "id", inTag: tag),
                  decodeHTMLEntities(idValue) == "download-form" else {
                continue
            }
            let bodyStart = match.range.upperBound
            let tail = html[bodyStart...]
            let bodyEnd = tail.firstMatch(of: /<\/(?i:form)\s*>/)?.range.lowerBound ?? html.endIndex
            return (match.range, bodyStart..<bodyEnd)
        }
        return nil
    }

    private static func htmlAttributeValue(named name: String, inTag tag: String) -> String? {
        let attrPattern = /([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))/
        for match in tag.matches(of: attrPattern)
        where match.output.1.caseInsensitiveCompare(name) == .orderedSame {
            if let doubleQuoted = match.output.2 {
                return String(doubleQuoted)
            }
            if let singleQuoted = match.output.3 {
                return String(singleQuoted)
            }
            if let unquoted = match.output.4 {
                return String(unquoted)
            }
        }
        return nil
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#38;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    private static func scrapeDownloadLink(
        from url: URL,
        session: URLSession?,
        timeout: TimeInterval
    ) async -> URL? {
        let activeSession = session ?? URLSession.shared
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )

        guard let (data, _) = try? await activeSession.data(for: request),
              let html = String(data: data, encoding: .utf8) else {
            return nil
        }
        return extractDownloadLink(from: html)
    }

    private func takeRedirectedGoogleDriveURL() -> URL? {
        redirectedGoogleDriveURL.withLock { $0 }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        if let redirectURL = request.url,
           let converted = Self.convertGoogleDriveLink(redirectURL.absoluteString) {
            redirectedGoogleDriveURL.withLock { $0 = converted }
        }
        completionHandler(nil)
    }
}
