public enum SSHAuthorizationAction: String, CaseIterable, Equatable, Sendable {
    case synchronizeAuthorization
    case recheck
    case addAndVerifyPassword
    case generateLocalKey
    case confirmHostKey
    case retry
    case none

    public var title: String {
        switch self {
        case .synchronizeAuthorization: "同步 SSH 授权"
        case .recheck: "重新检查"
        case .addAndVerifyPassword: "添加并验证密码"
        case .generateLocalKey: "生成本地密钥"
        case .confirmHostKey: "确认主机身份"
        case .retry: "重试"
        case .none: ""
        }
    }

    public var systemImage: String {
        switch self {
        case .synchronizeAuthorization: "key.horizontal.fill"
        case .recheck: "arrow.clockwise"
        case .addAndVerifyPassword: "lock.open"
        case .generateLocalKey: "key"
        case .confirmHostKey: "checkmark.shield"
        case .retry: "arrow.clockwise"
        case .none: ""
        }
    }
}

public extension AuthorizationStatus {
    var isInFlight: Bool {
        self == .checking || self == .syncing
    }

    func primaryAction(hasStoredPassword: Bool, hasLocalKey: Bool) -> SSHAuthorizationAction {
        switch self {
        case .authorized:
            .recheck
        case .hostKeyPending, .hostKeyMismatch:
            .confirmHostKey
        case .missingLocalKey:
            .generateLocalKey
        case .needsAuthorization, .keyAuthenticationFailed, .syncPending:
            if !hasLocalKey {
                .generateLocalKey
            } else if !hasStoredPassword {
                .addAndVerifyPassword
            } else {
                .synchronizeAuthorization
            }
        case .passwordAuthenticationFailed:
            .addAndVerifyPassword
        case .unreachable, .authorizationConflict:
            .retry
        case .checking, .syncing:
            .none
        }
    }
}
