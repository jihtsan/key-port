import Foundation

/// URL / `host:port` assembly for service access (architecture 9.1).
///
/// Pure functions only: no platform singletons, no TLS or trust decisions.
/// HTTPS scheme is preserved verbatim — there is no trust bypass anywhere in
/// this layer; certificate and login handling stay with the external app that
/// opens the URL.
public enum ServiceEndpointFormatter {
    public enum FormattingError: Error, Hashable {
        case emptyHost
        case invalidHost
        case invalidPort
        case invalidPath
        case unsupportedScheme
    }

    public enum HTTPScheme: String, Hashable, Sendable {
        case http
        case https
    }

    /// Loopback literal used for tunnel endpoints. IPv4 only, so a `localhost`
    /// lookup can never resolve to an unlistened IPv6 loopback.
    public static let tunnelLoopback = "127.0.0.1"

    // MARK: - HTTP(S)

    /// Direct access uses the actually selected address. IPv6 literals are
    /// wrapped in brackets before being assigned to `URLComponents.host`.
    public static func directURL(
        scheme: HTTPScheme,
        host: String,
        port: UInt16,
        path: String? = nil
    ) throws -> URL {
        try url(scheme: scheme, host: host, port: port, path: path)
    }

    /// Tunnel access always targets the IPv4 loopback with the local port.
    public static func tunnelURL(
        scheme: HTTPScheme,
        localPort: UInt16,
        path: String? = nil
    ) throws -> URL {
        try url(scheme: scheme, host: tunnelLoopback, port: localPort, path: path)
    }

    // MARK: - TCP host:port

    /// DNS/IPv4 render as `host:port`, IPv6 as `[addr]:port`.
    public static func directHostPort(host: String, port: UInt16) throws -> String {
        let normalized = try normalizedHost(host)
        try validatePort(port)
        if isIPv6Literal(normalized) {
            return "[\(normalized)]:\(port)"
        }
        return "\(normalized):\(port)"
    }

    public static func tunnelHostPort(localPort: UInt16) throws -> String {
        try validatePort(localPort)
        return "\(tunnelLoopback):\(localPort)"
    }

    // MARK: - Internals

    private static func url(scheme: HTTPScheme, host: String, port: UInt16, path: String?) throws -> URL {
        let normalized = try normalizedHost(host)
        try validatePort(port)
        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = isIPv6Literal(normalized) ? "[\(normalized)]" : normalized
        components.port = Int(port)
        if let path {
            components.path = try normalizedPath(path)
        }
        // user/password are never set: user-info is forbidden by contract.
        guard let url = components.url else {
            throw FormattingError.invalidHost
        }
        return url
    }

    private static func normalizedHost(_ host: String) throws -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[") && value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty else { throw FormattingError.emptyHost }
        let isV6 = isIPv6Literal(value)
        // Zone IDs (`%en0`) are out of contract: `%` is rejected for IPv6.
        let forbidden: CharacterSet = isV6
            ? CharacterSet(charactersIn: "/@?#[]% \t\r\n")
            : CharacterSet(charactersIn: "/@?#[]: \t\r\n")
        guard value.rangeOfCharacter(from: forbidden) == nil else {
            throw FormattingError.invalidHost
        }
        guard !isV6 || isPlausibleIPv6(value) else {
            throw FormattingError.invalidHost
        }
        return value
    }

    static func isIPv6Literal(_ host: String) -> Bool {
        host.contains(":")
    }

    private static func isPlausibleIPv6(_ host: String) -> Bool {
        var socketAddress = sockaddr_in6()
        return host.withCString { cString in
            inet_pton(AF_INET6, cString, &socketAddress.sin6_addr)
        } == 1
    }

    private static func validatePort(_ port: UInt16) throws {
        guard port > 0 else { throw FormattingError.invalidPort }
    }

    /// Only normalized absolute paths are accepted: leading `/`, no empty or
    /// dot segments, no query/fragment smuggling.
    private static func normalizedPath(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("//"),
              !path.contains("?"), !path.contains("#") else {
            throw FormattingError.invalidPath
        }
        for segment in path.split(separator: "/", omittingEmptySubsequences: false) where !segment.isEmpty {
            if segment == "." || segment == ".." {
                throw FormattingError.invalidPath
            }
        }
        return path
    }
}
