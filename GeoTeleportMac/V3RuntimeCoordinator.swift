import Foundation

struct DependencyRefreshResult {
    let availability: BackendAvailability
    let capabilities: BackendCapabilities
    let availabilityAssessment: DeviceAgentAvailability?
    let logLines: [String]

    var backendIsReady: Bool {
        availability.isReady
    }

    var canRefreshDeviceState: Bool {
        availability.canRefreshDeviceState
    }
}

struct DeviceRefreshResult {
    let snapshot: DeviceSnapshot
    let tunnelState: TunnelState
    let deviceAssessment: DeviceAgentSessionAssessment?
    let tunnelAssessment: DeviceAgentSessionAssessment?
    let logLines: [String]
}

enum SessionRefreshScope {
    case deviceOnly
    case tunnelOnly
    case full

    var label: String {
        switch self {
        case .deviceOnly:
            return "device probe"
        case .tunnelOnly:
            return "tunnel probe"
        case .full:
            return "full probe"
        }
    }
}

enum DeviceProbeFocus {
    case attachment
    case selection
    case deviceInfo

    var label: String {
        switch self {
        case .attachment:
            return "attachment"
        case .selection:
            return "selection"
        case .deviceInfo:
            return "device-info"
        }
    }

    var title: String {
        switch self {
        case .attachment:
            return "Attachment"
        case .selection:
            return "Selection"
        case .deviceInfo:
            return "Device Info"
        }
    }
}

struct V3RuntimeCoordinator {
    let backend: DeviceBackend

    func refreshDependencies() -> DependencyRefreshResult {
        let availability = backend.probeAvailability()

        var logLines: [String] = [
            "------------------------------------------",
            "[INIT] Starting backend probe...",
            "[BACKEND] Track: \(backend.track.displayName)",
            "[BACKEND] Capabilities: \(backend.capabilities.summary)"
        ]

        logLines.append("[BACKEND] Device-agent runtime selected")
        if let noPythonBackend = backend as? NoPythonBackendStub {
            let probe = noPythonBackend.availabilityProbe()
            if let summary = probe.availability.summary, !summary.isEmpty {
                logLines.append("[BACKEND] \(summary)")
            }
            if let assessment = probe.assessment {
                logLines.append("[BACKEND] Bootstrap gate: \(assessment.readinessGate.title)")
                logLines.append("[BACKEND] Bootstrap next: \(assessment.nextAction)")
                logLines.append("[BACKEND] Bootstrap confidence: \(assessment.confidence.uppercased())")
            }
            logLines.append(contentsOf: probe.events.map(\.logLine))
        }

        return DependencyRefreshResult(
            availability: availability,
            capabilities: backend.capabilities,
            availabilityAssessment: (backend as? NoPythonBackendStub)?.availabilityProbe().assessment,
            logLines: logLines
        )
    }

    func refreshDeviceState() -> DeviceRefreshResult {
        refreshDeviceState(
            scope: .full,
            existingSnapshot: nil,
            existingDeviceAssessment: nil,
            existingTunnelState: nil,
            existingTunnelAssessment: nil
        )
    }

