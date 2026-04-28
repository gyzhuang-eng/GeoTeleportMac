import Foundation

// Reference-type box holding mutable iOS 17+ state for NoPythonBackendStub.
// NoPythonBackendStub is a struct, so mutable cross-call state lives here.
private final class Ios17BackendState {
    // Updated by fetchConnectedDevice; read by setLocation/clearLocation.
    // Accesses happen on background DispatchQueue.global threads; NSLock guards them.
    private let lock = NSLock()
    private var _udid: String?
    private var _major: Int?

    let locationController = NativeDeviceCoreIos17LocationController()

    var udid: String? {
        get { lock.lock(); defer { lock.unlock() }; return _udid }
        set { lock.lock(); defer { lock.unlock() }; _udid = newValue }
    }

    var iosMajor: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _major }
        set { lock.lock(); defer { lock.unlock() }; _major = newValue }
    }

    func update(snapshot: DeviceSnapshot) {
        lock.lock()
        let newUdid = snapshot.deviceIdentifier
        let newMajor = snapshot.iosMajorVersion
        let udidChanged = newUdid != _udid
        _udid = newUdid
        _major = newMajor
        lock.unlock()
        if udidChanged {
            locationController.invalidate()
        }
    }
}

struct NoPythonBackendStub: DeviceBackend {
    let track: BackendTrack = .noPythonStub
    let capabilities = BackendCapabilities(
        canDiscoverDevices: true,
        canObserveTunnel: true,
        canInjectLocation: true
    )
    private let agentClient: DeviceAgentClient
    private let ios17State = Ios17BackendState()

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
            ios17State.update(snapshot: state.snapshot)
            return state.snapshot
        case .failure(let failure):
            let errorSnapshot = DeviceSnapshot(
                isConnected: false,
                connectionSummary: failure.message.uppercased(),
                iosVersion: nil,
                deviceName: nil,
                deviceIdentifier: nil,
                serialSuffix: nil,
                vendorID: nil,
                productID: nil,
                probeSource: "agent-error",
                matchedDeviceCount: 0
            )
            ios17State.update(snapshot: errorSnapshot)
            return errorSnapshot
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

    func setLocation(_ request: TeleportRequest) -> Result<LocationCommandExecution, BackendFailure> {
        if let major = ios17State.iosMajor, major >= 17,
           let udid = ios17State.udid, !udid.isEmpty {
            return ios17LocationResult(
                ios17State.locationController.setLocation(
                    udid: udid,
                    lat: request.latitude,
                    lon: request.longitude
                )
            )
        }
        switch agentClient.setLocation(request) {
        case .success(let result):
            return .success(
                LocationCommandExecution(
                    response: result.response,
                    diagnosticLines: result.events.map(\.logLine)
                )
            )
        case .failure(let failure):
            switch failure.code {
            case .invalidRequest:
                return .failure(.invalidRequest(failure.message))
            case .transportExecutionFailed:
                return .failure(.executionFailed(failure.message))
            case .agentUnavailable, .transportUnimplemented, .unsupportedOperation, .schemaVersionMismatch:
                return .failure(.unavailable(failure.message))
            }
        }
    }

    func clearLocation() -> Result<LocationCommandExecution, BackendFailure> {
        if let major = ios17State.iosMajor, major >= 17,
           let udid = ios17State.udid, !udid.isEmpty {
            return ios17LocationResult(
                ios17State.locationController.clearLocation(udid: udid)
            )
        }
        switch agentClient.clearLocation() {
        case .success(let result):
            return .success(
                LocationCommandExecution(
                    response: result.response,
                    diagnosticLines: result.events.map(\.logLine)
                )
            )
        case .failure(let failure):
            switch failure.code {
            case .invalidRequest:
                return .failure(.invalidRequest(failure.message))
            case .transportExecutionFailed:
                return .failure(.executionFailed(failure.message))
            case .agentUnavailable, .transportUnimplemented, .unsupportedOperation, .schemaVersionMismatch:
                return .failure(.unavailable(failure.message))
            }
        }
    }

    private func ios17LocationResult(
        _ result: Result<DeviceAgentTeleportResult, DeviceAgentFailure>
    ) -> Result<LocationCommandExecution, BackendFailure> {
        switch result {
        case .success(let r):
            return .success(LocationCommandExecution(
                response: r.response,
                diagnosticLines: r.events.map(\.logLine)
            ))
        case .failure(let f):
            switch f.code {
            case .transportExecutionFailed:
                return .failure(.executionFailed(f.message))
            default:
                return .failure(.unavailable(f.message))
            }
        }
    }

    static func bootstrapNextAction(for blockers: [DeviceAgentAssessmentBlockerCode]) -> String {
        if blockers.contains(.xcodeToolchainMissing) {
            return "GeoTeleport cannot start because this build reported a deprecated bootstrap blocker. Refresh the app and export diagnostics if it persists."
        }
        if blockers.contains(.pymobiledevice3Missing) {
            return "GeoTeleport cannot start because this build reported a deprecated bootstrap blocker. Refresh the app and export diagnostics if it persists."
        }
        if blockers.contains(.bundledDeviceCoreMissing) {
            return "GeoTeleport cannot find its bundled device core. Reinstall the app from the DMG and try again."
        }
        return "Attach an iPhone over USB, unlock it, and trust this Mac."
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
            ios17State.update(snapshot: state.snapshot)
            return (state.snapshot, state.assessment, state.events + assessmentEvents)
        case .failure(let failure):
            let errorSnapshot = DeviceSnapshot(
                isConnected: false,
                connectionSummary: failure.message.uppercased(),
                iosVersion: nil,
                deviceName: nil,
                deviceIdentifier: nil,
                serialSuffix: nil,
                vendorID: nil,
                productID: nil,
                probeSource: "agent-error",
                matchedDeviceCount: 0
            )
            ios17State.update(snapshot: errorSnapshot)
            return (
                errorSnapshot,
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
                    DeviceAgentDiagnosticEvent(level: .info, message: "Tunnel endpoint: \($0.tunnelEndpointResult?.summary ?? "None")"),
                    DeviceAgentDiagnosticEvent(level: .info, message: "Injection transport: \($0.injectionTransportProbeResult?.summary ?? "None")"),
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
