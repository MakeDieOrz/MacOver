//
//  NetworkVM.swift
//  PlayCover
//
//  Created by Isaac Marovitz on 09/10/2022.
//

import Foundation
import SystemConfiguration

public class NetworkVM {
    public static func isConnectedToNetwork() -> Bool {
        guard let flags = getFlags() else { return false }
        let isReachable = flags.contains(.reachable)
        let needsConnection = flags.contains(.connectionRequired)
        let result = (isReachable && !needsConnection)

        if !result && !PlayCoverDiagnostics.hasActiveToast(ofType: .network) {
            PlayCoverDiagnostics.showToast(
                toastType: .network,
                toastDetails: NSLocalizedString("ipaLibrary.noNetworkConnection.toast", comment: "")
            )
        }

        return result
    }

    public static func getFlags() -> SCNetworkReachabilityFlags? {
        guard let reachability = ipv4Reachability() ?? ipv6Reachability() else { return nil }
        var flags = SCNetworkReachabilityFlags()
        if !SCNetworkReachabilityGetFlags(reachability, &flags) {
            return nil
        }
        return flags
    }

    public static func ipv4Reachability() -> SCNetworkReachability? {
        var zeroAddress = sockaddr_in()
        zeroAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        zeroAddress.sin_family = sa_family_t(AF_INET)

        return withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        })
    }

    public static func ipv6Reachability() -> SCNetworkReachability? {
        var zeroAddress = sockaddr_in6()
        zeroAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        zeroAddress.sin6_family = sa_family_t(AF_INET6)

        return withUnsafePointer(to: &zeroAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                SCNetworkReachabilityCreateWithAddress(nil, $0)
            }
        })
    }

    public static func isURLAccessible(url: URL, popup: Bool = false) async -> (URL?, Bool) {
        guard isConnectedToNetwork() else {
            return (nil, false)
        }

        let validStatusCodes = [200, 301, 302, 303, 307, 308]
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if validStatusCodes.contains(httpResponse.statusCode) {
                    return (httpResponse.url, true)
                } else if popup {
                    PlayCoverDiagnostics.reportError(
                        "Unable to download: \(httpResponse.statusCode) " +
                        "\(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))"
                    )
                }
            }
        } catch {
            if popup {
                PlayCoverDiagnostics.reportError(error)
            } else {
                PlayCoverDiagnostics.log(error.localizedDescription, isError: true)
            }
        }

        return (nil, false)
    }

    public static func urlAccessible(url: URL,
                                     popup: Bool = false,
                                     completion: (@Sendable (URL?, Bool) -> Void)? = nil) {
        Task {
            let (finalURL, available) = await isURLAccessible(url: url, popup: popup)
            await MainActor.run {
                completion?(finalURL, available)
            }
        }
    }
}
