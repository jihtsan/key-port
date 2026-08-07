public enum SSHAuthenticationRecoveryAction: Equatable, Sendable {
    case manualAuthorization
    case authorizeWithStoredPassword
}

public enum SSHAuthenticationRecovery {
    public static func action(hasStoredPassword: Bool) -> SSHAuthenticationRecoveryAction {
        hasStoredPassword ? .authorizeWithStoredPassword : .manualAuthorization
    }
}
