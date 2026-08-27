import Foundation

public enum DiscoveryPlatform: String, Codable, CaseIterable, Hashable, Sendable {
    case linux
    case macOS = "macOS"
    case unsupported
}

public enum DiscoveryTool: String, Codable, CaseIterable, Hashable, Sendable {
    case ss
    case lsof
}

public enum DiscoveryTransport: String, Codable, CaseIterable, Hashable, Sendable {
    case tcp
}

public struct DiscoveryLimits: Sendable, Equatable {
    public static let `default` = DiscoveryLimits()

    public let timeout: Duration
    public let maximumOutputBytes: Int
    public let maximumCandidates: Int

    public init(
        timeout: Duration = .seconds(10),
        maximumOutputBytes: Int = 512 * 1024,
        maximumCandidates: Int = 500
    ) {
        self.timeout = timeout
        self.maximumOutputBytes = max(0, maximumOutputBytes)
        self.maximumCandidates = max(0, maximumCandidates)
    }
}

public struct DiscoveryCapabilities: Sendable, Equatable {
    public let platform: DiscoveryPlatform
    public let tools: [DiscoveryTool]

    public init(platform: DiscoveryPlatform, tools: [DiscoveryTool]) {
        self.platform = platform
        self.tools = DiscoveryTool.allCases.filter { tools.contains($0) }
    }

    public var isSupported: Bool {
        platform == .linux || platform == .macOS
    }

    public var canDiscover: Bool {
        preferredTool != nil
    }

    public var preferredTool: DiscoveryTool? {
        switch platform {
        case .linux:
            if tools.contains(.ss) { return .ss }
            if tools.contains(.lsof) { return .lsof }
        case .macOS:
            if tools.contains(.lsof) { return .lsof }
        case .unsupported:
            break
        }
        return nil
    }

    public static func parse(_ output: Data) -> Self {
        var platform: DiscoveryPlatform = .unsupported
        var tools: [DiscoveryTool] = []

        for line in output.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let line = String(bytes: line, encoding: .utf8) else { continue }
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if value == "platform=linux" {
                platform = .linux
            } else if value == "platform=macos" {
                platform = .macOS
            } else if value == "platform=unsupported" {
                platform = .unsupported
            } else if value == "tool=ss" {
                tools.append(.ss)
            } else if value == "tool=lsof" {
                tools.append(.lsof)
            }
        }

        return Self(platform: platform, tools: tools)
    }
}

public struct DiscoveryCandidate: Identifiable, Hashable, Sendable {
    public let transport: DiscoveryTransport
    public let bind: HostV6.ListenerBind
    public let port: UInt16
    public let processHint: String?

    public init(
        transport: DiscoveryTransport = .tcp,
        bind: HostV6.ListenerBind,
        port: UInt16,
        processHint: String? = nil
    ) {
        self.transport = transport
        self.bind = bind
        self.port = port
        self.processHint = processHint
    }

    public var id: String {
        "\(transport.rawValue)|\(Self.bindKey(bind))|\(port)"
    }

    public var listenerBind: HostV6.ListenerBind { bind }
    public var processBasename: String? { processHint }

    private static func bindKey(_ bind: HostV6.ListenerBind) -> String {
        switch bind {
        case .loopbackV4: return "loopback-v4"
        case .loopbackV6: return "loopback-v6"
        case .wildcardV4: return "wildcard-v4"
        case .wildcardV6: return "wildcard-v6"
        case .specific(let address): return "specific-\(address.family.rawValue)-\(address.value)"
        }
    }
}

public struct DiscoveryResult: Sendable, Equatable {
    public let candidates: [DiscoveryCandidate]
    public let warnings: [DiscoveryWarningCode]
    public let partialParseCount: Int
    public let truncated: Bool

    public init(
        candidates: [DiscoveryCandidate],
        warnings: [DiscoveryWarningCode] = [],
        partialParseCount: Int = 0,
        truncated: Bool = false
    ) {
        self.candidates = candidates
        self.warnings = DiscoveryWarningCode.allCases.filter { warnings.contains($0) }
        self.partialParseCount = max(0, partialParseCount)
        self.truncated = truncated
    }

    public var hasWarnings: Bool { !warnings.isEmpty }
}

public enum ListenerDiscoveryParseError: Error, Equatable, Sendable {
    case outputLimitExceeded
    case unsupportedPlatform
    case noValidRecords
}

public typealias DiscoveryParseError = ListenerDiscoveryParseError

