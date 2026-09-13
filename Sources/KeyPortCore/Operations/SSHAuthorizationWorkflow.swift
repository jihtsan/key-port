import Foundation

/// The user-visible stages of the first SSH access flow.
///
/// This is deliberately a metadata-only state. Passwords, private-key paths,
/// agent state and command output never belong in this value.
public enum SSHFirstAccessStage: String, Codable, CaseIterable, Hashable, Sendable {
    case targetSelected
    case hostKeyReview
    case credentialRequired
    case credentialVerified
    case localKeyRequired
    case readyToAuthorize
    case authorizing
    case writtenAwaitingVerification
    case authorized
    case blocked
    case cancelled
    case expired

    public var title: String {
        switch self {
        case .targetSelected: "已选择目标"
        case .hostKeyReview: "核对主机身份"
        case .credentialRequired: "需要验证密码"
        case .credentialVerified: "密码已验证"
        case .localKeyRequired: "准备本机密钥"
        case .readyToAuthorize: "准备远端授权"
        case .authorizing: "正在写入授权"
        case .writtenAwaitingVerification: "已写入，等待复检"
        case .authorized: "免密已可用"
        case .blocked: "等待处理"
        case .cancelled: "已取消"
        case .expired: "已过期"
        }
    }

    public var systemImage: String {
        switch self {
        case .targetSelected: "scope"
        case .hostKeyReview: "checkmark.shield"
        case .credentialRequired: "lock.open"
        case .credentialVerified: "checkmark.lock"
        case .localKeyRequired: "key"
        case .readyToAuthorize: "key.horizontal"
        case .authorizing: "arrow.triangle.2.circlepath"
        case .writtenAwaitingVerification: "exclamationmark.shield"
        case .authorized: "checkmark.shield.fill"
        case .blocked: "pause.circle"
        case .cancelled: "xmark.circle"
        case .expired: "clock.badge.exclamationmark"
        }
    }

    /// The normal forward path. `blockedAt` on `SSHFirstAccessState` preserves
    /// the stage that needs attention when the visible stage is `.blocked`.
    public var progressRank: Int? {
        switch self {
        case .targetSelected: 0
        case .hostKeyReview: 1
        case .credentialRequired: 2
        case .credentialVerified: 3
        case .localKeyRequired: 4
        case .readyToAuthorize: 5
        case .authorizing: 6
        case .writtenAwaitingVerification: 7
        case .authorized: 8
        case .blocked, .cancelled, .expired: nil
        }
    }
}

public enum SSHAuthorizationFailureCode: String, Codable, CaseIterable, Hashable, Sendable {
    case hostKeyPending
    case hostKeyChanged
    case missingPassword
    case passwordRejected
    case missingLocalKey
    case keyAuthenticationFailed
    case verificationFailedAfterWrite
    case remoteWriteFailed
    case routeUnavailable
    case unreachable
    case localAuthorizationFailed
    case cancelled
    case expired
    case invalidTarget
    case interrupted

    public var title: String {
        switch self {
        case .hostKeyPending: "等待确认主机身份"
        case .hostKeyChanged: "主机身份发生变化"
        case .missingPassword: "缺少已验证的密码"
        case .passwordRejected: "服务器拒绝密码"
        case .missingLocalKey: "缺少本机密钥"
        case .keyAuthenticationFailed: "免密复检失败"
        case .verificationFailedAfterWrite: "已写入但复检失败"
        case .remoteWriteFailed: "远端授权写入失败"
        case .routeUnavailable: "没有可用 SSH 路径"
        case .unreachable: "服务器无法连接"
        case .localAuthorizationFailed: "本机身份验证未通过"
        case .cancelled: "操作已取消"
        case .expired: "操作已过期"
        case .invalidTarget: "目标已不存在"
        case .interrupted: "上次操作未完成"
        }
    }

