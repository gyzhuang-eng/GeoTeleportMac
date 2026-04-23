import Darwin
import Foundation

enum V3DeviceAgentEntrypoint {
    static let launchArgument = "--v3-agent"
    static let tunnelLogSelfCheckArgument = "--v3-self-check-tunnel-log-parser"
    static let injectionTransportSelfCheckArgument = "--v3-self-check-injection-transport"
    static let xcodeLocationHarnessSelfCheckArgument = "--v3-self-check-xcode-location-harness"

    static func runIfNeeded(
        arguments: [String] = CommandLine.arguments,
        stdin: FileHandle = .standardInput,
        stdout: FileHandle = .standardOutput,
        stderr: FileHandle = .standardError,
        service: DeviceAgentServicing = StubDeviceAgentService()
    ) -> Bool {
        if arguments.contains(tunnelLogSelfCheckArgument) {
            let report = StubDeviceAgentService.runExpectedRSDEndpointSelfCheckReport()
            let status: Int32 = report.contains("\nFAIL ") ? 1 : 0
            let target = status == 0 ? stdout : stderr
            if let data = report.data(using: .utf8) {
                try? target.write(contentsOf: data)
            }
            Darwin.exit(status)
        }

        if arguments.contains(injectionTransportSelfCheckArgument) {
            let report = StubDeviceAgentService.runInjectionTransportSelfCheckReport()
            let status: Int32 = report.contains("\nFAIL ") ? 1 : 0
            let target = status == 0 ? stdout : stderr
            if let data = report.data(using: .utf8) {
                try? target.write(contentsOf: data)
            }
            Darwin.exit(status)
        }

        if arguments.contains(xcodeLocationHarnessSelfCheckArgument) {
            let report = StubDeviceAgentService.runXcodeLocationHarnessSelfCheckReport()
            let status: Int32 = report.contains("\nFAIL ") ? 1 : 0
            let target = status == 0 ? stdout : stderr
            if let data = report.data(using: .utf8) {
                try? target.write(contentsOf: data)
            }
            Darwin.exit(status)
        }

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
