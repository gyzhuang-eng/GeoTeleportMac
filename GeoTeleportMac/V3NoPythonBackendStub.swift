import Foundation

struct NoPythonBackendStub: DeviceBackend {
    let track: BackendTrack = .noPythonStub
    let capabilities = BackendCapabilities(
        canDiscoverDevices: true,
        canObserveTunnel: true,
        canInjectLocation: false
    )
    private let agentClient: DeviceAgentClient

    init(agentClient: DeviceAgentClient = V3ChildProcessDeviceAgentClient()) {
        self.agentClient = agentClient
    }

    func probeAvailability() -> BackendAvailability {
        switch agentClient.probeAvailability() {
        case .success(let availability):
            return .partial(availability.summary)
        case .failure(let failure):
            return .unavailable(failure.message)
        }
    }

    func fetchConnectedDevice() -> DeviceSnapshot {
        switch agentClient.fetchConnectedDevice() {
        case .success(let state):
            return state.snapshot
        case .failure(let failure):
            return DeviceSnapshot(
                isConnected: false,
                connectionSummary: failure.message.uppercased(),
                iosVersion: nil,
                deviceName: nil,
                serialSuffix: nil,
                vendorID: nil,
                productID: nil,
                probeSource: "agent-error",
                matchedDeviceCount: 0
            )
        }
    }

    func fetchTunnelState(for device: DeviceSnapshot) -> TunnelState {
        switch agentClient.fetchTunnelState(for: device) {
        case .success(let state):
            return state.tunnelState
        case .failure:
            return .notRequired
        }
    }

    func setLocation(_ request: TeleportRequest) -> Result<TeleportResponse, BackendFailure> {
        switch agentClient.setLocation(request) {
        case .success(let result):
            return .success(result.response)
        case .failure(let failure):
            return .failure(.unavailable(failure.message))
        }
    }

    func availabilityEvents() -> [DeviceAgentDiagnosticEvent] {
        availabilityProbe().events
    }

    func deviceEvents() -> [DeviceAgentDiagnosticEvent] {
        deviceProbe().events
    }

    func tunnelEvents(for device: DeviceSnapshot) -> [DeviceAgentDiagnosticEvent] {
        tunnelProbe(for: device).events
    }

    func availabilityProbe() -> (
        availability: BackendAvailability,
        assessment: DeviceAgentAvailability?,
        events: [DeviceAgentDiagnosticEvent]
    ) {
        switch agentClient.probeAvailability() {
        case .success(let availability):
            let assessmentEvents = [
                DeviceAgentDiagnosticEvent(level: .info, message: "Bootstrap gate: \(availability.readinessGate.title)"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Bootstrap intent: \(availability.refreshIntent.map { "\($0.scope.title) / \($0.probeFocus?.title ?? "No Focus")" } ?? "None")"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Bootstrap focus: \(availability.recommendedProbeFocus?.title ?? "None")"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Bootstrap next action: \(availability.nextAction)"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Bootstrap confidence: \(availability.confidence)")
            ] + availability.blockerCodes.map { blocker in
                DeviceAgentDiagnosticEvent(level: .warning, message: "Bootstrap blocker: \(blocker.title)")
            }
            return (.partial(availability.summary), availability, availability.events + assessmentEvents)
        case .failure(let failure):
            return (
                .unavailable(failure.message),
                nil,
                [DeviceAgentDiagnosticEvent(level: .error, message: failure.message)]
            )
        }
    }