    public var requiresUserAction: Bool {
        switch self {
        case .hostKeyPending, .hostKeyChanged, .missingPassword, .missingLocalKey,
             .passwordRejected, .localAuthorizationFailed, .invalidTarget, .interrupted:
            true
        case .keyAuthenticationFailed, .verificationFailedAfterWrite,
             .remoteWriteFailed, .routeUnavailable, .unreachable, .cancelled, .expired:
            false
        }
    }

    public var suggestedRecoveryAction: SSHAuthorizationRecoveryAction {
        switch self {
        case .hostKeyPending, .hostKeyChanged:
            .reviewHostKey
        case .missingPassword:
            .providePassword
        case .passwordRejected:
            .providePassword
        case .missingLocalKey:
            .prepareLocalKey
        case .verificationFailedAfterWrite:
            .recheck
        case .keyAuthenticationFailed, .remoteWriteFailed,
             .routeUnavailable, .unreachable, .cancelled, .expired, .invalidTarget,
             .interrupted:
            .retry
        case .localAuthorizationFailed:
            .retry
        }
    }
}

public enum SSHAuthorizationRecoveryAction: String, Codable, CaseIterable, Hashable, Sendable {
    case reviewHostKey
    case providePassword
    case prepareLocalKey
    case retry
    case recheck
    case none

    public var title: String {
        switch self {
        case .reviewHostKey: "核对主机身份"
        case .providePassword: "输入并验证密码"
        case .prepareLocalKey: "生成或导入本机密钥"
        case .retry: "重试"
        case .recheck: "重新检查"
        case .none: ""
        }
    }
}

/// A local, resumable first-access state. It contains only stable IDs and
/// stable failure categories so it is safe to keep in local preferences.
public struct SSHFirstAccessState: Codable, Hashable, Sendable {
    public let targetID: UUID
    public var stage: SSHFirstAccessStage
    public var blockedAt: SSHFirstAccessStage?
    public var completedStages: [SSHFirstAccessStage]
    public var failureCode: SSHAuthorizationFailureCode?
    public var recoveryAction: SSHAuthorizationRecoveryAction?
    public var attemptCount: Int
    public var updatedAt: Date

    public init(
        targetID: UUID,
        stage: SSHFirstAccessStage = .targetSelected,
        blockedAt: SSHFirstAccessStage? = nil,
        completedStages: [SSHFirstAccessStage] = [],
        failureCode: SSHAuthorizationFailureCode? = nil,
        recoveryAction: SSHAuthorizationRecoveryAction? = nil,
        attemptCount: Int = 0,
        updatedAt: Date = .now
    ) {
        self.targetID = targetID
        self.stage = stage
        self.blockedAt = blockedAt
        self.completedStages = Self.uniqueStages(completedStages)
        self.failureCode = failureCode
        self.recoveryAction = recoveryAction
        self.attemptCount = max(0, attemptCount)
        self.updatedAt = updatedAt
    }

    public var progressStage: SSHFirstAccessStage {
        stage == .blocked ? blockedAt ?? .targetSelected : stage
    }

    public var isTerminal: Bool {
        stage == .authorized || stage == .cancelled || stage == .expired
    }

    public var canResume: Bool {
        stage == .blocked || stage == .writtenAwaitingVerification
    }

    public mutating func recordProgress(
        to nextStage: SSHFirstAccessStage,
        now: Date = .now
    ) {
        if let rank = nextStage.progressRank {
            completedStages = Self.uniqueStages(
                completedStages + SSHFirstAccessStage.allCases.filter {
                    guard let existingRank = $0.progressRank else { return false }
                    return existingRank <= rank
                }
            )
        }
        stage = nextStage
        blockedAt = nil
        failureCode = nil
        recoveryAction = nil
        updatedAt = now
    }

    public mutating func recordBlock(
        code: SSHAuthorizationFailureCode,
        recoveryAction: SSHAuthorizationRecoveryAction,
        at blockedStage: SSHFirstAccessStage? = nil,
        now: Date = .now
    ) {
        blockedAt = blockedStage ?? progressStage
        stage = .blocked
        failureCode = code
        self.recoveryAction = recoveryAction
        updatedAt = now
    }

