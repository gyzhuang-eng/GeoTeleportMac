import Combine
import Foundation

@MainActor
final class V3DiagnosticsStore: ObservableObject {
    @Published var lines: [String]
    let maxLines: Int
    private let repeatWindow: TimeInterval
    private var lastSeenAtByMessage: [String: Date] = [:]

    init(
        maxLines: Int = 500,
        repeatWindow: TimeInterval = 8,
        initialLines: [String] = [
            ">>> KERNEL BOOT SEQUENCE STARTED...",
            ">>> INITIALIZING LOGGING SUBSYSTEM..."
        ]
    ) {
        self.maxLines = maxLines
        self.repeatWindow = repeatWindow
        self.lines = initialLines
    }

    func append(_ message: String) {
        let now = Date()
        if let lastSeenAt = lastSeenAtByMessage[message],
           now.timeIntervalSince(lastSeenAt) < repeatWindow {
            return
        }
        lastSeenAtByMessage[message] = now
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: now)
        let line = "[\(timestamp)] \(message)"
        lines.append(line)
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }

    func append(contentsOf messages: [String]) {
        for message in messages {
            append(message)
        }
    }

    func clear() {
        lines = [">>> LOG CLEARED."]
        lastSeenAtByMessage.removeAll()
    }
}
