import Foundation
import Security

enum CodeSigningInfo {
    static var teamIdentifier: String? {
        signingInformation?[kSecCodeInfoTeamIdentifier] as? String
    }

    static func entitlementValue(_ key: String) -> Any? {
        guard let entitlements = signingInformation?[kSecCodeInfoEntitlementsDict] as? NSDictionary else {
            return nil
        }
        return entitlements[key]
    }

    static func entitlementContains(_ expected: String, key: String) -> Bool {
        if let values = entitlementValue(key) as? [String] {
            return values.contains(expected) || values.contains("*")
        }
        if let value = entitlementValue(key) as? String {
            return value == expected || value == "*"
        }
        return false
    }

    private static var signingInformation: NSDictionary? {
        var dynamicCode: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &dynamicCode) == errSecSuccess,
              let dynamicCode else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(dynamicCode, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess else { return nil }
        return information as NSDictionary?
    }
}