    public mutating func recordCancellation(now: Date = .now) {
        guard !isTerminal else { return }
        stage = .cancelled
        failureCode = .cancelled
        recoveryAction = SSHAuthorizationRecoveryAction.none
        updatedAt = now
    }

    public mutating func recordExpiry(now: Date = .now) {
        guard !isTerminal else { return }
        stage = .expired
        failureCode = .expired
        recoveryAction = .retry
        updatedAt = now
    }

    private static func uniqueStages(_ stages: [SSHFirstAccessStage]) -> [SSHFirstAccessStage] {
        var seen = Set<SSHFirstAccessStage>()
        return stages.filter { seen.insert($0).inserted }
    }
}

public enum SSHFirstAccessTransitionError: Error, Equatable, Hashable, Sendable {
    case terminal(SSHFirstAccessStage)
    case invalid(from: SSHFirstAccessStage, to: SSHFirstAccessStage)
}

/// Pure transition validation for first access. The app-facing state can be
/// persisted and restored without bringing credentials into the workflow.
public struct SSHFirstAccessStateMachine: Sendable {
    public private(set) var state: SSHFirstAccessState

    public init(state: SSHFirstAccessState) {
        self.state = state
    }

    public init(targetID: UUID, now: Date = .now) {
        self.state = SSHFirstAccessState(targetID: targetID, updatedAt: now)
    }

    public mutating func transition(
        to nextStage: SSHFirstAccessStage,
        now: Date = .now
    ) throws {
        guard !state.isTerminal else {
            throw SSHFirstAccessTransitionError.terminal(state.stage)
        }
        guard Self.allowedTransitions[state.stage, default: []].contains(nextStage) else {
            throw SSHFirstAccessTransitionError.invalid(from: state.stage, to: nextStage)
        }
        state.recordProgress(to: nextStage, now: now)
        if nextStage == .authorizing {
            state.attemptCount += 1
        }
    }

    public mutating func block(
        code: SSHAuthorizationFailureCode,
        recoveryAction: SSHAuthorizationRecoveryAction,
        at blockedStage: SSHFirstAccessStage? = nil,
        now: Date = .now
    ) {
        guard !state.isTerminal else { return }
        state.recordBlock(
            code: code,
            recoveryAction: recoveryAction,
            at: blockedStage,
            now: now
        )
    }

    public mutating func cancel(now: Date = .now) {
        state.recordCancellation(now: now)
    }

    public mutating func expire(now: Date = .now) {
        state.recordExpiry(now: now)
    }

    private static let allowedTransitions: [SSHFirstAccessStage: Set<SSHFirstAccessStage>] = [
        .targetSelected: [.hostKeyReview, .credentialRequired, .credentialVerified, .localKeyRequired, .readyToAuthorize, .blocked, .cancelled, .expired],
        .hostKeyReview: [.credentialRequired, .credentialVerified, .localKeyRequired, .readyToAuthorize, .blocked, .cancelled, .expired],
        .credentialRequired: [.credentialVerified, .localKeyRequired, .readyToAuthorize, .blocked, .cancelled, .expired],
        .credentialVerified: [.localKeyRequired, .readyToAuthorize, .blocked, .cancelled, .expired],
        .localKeyRequired: [.readyToAuthorize, .blocked, .cancelled, .expired],
        .readyToAuthorize: [.authorizing, .blocked, .cancelled, .expired],
        .authorizing: [.writtenAwaitingVerification, .authorized, .blocked, .cancelled, .expired],
        .writtenAwaitingVerification: [.authorizing, .authorized, .blocked, .cancelled, .expired],
        .blocked: [.hostKeyReview, .credentialRequired, .credentialVerified, .localKeyRequired, .readyToAuthorize, .authorizing, .cancelled, .expired],
        .authorized: [.authorizing],
        .cancelled: [],
        .expired: [],
    ]
}

public enum SSHAuthorizationBatchPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case authorizing
    case paused
    case cancelling
    case completed
    case cancelled

    public var title: String {
        switch self {
        case .pending: "等待开始"
        case .authorizing: "正在批量授权"
        case .paused: "已暂停，等待处理"
        case .cancelling: "正在取消"
        case .completed: "批量授权完成"
        case .cancelled: "批量授权已取消"
        }
    }

    public var isActive: Bool {
        self == .pending || self == .authorizing || self == .cancelling
    }
}

public enum SSHAuthorizationBatchItemState: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case inProgress
    case succeeded
    case failed
    case blocked
    case skipped
    case cancelled

    public var title: String {
        switch self {
        case .pending: "待处理"
        case .inProgress: "处理中"
        case .succeeded: "成功"
        case .failed: "失败"
        case .blocked: "等待处理"
        case .skipped: "已跳过"
        case .cancelled: "已取消"
        }
    }

    public var systemImage: String {
        switch self {
        case .pending: "circle"
        case .inProgress: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .blocked: "pause.circle.fill"
        case .skipped: "minus.circle"
        case .cancelled: "xmark.circle"
        }
    }
}

public struct SSHAuthorizationBatchItem: Identifiable, Codable, Hashable, Sendable {
    public let targetID: UUID
    public var state: SSHAuthorizationBatchItemState
    public var failureCode: SSHAuthorizationFailureCode?
    public var attemptCount: Int
    public var updatedAt: Date
    public var completedAt: Date?

    public var id: UUID { targetID }

