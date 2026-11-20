import Darwin
import Foundation
import Security

public enum HelperSecurityValidator {
    public static let expectedClientBundleID = "io.playcover.PlayCover"

    private static let developerIDRequirementString =
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ " +
        "and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */"

    public static func validateBundleIdentifier(_ bundleID: String) -> Bool {
        guard bundleID.count >= 2, bundleID.count <= 128 else {
            return false
        }
        guard bundleID.contains("."),
              !bundleID.hasPrefix("."),
              !bundleID.hasSuffix("."),
              !bundleID.contains("..") else {
            return false
        }
        return bundleID.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 0x30 && v <= 0x39)
                || (v >= 0x41 && v <= 0x5A)
                || (v >= 0x61 && v <= 0x7A)
                || v == 0x2E
                || v == 0x2D
                || v == 0x5F
        }
    }

    public static func validateContainerPath(
        _ path: String,
        userHomeRoot: String? = nil
    ) -> String? {
        guard !path.isEmpty, path.hasPrefix("/") else {
            return nil
        }
        if path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return nil
        }

        let rawURL = URL(fileURLWithPath: path)
        if rawURL.pathComponents.contains("..") || rawURL.pathComponents.contains(".") {
            return nil
        }

        let standardized = rawURL.standardizedFileURL.path
        let components = URL(fileURLWithPath: standardized).pathComponents
        // Expected shape: ["/", "Users", "<username>", "Library", "Containers", "<bundleID>", ...]
        guard components.count >= 6,
              components[0] == "/",
              components[1] == "Users",
              !components[2].isEmpty,
              components[2] != "." && components[2] != "..",
              components[3] == "Library",
              components[4] == "Containers" else {
            return nil
        }

        let containerID = components[5]
        guard validateBundleIdentifier(containerID) else {
            return nil
        }

        if let userHomeRoot {
            let expectedPrefix = URL(fileURLWithPath: userHomeRoot)
                .standardizedFileURL
                .appendingPathComponent("Library/Containers", isDirectory: true)
                .path
            guard standardized.hasPrefix(expectedPrefix + "/") else {
                return nil
            }
        }

        return standardized
    }

    public static func isValidTeamIdentifier(_ teamID: String) -> Bool {
        guard !teamID.isEmpty, teamID.count <= 32 else {
            return false
        }
        return teamID.unicodeScalars.allSatisfy { scalar in
            let v = scalar.value
            return (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A)
        }
    }

    public static func clientCodeSigningRequirement(teamID: String? = currentProcessTeamIdentifier()) -> String? {
        guard let teamID, isValidTeamIdentifier(teamID) else {
            return nil
        }
        return "identifier \"\(expectedClientBundleID)\" and \(developerIDRequirementString) " +
            "and certificate leaf[subject.OU] = \"\(teamID)\""
    }

    public static func verifyIncomingConnection(_ connection: NSXPCConnection) -> Bool {
        guard let ownTeamID = currentProcessTeamIdentifier(),
              let requirementString = clientCodeSigningRequirement(teamID: ownTeamID) else {
            return false
        }

        connection.setCodeSigningRequirement(requirementString)

        let pid = connection.processIdentifier
        guard pid > 0 else {
            return false
        }
        let attributes: [String: Any] = [
            kSecGuestAttributePid as String: NSNumber(value: pid)
        ]

        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, SecCSFlags(), &guestCode) == errSecSuccess,
              let code = guestCode else {
            return false
        }

        var guestStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &guestStatic) == errSecSuccess,
              let staticClient = guestStatic else {
            return false
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementString as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let devIDRequirement = requirement,
        SecStaticCodeCheckValidity(staticClient, SecCSFlags(), devIDRequirement) == errSecSuccess else {
            return false
        }

        var clientInfoCF: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticClient,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &clientInfoCF
        ) == errSecSuccess,
        let clientInfo = clientInfoCF as? [String: Any],
        let clientIdentifier = clientInfo[kSecCodeInfoIdentifier as String] as? String,
        let clientTeamID = clientInfo[kSecCodeInfoTeamIdentifier as String] as? String,
        clientIdentifier == expectedClientBundleID,
        clientTeamID == ownTeamID else {
            return false
        }

        return true
    }

    public static func currentProcessTeamIdentifier() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &selfCode) == errSecSuccess, let code = selfCode else {
            return nil
        }
        var selfStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &selfStatic) == errSecSuccess,
              let staticSelf = selfStatic else {
            return nil
        }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticSelf,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF
        ) == errSecSuccess,
        let info = infoCF as? [String: Any] else {
            return nil
        }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
