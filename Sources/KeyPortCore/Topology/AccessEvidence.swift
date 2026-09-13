import Foundation

/// Freshness of a locally observed access fact.
///
/// The value deliberately does not encode whether the observation succeeded:
/// a recent failed probe is still useful negative evidence. Callers should
/// inspect `wasReachable` or the authentication check state separately.
public enum TopologyEvidenceFreshness: String, Codable, Hashable, Sendable {
    case unknown
    case fresh
    case expired
    case networkChanged
}

public enum SSHAuthorizationDecision: String, Codable, Hashable, Sendable {
    case installNewAuthorization
    case verifyExistingAccountAuthorization
}

public enum TopologyEvidencePolicy {
    /// Reachability is a short-lived routing hint. It must not silently turn
    /// into a durable connectivity guarantee after a network change.
    public static let reachabilityValidityDuration: TimeInterval = 5 * 60

    /// Authentication evidence is useful for the current device for one day;
    /// the remote authorization relation itself remains account-level data.
    public static let accessVerificationValidityDuration: TimeInterval = 24 * 60 * 60
}

public extension ReachabilityObservation {
    func freshness(
        at date: Date = .now,
        networkEpoch currentNetworkEpoch: UInt64,
        validFor validityDuration: TimeInterval = TopologyEvidencePolicy.reachabilityValidityDuration
    ) -> TopologyEvidenceFreshness {
        guard networkEpoch == currentNetworkEpoch else { return .networkChanged }
        guard observedAt <= date else { return .unknown }
        return date.timeIntervalSince(observedAt) <= max(0, validityDuration) ? .fresh : .expired
    }
}

public extension AccessVerification {
    /// The most recent time at which any part of this verification was
    /// detected. `lastCheckedAt` is retained as the legacy aggregate value;
    /// newer records may have a more precise authentication timestamp.
    var detectedAt: Date? {
        [
            lastCheckedAt,
            passwordCheck?.checkedAt,
            keyCheck?.checkedAt,
            machineConfigurationRefreshAttemptedAt,
        ]
        .compactMap { $0 }
        .max()
    }

    func freshness(
        at date: Date = .now,
        networkEpoch currentNetworkEpoch: UInt64?,
        validFor validityDuration: TimeInterval = TopologyEvidencePolicy.accessVerificationValidityDuration
    ) -> TopologyEvidenceFreshness {
        guard let storedNetworkEpoch = networkEpoch,
              let currentNetworkEpoch else {
            return .unknown
        }
        guard storedNetworkEpoch == currentNetworkEpoch else { return .networkChanged }
        guard let detectedAt, detectedAt <= date else { return .unknown }
        return date.timeIntervalSince(detectedAt) <= max(0, validityDuration) ? .fresh : .expired
    }
}

public extension TopologySnapshot {
    /// Resolves a profile to its account without exposing the compatibility
    /// `ServerConnection` projection to callers.
    func account(forProfileID profileID: UUID) -> SSHAccount? {
        guard let profile = connectionProfile(id: profileID) else { return nil }
        return activeAccounts.first { $0.id == profile.accountID }
    }

    /// Returns at most one active authorization for each account/key identity.
    /// Duplicate legacy rows are coalesced deterministically by newest update,
    /// then by stable ID, so adding another address cannot create another
    /// account authorization.
    func activeAuthorizations(for accountID: UUID) -> [SSHAuthorization] {
        let grouped = Dictionary(grouping: authorizations.filter {
            $0.accountID == accountID
                && !$0.isDeleted
                && $0.relationState == .active
        }, by: { authorization in
            let fingerprint = authorization.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            return fingerprint.isEmpty ? "key:\(authorization.keyID)" : "fingerprint:\(fingerprint)"
        })
        return grouped.values.compactMap { values in
            values.max {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt < $1.updatedAt }
                return $0.id < $1.id
            }
        }.sorted { $0.id < $1.id }
    }

    func activeAuthorization(
        for accountID: UUID,
        keyID: String,
        fingerprint: String
    ) -> SSHAuthorization? {
        activeAuthorizations(for: accountID).first {
            let storedFingerprint = $0.fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            let requestedFingerprint = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            return !requestedFingerprint.isEmpty && storedFingerprint == requestedFingerprint
                || (storedFingerprint.isEmpty && $0.keyID == keyID)
        }
    }

    func hasActiveAuthorization(
        for accountID: UUID,
        keyID: String,
        fingerprint: String
    ) -> Bool {
        activeAuthorization(for: accountID, keyID: keyID, fingerprint: fingerprint)?.remoteState == .authorized
    }

    /// Decides whether a new address needs a remote write. Authorization is
    /// account-scoped; a profile or endpoint is only the route used to verify
    /// that account's existing relation.
    func authorizationDecision(
        forProfileID profileID: UUID,
        keyID: String,
        fingerprint: String
    ) -> SSHAuthorizationDecision {
        guard let account = account(forProfileID: profileID) else {
            return .installNewAuthorization
        }
        return hasActiveAuthorization(
            for: account.id,
            keyID: keyID,
            fingerprint: fingerprint
        ) ? .verifyExistingAccountAuthorization : .installNewAuthorization
    }

    func latestAccessVerification(
        for accountID: UUID,
        deviceID: String,
        profileID: UUID? = nil
    ) -> AccessVerification? {
        accessVerifications
            .filter {
                $0.accountID == accountID
                    && $0.deviceID == deviceID
                    && (profileID == nil || $0.profileID == profileID)
            }
            .max {
                ($0.detectedAt ?? .distantPast, $0.id) < ($1.detectedAt ?? .distantPast, $1.id)
            }
    }
}
