import Foundation
import KeyPortCore
import OSLog

struct AuditLogService: Sendable {
    private let logger = Logger(subsystem: "com.jihtsan.KeyPort", category: "Audit")

    func event(category: String, action: String, targetID: String?, result: String, level: AuditEvent.Level = .info) -> AuditEvent {
        let event = AuditEvent(category: category, action: action, targetID: targetID, result: result, level: level)
        switch level {
        case .info:
            logger.info("\(category, privacy: .public).\(action, privacy: .public) result=\(result, privacy: .public) target=\(targetID ?? "none", privacy: .public)")
        case .warning:
            logger.warning("\(category, privacy: .public).\(action, privacy: .public) result=\(result, privacy: .public) target=\(targetID ?? "none", privacy: .public)")
        case .error:
            logger.error("\(category, privacy: .public).\(action, privacy: .public) result=\(result, privacy: .public) target=\(targetID ?? "none", privacy: .public)")
        }
        return event
    }
}