public enum ListenerDiscoveryParser {
    public static func parse(
        _ output: Data,
        platform: DiscoveryPlatform,
        limits: DiscoveryLimits = .default
    ) throws -> DiscoveryResult {
        guard output.count <= limits.maximumOutputBytes else {
            throw ListenerDiscoveryParseError.outputLimitExceeded
        }

        switch platform {
        case .linux:
            return try parse(output, tool: .ss, limits: limits)
        case .macOS:
            return try parse(output, tool: .lsof, limits: limits)
        case .unsupported:
            throw ListenerDiscoveryParseError.unsupportedPlatform
        }
    }

    public static func parse(
        _ output: Data,
        platform: DiscoveryPlatform,
        tool: DiscoveryTool,
        limits: DiscoveryLimits = .default
    ) throws -> DiscoveryResult {
        guard platform != .unsupported else {
            throw ListenerDiscoveryParseError.unsupportedPlatform
        }
        guard platform == .linux || tool == .lsof else {
            throw ListenerDiscoveryParseError.unsupportedPlatform
        }
        return try parse(output, tool: tool, limits: limits)
    }

    public static func parse(
        _ output: Data,
        tool: DiscoveryTool,
        limits: DiscoveryLimits = .default
    ) throws -> DiscoveryResult {
        guard output.count <= limits.maximumOutputBytes else {
            throw ListenerDiscoveryParseError.outputLimitExceeded
        }

        switch tool {
        case .ss:
            return try parseLinux(output, limits: limits)
        case .lsof:
            return try parseLsof(output, limits: limits)
        }
    }

    public static func parse(
        _ output: String,
        platform: DiscoveryPlatform,
        limits: DiscoveryLimits = .default
    ) throws -> DiscoveryResult {
        try parse(Data(output.utf8), platform: platform, limits: limits)
    }

