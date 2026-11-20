//
//  PlayRules.swift
//  PlayCover
//
//  Created by lucus lee on 2022/07/10.
//

import Foundation

public struct PlayRules: Decodable {
    public var blocklist: [String]?
    public var greenlist: [String]?
    public var allow: [String]?
    public var bypass: [String]?

    enum CodingKeys: String, CodingKey {
        case blocklist
        case blacklist
        case greenlist
        case whitelist
        case allow
        case bypass
    }

    public init(
        blocklist: [String]? = nil,
        greenlist: [String]? = nil,
        allow: [String]? = nil,
        bypass: [String]? = nil
    ) {
        self.blocklist = blocklist
        self.greenlist = greenlist
        self.allow = allow
        self.bypass = bypass
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blocklist = try container.decodeIfPresent([String].self, forKey: .blocklist)
            ?? container.decodeIfPresent([String].self, forKey: .blacklist)
        greenlist = try container.decodeIfPresent([String].self, forKey: .greenlist)
            ?? container.decodeIfPresent([String].self, forKey: .whitelist)
        allow = try container.decodeIfPresent([String].self, forKey: .allow)
        bypass = try container.decodeIfPresent([String].self, forKey: .bypass)
    }

    public static func buildRules(rules: [String], bundleID: String) -> [String] {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        var result: [String] = []
        let template = RuleTemplate(data: [
            "NSUserName": "\(NSUserName())",
            "BundleID": bundleID,
            "HomeDirectory": homeDirectory.path
        ])
        for rule in rules {
            result.append(template.render(template: rule))
        }
        return result
    }
}

@dynamicMemberLookup
public struct RuleTemplate {
    private var data: [String: String]

    public init(data: [String: String] = [:]) {
        self.data = data
    }

    public func render(template: String) -> String {
        var result = ""
        result.reserveCapacity(template.count)
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "$",
               let next = template.index(index, offsetBy: 1, limitedBy: template.endIndex),
               next < template.endIndex,
               template[next] == "{" {
                let keyStart = template.index(after: next)
                var scan = keyStart
                var foundClose: String.Index?
                while scan < template.endIndex {
                    let ch = template[scan]
                    if ch == "}" {
                        foundClose = scan
                        break
                    }
                    if ch == "{" {
                        break
                    }
                    scan = template.index(after: scan)
                }
                if let close = foundClose {
                    let key = String(template[keyStart..<close])
                    if let replacement = data[key] {
                        result.append(replacement)
                    } else {
                        result.append(contentsOf: template[index...close])
                    }
                    index = template.index(after: close)
                    continue
                }
            }
            result.append(template[index])
            index = template.index(after: index)
        }
        return result
    }

    public subscript(dynamicMember member: String) -> CustomStringConvertible? {
        get { data[member] }
        set { data[member] = newValue?.description }
    }

    public subscript(dynamicMember member: String) -> Date {
        get { dateFormatter.date(from: data[member] ?? "") ?? Date(timeIntervalSince1970: 0) }
        set { data[member] = dateFormatter.string(from: newValue) }
    }

    public let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ"
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()
}
