import Foundation

public enum RemoteMachineConfigurationParser {
    public static func parse(_ output: String, synchronizedAt: Date = .now) -> RemoteMachineConfiguration? {
        var values: [String: String] = [:]

        for rawLine in output.split(whereSeparator: \Character.isNewline) {
            let fields = rawLine.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            values[String(fields[0])] = String(fields[1]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let hostname = nonEmpty(values["hostname"]),
              let operatingSystem = nonEmpty(values["operating_system"]),
              let kernel = nonEmpty(values["kernel"]),
              let architecture = nonEmpty(values["architecture"]) else { return nil }

        let processorCount = values["processor_count"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        let memoryBytes = values["memory_bytes"].flatMap(UInt64.init).flatMap { $0 > 0 ? $0 : nil }

        return RemoteMachineConfiguration(
            hostname: hostname,
            operatingSystem: operatingSystem,
            kernel: kernel,
            architecture: architecture,
            processorCount: processorCount,
            memoryBytes: memoryBytes,
            synchronizedAt: synchronizedAt
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
