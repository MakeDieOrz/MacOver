//
//  GoogleDrive.swift
//  PlayCover
//
//  Created by Edoardo C. on 16/05/24.
//

import Foundation
import SwiftSoup

final class RedirectHandler: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var redirectedGoogleDriveURL: URL?

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
        do {
            let doc = try SwiftSoup.parse(htmlContent)
            guard let form = try doc.select("form#download-form").first() else {
                return nil
            }
            let action = try form.attr("action")
            guard !action.isEmpty else { return nil }
            let id = try form.select("input[name=id]").attr("value")
            let confirm = try form.select("input[name=confirm]").attr("value")
            let uuid = try form.select("input[name=uuid]").attr("value")
            let directDownloadLink = "\(action)?id=\(id)&confirm=\(confirm)&uuid=\(uuid)"
            return URL(string: directDownloadLink)
        } catch {
            return nil
        }
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
        lock.lock()
        defer { lock.unlock() }
        return redirectedGoogleDriveURL
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
            lock.lock()
            redirectedGoogleDriveURL = converted
            lock.unlock()
        }
        completionHandler(nil)
    }
}
