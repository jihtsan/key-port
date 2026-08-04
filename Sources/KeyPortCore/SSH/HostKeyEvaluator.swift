import Foundation

public enum HostKeyEvaluation: Equatable, Sendable {
    case pending
    case confirmed
    case changed(algorithms: [String])
}

public enum HostKeyEvaluator {
    public static func evaluate(observed: [HostKeyRecord], confirmed: [HostKeyRecord]) -> HostKeyEvaluation {
        guard !confirmed.isEmpty else { return .pending }
        let confirmedByAlgorithm = Dictionary(grouping: confirmed, by: \.algorithm)
        var changed: [String] = []
        var hasUnconfirmedAlgorithm = false
        var matched = false

        for key in observed {
            guard let known = confirmedByAlgorithm[key.algorithm] else {
                hasUnconfirmedAlgorithm = true
                continue
            }
            if known.contains(where: { $0.fingerprint == key.fingerprint }) {
                matched = true
            } else {
                changed.append(key.algorithm)
            }
        }
        if !changed.isEmpty { return .changed(algorithms: changed.sorted()) }
        if hasUnconfirmedAlgorithm { return .pending }
        return matched ? .confirmed : .pending
    }
}