    func refreshDeviceState(
        scope: SessionRefreshScope,
        deviceFocus: DeviceProbeFocus = .attachment,
        existingSnapshot: DeviceSnapshot?,
        existingDeviceAssessment: DeviceAgentSessionAssessment?,
        existingTunnelState: TunnelState?,
        existingTunnelAssessment: DeviceAgentSessionAssessment?
    ) -> DeviceRefreshResult {
        if let noPythonBackend = backend as? NoPythonBackendStub {
            switch scope {
            case .deviceOnly:
                let deviceProbe = noPythonBackend.deviceProbe()
                let actualFocus = deviceProbe.assessment?.recommendedProbeFocus.map(V3AppModel.mapProbeFocus) ?? deviceFocus
                return DeviceRefreshResult(
                    snapshot: deviceProbe.snapshot,
                    tunnelState: existingTunnelState ?? .notRequired,
                    deviceAssessment: deviceProbe.assessment,
                    tunnelAssessment: existingTunnelAssessment,
                    logLines: ["[REFRESH] Running \(actualFocus.label) device probe."] + deviceProbe.events.map(\.logLine)
                )
            case .tunnelOnly:
                guard let existingSnapshot, existingSnapshot.isConnected else {
                    let deviceProbe = noPythonBackend.deviceProbe()
                    let actualFocus = deviceProbe.assessment?.recommendedProbeFocus.map(V3AppModel.mapProbeFocus) ?? deviceFocus
                    return DeviceRefreshResult(
                        snapshot: deviceProbe.snapshot,
                        tunnelState: existingTunnelState ?? .notRequired,
                        deviceAssessment: deviceProbe.assessment,
                        tunnelAssessment: existingTunnelAssessment,
                        logLines: ["[REFRESH] No connected device context for tunnel-only refresh; falling back to \(actualFocus.label) device probe."] + deviceProbe.events.map(\.logLine)
                    )
                }
                let snapshot = existingSnapshot
                let tunnelProbe = noPythonBackend.tunnelProbe(for: snapshot)
                return DeviceRefreshResult(
                    snapshot: snapshot,
                    tunnelState: tunnelProbe.tunnelState,
                    deviceAssessment: existingDeviceAssessment,
                    tunnelAssessment: tunnelProbe.assessment,
                    logLines: ["[REFRESH] Running tunnel probe for \(snapshot.displayName)."] + tunnelProbe.events.map(\.logLine)
                )
            case .full:
                let deviceProbe = noPythonBackend.deviceProbe()
                let tunnelProbe = noPythonBackend.tunnelProbe(for: deviceProbe.snapshot)
                return DeviceRefreshResult(
                    snapshot: deviceProbe.snapshot,
                    tunnelState: tunnelProbe.tunnelState,
                    deviceAssessment: deviceProbe.assessment,
                    tunnelAssessment: tunnelProbe.assessment,
                    logLines: ["[REFRESH] Running full device + tunnel probe."] + deviceProbe.events.map(\.logLine) + tunnelProbe.events.map(\.logLine)
                )
            }
        }

        switch scope {
        case .deviceOnly:
            let snapshot = backend.fetchConnectedDevice()
            return DeviceRefreshResult(
                snapshot: snapshot,
                tunnelState: existingTunnelState ?? .notRequired,
                deviceAssessment: nil,
                tunnelAssessment: nil,
                logLines: ["[REFRESH] Running \(deviceFocus.label) device probe."]
            )
        case .tunnelOnly:
            let snapshot = existingSnapshot?.isConnected == true ? existingSnapshot! : backend.fetchConnectedDevice()
            if !snapshot.isConnected {
                return DeviceRefreshResult(
                    snapshot: snapshot,
                    tunnelState: existingTunnelState ?? .notRequired,
                    deviceAssessment: nil,
                    tunnelAssessment: nil,
                    logLines: ["[REFRESH] Tunnel probe skipped because no connected device was found."]
                )
            }
            let tunnelState = backend.fetchTunnelState(for: snapshot)
            return DeviceRefreshResult(
                snapshot: snapshot,
                tunnelState: tunnelState,
                deviceAssessment: nil,
                tunnelAssessment: nil,
                logLines: ["[REFRESH] Running tunnel probe for \(snapshot.displayName)."]
            )
        case .full:
            let snapshot = backend.fetchConnectedDevice()
            let tunnelState = backend.fetchTunnelState(for: snapshot)
            return DeviceRefreshResult(
                snapshot: snapshot,
                tunnelState: tunnelState,
                deviceAssessment: nil,
                tunnelAssessment: nil,
                logLines: ["[REFRESH] Running full device + tunnel probe."]
            )
        }
    }
}
