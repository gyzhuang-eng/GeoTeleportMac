import Foundation

enum V3DeviceAgentEntrypoint {
    static let launchArgument = "--v3-agent"

    static func runIfNeeded(
        arguments: [String] = CommandLine.arguments,
        stdin: FileHandle = .standardInput,
        stdout: FileHandle = .standardOutput,
        stderr: FileHandle = .standardError,
        service: DeviceAgentServicing = StubDeviceAgentService()
    ) -> Bool {
        guard arguments.contains(launchArgument) else {
            return false
        }

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        do {
            let inputData = try stdin.readToEnd() ?? Data()
            let request = try decoder.decode(DeviceAgentRequest.self, from: inputData)
            let response = service.handle(request)
            let responseData = try encoder.encode(response)
            try stdout.write(contentsOf: responseData)
        } catch {
            let failure = DeviceAgentResponse.failure(
                DeviceAgentFailure(
                    code: .agentUnavailable,
                    message: "Agent entrypoint failed: \(error.localizedDescription)"
                )
            )
            if let responseData = try? encoder.encode(failure) {
                try? stdout.write(contentsOf: responseData)
            } else {
                let fallback = "Agent entrypoint failed\n".data(using: .utf8) ?? Data()
                try? stderr.write(contentsOf: fallback)
            }
        }

        return true
    }
}
