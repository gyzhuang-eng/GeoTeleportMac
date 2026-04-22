import Foundation

enum DeviceAgentRequest: Codable, Equatable {
    case probeAvailability
    case fetchConnectedDevice
    case fetchTunnelState(DeviceSnapshot)
    case setLocation(TeleportRequest)

    private enum CodingKeys: String, CodingKey {
        case kind
        case deviceSnapshot
        case teleportRequest
    }

    private enum Kind: String, Codable {
        case probeAvailability
        case fetchConnectedDevice
        case fetchTunnelState
        case setLocation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .probeAvailability:
            self = .probeAvailability
        case .fetchConnectedDevice:
            self = .fetchConnectedDevice
        case .fetchTunnelState:
            self = .fetchTunnelState(try container.decode(DeviceSnapshot.self, forKey: .deviceSnapshot))
        case .setLocation:
            self = .setLocation(try container.decode(TeleportRequest.self, forKey: .teleportRequest))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .probeAvailability:
            try container.encode(Kind.probeAvailability, forKey: .kind)
        case .fetchConnectedDevice:
            try container.encode(Kind.fetchConnectedDevice, forKey: .kind)
        case .fetchTunnelState(let snapshot):
            try container.encode(Kind.fetchTunnelState, forKey: .kind)
            try container.encode(snapshot, forKey: .deviceSnapshot)
        case .setLocation(let request):
            try container.encode(Kind.setLocation, forKey: .kind)
            try container.encode(request, forKey: .teleportRequest)
        }
    }
}

enum DeviceAgentSuccessPayload: Codable, Equatable {
    case availability(DeviceAgentAvailability)
    case deviceState(DeviceAgentDeviceState)
    case tunnelState(DeviceAgentTunnelState)
    case teleportResult(DeviceAgentTeleportResult)

    private enum CodingKeys: String, CodingKey {
        case kind
        case availability
        case deviceState
        case tunnelState
        case teleportResult
    }

    private enum Kind: String, Codable {
        case availability
        case deviceState
        case tunnelState
        case teleportResult
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .availability:
            self = .availability(try container.decode(DeviceAgentAvailability.self, forKey: .availability))
        case .deviceState:
            self = .deviceState(try container.decode(DeviceAgentDeviceState.self, forKey: .deviceState))
        case .tunnelState:
            self = .tunnelState(try container.decode(DeviceAgentTunnelState.self, forKey: .tunnelState))
        case .teleportResult:
            self = .teleportResult(try container.decode(DeviceAgentTeleportResult.self, forKey: .teleportResult))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .availability(let value):
            try container.encode(Kind.availability, forKey: .kind)
            try container.encode(value, forKey: .availability)
        case .deviceState(let value):
            try container.encode(Kind.deviceState, forKey: .kind)
            try container.encode(value, forKey: .deviceState)
        case .tunnelState(let value):
            try container.encode(Kind.tunnelState, forKey: .kind)
            try container.encode(value, forKey: .tunnelState)
        case .teleportResult(let value):
            try container.encode(Kind.teleportResult, forKey: .kind)
            try container.encode(value, forKey: .teleportResult)
        }
    }
}

enum DeviceAgentResponse: Codable, Equatable {
    case success(DeviceAgentSuccessPayload)
    case failure(DeviceAgentFailure)

    private enum CodingKeys: String, CodingKey {
        case kind
        case success
        case failure
    }

    private enum Kind: String, Codable {
        case success
        case failure
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .success:
            self = .success(try container.decode(DeviceAgentSuccessPayload.self, forKey: .success))
        case .failure:
            self = .failure(try container.decode(DeviceAgentFailure.self, forKey: .failure))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let payload):
            try container.encode(Kind.success, forKey: .kind)
            try container.encode(payload, forKey: .success)
        case .failure(let failure):
            try container.encode(Kind.failure, forKey: .kind)
            try container.encode(failure, forKey: .failure)
        }
    }
}
