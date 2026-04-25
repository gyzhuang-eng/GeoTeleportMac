import Foundation

struct V3TelemetryEvent: Codable {
    enum EventType: String, Codable {
        case deviceCoreFailure
        case ios17DaemonCrash
        case ios17DaemonUnexpectedOutput
        case ios17DaemonTimeout
        case ios17DaemonLaunchFailure
        case ios17DaemonCommandFailure
        case ios17DaemonNoResponse
        case enumFailure
        case deviceInfoFailure
        case injectionFailure
    }

    let timestamp: String
    let type: EventType
    let summary: String
    let exitCode: Int?
    let errorMessage: String
}

final class V3TelemetryStore {
    static let shared = V3TelemetryStore()

    private let maxFileSize: Int = 5 * 1024 * 1024
    private let maxEntries: Int = 500
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let lock = NSLock()

    var isOptedIn: Bool {
        get { UserDefaults.standard.bool(forKey: "v3.telemetryOptIn") }
        set { UserDefaults.standard.set(newValue, forKey: "v3.telemetryOptIn") }
    }

    private var telemetryDirectory: String? {
        guard let base = NSSearchPathForDirectoriesInDomains(
            .applicationSupportDirectory, .userDomainMask, true
        ).first else { return nil }
        let dir = "\(base)/com.test.GeoTeleportMac.v3/telemetry"
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var logFilePath: String? {
        guard let dir = telemetryDirectory else { return nil }
        return "\(dir)/device_core_events.jsonl"
    }

    func record(
        type: V3TelemetryEvent.EventType,
        summary: String,
        exitCode: Int? = nil,
        errorMessage: String = ""
    ) {
        guard isOptedIn else { return }
        guard let path = logFilePath else { return }

        let entry = V3TelemetryEvent(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            type: type,
            summary: sanitize(summary),
            exitCode: exitCode,
            errorMessage: errorMessage
        )

        lock.lock()
        defer { lock.unlock() }

        // Read existing entries
        let existing = readEntriesUnlocked(at: path)

        // Keep only last maxEntries - 1 + the new one
        var entries = Array(existing.suffix(maxEntries - 1))
        entries.append(entry)

        // Write all entries as JSONL
        var output = ""
        for e in entries {
            if let data = try? encoder.encode(e),
               let line = String(data: data, encoding: .utf8) {
                let compact = line.replacingOccurrences(of: "\n", with: " ")
                output += compact + "\n"
            }
        }

        // If the file would exceed maxFileSize, truncate oldest entries
        if output.utf8.count > maxFileSize {
            while output.utf8.count > maxFileSize && entries.count > 1 {
                entries.removeFirst()
                output = ""
                for e in entries {
                    if let data = try? encoder.encode(e),
                       let line = String(data: data, encoding: .utf8) {
                        output += line.replacingOccurrences(of: "\n", with: " ") + "\n"
                    }
                }
            }
        }

        try? output.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func telemetryContent() -> String {
        guard let path = logFilePath else { return "" }
        lock.lock()
        defer { lock.unlock() }
        return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    func hasEntries() -> Bool {
        guard let path = logFilePath else { return false }
        lock.lock()
        defer { lock.unlock() }
        return FileManager.default.fileExists(atPath: path)
            && ((try? String(contentsOfFile: path, encoding: .utf8))?.isEmpty == false)
    }

    func clear() {
        guard let path = logFilePath else { return }
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Private

    private func readEntriesUnlocked(at path: String) -> [V3TelemetryEvent] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return content
            .split(separator: "\n")
            .compactMap { line -> V3TelemetryEvent? in
                guard let data = line.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(V3TelemetryEvent.self, from: data)
            }
    }

    /// Remove PII: no UDIDs, no coordinates, no serial numbers, no device names.
    private func sanitize(_ text: String) -> String {
        var result = text
        // Redact UDIDs (40 hex chars)
        result = result.replacingOccurrences(
            of: "[0-9a-fA-F]{25,40}",
            with: "[UDID]",
            options: .regularExpression
        )
        // Redact coordinates
        result = result.replacingOccurrences(
            of: "-?\\d{1,3}\\.\\d{4,}",
            with: "[COORD]",
            options: .regularExpression
        )
        // Redact serial suffixes
        result = result.replacingOccurrences(
            of: "serial\\s*[0-9A-Za-z]+",
            with: "serial [SERIAL]",
            options: [.regularExpression, .caseInsensitive]
        )
        return result
    }
}
