import LocalAuthentication

enum LocalAuthenticationError: LocalizedError {
    case unavailable
    case denied

    var errorDescription: String? {
        switch self {
        case .unavailable: "此 Mac 无法使用本地身份验证。"
        case .denied: "未完成本地身份验证。"
        }
    }
}

actor LocalAuthenticationService {
    func authorize(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw LocalAuthenticationError.unavailable
        }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw LocalAuthenticationError.denied
            }
        } catch {
            throw LocalAuthenticationError.denied
        }
    }
}
