import AppKit
import Foundation

enum TunnelLaunchResult: Equatable {
    case launched
    case failed(String)
}

struct V3TunnelLauncher {
    func launchInTerminal(command: String) -> TunnelLaunchResult {
        let escaped = command.replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """

        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&error)
        }

        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "Unknown AppleScript error"
            return .failed(message)
        }
        return .launched
    }

    func copyToPasteboard(_ command: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }
}
