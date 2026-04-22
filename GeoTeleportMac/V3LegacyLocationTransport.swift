import Foundation

struct V3LegacyLocationTransport {
    private let runner = ShellCommandRunner()
    private let pathResolver: LegacyCLIPathResolving

    init(pathResolver: LegacyCLIPathResolving) {
        self.pathResolver = pathResolver
    }

    func setLocation(_ request: TeleportRequest) -> Result<TeleportResponse, BackendFailure> {
        guard let _ = Double(request.latitude), let _ = Double(request.longitude) else {
            return .failure(.invalidRequest("Invalid coordinates"))
        }
        guard let cliPath = pathResolver.resolvedCLIPath() else {
            return .failure(.unavailable("Legacy device backend path missing"))
        }

        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["PYTHONIOENCODING"] = "utf-8"

        switch runner.run(
            cliPath,
            args: ["developer", "simulate-location", "set", "--", request.latitude, request.longitude],
            environment: env
        ) {
        case .success(let result):
            return .success(
                TeleportResponse(
                    stdout: result.stdout,
                    stderr: result.stderr,
                    exitCode: result.exitCode
                )
            )
        case .failure(let error):
            return .failure(.executionFailed(error.localizedDescription))
        }
    }
}
