import Foundation

struct V3SessionDiagnostics {
    static func diagnosticLines(
        backendTrack: BackendTrack,
        availability: BackendAvailability,
        capabilities: BackendCapabilities,
        snapshot: DeviceSnapshot,
        tunnelState: TunnelState,
        sessionState: DeviceSessionState,
        health: ConnectionHealth,
        blocker: SessionBlocker,
        readinessGate: SessionReadinessGate,
        deviceProbeFocus: DeviceProbeFocus,
        availabilityAssessment: DeviceAgentAvailability?,
        deviceAssessment: DeviceAgentSessionAssessment?,
        tunnelAssessment: DeviceAgentSessionAssessment?,
        lastLocationCommandRecord: LocationCommandRecord?
    ) -> [String] {
        var lines: [String] = [
            "[SESSION] Track: \(backendTrack.shortLabel)",
            "[SESSION] State: \(sessionState.title)",
            "[SESSION] Health: \(health.label)",
            "[SESSION] Health detail: \(V3AppModel.summarizeConnectionHealth(health, sessionState: sessionState, blocker: blocker, backendTrack: backendTrack, availabilityAssessment: availabilityAssessment, deviceAssessment: deviceAssessment, tunnelAssessment: tunnelAssessment))",
            "[SESSION] Readiness gate: \(readinessGate.title)",
            "[SESSION] Gate detail: \(V3AppModel.summarizeReadinessGate(readinessGate, backendTrack: backendTrack, sessionBlocker: blocker, deviceAssessment: deviceAssessment))",
            "[SESSION] Probe focus: \(deviceProbeFocus.title)",
            "[SESSION] Focus detail: \(V3AppModel.summarizeProbeFocus(deviceProbeFocus, snapshot: snapshot))",
            "[SESSION] Capabilities: \(capabilities.summary)",
            "[SESSION] Blocker: \(blocker.title)"
        ]

        if let summary = availability.summary, !summary.isEmpty {
            lines.append("[SESSION] Backend: \(summary)")
        }

        if let assessment = availabilityAssessment {
            lines.append("[SESSION] Bootstrap gate: \(assessment.readinessGate.title)")
            if let intent = assessment.refreshIntent {
                lines.append("[SESSION] Bootstrap intent: \(intent.scope.title) / \(intent.probeFocus?.title ?? "No Focus")")
            }
            if !assessment.summary.isEmpty {
                lines.append("[SESSION] Bootstrap readiness: \(assessment.summary)")
            }
            if !assessment.nextAction.isEmpty {
                lines.append("[SESSION] Bootstrap next action: \(assessment.nextAction)")
            }
            let blockerSummary = summarize(assessment.blockerCodes)
            if !blockerSummary.isEmpty {
                lines.append("[SESSION] Bootstrap blocker codes: \(blockerSummary)")
            }
            if !assessment.confidence.isEmpty {
                lines.append("[SESSION] Bootstrap confidence: \(assessment.confidence.uppercased())")
            }
        }

        if snapshot.isConnected {
            lines.append("[SESSION] Device: \(snapshot.displayName)")
            if let iosVersion = snapshot.iosVersion, !iosVersion.isEmpty {
                lines.append("[SESSION] iOS version: \(iosVersion)")
            }
            if let source = snapshot.probeSource, !source.isEmpty {
                lines.append("[SESSION] Probe source: \(source)")
            }
            if let serialSuffix = snapshot.serialSuffix, !serialSuffix.isEmpty {
                lines.append("[SESSION] Serial suffix: \(serialSuffix.uppercased())")
            }
            if snapshot.matchedDeviceCount > 1 {
                lines.append("[SESSION] Multiple mobile devices detected: \(snapshot.matchedDeviceCount)")
            }
        } else {
            lines.append("[SESSION] No connected mobile device in current snapshot")
        }

        if let assessment = deviceAssessment {
            lines.append("[SESSION] Device gate: \(assessment.readinessGate.title)")
            if let intent = assessment.refreshIntent {
                lines.append("[SESSION] Device intent: \(intent.scope.title) / \(intent.probeFocus?.title ?? "No Focus")")
            }
            lines.append("[SESSION] Device readiness: \(assessment.readinessSummary)")
            if let readiness = assessment.deviceInfoReadiness {
                lines.append("[SESSION] Device-info stage: \(V3AppModel.summarizeDeviceInfoReadiness(readiness))")
            }
            if let transportState = assessment.deviceInfoTransportState {
                lines.append("[SESSION] Device-info transport: \(V3AppModel.summarizeDeviceInfoTransportState(transportState))")
            }
            if let probeResult = assessment.deviceInfoTransportProbeResult {
                lines.append("[SESSION] Device-info slot: \(probeResult.transportID)")
                lines.append("[SESSION] Device-info probe result: \(V3AppModel.summarizeDeviceInfoTransportProbeResult(probeResult))")
            }
            if let contract = assessment.deviceInfoTransportContract {
                lines.append("[SESSION] Device-info contract: \(contract.contractID)")
                lines.append("[SESSION] Device-info contract detail: \(V3AppModel.summarizeDeviceInfoTransportContract(contract))")
            }
            if let typedMetadataResult = assessment.typedMetadataResult {
                lines.append("[SESSION] Typed metadata result: \(V3AppModel.summarizeTypedMetadataResult(typedMetadataResult))")
                if let artifact = typedMetadataResult.artifact {
                    lines.append("[SESSION] Typed metadata artifact: \(artifact.artifactID)")
                    lines.append("[SESSION] Typed metadata artifact detail: \(V3AppModel.summarizeTypedMetadataArtifact(artifact))")
                }
            }
            if let typedMetadataSession = assessment.typedMetadataSession {
                lines.append("[SESSION] Typed metadata session: \(typedMetadataSession.sessionID)")
                lines.append("[SESSION] Typed metadata session detail: \(V3AppModel.summarizeTypedMetadataSession(typedMetadataSession))")
            }
            let blockerSummary = summarize(assessment.blockerCodes)
            if !blockerSummary.isEmpty {
                lines.append("[SESSION] Device blocker codes: \(blockerSummary)")
            }
            if !assessment.nextAction.isEmpty {
                lines.append("[SESSION] Device next action: \(assessment.nextAction)")
            }
            if !assessment.confidence.isEmpty {
                lines.append("[SESSION] Device confidence: \(assessment.confidence.uppercased())")
            }
        }

        switch tunnelState {
        case .active:
            lines.append("[SESSION] Tunnel observation: active")
        case .starting:
            lines.append("[SESSION] Tunnel observation: product-owned tunnel is starting")
        case .failed:
            lines.append("[SESSION] Tunnel observation: product-owned tunnel failed")
        case .requiredInactive:
            lines.append("[SESSION] Tunnel observation: required but inactive")
        case .notRequired:
            lines.append("[SESSION] Tunnel observation: no verified product-owned tunnel state")
        }

        if let assessment = tunnelAssessment {
            lines.append("[SESSION] Tunnel gate: \(assessment.readinessGate.title)")
            if let intent = assessment.refreshIntent {
                lines.append("[SESSION] Tunnel intent: \(intent.scope.title) / \(intent.probeFocus?.title ?? "No Focus")")
            }
            lines.append("[SESSION] Tunnel readiness: \(assessment.readinessSummary)")
            if let requirement = assessment.tunnelRequirementResult {
                lines.append("[SESSION] Tunnel requirement: \(V3AppModel.summarizeTunnelRequirementResult(requirement))")
            }
            if let lifecycle = assessment.tunnelLifecycleResult {
                lines.append("[SESSION] Tunnel lifecycle: \(V3AppModel.summarizeTunnelLifecycleResult(lifecycle))")
            }
            if let tunnelSession = assessment.tunnelSession {
                lines.append("[SESSION] Tunnel session: \(tunnelSession.sessionID)")
                lines.append("[SESSION] Tunnel session detail: \(V3AppModel.summarizeTunnelSession(tunnelSession))")
            }
            if let tunnelHealth = assessment.tunnelHealthResult {
                lines.append("[SESSION] Tunnel health: \(V3AppModel.summarizeTunnelHealthResult(tunnelHealth))")
            }
            if let tunnelEndpoint = assessment.tunnelEndpointResult {
                lines.append("[SESSION] Tunnel endpoint: \(V3AppModel.summarizeTunnelEndpointResult(tunnelEndpoint))")
            }
            if let injectionTransport = assessment.injectionTransportProbeResult {
                lines.append("[SESSION] Injection transport: \(V3AppModel.summarizeInjectionTransportProbeResult(injectionTransport))")
            }
            let blockerSummary = summarize(assessment.blockerCodes)
            if !blockerSummary.isEmpty {
                lines.append("[SESSION] Tunnel blocker codes: \(blockerSummary)")
            }
            if !assessment.nextAction.isEmpty {
                lines.append("[SESSION] Tunnel next action: \(assessment.nextAction)")
            }
            if !assessment.confidence.isEmpty {
                lines.append("[SESSION] Tunnel confidence: \(assessment.confidence.uppercased())")
            }
            if readinessGate == .tunnelOwnership || readinessGate == .ready {
                lines.append("[SESSION] Tunnel stage: \(V3AppModel.summarizeTunnelStage(readinessGate, tunnelAssessment: assessment))")
                lines.append("[SESSION] Tunnel guidance: \(V3AppModel.summarizeTunnelAction(readinessGate, tunnelAssessment: assessment))")
            }
        }

        lines.append(
            "[SESSION] Guidance: \(V3AppModel.guidance(for: sessionState, snapshot: snapshot, backendTrack: backendTrack, readinessGate: readinessGate, deviceProbeFocus: deviceProbeFocus, availabilityAssessment: availabilityAssessment, deviceAssessment: deviceAssessment, tunnelAssessment: tunnelAssessment))"
        )
        if readinessGate == .injectionTransport {
            lines.append("[SESSION] Injection stage: \(V3AppModel.summarizeInjectionStage(availabilityAssessment: availabilityAssessment, tunnelAssessment: tunnelAssessment))")
            lines.append("[SESSION] Injection guidance: \(V3AppModel.summarizeInjectionAction(availabilityAssessment: availabilityAssessment, tunnelAssessment: tunnelAssessment))")
        }
        if let record = lastLocationCommandRecord {
            lines.append("[SESSION] Last location command: \(V3AppModel.summarizeLocationCommandRecord(record))")
            if !record.diagnosticLines.isEmpty {
                lines.append("[SESSION] Last location diagnostics:")
                lines.append(contentsOf: record.diagnosticLines.map { "[SESSION]   \($0)" })
            }
            if let stdout = record.stdout, !stdout.isEmpty {
                lines.append("[SESSION] Last location stdout: \(stdout)")
            }
            if let stderr = record.stderr, !stderr.isEmpty {
                lines.append("[SESSION] Last location stderr: \(stderr)")
            }
        }
        return lines
    }

    private static func summarize(_ codes: [DeviceAgentAssessmentBlockerCode]) -> String {
        guard !codes.isEmpty else { return "" }
        return codes.map(\.title).joined(separator: " | ")
    }
}