    public init(
        targetID: UUID,
        state: SSHAuthorizationBatchItemState = .pending,
        failureCode: SSHAuthorizationFailureCode? = nil,
        attemptCount: Int = 0,
        updatedAt: Date = .now,
        completedAt: Date? = nil
    ) {
        self.targetID = targetID
        self.state = state
        self.failureCode = failureCode
        self.attemptCount = max(0, attemptCount)
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

public enum SSHAuthorizationBatchPlanError: Error, Equatable, Hashable, Sendable {
    case emptyTargets
    case duplicateTarget(UUID)
    case invalidTransition
    case unknownTarget(UUID)
}

/// An ordered, local-only batch plan. Successful items are never reset by
/// retry, which makes a retry safe after a partial remote write.
public struct SSHAuthorizationBatchPlan: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let operationID: UUID
    public let deviceID: String
    public var items: [SSHAuthorizationBatchItem]
    public var phase: SSHAuthorizationBatchPhase
    public var blockedTargetID: UUID?
    public var pauseReason: SSHAuthorizationFailureCode?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        targetIDs: [UUID],
        deviceID: String,
        operationID: UUID = UUID(),
        now: Date = .now
    ) throws {
        guard !targetIDs.isEmpty else { throw SSHAuthorizationBatchPlanError.emptyTargets }
        var seen = Set<UUID>()
        for targetID in targetIDs where !seen.insert(targetID).inserted {
            throw SSHAuthorizationBatchPlanError.duplicateTarget(targetID)
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.operationID = operationID
        self.deviceID = deviceID
        self.items = targetIDs.map { SSHAuthorizationBatchItem(targetID: $0, updatedAt: now) }
        self.phase = .pending
        self.blockedTargetID = nil
        self.pauseReason = nil
        self.createdAt = now
        self.updatedAt = now
    }

    public var totalCount: Int { items.count }
    public var succeededCount: Int { items.filter { $0.state == .succeeded }.count }
    public var failedCount: Int { items.filter { $0.state == .failed }.count }
    public var blockedCount: Int { items.filter { $0.state == .blocked }.count }
    public var pendingCount: Int { items.filter { $0.state == .pending }.count }
    public var terminalCount: Int {
        items.filter {
            switch $0.state {
            case .succeeded, .failed, .blocked, .skipped, .cancelled: true
            case .pending, .inProgress: false
            }
        }.count
    }
    public var hasFailedItems: Bool { failedCount > 0 }
    public var isFinished: Bool { phase == .completed || phase == .cancelled }
    public var nextPendingTargetID: UUID? {
        guard phase == .authorizing else { return nil }
        return items.first(where: { $0.state == .pending })?.targetID
    }

    public mutating func begin(now: Date = .now) throws {
        guard phase == .pending || phase == .paused else {
            throw SSHAuthorizationBatchPlanError.invalidTransition
        }
        phase = .authorizing
        blockedTargetID = nil
        pauseReason = nil
        updatedAt = now
    }

    public mutating func markInProgress(targetID: UUID, now: Date = .now) throws {
        guard phase == .authorizing,
              let index = items.firstIndex(where: { $0.targetID == targetID }) else {
            throw SSHAuthorizationBatchPlanError.unknownTarget(targetID)
        }
        guard items[index].state == .pending else {
            throw SSHAuthorizationBatchPlanError.invalidTransition
        }
        items[index].state = .inProgress
        items[index].attemptCount += 1
        items[index].failureCode = nil
        items[index].completedAt = nil
        items[index].updatedAt = now
        updatedAt = now
    }

    public mutating func markSucceeded(targetID: UUID, now: Date = .now) throws {
        try finish(targetID: targetID, state: .succeeded, failureCode: nil, now: now)
    }

    public mutating func markFailed(
        targetID: UUID,
        code: SSHAuthorizationFailureCode,
        now: Date = .now
    ) throws {
        try finish(targetID: targetID, state: .failed, failureCode: code, now: now)
    }

    public mutating func markBlocked(
        targetID: UUID,
        code: SSHAuthorizationFailureCode,
        now: Date = .now
    ) throws {
        try finish(targetID: targetID, state: .blocked, failureCode: code, now: now)
        phase = .paused
        blockedTargetID = targetID
        pauseReason = code
        updatedAt = now
    }

    public mutating func pause(
        reason: SSHAuthorizationFailureCode,
        targetID: UUID? = nil,
        now: Date = .now
    ) {
        phase = .paused
        blockedTargetID = targetID
        pauseReason = reason
        updatedAt = now
    }

    public mutating func retryFailed(now: Date = .now) throws {
        guard !phase.isActive else { throw SSHAuthorizationBatchPlanError.invalidTransition }
        guard items.contains(where: { $0.state == .failed }) else {
            throw SSHAuthorizationBatchPlanError.invalidTransition
        }
        for index in items.indices where items[index].state == .failed {
            items[index].state = .pending
            items[index].failureCode = nil
            items[index].completedAt = nil
            items[index].updatedAt = now
        }
        phase = .pending
        blockedTargetID = nil
        pauseReason = nil
        updatedAt = now
    }

    public mutating func resumeAfterIntervention(now: Date = .now) throws {
        guard phase == .paused else { throw SSHAuthorizationBatchPlanError.invalidTransition }
        if let blockedTargetID,
           let index = items.firstIndex(where: { $0.targetID == blockedTargetID }),
           items[index].state == .blocked {
            items[index].state = .pending
            items[index].failureCode = nil
            items[index].completedAt = nil
            items[index].updatedAt = now
        }
        phase = .pending
        self.blockedTargetID = nil
        pauseReason = nil
        updatedAt = now
    }

    public mutating func cancel(now: Date = .now) {
        guard phase.isActive || phase == .paused else { return }
        phase = .cancelled
        for index in items.indices {
            switch items[index].state {
            case .pending, .inProgress, .blocked:
                items[index].state = .cancelled
                items[index].failureCode = .cancelled
                items[index].completedAt = now
                items[index].updatedAt = now
            case .succeeded, .failed, .skipped, .cancelled:
                break
            }
        }
        blockedTargetID = nil
        pauseReason = .cancelled
        updatedAt = now
    }

    /// Converts an in-flight item to a retryable item after an app restart.
    /// This does not touch already successful items.
    public mutating func recoverAfterInterruption(now: Date = .now) {
        guard phase == .authorizing || phase == .cancelling else { return }
        for index in items.indices where items[index].state == .inProgress {
            items[index].state = .pending
            items[index].failureCode = .interrupted
            items[index].completedAt = nil
            items[index].updatedAt = now
        }
        phase = .paused
        blockedTargetID = nil
        pauseReason = .interrupted
        updatedAt = now
    }

    public mutating func finishIfPossible(now: Date = .now) {
        guard phase == .authorizing,
              !items.contains(where: { $0.state == .pending || $0.state == .inProgress }) else { return }
        phase = .completed
        updatedAt = now
    }

    private mutating func finish(
        targetID: UUID,
        state: SSHAuthorizationBatchItemState,
        failureCode: SSHAuthorizationFailureCode?,
        now: Date
    ) throws {
        guard let index = items.firstIndex(where: { $0.targetID == targetID }) else {
            throw SSHAuthorizationBatchPlanError.unknownTarget(targetID)
        }
        guard items[index].state == .inProgress else {
            throw SSHAuthorizationBatchPlanError.invalidTransition
        }
        items[index].state = state
        items[index].failureCode = failureCode
        items[index].completedAt = now
        items[index].updatedAt = now
        updatedAt = now
    }
}

public enum SSHDeviceAuthorizationStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case authorized
    case remotelyAuthorized
    case needsAuthorization
    case missingLocalKey
    case remoteUnknown
    case deviceRevoked
    case checking
    case failed
    case staleVerification

