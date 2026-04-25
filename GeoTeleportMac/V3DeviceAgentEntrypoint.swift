import Darwin
import Foundation

enum V3DeviceAgentEntrypoint {
    static let launchArgument = "--v3-agent"
    static let toolchainProbeSelfCheckArgument = "--v3-self-check-toolchain-probe"
    static let nativeDeviceCoreEnumerationSelfCheckArgument = "--v3-self-check-native-device-core-enumeration"
    static let nativeDeviceCoreDeviceInfoSelfCheckArgument = "--v3-self-check-native-device-core-device-info"
    static let nativeDeviceCoreInjectionSelfCheckArgument = "--v3-self-check-native-device-core-injection"
    static let tunnelLogSelfCheckArgument = "--v3-self-check-tunnel-log-parser"
    static let injectionTransportSelfCheckArgument = "--v3-self-check-injection-transport"
    static let xcodeLocationHarnessSelfCheckArgument = "--v3-self-check-xcode-location-harness"
    static let agentProtocolVersionSelfCheckArgument = "--v3-self-check-agent-protocol-version"

    static func runIfNeeded(
        arguments: [String] = CommandLine.arguments,
        stdin: FileHandle = .standardInput,
        stdout: FileHandle = .standardOutput,
        stderr: FileHandle = .standardError,
        service: DeviceAgentServicing = StubDeviceAgentService()
    ) -> Bool {
        if arguments.contains(toolchainProbeSelfCheckArgument) {
            let report = StubDeviceAgentService.runToolchainProbeSelfCheckReport()
            let status: Int32 = report.contains("\nFAIL ") ? 1 : 0
            let target = status == 0 ? stdout : stderr
            if let data = report.data(using: .utf8) {
                try? target.write(contentsOf: data)
            }
            Darwin.exit(status)
        }

        if arguments.contains(nativeDeviceCoreEnumerationSelfCheckArgument) {
            let report = StubDeviceAgentService.runNativeDeviceCoreEnumerationSelfCheckReport()
            let status: Int32 = report.contains("\nFAIL ") ? 1 : 0
            let target = status == 0 ? stdout : stderr
            if let data = report.data(using: .utf8) {
                try? target.write(contentsOf: data)
            }
            Darwin.exit(status)
        }

        if arguments.contains(nativeDeviceCoreDeviceInfoSelfCheckArgument) {
            let report = StubDeviceAgentService.runNativeDeviceCoreDeviceInfoSelfCheckReport()
            let status: Int32 = report.contains("\nFAIL ") ? 1 : 0
            let target = status == 0 ? stdout : stderr
            if let data = report.data(using: .utf8) {
                try? target.write(contentsOf: data)
            }
            Darwin.exit(status)
        }

        if arguments.contains(nativeDeviceCoreInjectionSelfCheckArgument) {
            let report = StubDeviceAgentService.runNativeDeviceCoreInjectionSelfCheckReport()
            let status: Int32 = report.contains("\nFAIL ") ? 1 : 0
            let target = status == 0 ? stdout : stderr
            if let data = report.data(using: .utf8) {
                try? target.write(contentsOf: data)
            }
            Darwin.exit(status)
        }

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

        if arguments.contains(agentProtocolVersionSelfCheckArgument) {
            let report = StubDeviceAgentService.runAgentProtocolVersionSelfCheckReport()
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
            let request = try decodeRequest(from: inputData, decoder: decoder)
            let response = service.handle(request)
            let responseData = try encoder.encode(response)
            try stdout.write(contentsOf: responseData)
        } catch {
            let failure: DeviceAgentResponse
            switch error {
            case DeviceAgentProtocolCodingError.schemaVersionMismatch(let expected, let got):
                failure = .failure(
                    DeviceAgentFailure.schemaVersionMismatch(expected: expected, got: got)
                )
            default:
                failure = .failure(
                    DeviceAgentFailure(
                        code: .agentUnavailable,
                        message: "Agent entrypoint failed: \(error.localizedDescription)"
                    )
                )
            }
            if let responseData = try? encoder.encode(failure) {
                try? stdout.write(contentsOf: responseData)
            } else {
                let fallback = "Agent entrypoint failed\n".data(using: .utf8) ?? Data()
                try? stderr.write(contentsOf: fallback)
            }
        }

        return true
    }

    private static func decodeRequest(from inputData: Data, decoder: JSONDecoder) throws -> DeviceAgentRequest {
        let object = try JSONSerialization.jsonObject(with: inputData)
        guard let dictionary = object as? [String: Any],
              let schemaVersion = dictionary["schemaVersion"] as? Int else {
            throw DeviceAgentFailure(
                code: .invalidRequest,
                message: "Agent request is missing the protocol schemaVersion field."
            )
        }
        guard schemaVersion == DeviceAgentProtocolVersion.currentSchemaVersion else {
            throw DeviceAgentProtocolCodingError.schemaVersionMismatch(
                expected: DeviceAgentProtocolVersion.currentSchemaVersion,
                got: schemaVersion
            )
        }
        return try decoder.decode(DeviceAgentRequest.self, from: inputData)
    }
}
