import Foundation
import Darwin

public struct AccessFormDraft: Equatable {
    public var description = ""
    public var editingEntryID: String?
    public var profileID: String?
    public var automaticRouting: Bool?
    public var address = ""
    public var additionalAddresses: [String] = []
    public var addresses: [String] {
        var seen = Set<String>()
        return ([address] + additionalAddresses).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
    public var port = "22"
    public var account = ""
    public var password = ""
    public var privateKeyPath = ""
    public var existingKey = false
    public var alias = ""
    public init() {}

    public var validationMessage: String? {
        validationMessage(in: AliasDirectory())
    }

    public func validationMessage(in directory: AliasDirectory) -> String? {
        if let error = directory.validationMessage(for: alias, editingEntryID: editingEntryID) { return error }
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if additionalAddresses.contains(where: { !Self.isValidHost($0.trimmingCharacters(in: .whitespacesAndNewlines)) }) { return "请检查附加地址，输入有效的 IP 地址或主机名。" }
        if !Self.isValidHost(host) { return "请输入有效的 IP 地址或主机名，不含协议与账户。" }
        if !port.allSatisfy({ $0.isASCII && $0.isNumber }) || Int(port).map({ !(1...65535).contains($0) }) != false { return "端口必须为 1–65535。" }
        if account.isEmpty || account.hasPrefix("-") || account.contains(where: { $0.isWhitespace }) { return "请输入有效的登录账户。" }
        if !existingKey && password.isEmpty { return "请输入登录密码，或选择使用现有密钥。" }
        return nil
    }
    /// Syntax validation only. No DNS lookup, network probe, or identity claim.
    public static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253, host.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return false }
        var literal = host
        if literal.hasPrefix("[") || literal.hasSuffix("]") {
            guard literal.hasPrefix("["), literal.hasSuffix("]") else { return false }
            literal = String(literal.dropFirst().dropLast())
            guard literal.contains(":") else { return false }
        }
        if literal.contains(":") {
            let components = literal.split(separator: "%", omittingEmptySubsequences: false)
            guard components.count <= 2 else { return false }
            if components.count == 2 {
                guard !components[1].isEmpty, components[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else { return false }
            }
            var value = in6_addr()
            return String(components[0]).withCString { inet_pton(AF_INET6, $0, &value) } == 1
        }
        if literal.allSatisfy({ $0.isNumber || $0 == "." }), literal.contains(".") {
            let octets = literal.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.allSatisfy({ !$0.isEmpty && ($0.count == 1 || $0.first != "0") }) else { return false }
            var value = in_addr()
            return literal.withCString { inet_pton(AF_INET, $0, &value) } == 1
        }
        let dnsName = literal.hasSuffix(".") ? String(literal.dropLast()) : literal
        let labels = dnsName.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        }
    }


}

/// Validation errors belong to a submit attempt, not to the cleared credential afterward.
struct AccessFormSubmissionState {
    private(set) var error: String?
    mutating func prepare(_ draft: inout AccessFormDraft, directory: AliasDirectory = .init()) -> AccessFormDraft? {
        error = draft.validationMessage(in: directory)
        guard error == nil else { return nil }
        let submission = draft
        draft.password = ""
        return submission
    }
    mutating func edited() { error = nil }
}
