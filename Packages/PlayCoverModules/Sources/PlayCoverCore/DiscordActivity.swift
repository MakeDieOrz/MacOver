//
//  DiscordActivity.swift
//  PlayCover
//
//  Created by 이승윤 on 2022/07/16.
//

import Foundation

public struct DiscordActivity: Codable, Equatable {
    public var enable = false
    public var applicationID = ""
    public var details = ""
    public var state = ""
    public var image = ""

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enable = try container.decodeIfPresent(Bool.self, forKey: .enable) ?? false
        applicationID = try container.decodeIfPresent(String.self, forKey: .applicationID) ?? ""
        details = try container.decodeIfPresent(String.self, forKey: .details) ?? ""
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? ""
        image = try container.decodeIfPresent(String.self, forKey: .image) ?? ""
    }
}
