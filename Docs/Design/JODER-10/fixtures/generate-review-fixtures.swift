#!/usr/bin/env swift

import Foundation

enum FixtureError: Error, CustomStringConvertible {
    case missingOutputDirectory

    var description: String {
        switch self {
        case .missingOutputDirectory:
            return "usage: swift generate-review-fixtures.swift --output-dir <directory>"
        }
    }
}

let arguments = CommandLine.arguments
guard let outputFlag = arguments.firstIndex(of: "--output-dir"),
      arguments.indices.contains(outputFlag + 1),
      !arguments[outputFlag + 1].isEmpty else {
    throw FixtureError.missingOutputDirectory
}

let outputDirectory = URL(fileURLWithPath: arguments[outputFlag + 1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let serverAID = "11111111-1111-4111-8111-111111111111"
let serverBID = "22222222-2222-4222-8222-222222222222"
let deviceID = "device_review_fixture"
let keyID = "key_review_fixture"
let nodeAssociationID = "database-b.review.example"
let timestamp = "2026-08-25T00:00:00Z"
let sharedED25519Blob = "AAAAC3NzaC1lZDI1NTE5AAAAIEdldmlldy1maXh0dXJlLWVkMjU1MTk="
let sharedRSABlob = "AAAAB3NzaC1yc2EAAAADAQABAAABAQCreviewfixture"

func hostKey(algorithm: String, fingerprint: String, line: String) -> [String: Any] {
    [
        "algorithm": algorithm,
        "fingerprint": fingerprint,
        "knownHostsLine": line,
        "firstConfirmedAt": timestamp,
        "lastSeenAt": timestamp
    ]
}

let commonRepeatedLine = "db.example.com ssh-rsa \(sharedRSABlob)"

func serverA() -> [String: Any] {
    [
        "id": serverAID,
        "name": "Database A",
        "host": "DB.EXAMPLE.COM.",
        "port": 22,
        "username": "alice",
        "alias": "db-alice",
        "group": "production",
        "notes": "owner-a-note",
        "confirmedHostKeys": [
            hostKey(
                algorithm: "ssh-ed25519",
                fingerprint: "SHA256:shared-ed25519",
                line: "DB.EXAMPLE.COM. ssh-ed25519 \(sharedED25519Blob)"
            ),
            hostKey(
                algorithm: "ssh-rsa",
                fingerprint: "SHA256:shared-rsa",
                line: commonRepeatedLine
            )
        ],
        "status": "authorized",
        "statusDetail": "legacy-a-authorized",
        "lastCheckedAt": timestamp,
        "passwordCheck": [
            "state": "succeeded",
            "detail": "legacy-a-password-ok",
            "checkedAt": timestamp
        ],
        "keyCheck": [
            "state": "succeeded",
            "detail": "legacy-a-key-ok",
            "checkedAt": timestamp
        ],
        "createdAt": timestamp,
        "updatedAt": timestamp,
        "isDeleted": false,
        "version": 10
    ]
}

func serverB(version: Int, alias: String, isDeleted: Bool, includeNewPin: Bool) -> [String: Any] {
    var keys: [[String: Any]] = [
        hostKey(
            algorithm: "ssh-ed25519",
            fingerprint: "SHA256:shared-ed25519",
            line: "db.example.com ssh-ed25519 \(sharedED25519Blob)"
        ),
        hostKey(
            algorithm: "ssh-rsa",
            fingerprint: "SHA256:shared-rsa",
            line: commonRepeatedLine
        )
    ]
    if includeNewPin {
        keys.append(hostKey(
            algorithm: "ecdsa-sha2-nistp256",
            fingerprint: "SHA256:b-version-2",
            line: "db.example.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXJldmlldy1maXh0dXJl"
        ))
    }

    return [
        "id": serverBID,
        "name": version == 1 ? "Database B" : "Database B updated",
        "host": "db.example.com",
        "port": 22,
        "username": "bob",
        "alias": alias,
        "group": "production",
        "notes": "owner-b-note-v\(version)",
        "confirmedHostKeys": keys,
        "status": version == 1 ? "keyAuthenticationFailed" : "authorized",
        "statusDetail": version == 1 ? "legacy-b-key-failed" : "legacy-b-authorized",
        "lastCheckedAt": timestamp,
        "passwordCheck": [
            "state": "succeeded",
            "detail": "legacy-b-password-ok",
            "checkedAt": timestamp
        ],
        "keyCheck": [
            "state": version == 1 ? "failed" : "succeeded",
            "detail": version == 1 ? "legacy-b-key-failed" : "legacy-b-key-ok",
            "checkedAt": timestamp
        ],
        "createdAt": timestamp,
        "updatedAt": "2026-08-25T00:00:0\(min(version, 9))Z",
        "isDeleted": isDeleted,
        "version": version
    ]
}

func auditEvents() -> [[String: Any]] {
    (1...1_000).map { index in
        [
            "id": String(format: "aaaaaaaa-aaaa-4aaa-8aaa-%012d", index),
            "timestamp": timestamp,
            "category": "review-fixture",
            "action": "event-\(index)",
            "targetID": index.isMultiple(of: 2) ? serverAID : serverBID,
            "result": "stable-code-\(index)",
            "level": index.isMultiple(of: 10) ? "warning" : "info"
        ]
    }
}

func snapshot(serverB: [String: Any]) -> [String: Any] {
    [
        "schemaVersion": 5,
        "servers": [serverA(), serverB],
        "devices": [[
            "id": deviceID,
            "name": "Review Mac",
            "isCurrent": true,
            "registeredAt": timestamp,
            "lastActiveAt": timestamp,
            "isRevoked": false
        ]],
        "keys": [[
            "id": keyID,
            "deviceID": deviceID,
            "kind": "ed25519",
            "publicKey": "ssh-ed25519 \(sharedED25519Blob) keyport:v1:\(keyID):review-mac",
            "fingerprint": "SHA256:device-key",
            "privateKeyPath": "/fixture-only/.ssh/keyport/identities/\(keyID)",
            "isInAgent": true,
            "origin": "generated",
            "isLocallyAvailable": true
        ]],
        "authorizations": [[
            "serverID": serverBID,
            "keyID": keyID,
            "fingerprint": "SHA256:device-key",
            "remoteComment": "keyport:v1:\(keyID):review-mac",
            "status": "authorized",
            "authorizedAt": timestamp,
            "lastVerifiedAt": timestamp,
            "updatedAt": timestamp,
            "isDeleted": false,
            "version": 1
        ]],
        "auditEvents": auditEvents(),
        "nodeAssociations": [[
            "testCaseNodeID": nodeAssociationID,
            "serverID": serverBID,
            "target": [
                "provider": "tailscale",
                "tailnetKey": "review.example",
                "nodeID": "node-review-database-b"
            ],
            "state": "linked",
            "method": "manual",
            "autoLinkEnabled": true,
            "evidenceKinds": ["exact_magicdns"],
            "reasonCodes": [],
            "confirmedAt": timestamp,
            "lastVerifiedAt": timestamp,
            "updatedAt": timestamp,
            "revision": 1
        ]]
    ]
}

func writeJSON(_ object: Any, named filename: String) throws {
    var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    data.append(0x0A)
    try data.write(to: outputDirectory.appendingPathComponent(filename), options: .atomic)
}

try writeJSON(
    snapshot(serverB: serverB(version: 1, alias: "db-bob", isDeleted: false, includeNewPin: false)),
    named: "v5-a10-b1.json"
)
try writeJSON(
    snapshot(serverB: serverB(version: 2, alias: "db-bob-v2", isDeleted: false, includeNewPin: true)),
    named: "v5-a10-b2.json"
)
try writeJSON(
    snapshot(serverB: serverB(version: 3, alias: "db-bob-v2", isDeleted: true, includeNewPin: true)),
    named: "v5-a10-b3-deleted.json"
)

try writeJSON([
    "format": "JODER-10-review-fixtures-v1",
    "files": ["v5-a10-b1.json", "v5-a10-b2.json", "v5-a10-b3-deleted.json"],
    "expected": [
        "serverCount": 2,
        "normalizedHostCount": 1,
        "normalizedAddressCount": 1,
        "identityCount": 2,
        "deviceCount": 1,
        "keyCount": 1,
        "authorizationCount": 1,
        "nodeAssociationCount": 1,
        "auditEventCount": 1_000,
        "a10b1LogicalPinCount": 2,
        "a10b1KnownHostsLineProvenanceCount": 4,
        "a10b1UniqueRenderedKnownHostsLineCount": 3
    ]
], named: "manifest.json")

print(outputDirectory.path)
