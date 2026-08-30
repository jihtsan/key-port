import AppKit
import Foundation
import KeyPortCore

enum SSHCommandPresentation {
    static func command(server: ServerConnection, endpoint: Endpoint? = nil) -> String {
        guard let endpoint else {
            return "ssh \(shellQuote(server.alias))"
        }

        return [
            "ssh",
            "-p",
            String(endpoint.port),
            shellQuote("\(server.username)@\(endpoint.address)"),
        ].joined(separator: " ")
    }

    static func terminalURL(server: ServerConnection, endpoint: Endpoint? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = "ssh"

        if let endpoint {
            components.user = server.username
            components.host = endpoint.address
            components.port = Int(endpoint.port)
        } else {
            components.host = server.alias
        }

        return components.url
    }

    private static func shellQuote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safeCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~@:%+=,/")
        )
        if value.unicodeScalars.allSatisfy({ safeCharacters.contains($0) }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

@MainActor
final class TerminalService {
    func open(server: ServerConnection, endpoint: Endpoint? = nil) -> Bool {
        guard let url = SSHCommandPresentation.terminalURL(server: server, endpoint: endpoint) else {
            return false
        }
        return NSWorkspace.shared.open(url)
    }
}
