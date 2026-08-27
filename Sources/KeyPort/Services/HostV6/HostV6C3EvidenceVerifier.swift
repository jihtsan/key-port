import Foundation
import KeyPortCore
import Security

struct HostV6VerifiedCMSArtifact: Sendable {
    let content: Data
    let signerTeamIdentifier: String
    let signerCertificateSHA256: String
}

enum HostV6CertificateFieldParser {
    static func organizationalUnit(in values: NSDictionary) -> String? {
        guard let property = values[kSecOIDOrganizationalUnitName] else { return nil }
        return propertyStringValue(in: property)
    }

    private static func propertyStringValue(in property: Any) -> String? {
        if let string = property as? String, !string.isEmpty {
            return string
        }
        if let dictionary = property as? NSDictionary {
            guard let value = dictionary[kSecPropertyKeyValue] else { return nil }
            return propertyStringValue(in: value)
        }
        if let array = property as? NSArray {
            for item in array {
                if let value = propertyStringValue(in: item) { return value }
            }
        }
        return nil
    }
}

protocol HostV6CMSArtifactVerifying: Sendable {
    func verify(_ artifact: Data) throws -> HostV6VerifiedCMSArtifact
}

struct HostV6C3EvidenceVerifier: Sendable {
    private let cmsVerifier: any HostV6CMSArtifactVerifying
    private let currentTeamIdentifier: @Sendable () -> String?
    private let currentBuildIdentifier: @Sendable () -> String?

    init(
        cmsVerifier: any HostV6CMSArtifactVerifying = SecurityHostV6CMSArtifactVerifier(),
        currentTeamIdentifier: @escaping @Sendable () -> String? = { CodeSigningInfo.teamIdentifier },
        currentBuildIdentifier: @escaping @Sendable () -> String? = { CodeSigningInfo.uniqueBuildIdentifier }
    ) {
        self.cmsVerifier = cmsVerifier
        self.currentTeamIdentifier = currentTeamIdentifier
        self.currentBuildIdentifier = currentBuildIdentifier
    }

    func verify(_ artifacts: [Data]) throws -> HostV6.AuthorityActivationEvidence {
        guard let expectedTeamIdentifier = currentTeamIdentifier(),
              !expectedTeamIdentifier.isEmpty,
              let expectedBuildIdentifier = currentBuildIdentifier(),
              !expectedBuildIdentifier.isEmpty,
              artifacts.count >= 2 else {
            throw gateFailure()
        }

        let verified = try artifacts.map { artifact -> (
            report: HostV6.AuthorityC3Report,
            digest: String,
            signerCertificateSHA256: String
        ) in
            let signed = try cmsVerifier.verify(artifact)
            guard signed.signerTeamIdentifier == expectedTeamIdentifier else {
                throw gateFailure()
            }
            let report: HostV6.AuthorityC3Report
            do {
                report = try HostV6.CanonicalJSON.decode(
                    HostV6.AuthorityC3Report.self,
                    from: signed.content
                )
            } catch {
                throw gateFailure()
            }
            guard report.schemaVersion == HostV6.AuthorityC3Report.currentSchemaVersion,
                  report.teamIdentifier == expectedTeamIdentifier,
                  !signed.signerCertificateSHA256.isEmpty,
                  report.signerCertificateSHA256 == signed.signerCertificateSHA256,
                  report.completedRequirements == Set(HostV6.AuthorityRequirement.allCases),
                  !report.deviceID.isEmpty,
                  !report.verifiedCloudPayloadHash.isEmpty,
                  !report.cloudChangeTag.isEmpty,
                  report.codeVersion == expectedBuildIdentifier else {
                throw gateFailure()
            }
            return (
                report,
                HostV6.CanonicalJSON.sha256(artifact),
                signed.signerCertificateSHA256
            )
        }

        guard let baseline = verified.first?.report,
              verified.count >= 2,
              Set(verified.map(\.report.deviceID)).count == verified.count,
              Set(verified.map(\.signerCertificateSHA256)).count == verified.count,
              Set(verified.map(\.digest)).count == verified.count,
              verified.allSatisfy({ candidate in
                  candidate.report.completedRequirements == baseline.completedRequirements
                    && candidate.report.acknowledgedDeviceIDs == baseline.acknowledgedDeviceIDs
                    && candidate.report.verifiedCloudPayloadHash == baseline.verifiedCloudPayloadHash
                    && candidate.report.cloudChangeTag == baseline.cloudChangeTag
                    && candidate.report.codeVersion == baseline.codeVersion
              }) else {
            throw gateFailure()
        }

        return HostV6.AuthorityActivationEvidence(
            completedRequirements: baseline.completedRequirements,
            signedDevices: verified.map {
                HostV6.AuthoritySignedDeviceEvidence(
                    deviceID: $0.report.deviceID,
                    signerCertificateSHA256: $0.signerCertificateSHA256,
                    artifactDigest: $0.digest
                )
            },
            acknowledgedDeviceIDs: baseline.acknowledgedDeviceIDs,
            verifiedCloudPayloadHash: baseline.verifiedCloudPayloadHash,
            cloudChangeTag: baseline.cloudChangeTag,
            codeVersion: baseline.codeVersion,
            signerTeamIdentifier: expectedTeamIdentifier
        )
    }

    private func gateFailure() -> HostV6.CloudV2Error {
        .failure(.authorityGateFailed)
    }
}

struct SecurityHostV6CMSArtifactVerifier: HostV6CMSArtifactVerifying {
    func verify(_ artifact: Data) throws -> HostV6VerifiedCMSArtifact {
        guard !artifact.isEmpty else { throw gateFailure() }
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else {
            throw gateFailure()
        }
        let updateStatus = artifact.withUnsafeBytes { bytes in
            CMSDecoderUpdateMessage(decoder, bytes.baseAddress!, bytes.count)
        }
        guard updateStatus == errSecSuccess,
              CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
            throw gateFailure()
        }

        var signerCount = 0
        guard CMSDecoderGetNumSigners(decoder, &signerCount) == errSecSuccess,
              signerCount == 1 else {
            throw gateFailure()
        }
        var signerStatus: CMSSignerStatus = .unsigned
        let policy = SecPolicyCreateBasicX509()
        guard CMSDecoderCopySignerStatus(
            decoder,
            0,
            policy,
            true,
            &signerStatus,
            nil,
            nil
        ) == errSecSuccess,
              signerStatus == .valid else {
            throw gateFailure()
        }

        var certificate: SecCertificate?
        guard CMSDecoderCopySignerCert(decoder, 0, &certificate) == errSecSuccess,
              let certificate,
              let teamIdentifier = organizationalUnit(of: certificate),
              !teamIdentifier.isEmpty else {
            throw gateFailure()
        }
        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess,
              let content else {
            throw gateFailure()
        }
        return HostV6VerifiedCMSArtifact(
            content: content as Data,
            signerTeamIdentifier: teamIdentifier,
            signerCertificateSHA256: HostV6.CanonicalJSON.sha256(
                SecCertificateCopyData(certificate) as Data
            )
        )
    }

    private func organizationalUnit(of certificate: SecCertificate) -> String? {
        let keys = [kSecOIDOrganizationalUnitName] as CFArray
        guard let values = SecCertificateCopyValues(certificate, keys, nil) as NSDictionary?,
              let result = HostV6CertificateFieldParser.organizationalUnit(in: values) else {
            return nil
        }
        return result
    }

    private func gateFailure() -> HostV6.CloudV2Error {
        .failure(.authorityGateFailed)
    }
}