    public static func parseLinux(
        _ output: Data,
        limits: DiscoveryLimits = .default
    ) throws -> DiscoveryResult {
        guard output.count <= limits.maximumOutputBytes else {
            throw ListenerDiscoveryParseError.outputLimitExceeded
        }

        var candidates: [DiscoveryCandidate] = []
        var candidateIndexes: [String: Int] = [:]
        var partialParseCount = 0
        var permissionLimited = false
        var containerProxySeen = false
        var sawMeaningfulRecord = false

        for lineBytes in output.split(separator: 0x0A, omittingEmptySubsequences: false) {
            var bytes = Array(lineBytes)
            if bytes.last == 0x0D { bytes.removeLast() }
            guard let line = String(bytes: bytes, encoding: .utf8) else {
                if !bytes.isEmpty { partialParseCount += 1; sawMeaningfulRecord = true }
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            sawMeaningfulRecord = true
            if isLinuxHeader(trimmed) { continue }

            let fields = trimmed.split(whereSeparator: { $0.isWhitespace })
            guard fields.first == "LISTEN" else {
                partialParseCount += 1
                continue
            }

            guard fields.count > 3, let endpoint = parseEndpoint(String(fields[3])) else {
                partialParseCount += 1
                continue
            }

            let processHint = sanitizedProcessHint(inLinuxLine: trimmed)
            if processHint == nil { permissionLimited = true }
            if isContainerProxy(processHint) { containerProxySeen = true }
            append(
                DiscoveryCandidate(bind: endpoint.bind, port: endpoint.port, processHint: processHint),
                to: &candidates,
                indexes: &candidateIndexes
            )
        }

        return try makeResult(
            candidates: candidates,
            partialParseCount: partialParseCount,
            permissionLimited: permissionLimited,
            containerProxySeen: containerProxySeen,
            sawMeaningfulRecord: sawMeaningfulRecord,
            limits: limits
        )
    }

    public static func parseLinux(
        _ output: String,
        limits: DiscoveryLimits = .default
    ) throws -> DiscoveryResult {
        try parseLinux(Data(output.utf8), limits: limits)
    }

    public static func parseMacOS(
        _ output: Data,
        limits: DiscoveryLimits = .default
    ) throws -> DiscoveryResult {
        try parseLsof(output, limits: limits)
    }

    public static func parseLsof(
        _ output: Data,
        limits: DiscoveryLimits = .default
    ) throws -> DiscoveryResult {
        guard output.count <= limits.maximumOutputBytes else {
            throw ListenerDiscoveryParseError.outputLimitExceeded
        }

        var candidates: [DiscoveryCandidate] = []
        var candidateIndexes: [String: Int] = [:]
        var partialParseCount = 0
        var permissionLimited = false
        var containerProxySeen = false
        var sawMeaningfulRecord = false
        var fields: [String] = []

        for fieldBytes in output.split(separator: 0x00, omittingEmptySubsequences: true) {
            let normalizedFieldBytes = fieldBytes.drop(while: { $0 == 0x0A || $0 == 0x0D })
            guard !normalizedFieldBytes.isEmpty else {
                continue
            }
            guard let field = String(bytes: normalizedFieldBytes, encoding: .utf8), !field.isEmpty else {
                partialParseCount += 1
                sawMeaningfulRecord = true
                continue
            }
            sawMeaningfulRecord = true
            if field.first == "p" {
                flushMacOSRecord(
                    fields,
                    candidates: &candidates,
                    indexes: &candidateIndexes,
                    partialParseCount: &partialParseCount,
                    permissionLimited: &permissionLimited,
                    containerProxySeen: &containerProxySeen
                )
                fields = [field]
            } else if fields.isEmpty {
                partialParseCount += 1
            } else {
                fields.append(field)
            }
        }
        flushMacOSRecord(
            fields,
            candidates: &candidates,
            indexes: &candidateIndexes,
            partialParseCount: &partialParseCount,
            permissionLimited: &permissionLimited,
            containerProxySeen: &containerProxySeen
        )

        return try makeResult(
            candidates: candidates,
            partialParseCount: partialParseCount,
            permissionLimited: permissionLimited,
            containerProxySeen: containerProxySeen,
            sawMeaningfulRecord: sawMeaningfulRecord,
            limits: limits
        )
    }

    public static func parseMacOS(
        _ output: String,
        limits: DiscoveryLimits = .default
    ) throws -> DiscoveryResult {
        try parseMacOS(Data(output.utf8), limits: limits)
    }

    private struct ParsedEndpoint {
        let bind: HostV6.ListenerBind
        let port: UInt16
    }

    private static func flushMacOSRecord(
        _ fields: [String],
        candidates: inout [DiscoveryCandidate],
        indexes: inout [String: Int],
        partialParseCount: inout Int,
        permissionLimited: inout Bool,
        containerProxySeen: inout Bool
    ) {
        guard !fields.isEmpty else { return }

        var endpoints: [String] = []
        var process: String?
        var hasState = false
        var isListening = true

        for field in fields {
            guard let tag = field.first else { continue }
            switch tag {
            case "c":
                process = String(field.dropFirst())
            case "n":
                endpoints.append(String(field.dropFirst()))
            case "T":
                hasState = true
                if field.localizedCaseInsensitiveContains("ST=LISTEN") {
                    isListening = true
                } else if field.localizedCaseInsensitiveContains("ST=") {
                    isListening = false
                }
            default:
                break
            }
        }

        guard !hasState || isListening else { return }
        guard !endpoints.isEmpty else {
            partialParseCount += 1
            permissionLimited = true
            return
        }

        let processHint = sanitizedProcessHint(process)
        if processHint == nil { permissionLimited = true }
        if isContainerProxy(processHint) { containerProxySeen = true }

        var parsedAny = false
        for endpointText in endpoints {
            guard let endpoint = parseEndpoint(endpointText) else {
                partialParseCount += 1
                continue
            }
            parsedAny = true
            append(
                DiscoveryCandidate(bind: endpoint.bind, port: endpoint.port, processHint: processHint),
                to: &candidates,
                indexes: &indexes
            )
        }
        if !parsedAny && !endpoints.isEmpty { permissionLimited = true }
    }

    private static func makeResult(
        candidates: [DiscoveryCandidate],
        partialParseCount: Int,
        permissionLimited: Bool,
        containerProxySeen: Bool,
        sawMeaningfulRecord: Bool,
        limits: DiscoveryLimits
    ) throws -> DiscoveryResult {
        guard !candidates.isEmpty || !sawMeaningfulRecord || partialParseCount == 0 else {
            throw ListenerDiscoveryParseError.noValidRecords
        }

        var resultCandidates = candidates
        let truncated = resultCandidates.count > limits.maximumCandidates
        if truncated {
            resultCandidates = Array(resultCandidates.prefix(limits.maximumCandidates))
        }

        var warnings: [DiscoveryWarningCode] = []
        if permissionLimited { warnings.append(.permissionLimited) }
        if partialParseCount > 0 { warnings.append(.partialParse) }
        if truncated { warnings.append(.truncated) }
        if containerProxySeen { warnings.append(.containerMappingNotObservable) }

        return DiscoveryResult(
            candidates: resultCandidates,
            warnings: warnings,
            partialParseCount: partialParseCount,
            truncated: truncated
        )
    }

    private static func append(
        _ candidate: DiscoveryCandidate,
        to candidates: inout [DiscoveryCandidate],
        indexes: inout [String: Int]
    ) {
        if let index = indexes[candidate.id] {
            if candidates[index].processHint == nil, candidate.processHint != nil {
                candidates[index] = candidate
            }
            return
        }
        indexes[candidate.id] = candidates.count
        candidates.append(candidate)
    }

    private static func isLinuxHeader(_ line: String) -> Bool {
        line.localizedCaseInsensitiveCompare("Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process") == .orderedSame
            || line.hasPrefix("Netid ")
    }

    private static func sanitizedProcessHint(inLinuxLine line: String) -> String? {
        guard let users = line.range(of: "users:") else { return nil }
        let suffix = line[users.upperBound...]
        guard let openingQuote = suffix.firstIndex(of: "\"") else { return nil }
        let nameStart = suffix.index(after: openingQuote)
        guard let closingQuote = suffix[nameStart...].firstIndex(of: "\"") else { return nil }
        return sanitizedProcessHint(String(suffix[nameStart..<closingQuote]))
    }

    private static func sanitizedProcessHint(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        guard trimmed.unicodeScalars.allSatisfy({ scalar in
            CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar)
                || scalar == "." || scalar == "_" || scalar == "-"
        }) else { return nil }
        return trimmed
    }

