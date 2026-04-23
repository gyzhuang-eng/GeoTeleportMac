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
    func run(
        _ executable: String,
        args: [String],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil
    ) -> Result<ShellCommandResult, ShellCommandError> {
        let task = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let readGroup = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()

        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        if let environment {
            task.environment = environment
        }
        if let workingDirectory, !workingDirectory.isEmpty {
            task.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        do {
            readGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { readGroup.leave() }
                stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            }
            readGroup.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { readGroup.leave() }
                stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            }
            try task.run()
            task.waitUntilExit()
            readGroup.wait()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }

        let stdout = String(
            data: stdoutData,
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrData,
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
