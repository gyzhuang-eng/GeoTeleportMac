import Foundation

struct LegacyDiagnostics {
    static func humanize(stderr: String, stdout: String, exit: Int32) -> String {
        let combined = (stderr + "\n" + stdout).lowercased()
        if combined.contains("casefold") || combined.contains("tunnelprotocol")
            || (combined.contains("attributeerror") && combined.contains("click")) {
            return "Bundled transport is broken. Reinstall or refresh the legacy device backend."
        }
        if combined.contains("no module named") && combined.contains("pymobiledevice3") {
            return "Legacy device backend is missing required runtime pieces."
        }
        if combined.contains("traceback") && combined.contains("pymobiledevice3") {
            return "Legacy device backend crashed while talking to the device."
        }
        if combined.contains("tunneld") || combined.contains("rsd") || combined.contains("no developer mode") {
            return "The iOS 17+ tunnel is not running."
        }
        if combined.contains("not paired") || combined.contains("pairing") {
            return "Device is not paired. Trust this Mac on the iPhone."
        }
        if combined.contains("permission") || combined.contains("denied") {
            return "Permission denied. Check Developer Mode and pairing."
        }
        if combined.contains("no device") || combined.contains("not connected") {
            return "Device disappeared during injection."
        }

        let first = stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !first.isEmpty {
            return first.count > 120 ? String(first.prefix(117)) + "…" : first
        }
        return "Exit code \(exit)."
    }
}
