import Combine
import Foundation

struct DiagnosticEntry: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

@MainActor
final class V3DiagnosticsStore: ObservableObject {
    @Published var entries: [DiagnosticEntry] = []
    var lines: [String] { entries.map(\.text) }

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
        self.entries = initialLines.map { DiagnosticEntry(text: $0) }
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
        entries.append(DiagnosticEntry(text: line))
        if entries.count > maxLines {
            entries.removeFirst(entries.count - maxLines)
        }
    }

    func append(contentsOf messages: [String]) {
        for message in messages {
            append(message)
        }
    }

    func clear() {
        entries = [DiagnosticEntry(text: ">>> LOG CLEARED.")]
        lastSeenAtByMessage.removeAll()
    }
}