    func deviceProbe() -> (
        snapshot: DeviceSnapshot,
        assessment: DeviceAgentSessionAssessment?,
        events: [DeviceAgentDiagnosticEvent]
    ) {
        switch agentClient.fetchConnectedDevice() {
        case .success(let state):
            let assessmentEvents = [
                DeviceAgentDiagnosticEvent(level: .info, message: "Readiness gate: \(state.assessment.readinessGate.title)"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Refresh intent: \(state.assessment.refreshIntent.map { "\($0.scope.title) / \($0.probeFocus?.title ?? "No Focus")" } ?? "None")"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Probe focus: \(state.assessment.recommendedProbeFocus?.title ?? "None")"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Device-info stage: \(state.assessment.deviceInfoReadiness?.title ?? "None")"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Device-info transport: \(state.assessment.deviceInfoTransportState?.title ?? "None")"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Device-info slot: \(state.assessment.deviceInfoTransportProbeResult?.transportID ?? "None")"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Device-info probe result: \(state.assessment.deviceInfoTransportProbeResult?.summary ?? "None")"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Device-info contract: \(state.assessment.deviceInfoTransportContract?.contractID ?? "None")"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Typed metadata result: \(state.assessment.typedMetadataResult?.summary ?? "None")"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Typed metadata artifact: \(state.assessment.typedMetadataResult?.artifact?.artifactID ?? "None")"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Typed metadata session: \(state.assessment.typedMetadataSession?.sessionID ?? "None")"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Session readiness: \(state.assessment.readinessSummary)"),
                DeviceAgentDiagnosticEvent(level: .info, message: "Next action: \(state.assessment.nextAction)")
            ] + state.assessment.blockers.map { blocker in
                DeviceAgentDiagnosticEvent(level: .warning, message: "Session blocker: \(blocker)")
            } + [
                DeviceAgentDiagnosticEvent(level: .info, message: "Assessment confidence: \(state.assessment.confidence)")
            ]
            return (state.snapshot, state.assessment, state.events + assessmentEvents)
        case .failure(let failure):
            return (
                DeviceSnapshot(
                    isConnected: false,
                    connectionSummary: failure.message.uppercased(),
                    iosVersion: nil,
                    deviceName: nil,
                    serialSuffix: nil,
                    vendorID: nil,
                    productID: nil,
                    probeSource: "agent-error",
                    matchedDeviceCount: 0
                ),
                nil,
                [
                    DeviceAgentDiagnosticEvent(level: .warning, message: failure.message),
                    DeviceAgentDiagnosticEvent(level: .warning, message: "Agent session assessment unavailable because device probe failed")
                ]
            )
        }
    }

    func tunnelProbe(for device: DeviceSnapshot) -> (
        tunnelState: TunnelState,
        assessment: DeviceAgentSessionAssessment?,
        events: [DeviceAgentDiagnosticEvent]
    ) {
        switch agentClient.fetchTunnelState(for: device) {
        case .success(let state):
            let assessmentEvents = state.assessment.map {
                [
                    DeviceAgentDiagnosticEvent(level: .info, message: "Tunnel gate: \($0.readinessGate.title)"),
                    DeviceAgentDiagnosticEvent(level: .info, message: "Tunnel intent: \($0.refreshIntent.map { "\($0.scope.title) / \($0.probeFocus?.title ?? "No Focus")" } ?? "None")"),
                    DeviceAgentDiagnosticEvent(level: .info, message: "Tunnel readiness: \($0.readinessSummary)"),
                    DeviceAgentDiagnosticEvent(level: .info, message: "Tunnel requirement: \($0.tunnelRequirementResult?.summary ?? "None")"),
                    DeviceAgentDiagnosticEvent(level: .info, message: "Tunnel lifecycle: \($0.tunnelLifecycleResult?.summary ?? "None")"),
                    DeviceAgentDiagnosticEvent(level: .info, message: "Tunnel session: \($0.tunnelSession?.summary ?? "None")"),
                    DeviceAgentDiagnosticEvent(level: .info, message: "Tunnel health: \($0.tunnelHealthResult?.summary ?? "None")"),
                    DeviceAgentDiagnosticEvent(level: .info, message: "Tunnel next action: \($0.nextAction)"),
                    DeviceAgentDiagnosticEvent(level: .info, message: "Tunnel confidence: \($0.confidence)")
                ] + $0.blockers.map { blocker in
                    DeviceAgentDiagnosticEvent(level: .warning, message: "Tunnel blocker: \(blocker)")
                }
            } ?? []
            return (state.tunnelState, state.assessment, state.events + assessmentEvents)
        case .failure(let failure):
            return (
                .notRequired,
                nil,
                [DeviceAgentDiagnosticEvent(level: .warning, message: failure.message)]
            )
        }
    }
}