    private static func isContainerProxy(_ processHint: String?) -> Bool {
        guard let processHint else { return false }
        let value = processHint.localizedLowercase
        return value == "docker-proxy" || value == "podman-proxy"
    }

    private static func parseEndpoint(_ text: String) -> ParsedEndpoint? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let arrow = value.range(of: "->") {
            value = String(value[..<arrow.lowerBound])
        }
        guard !value.isEmpty else { return nil }

        let host: String
        let portText: String
        if value.first == "[" {
            guard let closing = value.firstIndex(of: "]") else { return nil }
            host = String(value[value.index(after: value.startIndex)..<closing])
            let suffix = String(value[value.index(after: closing)...])
            guard suffix.first == ":" else { return nil }
            portText = String(suffix.dropFirst())
        } else {
            guard let separator = value.lastIndex(of: ":") else { return nil }
            host = String(value[..<separator])
            portText = String(value[value.index(after: separator)...])
        }

        guard let numericPort = Int(portText), (1...Int(UInt16.max)).contains(numericPort) else {
            return nil
        }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let bind: HostV6.ListenerBind
        switch normalizedHost {
        case "", "*", "0.0.0.0":
            bind = .wildcardV4
        case "127.0.0.1":
            bind = .loopbackV4
        case "::", ":::" , "0:0:0:0:0:0:0:0":
            bind = .wildcardV6
        case "::1", "0:0:0:0:0:0:0:1":
            bind = .loopbackV6
        default:
            let address = normalizedHost.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? normalizedHost
            if isIPv4(address) {
                bind = .specific(HostV6.IPAddress(value: address, family: .v4))
            } else if isIPv6(address) {
                bind = .specific(HostV6.IPAddress(value: address, family: .v6))
            } else {
                return nil
            }
        }
        return ParsedEndpoint(bind: bind, port: UInt16(numericPort))
    }

    private static func isIPv4(_ value: String) -> Bool {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4 else { return false }
        return components.allSatisfy { component in
            guard let number = Int(component), (0...255).contains(number) else { return false }
            return !component.isEmpty
        }
    }

    private static func isIPv6(_ value: String) -> Bool {
        guard value.contains(":") else { return false }
        let doubleColonCount = value.components(separatedBy: "::").count - 1
        guard doubleColonCount <= 1 else { return false }
        let groups = value.replacingOccurrences(of: "::", with: ":").split(separator: ":", omittingEmptySubsequences: true)
        guard !groups.isEmpty, groups.count <= 8 else { return false }
        guard groups.allSatisfy({ group in
            if group.contains(".") { return isIPv4(String(group)) }
            return group.count <= 4 && !group.isEmpty && group.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 48 && scalar.value <= 57)
                    || (scalar.value >= 65 && scalar.value <= 70)
                    || (scalar.value >= 97 && scalar.value <= 102)
            }
        }) else { return false }
        if doubleColonCount == 0 {
            return groups.count == 8 || (groups.count == 7 && groups.last?.contains(".") == true)
        }
        return true
    }
}