    public var title: String {
        switch self {
        case .authorized: "本机已验证"
        case .remotelyAuthorized: "远端已授权"
        case .needsAuthorization: "待授权"
        case .missingLocalKey: "缺少本机密钥"
        case .remoteUnknown: "远端状态未知"
        case .deviceRevoked: "设备已撤销"
        case .checking: "检查中"
        case .failed: "最近验证失败"
        case .staleVerification: "需要重新验证"
        }
    }

    public var systemImage: String {
        switch self {
        case .authorized: "checkmark.shield.fill"
        case .remotelyAuthorized: "checkmark.circle"
        case .needsAuthorization: "key.horizontal"
        case .missingLocalKey: "key.slash"
        case .remoteUnknown: "questionmark.circle"
        case .deviceRevoked: "nosign"
        case .checking: "arrow.triangle.2.circlepath"
        case .failed: "xmark.circle.fill"
        case .staleVerification: "clock.badge.exclamationmark"
        }
    }
}

/// A projection that keeps shared remote authorization separate from the
/// current Mac's local key and verification facts.
public struct SSHDeviceAuthorizationSummary: Identifiable, Codable, Hashable, Sendable {
    public let accountID: UUID
    public let deviceID: String
    public let status: SSHDeviceAuthorizationStatus
    public let remoteAuthorized: Bool
    public let localKeyAvailable: Bool
    public let lastVerifiedAt: Date?

    public var id: String { "(deviceID):(accountID.uuidString.lowercased())" }

    public init(
        accountID: UUID,
        deviceID: String,
        status: SSHDeviceAuthorizationStatus,
        remoteAuthorized: Bool,
        localKeyAvailable: Bool,
        lastVerifiedAt: Date?
    ) {
        self.accountID = accountID
        self.deviceID = deviceID
        self.status = status
        self.remoteAuthorized = remoteAuthorized
        self.localKeyAvailable = localKeyAvailable
        self.lastVerifiedAt = lastVerifiedAt
    }
}

public enum SSHAuthorizationProjection {
    public static let defaultVerificationLifetime: TimeInterval = 24 * 60 * 60

