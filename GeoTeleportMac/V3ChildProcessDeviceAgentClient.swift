import Foundation

struct V3ChildProcessDeviceAgentClient: DeviceAgentClient {
    private let executablePath: String?
    private let fallback: DeviceAgentClient
    private let cache: V3DeviceAgentCache
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        executablePath: String? = Bundle.main.executableURL?.path,
        fallback: DeviceAgentClient = LocalJSONDeviceAgentClient(),
        cache: V3DeviceAgentCache = V3DeviceAgentCache()
    ) {
        self.executablePath = executablePath
        self.fallback = fallback
        self.cache = cache
    }

    func probeAvailability() -> Result<DeviceAgentAvailability, DeviceAgentFailure> {
        cache.availability {
            switch send(.probeAvailability) {
            case .success(.availability(let availability)):
                var events = availability.events
                events.insert(
                    DeviceAgentDiagnosticEvent(level: .info, message: "Child-process agent transport active"),
                    at: 0
                )
                return .success(
                    DeviceAgentAvailability(
                        isReachable: availability.isReachable,
                        summary: availability.summary,
                        readinessGate: availability.readinessGate,
                        refreshIntent: availability.refreshIntent,
                        recommendedProbeFocus: availability.recommendedProbeFocus,
                        nextAction: availability.nextAction,
                        blockerCodes: availability.blockerCodes,
                        confidence: availability.confidence,
                        events: events
                    )
                )
            case .success:
                return .failure(DeviceAgentFailure(
                    code: .agentUnavailable,
                    message: "Agent returned the wrong payload for availability."
                ))
            case .failure(let failure):
                return .failure(failure)
            }
        }
    }

    func fetchConnectedDevice() -> Result<DeviceAgentDeviceState, DeviceAgentFailure> {
        cache.deviceState {
            switch send(.fetchConnectedDevice) {
            case .success(.deviceState(let state)):
                return .success(state)
            case .success:
                return .failure(DeviceAgentFailure(
                    code: .agentUnavailable,
                    message: "Agent returned the wrong payload for device discovery."
                ))
            case .failure(let failure):
                return .failure(failure)
            }
        }
    }

    func fetchTunnelState(for device: DeviceSnapshot) -> Result<DeviceAgentTunnelState, DeviceAgentFailure> {
        cache.tunnelState(for: device) {
            switch send(.fetchTunnelState(device)) {
            case .success(.tunnelState(let state)):
                return .success(state)
            case .success:
                return .failure(DeviceAgentFailure(
                    code: .agentUnavailable,
                    message: "Agent returned the wrong payload for tunnel state."
                ))
            case .failure(let failure):
                return .failure(failure)
            }
        }
    }

    func setLocation(_ request: TeleportRequest) -> Result<DeviceAgentTeleportResult, DeviceAgentFailure> {
        switch send(.setLocation(request)) {
        case .success(.teleportResult(let result)):
            return .success(result)
        case .success:
            return .failure(DeviceAgentFailure(
                code: .agentUnavailable,
                message: "Agent returned the wrong payload for location injection."
            ))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func clearLocation() -> Result<DeviceAgentTeleportResult, DeviceAgentFailure> {
        switch send(.clearLocation) {
        case .success(.teleportResult(let result)):
            return .success(result)
        case .success:
            return .failure(DeviceAgentFailure(
                code: .agentUnavailable,
                message: "Agent returned the wrong payload for location clear."
            ))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private func send(_ request: DeviceAgentRequest) -> Result<DeviceAgentSuccessPayload, DeviceAgentFailure> {
        guard let executablePath, !executablePath.isEmpty else {
            return fallbackSend(request, extraMessage: "Executable path unavailable for child-process agent.")
        }

        let task = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = [V3DeviceAgentEntrypoint.launchArgument]
        task.standardInput = stdinPipe
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe
        // Pass user's preferred device UDID (set when multiple devices are connected).
        if case .fetchConnectedDevice = request,
           let preferred = UserDefaults.standard.string(forKey: "v3.selectedDeviceUDID"),
           !preferred.isEmpty {
            var env = ProcessInfo.processInfo.environment
            env["GTM_PREFERRED_DEVICE_UDID"] = preferred
            task.environment = env
        }

        do {
            let requestData = try encoder.encode(request)
            try task.run()
            stdinPipe.fileHandleForWriting.write(requestData)
            try? stdinPipe.fileHandleForWriting.close()
            task.waitUntilExit()

            let responseData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            guard task.terminationStatus == 0 else {
                let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return fallbackSend(
                    request,
                    extraMessage: "Child-process agent exited with code \(task.terminationStatus). \(stderrText)"
                )
            }

            switch decodeResponse(responseData) {
            case .success(let response):
                switch response {
                case .success(let payload):
                    return .success(payload)
                case .failure(let failure):
                    return .failure(failure)
                }
            case .failure(let failure):
                return .failure(failure)
            }
        } catch {
            return fallbackSend(
                request,
                extraMessage: "Child-process agent transport failed: \(error.localizedDescription)"
            )
        }
    }

    private func decodeResponse(_ responseData: Data) -> Result<DeviceAgentResponse, DeviceAgentFailure> {
        do {
            let object = try JSONSerialization.jsonObject(with: responseData)
            guard let dictionary = object as? [String: Any],
                  let schemaVersion = dictionary["schemaVersion"] as? Int else {
                return .failure(
                    DeviceAgentFailure(
                        code: .agentUnavailable,
                        message: "Child-process agent returned a malformed response envelope."
                    )
                )
            }
            guard schemaVersion == DeviceAgentProtocolVersion.currentSchemaVersion else {
                return .failure(
                    DeviceAgentFailure.schemaVersionMismatch(
                        expected: DeviceAgentProtocolVersion.currentSchemaVersion,
                        got: schemaVersion
                    )
                )
            }
            return .success(try decoder.decode(DeviceAgentResponse.self, from: responseData))
        } catch {
            return .failure(
                DeviceAgentFailure(
                    code: .agentUnavailable,
                    message: "Child-process agent returned undecodable JSON: \(error.localizedDescription)"
                )
            )
        }
    }

    private func fallbackSend(
        _ request: DeviceAgentRequest,
        extraMessage: String
    ) -> Result<DeviceAgentSuccessPayload, DeviceAgentFailure> {
        switch request {
        case .probeAvailability:
            return fallback.probeAvailability().map { availability in
                .availability(
                    DeviceAgentAvailability(
                        isReachable: availability.isReachable,
                        summary: availability.summary,
                        readinessGate: availability.readinessGate,
                        refreshIntent: availability.refreshIntent,
                        recommendedProbeFocus: availability.recommendedProbeFocus,
                        nextAction: availability.nextAction,
                        blockerCodes: availability.blockerCodes,
                        confidence: availability.confidence,
                        events: availability.events + [
                            DeviceAgentDiagnosticEvent(level: .warning, message: extraMessage),
                            DeviceAgentDiagnosticEvent(level: .warning, message: "Fell back to in-process agent transport")
                        ]
                    )
                )
            }
        case .fetchConnectedDevice:
            return fallback.fetchConnectedDevice().map(DeviceAgentSuccessPayload.deviceState)
        case .fetchTunnelState(let device):
            return fallback.fetchTunnelState(for: device).map(DeviceAgentSuccessPayload.tunnelState)
        case .setLocation(let request):
            return fallback.setLocation(request).map(DeviceAgentSuccessPayload.teleportResult)
        case .clearLocation:
            return fallback.clearLocation().map(DeviceAgentSuccessPayload.teleportResult)
        }
    }
}
