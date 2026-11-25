//
//  ITunesResponse.swift
//  PlayCover
//
//  Created by Isaac Marovitz on 23/08/2022.
//

import Foundation

public struct ITunesResult: Codable, Sendable {
    public let isGameCenterEnabled: Bool
    public let features: [String]
    public let advisories: [String]
    public let supportedDevices: [String]
    public let screenshotUrls: [String]
    public let ipadScreenshotUrls: [String]
    public let appletvScreenshotUrls: [String]
    public let artworkUrl60: String
    public let artworkUrl512: String
    public let artworkUrl100: String
    public let artistViewUrl: String
    public let kind: String
    public let artistId: Int
    public let artistName: String
    public let genres: [String]
    public let price: Float
    public let releaseNotes: String?
    public let description: String
    public let isVppDeviceBasedLicensingEnabled: Bool
    public let primaryGenreName: String
    public let primaryGenreId: Int
    public let bundleId: String
    public let genreIds: [String]
    public let currency: String
    public let releaseDate: String
    public let sellerName: String
    public let trackId: Int
    public let trackName: String
    public let currentVersionReleaseDate: String
    public let averageUserRating: Float
    public let averageUserRatingForCurrentVersion: Float?
    public let trackViewUrl: String?
    public let trackContentRating: String?
    public let minimumOsVersion: String
    public let trackCensoredName: String
    public let languageCodesISO2A: [String]
    public let fileSizeBytes: String
    public let sellerUrl: String?
    public let formattedPrice: String
    public let contentAdvisoryRating: String
    public let userRatingCountForCurrentVersion: Int
    public let version: String
    public let wrapperType: String
    public let userRatingCount: Int
}

public struct ITunesResponse: Codable, Sendable {
    public let resultCount: Int
    public let results: [ITunesResult]
}

public func getITunesData(_ itunesLookup: String) async -> ITunesResponse? {
    guard NetworkVM.isConnectedToNetwork(), let url = URL(string: itunesLookup) else {
        return nil
    }

    return await withCheckedContinuation { continuation in
        URLSession.shared.dataTask(with: URLRequest(url: url)) { data, _, error in
            do {
                if error == nil, let data = data {
                    let decoder = JSONDecoder()
                    let jsonResult: ITunesResponse = try decoder.decode(ITunesResponse.self, from: data)
                    continuation.resume(returning: jsonResult.resultCount > 0 ? jsonResult : nil)
                    return
                }
            } catch {
                print("Error getting iTunes data from URL: \(itunesLookup): \(error)")
            }

            continuation.resume(returning: nil)
        }.resume()
    }
}
