import Foundation

struct ShellCommandResult: Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum ShellCommandError: Error, Equatable {
    case launchFailed(String)
}

struct ShellCommandRunner {
    func run(_ executable: String, args: [String], environment: [String: String]? = nil) -> Result<ShellCommandResult, ShellCommandError> {
        let task = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        if let environment {
            task.environment = environment
        }

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        return .success(
            ShellCommandResult(
                stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                exitCode: task.terminationStatus
            )
        )
    }
}
