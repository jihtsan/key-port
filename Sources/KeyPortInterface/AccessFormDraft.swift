import Foundation

public struct AccessFormDraft: Equatable {
    public var name = ""
    public var address = ""
    public var port = "22"
    public var account = ""
    public var password = ""
    public var existingKey = false
    public var alias = ""
    public init() {}

    public var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请输入服务器名称。" }
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty || host.hasPrefix("-") || host.contains(where: { $0.isWhitespace }) || host.contains("/") || host.contains("@") { return "请输入有效的 IP 地址或主机名，不含协议与账户。" }
        if !port.allSatisfy({ $0.isASCII && $0.isNumber }) || Int(port).map({ !(1...65535).contains($0) }) != false { return "端口必须为 1–65535。" }
        if account.isEmpty || account.hasPrefix("-") || account.contains(where: { $0.isWhitespace }) { return "请输入有效的登录账户。" }
        if !existingKey && password.isEmpty { return "请输入登录密码，或选择使用现有密钥。" }
        if !alias.isEmpty && !alias.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) { return "SSH 别名只能包含英文字母、数字、点、横线及下划线。" }
        if alias.hasPrefix("-") { return "SSH 别名不能以横线开头。" }
        return nil
    }
    public var suggestedAlias: String {
        name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? String($0) : "-" }.joined().trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
