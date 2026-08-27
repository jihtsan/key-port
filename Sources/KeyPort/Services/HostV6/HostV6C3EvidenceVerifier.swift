import Foundation
import KeyPortCore
import Security

struct HostV6VerifiedCMSArtifact: Sendable {
    let content: Data
    let signerTeamIdentifier: String
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

    init(
        cmsVerifier: any HostV6CMSArtifactVerifying = SecurityHostV6CMSArtifactVerifier(),
        currentTeamIdentifier: @escaping @Sendable () -> String? = { CodeSigningInfo.teamIdentifier }
    ) {
        self.cmsVerifier = cmsVerifier
        self.currentTeamIdentifier = currentTeamIdentifier
    }

    func verify(_ artifacts: [Data]) throws -> HostV6.AuthorityActivationEvidence {
        guard let expectedTeamIdentifier = currentTeamIdentifier(),
              !expectedTeamIdentifier.isEmpty,
              artifacts.count >= 2 else {
            throw gateFailure()
        }

        let verified = try artifacts.map { artifact -> (
            report: HostV6.AuthorityC3Report,
            digest: String
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
                  report.completedRequirements == Set(HostV6.AuthorityRequirement.allCases),
                  !report.deviceID.isEmpty,
                  !report.verifiedCloudPayloadHash.isEmpty,
                  !report.cloudChangeTag.isEmpty,
                  !report.codeVersion.isEmpty else {
                throw gateFailure()
            }
            return (report, HostV6.CanonicalJSON.sha256(artifact))
        }

        guard let baseline = verified.first?.report,
              Set(verified.map(\.report.deviceID)).count >= 2,
              Set(verified.map(\.digest)).count >= 2,
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
            signedMacDeviceIDs: verified.map(\.report.deviceID),
            acknowledgedDeviceIDs: baseline.acknowledgedDeviceIDs,
            verifiedCloudPayloadHash: baseline.verifiedCloudPayloadHash,
            cloudChangeTag: baseline.cloudChangeTag,
            codeVersion: baseline.codeVersion,
            signerTeamIdentifier: expectedTeamIdentifier,
            signedArtifactDigests: verified.map(\.digest)
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
            signerTeamIdentifier: teamIdentifier
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