    public static func summaries(
        for accountID: UUID,
        currentDeviceID: String?,
        topology: TopologySnapshot,
        now: Date = .now,
        verificationLifetime: TimeInterval = defaultVerificationLifetime,
        currentNetworkEpoch: UInt64? = nil
    ) -> [SSHDeviceAuthorizationSummary] {
        topology.profiles
            .sorted { $0.id < $1.id }
            .map { profile in
                summary(
                    for: accountID,
                    deviceID: profile.id,
                    currentDeviceID: currentDeviceID,
                    topology: topology,
                    now: now,
                    verificationLifetime: verificationLifetime,
                    currentNetworkEpoch: currentNetworkEpoch
                )
            }
    }

    public static func summary(
        for accountID: UUID,
        deviceID: String,
        currentDeviceID: String?,
        topology: TopologySnapshot,
        now: Date = .now,
        verificationLifetime: TimeInterval = defaultVerificationLifetime,
        currentNetworkEpoch: UInt64? = nil
    ) -> SSHDeviceAuthorizationSummary {
        let profile = topology.profiles.first(where: { $0.id == deviceID })
        let keys = topology.sshKeys.filter { $0.deviceID == deviceID }
        let keyIDs = Set(keys.map(\.id))
        let keyFingerprints = Set(keys.map(\.fingerprint).filter { !$0.isEmpty })
        let accountAuthorizations = topology.activeAuthorizations(for: accountID)
        let remoteAuthorized = accountAuthorizations.contains {
            $0.remoteState == .authorized
                && (keyFingerprints.contains($0.fingerprint)
                    || ($0.fingerprint.isEmpty && keyIDs.contains($0.keyID)))
        }
        let localKeyAvailable = keys.contains { $0.isLocallyAvailable && $0.privateKeyPath != nil }
        let latestVerification = topology.latestAccessVerification(
            for: accountID,
            deviceID: deviceID
        )
        let lastVerifiedAt = latestVerification?.keyCheck?.state == .succeeded
            ? latestVerification?.keyCheck?.checkedAt ?? latestVerification?.lastCheckedAt
            : nil
        let verificationIsCurrent: Bool = {
            guard let latestVerification else { return false }
            if currentNetworkEpoch != nil {
                return latestVerification.freshness(
                    at: now,
                    networkEpoch: currentNetworkEpoch,
                    validFor: verificationLifetime
                ) == .fresh
            }
            guard let detectedAt = latestVerification.detectedAt,
                  detectedAt <= now else { return false }
            return now.timeIntervalSince(detectedAt) <= verificationLifetime
        }()

        let status: SSHDeviceAuthorizationStatus
        if profile?.isRevoked == true {
            status = .deviceRevoked
        } else if deviceID != currentDeviceID {
            status = remoteAuthorized ? .remotelyAuthorized : .remoteUnknown
        } else if latestVerification?.status == .checking || latestVerification?.status == .syncing {
            status = .checking
        } else if latestVerification?.status == .authorized && remoteAuthorized {
            status = verificationIsCurrent ? .authorized : .staleVerification
        } else if latestVerification?.status == .authorizationWrittenAwaitingVerification
                    || latestVerification?.status == .authorizationConflict
                    || latestVerification?.status == .keyAuthenticationFailed
                    || latestVerification?.status == .passwordAuthenticationFailed
                    || latestVerification?.status == .unreachable {
            status = .failed
        } else if !localKeyAvailable {
            status = .missingLocalKey
        } else if remoteAuthorized {
            status = .staleVerification
        } else if latestVerification?.status == .hostKeyPending
                    || latestVerification?.status == .hostKeyMismatch {
            status = .failed
        } else {
            status = .needsAuthorization
        }

        return SSHDeviceAuthorizationSummary(
            accountID: accountID,
            deviceID: deviceID,
            status: status,
            remoteAuthorized: remoteAuthorized,
            localKeyAvailable: localKeyAvailable,
            lastVerifiedAt: lastVerifiedAt
        )
    }
}
