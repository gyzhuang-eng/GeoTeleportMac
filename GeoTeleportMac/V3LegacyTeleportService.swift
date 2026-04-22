import Foundation

struct LegacyTeleportExecutionResult {
    let logLines: [String]
    let status: AppStatus
}

struct V3LegacyTeleportService {
    let backend: DeviceBackend

    func execute(request: TeleportRequest) -> LegacyTeleportExecutionResult {
        switch backend.setLocation(request) {
        case .success(let response):
            var logLines: [String] = []
            logLines.append(response.stdout.isEmpty ? "[STDOUT] (Empty)" : "[STDOUT] >> \(response.stdout)")
            logLines.append(response.stderr.isEmpty ? "[STDERR] (Empty)" : "[STDERR] >> \(response.stderr)")
            logLines.append("[SYS] Process Exited. Code: \(response.exitCode)")

            let stderrLower = response.stderr.lowercased()
            let stdoutLower = response.stdout.lowercased()
            let suspicious = [
                "rsd", "tunneld", "traceback", "exception", "no device",
                "not paired", "permission denied", "connectionrefused",
                "connectionabort", "remoteserviced", "quic"
            ]
            let looksBad = suspicious.contains { stderrLower.contains($0) || stdoutLower.contains($0) }

            if response.exitCode == 0 && !looksBad {
                logLines.append("[RESULT] ✅ SUCCESS: Signal Injected.")
                return LegacyTeleportExecutionResult(
                    logLines: logLines,
                    status: .success("GPS moved", "\(request.latitude), \(request.longitude)")
                )
            }

            if response.exitCode == 0 && looksBad {
                logLines.append("[RESULT] ⚠️ Exit 0 but stderr looks bad — treating as failure.")
                let reason = LegacyDiagnostics.humanize(
                    stderr: response.stderr,
                    stdout: response.stdout,
                    exit: response.exitCode
                )
                return LegacyTeleportExecutionResult(
                    logLines: logLines,
                    status: .failure("Teleport may not have worked", reason)
                )
            }

            logLines.append("[RESULT] ❌ FAILURE: Non-zero exit code.")
            let reason = LegacyDiagnostics.humanize(
                stderr: response.stderr,
                stdout: response.stdout,
                exit: response.exitCode
            )
            return LegacyTeleportExecutionResult(
                logLines: logLines,
                status: .failure("Teleport failed", reason)
            )
        case .failure(let failure):
            let message: String
            switch failure {
            case .unavailable(let value), .invalidRequest(let value), .executionFailed(let value):
                message = value
            }
            return LegacyTeleportExecutionResult(
                logLines: ["[EXCEPTION] \(String(describing: failure))"],
                status: .failure("Teleport failed", message)
            )
        }
    }
}
