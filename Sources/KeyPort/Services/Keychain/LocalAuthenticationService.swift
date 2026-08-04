import LocalAuthentication

enum LocalAuthenticationError: LocalizedError {
    case unavailable
    case denied

    var errorDescription: String? {
        switch self {
        case .unavailable: "Local authentication is unavailable on this Mac."
        case .denied: "Local authentication was not completed."
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
