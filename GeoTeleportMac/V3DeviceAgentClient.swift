import Foundation

protocol DeviceAgentClient {
    func probeAvailability() -> Result<DeviceAgentAvailability, DeviceAgentFailure>
    func fetchConnectedDevice() -> Result<DeviceAgentDeviceState, DeviceAgentFailure>
    func fetchTunnelState(for device: DeviceSnapshot) -> Result<DeviceAgentTunnelState, DeviceAgentFailure>
    func setLocation(_ request: TeleportRequest) -> Result<DeviceAgentTeleportResult, DeviceAgentFailure>
    func clearLocation() -> Result<DeviceAgentTeleportResult, DeviceAgentFailure>
}

struct LocalJSONDeviceAgentClient: DeviceAgentClient {
    private let service: DeviceAgentServicing
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(service: DeviceAgentServicing = StubDeviceAgentService()) {
        self.service = service
    }

    func probeAvailability() -> Result<DeviceAgentAvailability, DeviceAgentFailure> {
        switch send(.probeAvailability) {
        case .success(.availability(let availability)):
            return .success(availability)
        case .success:
            return .failure(DeviceAgentFailure(
                code: .agentUnavailable,
                message: "Agent returned the wrong payload for availability."
            ))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func fetchConnectedDevice() -> Result<DeviceAgentDeviceState, DeviceAgentFailure> {
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

    func fetchTunnelState(for device: DeviceSnapshot) -> Result<DeviceAgentTunnelState, DeviceAgentFailure> {
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
        do {
            let requestData = try encoder.encode(request)
            let decodedRequest = try decoder.decode(DeviceAgentRequest.self, from: requestData)
            let response = service.handle(decodedRequest)
            let responseData = try encoder.encode(response)
            let decodedResponse = try decoder.decode(DeviceAgentResponse.self, from: responseData)
            switch decodedResponse {
            case .success(let payload):
                return .success(payload)
            case .failure(let failure):
                return .failure(failure)
            }
        } catch {
            return .failure(
                DeviceAgentFailure(
                    code: .agentUnavailable,
                    message: "Failed to encode/decode the local device-agent protocol: \(error.localizedDescription)"
                )
            )
        }
    }
}
