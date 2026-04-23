import Combine
import Foundation

@MainActor
final class V3AppModel: ObservableObject {
    @Published var backendTrack: BackendTrack = BackendTrack.primaryTrack
    @Published var backendAvailability: BackendAvailability = .unavailable("Backend not initialized")
    @Published var backendCapabilities = BackendCapabilities(
        canDiscoverDevices: false,
        canObserveTunnel: false,
        canInjectLocation: false
    )
    @Published var resolvedCLIPath: String = ""
    @Published var deviceSnapshot = DeviceSnapshot(
        isConnected: false,
        connectionSummary: "INITIALIZING...",
        iosVersion: nil,
        deviceName: nil,
        deviceIdentifier: nil,
        serialSuffix: nil,
        vendorID: nil,
        productID: nil,
        probeSource: nil,
        matchedDeviceCount: 0
    )
    @Published var tunnelState: TunnelState = .notRequired
    @Published var availabilityAssessment: DeviceAgentAvailability?
    @Published var deviceAssessment: DeviceAgentSessionAssessment?
    @Published var tunnelAssessment: DeviceAgentSessionAssessment?
    @Published var lastLocationCommandRecord: LocationCommandRecord?

    var isEnvironmentReady: Bool {
        if backendTrack == .noPythonStub {
            return !backendAvailability.isUnavailable
        }
        return backendAvailability.isReady
    }

    var isBackendPartiallyAvailable: Bool {
        if case .partial = backendAvailability {
            return true
        }
        return false
    }

    var backendAvailabilitySummary: String {
        backendAvailability.summary ?? ""
    }

    var backendCapabilitySummary: String {
        backendCapabilities.summary
    }

    var isDeviceConnected: Bool {
        deviceSnapshot.isConnected
    }

    var sessionState: DeviceSessionState {
        Self.deriveSessionState(
            availability: backendAvailability,
            capabilities: backendCapabilities,
            snapshot: deviceSnapshot,
            tunnelState: tunnelState,
            backendTrack: backendTrack,
            deviceAssessment: deviceAssessment,
            tunnelAssessment: tunnelAssessment
        )
    }

    var connectionHealth: ConnectionHealth {
        Self.deriveConnectionHealth(
            for: sessionState,
            backendTrack: backendTrack,
            availabilityAssessment: availabilityAssessment,
            deviceAssessment: deviceAssessment,
            tunnelAssessment: tunnelAssessment
        )
    }

    var sessionBlocker: SessionBlocker {
        Self.deriveSessionBlocker(
            for: sessionState,
            backendTrack: backendTrack,
            availabilityAssessment: availabilityAssessment,
            deviceAssessment: deviceAssessment,
            tunnelAssessment: tunnelAssessment
        )
    }

    var readinessGate: SessionReadinessGate {
        Self.deriveReadinessGate(
            availability: backendAvailability,
            sessionState: sessionState,
            blocker: sessionBlocker,
            backendTrack: backendTrack,
            capabilities: backendCapabilities,
            availabilityAssessment: availabilityAssessment,
            deviceAssessment: deviceAssessment,
            tunnelAssessment: tunnelAssessment
        )
    }

    var sessionSummary: String {
        if backendTrack == .noPythonStub,
           let summary = availabilityAssessment?.summary,
           !summary.isEmpty,
           readinessGate == .backendBootstrap {
            return summary
        }
        if backendTrack == .noPythonStub,
           readinessGate == .injectionTransport {
            return injectionStageSummary
        }
        if backendTrack == .noPythonStub,
           let readinessSummary = deviceAssessment?.readinessSummary,
           !readinessSummary.isEmpty {
            return readinessSummary
        }
        return Self.summarizeSessionState(
            sessionState,
            availability: backendAvailability,
            snapshot: deviceSnapshot,
            deviceAssessment: deviceAssessment,
            tunnelAssessment: tunnelAssessment
        )
    }

    var nextActionText: String {
        if backendTrack == .noPythonStub,
           let nextAction = availabilityAssessment?.nextAction,
           !nextAction.isEmpty,
           readinessGate == .backendBootstrap {
            return nextAction
        }
        if backendTrack == .noPythonStub,
           readinessGate == .injectionTransport {
            return injectionStageActionText
        }
        return Self.guidance(
            for: sessionState,
            snapshot: deviceSnapshot,
            backendTrack: backendTrack,
            readinessGate: readinessGate,
            deviceProbeFocus: effectiveDeviceProbeFocus,
            availabilityAssessment: availabilityAssessment,
            deviceAssessment: deviceAssessment,
            tunnelAssessment: tunnelAssessment
        )
    }

    var healthSummary: String {
        Self.summarizeConnectionHealth(
            connectionHealth,
            sessionState: sessionState,
            blocker: sessionBlocker,
            backendTrack: backendTrack,
            availabilityAssessment: availabilityAssessment,
            deviceAssessment: deviceAssessment,
            tunnelAssessment: tunnelAssessment
        )
    }

    var readinessGateSummary: String {
        Self.summarizeReadinessGate(
            readinessGate,
            backendTrack: backendTrack,
            sessionBlocker: sessionBlocker,
            deviceAssessment: deviceAssessment
        )
    }

    var assessmentConfidenceText: String {
        guard backendTrack == .noPythonStub else { return "" }
        var parts: [String] = []
        if let confidence = availabilityAssessment?.confidence, !confidence.isEmpty {
            parts.append("Bootstrap confidence: \(confidence.uppercased())")
        }
        if let confidence = deviceAssessment?.confidence, !confidence.isEmpty {
            parts.append("Device confidence: \(confidence.uppercased())")
        }
        if let confidence = tunnelAssessment?.confidence, !confidence.isEmpty {
            parts.append("Tunnel confidence: \(confidence.uppercased())")
        }
        return parts.joined(separator: " · ")
    }

    var bootstrapSummary: String {
        guard backendTrack == .noPythonStub,
              let summary = availabilityAssessment?.summary,
              deviceAssessment == nil,
              tunnelAssessment == nil,
              !summary.isEmpty else {
            return ""
        }
        return summary
    }

    var bootstrapNextAction: String {
        guard backendTrack == .noPythonStub,
              let nextAction = availabilityAssessment?.nextAction,
              deviceAssessment == nil,
              tunnelAssessment == nil,
              !nextAction.isEmpty else {
            return ""
        }
        return nextAction
    }

    var tunnelAssessmentSummary: String {
        guard backendTrack == .noPythonStub,
              let summary = tunnelAssessment?.readinessSummary,
              !summary.isEmpty else {
            return ""
        }
        return summary
    }

    var tunnelRequirementSummary: String {
        guard backendTrack == .noPythonStub,
              let requirement = tunnelAssessment?.tunnelRequirementResult else {
            return ""
        }
        return "Tunnel requirement: \(Self.summarizeTunnelRequirementResult(requirement))"
    }

    var tunnelLifecycleSummary: String {
        guard backendTrack == .noPythonStub,
              let lifecycle = tunnelAssessment?.tunnelLifecycleResult else {
            return ""
        }
        return "Tunnel lifecycle: \(Self.summarizeTunnelLifecycleResult(lifecycle))"
    }

    var tunnelSessionSummary: String {
        guard backendTrack == .noPythonStub,
              let session = tunnelAssessment?.tunnelSession else {
            return ""
        }
        return "Tunnel session: \(Self.summarizeTunnelSession(session))"
    }

    var tunnelHealthSummary: String {
        guard backendTrack == .noPythonStub,
              let health = tunnelAssessment?.tunnelHealthResult else {
            return ""
        }
        return "Tunnel health: \(Self.summarizeTunnelHealthResult(health))"
    }

    var tunnelEndpointSummary: String {
        guard backendTrack == .noPythonStub,
              let endpoint = tunnelAssessment?.tunnelEndpointResult else {
            return ""
        }
        return "Tunnel endpoint: \(Self.summarizeTunnelEndpointResult(endpoint))"
    }

    var injectionTransportSummary: String {
        guard backendTrack == .noPythonStub,
              let probe = tunnelAssessment?.injectionTransportProbeResult else {
            return ""
        }
        return "Injection transport: \(Self.summarizeInjectionTransportProbeResult(probe))"
    }

    var deviceInfoStageSummary: String {
        guard backendTrack == .noPythonStub,
              readinessGate == .deviceInfoTransport,
              let readiness = deviceAssessment?.deviceInfoReadiness else {
            return ""
        }
        return "Device-info stage: \(Self.summarizeDeviceInfoReadiness(readiness))"
    }

    var deviceInfoTransportSummary: String {
        guard backendTrack == .noPythonStub,
              readinessGate == .deviceInfoTransport,
              let transportState = deviceAssessment?.deviceInfoTransportState else {
            return ""
        }
        return "Device-info transport: \(Self.summarizeDeviceInfoTransportState(transportState))"
    }

    var deviceInfoProbeResultSummary: String {
        guard backendTrack == .noPythonStub,
              readinessGate == .deviceInfoTransport,
              let probeResult = deviceAssessment?.deviceInfoTransportProbeResult else {
            return ""
        }
        return "Device-info probe: \(Self.summarizeDeviceInfoTransportProbeResult(probeResult))"
    }

    var deviceInfoTransportSlotSummary: String {
        guard backendTrack == .noPythonStub,
              readinessGate == .deviceInfoTransport,
              let probeResult = deviceAssessment?.deviceInfoTransportProbeResult else {
            return ""
        }
        return "Device-info slot: \(probeResult.transportID)"
    }

    var deviceInfoContractSummary: String {
        guard backendTrack == .noPythonStub,
              readinessGate == .deviceInfoTransport,
              let contract = deviceAssessment?.deviceInfoTransportContract else {
            return ""
        }
        return "Device-info contract: \(Self.summarizeDeviceInfoTransportContract(contract))"
    }

    var typedMetadataResultSummary: String {
        guard backendTrack == .noPythonStub,
              readinessGate == .deviceInfoTransport,
              let typedMetadataResult = deviceAssessment?.typedMetadataResult else {
            return ""
        }
        return "Typed metadata result: \(Self.summarizeTypedMetadataResult(typedMetadataResult))"
    }

    var typedMetadataArtifactSummary: String {
        guard backendTrack == .noPythonStub,
              readinessGate == .deviceInfoTransport,
              let artifact = deviceAssessment?.typedMetadataResult?.artifact else {
            return ""
        }
        return "Typed metadata artifact: \(Self.summarizeTypedMetadataArtifact(artifact))"
    }

    var typedMetadataSessionSummary: String {
        guard backendTrack == .noPythonStub,
              readinessGate == .deviceInfoTransport,
              let session = deviceAssessment?.typedMetadataSession else {
            return ""
        }
        return "Typed metadata session: \(Self.summarizeTypedMetadataSession(session))"
    }

    var injectionStageSummary: String {
        guard backendTrack == .noPythonStub,
              readinessGate == .injectionTransport else { return "" }
        return Self.summarizeInjectionStage(
            availabilityAssessment: availabilityAssessment,
            tunnelAssessment: tunnelAssessment
        )
    }

    var injectionStageActionText: String {
        guard backendTrack == .noPythonStub,
              readinessGate == .injectionTransport else { return "" }
        return Self.summarizeInjectionAction(
            availabilityAssessment: availabilityAssessment,
            tunnelAssessment: tunnelAssessment
        )
    }

    var tunnelIntentSummary: String {
        guard backendTrack == .noPythonStub,
              effectiveRefreshScope == .tunnelOnly,
              let intent = tunnelAssessment?.refreshIntent else {
            return ""
        }
        return "Tunnel intent: \(intent.scope.title) / \(intent.probeFocus?.title ?? "No Focus")"
    }

    var tunnelConfidenceSummary: String {
        guard backendTrack == .noPythonStub,
              effectiveRefreshScope == .tunnelOnly,
              let confidence = tunnelAssessment?.confidence,
              !confidence.isEmpty else {
            return ""
        }
        return "Tunnel confidence: \(confidence.uppercased())"
    }

    var lastLocationCommandSummary: String {
        guard let record = lastLocationCommandRecord else { return "" }
        return "Last location command: \(Self.summarizeLocationCommandRecord(record))"
    }

    var hardwareStatusTitle: String {
        if backendTrack == .noPythonStub {
            return "\(sessionState.title.uppercased()) · \(connectionHealth.label)"
        }
        return deviceSnapshot.isConnected ? "HARDWARE CONNECTED" : "NO USB CONNECTION"
    }

    var connectionStatusText: String {
        if backendTrack == .noPythonStub {
            if deviceSnapshot.isConnected {
                return [deviceSnapshot.connectionSummary, detailedProbeText, sessionSummary]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
            }
            return sessionSummary
        }
        return deviceSnapshot.isConnected ? "READY TO INJECT" : "CONNECT VIA USB CABLE"
    }

    var detailedProbeText: String {
        guard deviceSnapshot.isConnected else { return "" }
        var parts: [String] = []
        if let source = deviceSnapshot.probeSource, !source.isEmpty {
            parts.append(source.uppercased())
        }
        if let serialSuffix = deviceSnapshot.serialSuffix, !serialSuffix.isEmpty {
            parts.append("SN \(serialSuffix.uppercased())")
        }
        if deviceSnapshot.matchedDeviceCount > 1 {
            parts.append("\(deviceSnapshot.matchedDeviceCount) DEVICES")
        }
        return parts.joined(separator: " · ")
    }

    var deviceIOSVersion: String {
        deviceSnapshot.iosVersion ?? ""
    }

    var deviceIOSMajor: Int {
        deviceSnapshot.iosMajorVersion ?? 0
    }

    var tunneldRunning: Bool {
        tunnelState == .active
    }

    var needsTunnel: Bool {
        if backendTrack == .noPythonStub,
           tunnelAssessment?.injectionTransportProbeResult?.transportState == .xcodeTestHarness {
            return false
        }
        return deviceIOSMajor >= 17 && !tunneldRunning
    }

    var preferredRefreshScope: SessionRefreshScope {
        if backendTrack == .noPythonStub,
           let recommendedScope = deviceAssessment?.refreshIntent?.scope ??
                tunnelAssessment?.refreshIntent?.scope ??
                availabilityAssessment?.refreshIntent?.scope {
            return Self.mapRefreshScope(recommendedScope)
        }
        if backendTrack == .noPythonStub,
           tunnelAssessment?.injectionTransportProbeResult?.transportState == .xcodeTestHarness {
            return .deviceOnly
        }
        switch readinessGate {
        case .backendBootstrap:
            return .full
        case .deviceAttachment, .deviceSelection, .deviceInfoTransport, .injectionTransport:
            return .deviceOnly
        case .tunnelOwnership, .ready:
            return .tunnelOnly
        }
    }

    var tunnelStageSummary: String {
        guard backendTrack == .noPythonStub,
              effectiveRefreshScope == .tunnelOnly else { return "" }
        return Self.summarizeTunnelStage(readinessGate, tunnelAssessment: tunnelAssessment)
    }

    var tunnelStageActionText: String {
        guard backendTrack == .noPythonStub,
              effectiveRefreshScope == .tunnelOnly else { return "" }
        return Self.summarizeTunnelAction(readinessGate, tunnelAssessment: tunnelAssessment)
    }

    var effectiveRefreshScope: SessionRefreshScope {
        switch preferredRefreshScope {
        case .tunnelOnly:
            return deviceSnapshot.isConnected ? .tunnelOnly : .deviceOnly
        case .deviceOnly, .full:
            return preferredRefreshScope
        }
    }

    var effectiveDeviceProbeFocus: DeviceProbeFocus {
        if backendTrack == .noPythonStub,
           let recommended = deviceAssessment?.refreshIntent?.probeFocus ??
                availabilityAssessment?.refreshIntent?.probeFocus ??
                deviceAssessment?.recommendedProbeFocus ??
                availabilityAssessment?.recommendedProbeFocus {
            return Self.mapProbeFocus(recommended)
        }
        if !deviceSnapshot.isConnected || sessionBlocker == .noDevice {
            return .attachment
        }
        if sessionBlocker == .multipleDevices || sessionState == .multipleDevices {
            return .selection
        }
        return .deviceInfo
    }

    var preferredRefreshActionText: String {
        if backendTrack == .noPythonStub {
            switch effectiveRefreshScope {
            case .full:
                return "Probe backend bootstrap"
            case .deviceOnly:
                switch effectiveDeviceProbeFocus {
                case .attachment:
                    return "Probe for attached device"
                case .selection:
                    return "Refresh device selection"
                case .deviceInfo:
                    return "Refresh device-info gate"
                }
            case .tunnelOnly:
                switch readinessGate {
                case .tunnelOwnership:
                    return "Refresh tunnel ownership state"
                case .ready:
                    return "Refresh ready session"
                case .backendBootstrap, .deviceAttachment, .deviceSelection, .deviceInfoTransport, .injectionTransport:
                    break
                }
            }
        }
        return "Probe compatibility transport"
    }

    var preferredRefreshHelpText: String {
        guard backendTrack == .noPythonStub else {
            return preferredRefreshActionText
        }
        return [preferredRefreshActionText, refreshActionDetail]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
    }

    var refreshIntentSummary: String {
        guard backendTrack == .noPythonStub else { return "" }
        switch effectiveRefreshScope {
        case .full:
            return "Refresh intent: Full Probe"
        case .deviceOnly:
            return "Refresh intent: Device Probe / \(effectiveDeviceProbeFocus.title)"
        case .tunnelOnly:
            return "Refresh intent: Tunnel Probe"
        }
    }

    var refreshIntentDetail: String {
        guard backendTrack == .noPythonStub else { return "" }
        switch effectiveRefreshScope {
        case .full:
            return "The backend is still bootstrapping, so the next refresh should run the full probe path."
        case .deviceOnly:
            return "The next refresh should stay on device probing and focus on \(effectiveDeviceProbeFocus.title.lowercased()) readiness."
        case .tunnelOnly:
            return "The next refresh should stay on tunnel ownership instead of re-running device attachment work."
        }
    }

    var refreshActionDetail: String {
        guard backendTrack == .noPythonStub else { return "" }
        switch effectiveRefreshScope {
        case .full:
            return "Run the full bootstrap path before session-specific checks."
        case .deviceOnly:
            switch effectiveDeviceProbeFocus {
            case .attachment:
                return "Check USB attachment and trust state before deeper session work."
            case .selection:
                return "Verify which attached device should own the current session."
            case .deviceInfo:
                return "Advance device metadata transport beyond raw USB visibility."
            }
        case .tunnelOnly:
            return "Verify tunnel ownership and tunnel readiness without re-running device attachment."
        }
    }

    var manualRefreshLogSummary: String {
        guard backendTrack == .noPythonStub else {
            return "refreshing backend dependencies"
        }
        switch effectiveRefreshScope {
        case .full:
            return "probing full bootstrap path for \(readinessGate.title.lowercased())"
        case .deviceOnly:
            return "probing device readiness (\(effectiveDeviceProbeFocus.label)) for \(readinessGate.title.lowercased())"
        case .tunnelOnly:
            return "probing tunnel ownership for \(readinessGate.title.lowercased())"
        }
    }

    var probeFocusSummary: String {
        guard backendTrack == .noPythonStub else { return "" }
        return "Probe focus: \(effectiveDeviceProbeFocus.title)"
    }

    var probeFocusDetail: String {
        guard backendTrack == .noPythonStub else { return "" }
        return Self.summarizeProbeFocus(
            effectiveDeviceProbeFocus,
            snapshot: deviceSnapshot
        )
    }

    static func deriveSessionState(
        availability: BackendAvailability,
        capabilities: BackendCapabilities,
        snapshot: DeviceSnapshot,
        tunnelState: TunnelState,
        backendTrack: BackendTrack = .legacyPreview,
        deviceAssessment: DeviceAgentSessionAssessment? = nil,
        tunnelAssessment: DeviceAgentSessionAssessment? = nil
    ) -> DeviceSessionState {
        if case .unavailable = availability {
            return .backendUnavailable
        }
        guard snapshot.isConnected else {
            return .disconnected
        }
        if backendTrack == .noPythonStub,
           let assessmentDriven = deriveAssessmentDrivenSessionState(
            capabilities: capabilities,
            deviceAssessment: deviceAssessment,
            tunnelAssessment: tunnelAssessment
           ) {
            return assessmentDriven
        }
        if !capabilities.canDiscoverDevices {
            return .degraded("Device probe capability missing")
        }
        if !availability.isReady {
            return .usbDetected
        }
        if (snapshot.iosMajorVersion ?? 0) >= 17 && tunnelState != .active {
            return .tunnelRequired
        }
        if !capabilities.canInjectLocation {
            return .injectionUnavailable
        }
        if availability.isReady && capabilities.canInjectLocation {
            return .readyForInjection
        }
        return .degraded("Backend did not resolve to a known session state")
    }

    nonisolated static func deriveAssessmentDrivenSessionState(
        capabilities: BackendCapabilities,
        deviceAssessment: DeviceAgentSessionAssessment?,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> DeviceSessionState? {
        let codes = (deviceAssessment?.blockerCodes ?? []) + (tunnelAssessment?.blockerCodes ?? [])
        if codes.contains(.multipleDevices) {
            return .multipleDevices
        }
        if codes.contains(.legacyTunnelObserved) || codes.contains(.tunnelUnverified) {
            return .tunnelObservationOnly
        }
        if codes.contains(.deviceInfoMissing) {
            return .deviceInfoPending
        }
        if codes.contains(.tunnelFailed) {
            return .tunnelRequired
        }
        if codes.contains(.tunnelRequired) {
            return .tunnelRequired
        }
        if codes.contains(.tunnelUnknown) {
            return .tunnelObservationOnly
        }
        if let deviceAssessment,
           deviceAssessment.blockerCodes.isEmpty,
           let tunnelAssessment,
           tunnelAssessment.blockerCodes.isEmpty {
            return capabilities.canInjectLocation ? .readyForInjection : .injectionUnavailable
        }
        return nil
    }

    static func deriveConnectionHealth(
        for sessionState: DeviceSessionState,
        backendTrack: BackendTrack = .legacyPreview,
        availabilityAssessment: DeviceAgentAvailability? = nil,
        deviceAssessment: DeviceAgentSessionAssessment? = nil,
        tunnelAssessment: DeviceAgentSessionAssessment? = nil
    ) -> ConnectionHealth {
        if backendTrack == .noPythonStub,
           let assessmentDriven = deriveAssessmentDrivenHealth(
            sessionState: sessionState,
            availabilityAssessment: availabilityAssessment,
            deviceAssessment: deviceAssessment,
            tunnelAssessment: tunnelAssessment
           ) {
            return assessmentDriven
        }
        switch sessionState {
        case .backendUnavailable, .disconnected:
            return .offline
        case .usbDetected, .deviceInfoPending, .injectionUnavailable, .tunnelRequired:
            return .partial
        case .multipleDevices, .tunnelObservationOnly:
            return .unstable
        case .degraded:
            return .degraded
        case .readyForInjection:
            return .healthy
        }
    }

    nonisolated static func deriveAssessmentDrivenHealth(
        sessionState: DeviceSessionState,
        availabilityAssessment: DeviceAgentAvailability?,
        deviceAssessment: DeviceAgentSessionAssessment?,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> ConnectionHealth? {
        switch sessionState {
        case .backendUnavailable, .disconnected:
            return .offline
        case .degraded:
            return .degraded
        case .readyForInjection:
            return .healthy
        default:
            break
        }

        let codes = (availabilityAssessment?.blockerCodes ?? []) + (deviceAssessment?.blockerCodes ?? []) + (tunnelAssessment?.blockerCodes ?? [])
        if codes.contains(.multipleDevices) ||
            codes.contains(.legacyTunnelObserved) ||
            codes.contains(.tunnelUnverified) {
            return .unstable
        }
        if codes.contains(.tunnelFailed) {
            return .degraded
        }
        if codes.contains(.deviceInfoMissing) ||
            codes.contains(.injectionTransportMissing) ||
            codes.contains(.tunnelRequired) ||
            codes.contains(.tunnelUnknown) {
            return .partial
        }
        if !codes.isEmpty {
            return .degraded
        }
        return nil
    }

    nonisolated static func deriveSessionBlocker(
        for sessionState: DeviceSessionState,
        backendTrack: BackendTrack = .legacyPreview,
        availabilityAssessment: DeviceAgentAvailability? = nil,
        deviceAssessment: DeviceAgentSessionAssessment? = nil,
        tunnelAssessment: DeviceAgentSessionAssessment? = nil
    ) -> SessionBlocker {
        if backendTrack == .noPythonStub,
           let assessmentDriven = deriveAssessmentDrivenBlocker(
            availabilityAssessment: availabilityAssessment,
            deviceAssessment: deviceAssessment,
            tunnelAssessment: tunnelAssessment
           ) {
            return assessmentDriven
        }
        switch sessionState {
        case .backendUnavailable:
            return .backendUnavailable
        case .disconnected:
            return .noDevice
        case .usbDetected:
            return .backendPartial
        case .multipleDevices:
            return .multipleDevices
        case .deviceInfoPending:
            if let assessmentDriven = deriveAssessmentDrivenBlocker(
                availabilityAssessment: availabilityAssessment,
                deviceAssessment: deviceAssessment,
                tunnelAssessment: tunnelAssessment
            ) {
                return assessmentDriven
            }
            return .deviceInfoMissing
        case .tunnelObservationOnly:
            if let assessmentDriven = deriveAssessmentDrivenBlocker(
                availabilityAssessment: availabilityAssessment,
                deviceAssessment: deviceAssessment,
                tunnelAssessment: tunnelAssessment
            ) {
                return assessmentDriven
            }
            return .tunnelUnverified
        case .tunnelRequired:
            return .tunnelRequired
        case .injectionUnavailable:
            return .injectionMissing
        case .readyForInjection:
            return .none
        case .degraded(let reason):
            return .degraded(reason)
        }
    }

    nonisolated static func deriveAssessmentDrivenBlocker(
        availabilityAssessment: DeviceAgentAvailability?,
        deviceAssessment: DeviceAgentSessionAssessment?,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> SessionBlocker? {
        let codes = (availabilityAssessment?.blockerCodes ?? []) + (deviceAssessment?.blockerCodes ?? []) + (tunnelAssessment?.blockerCodes ?? [])
        if codes.contains(.multipleDevices) {
            return .multipleDevices
        }
        if codes.contains(.legacyTunnelObserved) {
            return .legacyTunnelObserved
        }
        if codes.contains(.tunnelUnverified) {
            return .tunnelUnverified
        }
        if codes.contains(.tunnelFailed) {
            return .tunnelFailed
        }
        if codes.contains(.tunnelUnknown) {
            return .tunnelUnknown
        }
        if codes.contains(.tunnelRequired) {
            return .tunnelRequired
        }
        if codes.contains(.deviceInfoMissing) {
            return .deviceInfoMissing
        }
        if codes.contains(.injectionTransportMissing) {
            return .injectionTransportMissing
        }
        if codes.contains(.noDevice) {
            return .noDevice
        }
        return nil
    }

    nonisolated static func summarizeSessionState(
        _ sessionState: DeviceSessionState,
        availability: BackendAvailability,
        snapshot: DeviceSnapshot,
        deviceAssessment: DeviceAgentSessionAssessment? = nil,
        tunnelAssessment: DeviceAgentSessionAssessment? = nil
    ) -> String {
        let backendSummary: String
        switch availability {
        case .unavailable(let value), .partial(let value):
            backendSummary = value
        case .ready:
            backendSummary = ""
        }
        let snapshotName = snapshot.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? snapshot.deviceName!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (snapshot.isConnected ? "iPhone" : "No Device")
        switch sessionState {
        case .backendUnavailable:
            return backendSummary.isEmpty ? "Backend unavailable" : backendSummary
        case .disconnected:
            return "Connect an iPhone over USB to begin a session."
        case .usbDetected:
            return "USB transport can see \(snapshotName), but backend readiness is still partial."
        case .multipleDevices:
            return "More than one USB-visible Apple mobile device is attached. Session selection is required."
        case .deviceInfoPending:
            if let typedMetadataSession = deviceAssessment?.typedMetadataSession {
                return "A seed-only typed metadata session exists (\(typedMetadataSession.sessionID)), but the device-agent backend still needs resolved metadata transport before session readiness can advance."
            }
            return "USB visibility exists, but the device-agent backend still needs device-info transport before it can resolve session readiness."
        case .tunnelObservationOnly:
            if let typedMetadataSession = deviceAssessment?.typedMetadataSession,
               typedMetadataSession.state == .resolvedIdentity {
                return "Typed metadata session is resolved, but tunnel lifecycle is still observational and not product-owned readiness."
            }
            return "Tunnel-related signals exist, but they are still observational and not product-owned readiness."
        case .tunnelRequired:
            if deviceAssessment?.blockerCodes.contains(.tunnelFailed) == true ||
                tunnelAssessment?.blockerCodes.contains(.tunnelFailed) == true {
                return "The device session is visible, but the product-owned tunnel startup most recently failed and needs a retry."
            }
            return "The device session is visible, but tunnel setup is still required."
        case .injectionUnavailable:
            if let summary = summarizeEndpointBackedInjectionReadiness(tunnelAssessment: tunnelAssessment) {
                return summary
            }
            return "A ready session boundary may exist, but location injection transport is not yet ready to execute."
        case .readyForInjection:
            return "Device session is healthy and ready for injection."
        case .degraded(let reason):
            return reason
        }
    }

    nonisolated static func guidance(
        for sessionState: DeviceSessionState,
        snapshot: DeviceSnapshot,
        backendTrack: BackendTrack = .legacyPreview,
        readinessGate: SessionReadinessGate? = nil,
        deviceProbeFocus: DeviceProbeFocus? = nil,
        availabilityAssessment: DeviceAgentAvailability? = nil,
        deviceAssessment: DeviceAgentSessionAssessment? = nil,
        tunnelAssessment: DeviceAgentSessionAssessment? = nil
    ) -> String {
        if backendTrack == .noPythonStub {
            if let readinessGate {
                switch readinessGate {
                case .injectionTransport:
                    return summarizeInjectionAction(
                        availabilityAssessment: availabilityAssessment,
                        tunnelAssessment: tunnelAssessment
                    )
                case .tunnelOwnership:
                    if let nextAction = tunnelAssessment?.nextAction, !nextAction.isEmpty {
                        return nextAction
                    }
                    return "Keep the probe on tunnel ownership: verify that the current tunnel state is product-owned and reproducible before promoting it to a ready session boundary."
                case .ready:
                    if let action = summarizeEndpointBackedInjectionAction(tunnelAssessment: tunnelAssessment) {
                        return action
                    }
                    if let nextAction = tunnelAssessment?.nextAction, !nextAction.isEmpty {
                        return nextAction
                    }
                    return "Hold the ready session boundary: keep tunnel ownership stable while injection transport is added as a separate layer."
                case .backendBootstrap, .deviceAttachment, .deviceSelection, .deviceInfoTransport:
                    break
                }
            }
            if let focus = deviceProbeFocus {
                let blocker = deriveSessionBlocker(
                    for: sessionState,
                    backendTrack: backendTrack,
                    availabilityAssessment: availabilityAssessment,
                    deviceAssessment: deviceAssessment,
                    tunnelAssessment: tunnelAssessment
                )
                return nextAction(
                    for: blocker,
                    snapshot: snapshot,
                    deviceProbeFocus: focus,
                    deviceAssessment: deviceAssessment
                )
            }
            if let nextAction = deviceAssessment?.nextAction, !nextAction.isEmpty {
                return nextAction
            }
            if let nextAction = tunnelAssessment?.nextAction, !nextAction.isEmpty {
                return nextAction
            }
        }
        return nextAction(
            for: deriveSessionBlocker(
                for: sessionState,
                backendTrack: backendTrack,
                availabilityAssessment: availabilityAssessment,
                deviceAssessment: deviceAssessment,
                tunnelAssessment: tunnelAssessment
            ),
            snapshot: snapshot,
            deviceProbeFocus: deviceProbeFocus,
            deviceAssessment: deviceAssessment
        )
    }

    nonisolated static func summarizeConnectionHealth(
        _ health: ConnectionHealth,
        sessionState: DeviceSessionState,
        blocker: SessionBlocker,
        backendTrack: BackendTrack = .legacyPreview,
        availabilityAssessment: DeviceAgentAvailability? = nil,
        deviceAssessment: DeviceAgentSessionAssessment? = nil,
        tunnelAssessment: DeviceAgentSessionAssessment? = nil
    ) -> String {
        if backendTrack == .noPythonStub {
            switch health {
            case .offline:
                return "Device-agent runtime is not holding a usable device session yet."
            case .partial:
                if let blocker = tunnelAssessment?.blockerCodes.first?.rawValue ??
                    deviceAssessment?.blockerCodes.first?.rawValue ??
                    availabilityAssessment?.blockerCodes.first?.rawValue,
                   !blocker.isEmpty {
                    return "Device-agent runtime is partially wired: \(blocker)."
                }
                return "Device-agent runtime has partial session data, but key transport layers are still missing."
            case .unstable:
                if let blocker = ([deviceAssessment, tunnelAssessment]
                    .compactMap { $0?.blockers.first }).first,
                   !blocker.isEmpty {
                    return blocker
                }
                return "Device-agent runtime sees conflicting or unverified session signals."
            case .degraded:
                if let blocker = ([tunnelAssessment, deviceAssessment]
                    .flatMap { $0?.blockerCodes ?? [] })
                    .first(where: { $0 == .tunnelFailed }) {
                    return "Device-agent runtime reached a degraded session path: \(blocker.rawValue)."
                }
                return "Device-agent runtime reached a degraded session path."
            case .healthy:
                return "Device-agent runtime session model reports a healthy path."
            }
        }

        switch health {
        case .offline:
            return "No active device session is available."
        case .partial:
            return "The session is partially available but not ready for teleport."
        case .unstable:
            return "The session is visible, but the current state is not stable enough for use."
        case .degraded:
            switch sessionState {
            case .degraded(let reason):
                return reason
            default:
                return summarizeBlocker(blocker)
            }
        case .healthy:
            return "The session is healthy and should accept location injection."
        }
    }

    nonisolated static func deriveReadinessGate(
        availability: BackendAvailability,
        sessionState: DeviceSessionState,
        blocker: SessionBlocker,
        backendTrack: BackendTrack = .legacyPreview,
        capabilities: BackendCapabilities,
        availabilityAssessment: DeviceAgentAvailability? = nil,
        deviceAssessment: DeviceAgentSessionAssessment? = nil,
        tunnelAssessment: DeviceAgentSessionAssessment? = nil
    ) -> SessionReadinessGate {
        if case .unavailable = availability {
            return .backendBootstrap
        }

        if backendTrack == .noPythonStub {
            if deviceAssessment == nil,
               tunnelAssessment == nil,
               let gate = availabilityAssessment?.readinessGate {
                switch gate {
                case .backendBootstrap:
                    return .backendBootstrap
                case .deviceAttachment:
                    return .deviceAttachment
                case .deviceSelection:
                    return .deviceSelection
                case .deviceInfoTransport:
                    return .deviceInfoTransport
                case .tunnelOwnership:
                    return .tunnelOwnership
                case .injectionTransport:
                    return .injectionTransport
                case .ready:
                    break
                }
            }
            if let gate = deviceAssessment?.readinessGate {
                switch gate {
                case .backendBootstrap:
                    return .backendBootstrap
                case .deviceAttachment:
                    return .deviceAttachment
                case .deviceSelection:
                    return .deviceSelection
                case .deviceInfoTransport:
                    return .deviceInfoTransport
                case .tunnelOwnership:
                    return .tunnelOwnership
                case .injectionTransport:
                    return .injectionTransport
                case .ready:
                    break
                }
            }
            if let gate = tunnelAssessment?.readinessGate {
                switch gate {
                case .backendBootstrap:
                    return .backendBootstrap
                case .deviceAttachment:
                    return .deviceAttachment
                case .deviceSelection:
                    return .deviceSelection
                case .deviceInfoTransport:
                    return .deviceInfoTransport
                case .tunnelOwnership:
                    return .tunnelOwnership
                case .injectionTransport:
                    return .injectionTransport
                case .ready:
                    break
                }
            }
            let codes = (availabilityAssessment?.blockerCodes ?? []) + (deviceAssessment?.blockerCodes ?? []) + (tunnelAssessment?.blockerCodes ?? [])
            if codes.contains(.noDevice) || isState(sessionState, matching: .disconnected) {
                return .deviceAttachment
            }
            if codes.contains(.multipleDevices) || isState(sessionState, matching: .multipleDevices) {
                return .deviceSelection
            }
            if codes.contains(.deviceInfoMissing) || isState(sessionState, matching: .deviceInfoPending) {
                return .deviceInfoTransport
            }
            if codes.contains(.legacyTunnelObserved) ||
                codes.contains(.tunnelUnverified) ||
                codes.contains(.tunnelFailed) ||
                codes.contains(.tunnelRequired) ||
                codes.contains(.tunnelUnknown) ||
                isState(sessionState, matching: .tunnelObservationOnly) ||
                isState(sessionState, matching: .tunnelRequired) {
                return .tunnelOwnership
            }
            if !capabilities.canInjectLocation ||
                codes.contains(.injectionTransportMissing) ||
                isBlocker(blocker, matching: .injectionMissing) ||
                isBlocker(blocker, matching: .injectionTransportMissing) ||
                isState(sessionState, matching: .injectionUnavailable) {
                return .injectionTransport
            }
            return .ready
        }

        switch blocker {
        case .backendUnavailable, .backendPartial:
            return .backendBootstrap
        case .noDevice:
            return .deviceAttachment
        case .multipleDevices:
            return .deviceSelection
        case .deviceInfoMissing:
            return .deviceInfoTransport
        case .tunnelUnknown, .legacyTunnelObserved, .tunnelUnverified, .tunnelRequired, .tunnelFailed:
            return .tunnelOwnership
        case .injectionMissing, .injectionTransportMissing:
            return .injectionTransport
        case .degraded:
            return .backendBootstrap
        case .none:
            return .ready
        }
    }

    nonisolated static func summarizeReadinessGate(
        _ gate: SessionReadinessGate,
        backendTrack: BackendTrack = .legacyPreview,
        sessionBlocker: SessionBlocker,
        deviceAssessment: DeviceAgentSessionAssessment? = nil
    ) -> String {
        switch gate {
        case .backendBootstrap:
            return backendTrack == .noPythonStub
                ? "The device-agent backend boundary is up, but core session services are still bootstrapping."
                : "The preview backend is not fully initialized."
        case .deviceAttachment:
            return "A trusted USB-attached iPhone is still required before session work can continue."
        case .deviceSelection:
            return "One concrete device must be selected before product-owned session state can advance."
        case .deviceInfoTransport:
            if deviceAssessment?.typedMetadataSession != nil {
                return "A seed-only typed metadata session is active, but the backend still needs resolved metadata transport before readiness can advance."
            }
            return "The next missing layer is device-info transport, so readiness cannot move past USB visibility yet."
        case .tunnelOwnership:
            return "Tunnel lifecycle is still observational; V3 still needs product-owned tunnel state before readiness can advance."
        case .injectionTransport:
            return "The remaining gate is location injection transport."
        case .ready:
            return isBlocker(sessionBlocker, matching: .none)
                ? "All current readiness gates are satisfied."
                : "The session is close to ready, but a residual blocker still needs to clear."
        }
    }

    nonisolated static func summarizeProbeFocus(
        _ focus: DeviceProbeFocus,
        snapshot: DeviceSnapshot
    ) -> String {
        let snapshotName = snapshot.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? snapshot.deviceName!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (snapshot.isConnected ? "attached iPhone" : "device")
        switch focus {
        case .attachment:
            return "Attachment focus is checking for a trusted USB-visible device before deeper transport work."
        case .selection:
            return "Selection focus is narrowing the session down to one concrete device instead of \(snapshotName) plus extras."
        case .deviceInfo:
            return "Device Info focus is trying to move \(snapshotName) past USB visibility into typed session metadata."
        }
    }

    nonisolated static func summarizeDeviceInfoReadiness(
        _ readiness: DeviceAgentDeviceInfoReadiness
    ) -> String {
        switch readiness {
        case .usbVisibilityOnly:
            return "USB transport can see a device, but identity is still too thin for typed session metadata."
        case .usbIdentityObserved:
            return "USB identity is already visible, but product-owned typed metadata transport is still missing."
        case .typedMetadataMissing:
            return "Typed session metadata has not been attached yet."
        }
    }

    nonisolated static func summarizeDeviceInfoTransportState(
        _ transportState: DeviceAgentDeviceInfoTransportState
    ) -> String {
        switch transportState {
        case .probeOnly:
            return "No transport bootstrap exists yet; the backend is still relying on raw USB probing."
        case .bootstrapReady:
            return "Enough USB identity is visible to bootstrap a future typed metadata transport, but that transport is not product-owned yet."
        }
    }

    nonisolated static func summarizeDeviceInfoTransportContract(
        _ contract: DeviceAgentDeviceInfoTransportContract
    ) -> String {
        "\(contract.phase.rawValue): \(contract.summary) Expected artifact: \(contract.expectedArtifact)."
    }

    nonisolated static func summarizeDeviceInfoTransportProbeResult(
        _ probeResult: DeviceAgentDeviceInfoTransportProbeResult
    ) -> String {
        "\(probeResult.transportState.rawValue): \(probeResult.summary) Next action: \(probeResult.nextAction) Confidence: \(probeResult.confidence.uppercased())."
    }

    nonisolated static func summarizeTypedMetadataResult(
        _ result: DeviceAgentTypedMetadataResult
    ) -> String {
        "\(result.state.rawValue): \(result.summary) Next action: \(result.nextAction) Confidence: \(result.confidence.uppercased())."
    }

    nonisolated static func summarizeTypedMetadataArtifact(
        _ artifact: DeviceAgentTypedMetadataArtifact
    ) -> String {
        let observed = artifact.observedProperties.joined(separator: ", ")
        let summaryParts = [
            artifact.summary,
            artifact.deviceName.map { "Device: \($0)." },
            artifact.iosVersion.map { "iOS: \($0)." },
            artifact.serialSuffix.map { "Serial suffix: \($0.uppercased())." },
            artifact.vendorID.map { "Vendor: \($0)." },
            artifact.productID.map { "Product: \($0)." },
            observed.isEmpty ? nil : "Observed properties: \(observed)."
        ]
        return summaryParts.compactMap { $0 }.joined(separator: " ")
    }

    nonisolated static func summarizeTypedMetadataSession(
        _ session: DeviceAgentTypedMetadataSession
    ) -> String {
        "\(session.state.rawValue): \(session.summary) Artifact: \(session.artifactID). Next action: \(session.nextAction)"
    }

    nonisolated static func summarizeTunnelRequirementResult(
        _ result: DeviceAgentTunnelRequirementResult
    ) -> String {
        "\(result.state.rawValue): \(result.summary) Next action: \(result.nextAction) Confidence: \(result.confidence.uppercased())."
    }

    nonisolated static func summarizeTunnelLifecycleResult(
        _ result: DeviceAgentTunnelLifecycleResult
    ) -> String {
        "\(result.state.rawValue): \(result.summary) Next action: \(result.nextAction) Confidence: \(result.confidence.uppercased())."
    }

    nonisolated static func summarizeTunnelSession(
        _ session: DeviceAgentTunnelSession
    ) -> String {
        "\(session.state.rawValue): \(session.summary) Ownership: \(session.ownershipSummary). Next action: \(session.nextAction)"
    }

    nonisolated static func summarizeTunnelHealthResult(
        _ result: DeviceAgentTunnelHealthResult
    ) -> String {
        let protocolHint = result.protocolHint.map {
            "Protocol: \(summarizeTunnelProtocolHint($0))."
        } ?? ""
        let endpoint = result.endpointSummary.map { "Endpoint: \($0)." } ?? ""
        return "\(result.state.rawValue): \(result.summary) \(protocolHint) \(endpoint) Next action: \(result.nextAction) Confidence: \(result.confidence.uppercased())."
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func summarizeTunnelEndpointResult(
        _ result: DeviceAgentTunnelEndpointResult
    ) -> String {
        "\(result.state.rawValue): \(result.summary) Artifact: \(result.artifact.host):\(result.artifact.port). Next action: \(result.nextAction) Confidence: \(result.confidence.uppercased())."
    }

    nonisolated static func summarizeInjectionTransportProbeResult(
        _ result: DeviceAgentInjectionTransportProbeResult
    ) -> String {
        switch result.transportState {
        case .xcodeTestHarness:
            return "\(result.transportState.rawValue): \(result.summary) Input: \(result.contract.expectedInput). Next action: \(result.nextAction) Confidence: \(result.confidence.uppercased())."
        case .unavailable, .endpointBackedStub, .endpointBackedCommand:
            return "\(result.transportState.rawValue): \(result.summary) Contract: \(result.contract.contractID). Next action: \(result.nextAction) Confidence: \(result.confidence.uppercased())."
        }
    }

    nonisolated static func summarizeTunnelProtocolHint(
        _ hint: DeviceAgentTunnelProtocolHint
    ) -> String {
        switch hint {
        case .listenerOnly:
            return "Listener Only"
        case .tcpConnectVerified:
            return "TCP Connect Verified"
        case .sessionHandshakeVerified:
            return "Session Handshake Verified"
        case .rsdMarkerObserved:
            return "RSD Marker Observed"
        case .expectedRSDConnectVerified:
            return "Expected RSD Connect Verified"
        case .expectedRSDHandshakeVerified:
            return "Expected RSD Handshake Verified"
        }
    }

    nonisolated static func summarizeTunnelStage(
        _ gate: SessionReadinessGate,
        tunnelAssessment: DeviceAgentSessionAssessment? = nil
    ) -> String {
        if let summary = tunnelAssessment?.readinessSummary, !summary.isEmpty {
            return summary
        }
        switch gate {
        case .tunnelOwnership:
            return "Tunnel ownership is still being verified. The session is not yet product-owned."
        case .ready:
            if let summary = summarizeEndpointBackedInjectionReadiness(tunnelAssessment: tunnelAssessment) {
                return summary
            }
            return "Tunnel ownership is stable enough to hold a ready session boundary, but injection transport is still separate work."
        case .backendBootstrap, .deviceAttachment, .deviceSelection, .deviceInfoTransport, .injectionTransport:
            return "Tunnel probing is active, but the session has not settled into a tunnel-specific readiness boundary yet."
        }
    }

    nonisolated static func summarizeEndpointBackedInjectionReadiness(
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> String? {
        guard let probe = tunnelAssessment?.injectionTransportProbeResult else {
            return nil
        }
        switch probe.transportState {
        case .xcodeTestHarness:
            return "Direct Xcode-backed location injection is ready, so the primary transport no longer depends on Python or the compatibility tunnel path for this session."
        case .endpointBackedCommand:
            guard let endpoint = tunnelAssessment?.tunnelEndpointResult else { return nil }
            return "Verified tunnel endpoint \(endpoint.artifact.host):\(endpoint.artifact.port) is now product-owned state, and the endpoint-backed injection command adapter is ready to execute against it without rediscovering tunnel state."
        case .unavailable, .endpointBackedStub:
            return nil
        }
    }

    nonisolated static func summarizeEndpointBackedInjectionAction(
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> String? {
        guard let probe = tunnelAssessment?.injectionTransportProbeResult else {
            return nil
        }
        switch probe.transportState {
        case .xcodeTestHarness:
            return "Run set/clear through the Xcode test harness using the resolved device identifier, without rediscovering tunnel state or depending on the compatibility CLI bridge."
        case .endpointBackedCommand:
            guard let endpoint = tunnelAssessment?.tunnelEndpointResult else { return nil }
            return "Run set/clear through the endpoint-backed command adapter using verified tunnel endpoint \(endpoint.artifact.host):\(endpoint.artifact.port), while keeping the tunnel artifact as the only tunnel-side input."
        case .unavailable, .endpointBackedStub:
            return nil
        }
    }

    nonisolated static func summarizeInjectionStage(
        availabilityAssessment: DeviceAgentAvailability? = nil,
        tunnelAssessment: DeviceAgentSessionAssessment? = nil
    ) -> String {
        if let summary = summarizeEndpointBackedInjectionReadiness(tunnelAssessment: tunnelAssessment) {
            return summary
        }
        if let tunnelSummary = tunnelAssessment?.readinessSummary, !tunnelSummary.isEmpty {
            return "\(tunnelSummary) Injection transport is not yet ready to execute."
        }
        if let summary = availabilityAssessment?.summary, !summary.isEmpty {
            return summary
        }
        return "A ready session boundary may exist, but location injection transport is not yet ready to execute."
    }

    nonisolated static func summarizeInjectionAction(
        availabilityAssessment: DeviceAgentAvailability? = nil,
        tunnelAssessment: DeviceAgentSessionAssessment? = nil
    ) -> String {
        if let action = summarizeEndpointBackedInjectionAction(tunnelAssessment: tunnelAssessment) {
            return action
        }
        if let nextAction = availabilityAssessment?.nextAction, !nextAction.isEmpty {
            return nextAction
        }
        return "Keep the verified tunnel endpoint as the only tunnel-side input, and do not rediscover tunnel state in a parallel injection path."
    }

    nonisolated static func summarizeTunnelAction(
        _ gate: SessionReadinessGate,
        tunnelAssessment: DeviceAgentSessionAssessment? = nil
    ) -> String {
        if let nextAction = tunnelAssessment?.nextAction, !nextAction.isEmpty {
            return nextAction
        }
        switch gate {
        case .tunnelOwnership:
            return "Next action should verify that tunnel state is owned and reproducible, not just observed."
        case .ready:
            return "Next action should preserve the ready tunnel boundary while later transport layers are added."
        case .backendBootstrap, .deviceAttachment, .deviceSelection, .deviceInfoTransport, .injectionTransport:
            return "Next action should continue tunnel-side probing until ownership becomes explicit."
        }
    }

    nonisolated static func mapProbeFocus(_ focus: DeviceAgentProbeFocus) -> DeviceProbeFocus {
        switch focus {
        case .attachment:
            return .attachment
        case .selection:
            return .selection
        case .deviceInfo:
            return .deviceInfo
        }
    }

    nonisolated static func mapRefreshScope(_ scope: DeviceAgentRefreshScope) -> SessionRefreshScope {
        switch scope {
        case .deviceOnly:
            return .deviceOnly
        case .tunnelOnly:
            return .tunnelOnly
        case .full:
            return .full
        }
    }

    nonisolated static func isState(
        _ state: DeviceSessionState,
        matching expected: DeviceSessionState
    ) -> Bool {
        switch (state, expected) {
        case (.backendUnavailable, .backendUnavailable),
            (.disconnected, .disconnected),
            (.usbDetected, .usbDetected),
            (.multipleDevices, .multipleDevices),
            (.deviceInfoPending, .deviceInfoPending),
            (.tunnelObservationOnly, .tunnelObservationOnly),
            (.tunnelRequired, .tunnelRequired),
            (.injectionUnavailable, .injectionUnavailable),
            (.readyForInjection, .readyForInjection):
            return true
        case (.degraded, .degraded):
            return true
        default:
            return false
        }
    }

    nonisolated static func isBlocker(
        _ blocker: SessionBlocker,
        matching expected: SessionBlocker
    ) -> Bool {
        switch (blocker, expected) {
        case (.backendUnavailable, .backendUnavailable),
            (.noDevice, .noDevice),
            (.backendPartial, .backendPartial),
            (.multipleDevices, .multipleDevices),
            (.deviceInfoMissing, .deviceInfoMissing),
            (.injectionTransportMissing, .injectionTransportMissing),
            (.tunnelUnknown, .tunnelUnknown),
            (.legacyTunnelObserved, .legacyTunnelObserved),
            (.tunnelUnverified, .tunnelUnverified),
            (.tunnelRequired, .tunnelRequired),
            (.tunnelFailed, .tunnelFailed),
            (.injectionMissing, .injectionMissing),
            (.none, .none):
            return true
        case (.degraded, .degraded):
            return true
        default:
            return false
        }
    }

    nonisolated static func summarizeBlocker(_ blocker: SessionBlocker) -> String {
        switch blocker {
        case .backendUnavailable:
            return "Backend unavailable"
        case .noDevice:
            return "No device attached"
        case .backendPartial:
            return "Backend only partially available"
        case .multipleDevices:
            return "Multiple devices detected"
        case .deviceInfoMissing:
            return "Device info still missing"
        case .tunnelUnknown:
            return "Tunnel requirement unknown"
        case .legacyTunnelObserved:
            return "Legacy tunnel process observed"
        case .tunnelUnverified:
            return "Tunnel state unverified"
        case .tunnelRequired:
            return "Tunnel required"
        case .tunnelFailed:
            return "Product-owned tunnel startup failed"
        case .injectionMissing:
            return "Location injection transport unavailable"
        case .injectionTransportMissing:
            return "Injection transport gate still blocked"
        case .degraded(let reason):
            return reason
        case .none:
            return "No blocker"
        }
    }

    nonisolated static func nextAction(
        for blocker: SessionBlocker,
        snapshot: DeviceSnapshot,
        deviceProbeFocus: DeviceProbeFocus? = nil,
        deviceAssessment: DeviceAgentSessionAssessment? = nil
    ) -> String {
        let snapshotName = snapshot.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? snapshot.deviceName!.trimmingCharacters(in: .whitespacesAndNewlines)
            : (snapshot.isConnected ? "iPhone" : "No Device")
        if let deviceProbeFocus {
            switch deviceProbeFocus {
            case .attachment:
                return "Keep the probe on attachment: connect one iPhone over USB, unlock it, and trust this Mac so the session can move past device attachment."
            case .selection:
                return "Keep the probe on selection: leave only one target device attached or add explicit device selection before deeper session work."
            case .deviceInfo:
                return "Keep the probe on device info: add lockdown or equivalent metadata transport so \(snapshotName) can move beyond raw USB visibility."
            }
        }
        switch blocker {
        case .backendUnavailable:
            return "Probe the backend again before attempting device operations."
        case .noDevice:
            return "Attach an iPhone over USB and trust this Mac on the device."
        case .backendPartial:
            return "Backend transport sees \(snapshotName), but readiness is still partial. Continue wiring session services."
        case .multipleDevices:
            return "Disconnect extra iPhones or add explicit device selection before deeper session work."
        case .deviceInfoMissing:
            if let typedMetadataSession = deviceAssessment?.typedMetadataSession {
                return "Promote \(typedMetadataSession.sessionID) beyond seed-only metadata so the backend can move into tunnel ownership."
            }
            return "Implement device-info transport so the backend can move past USB-only visibility."
        case .injectionTransportMissing:
            return "Keep the verified tunnel endpoint as the only tunnel-side input and finish wiring the injection layer before treating the backend as fully teleport-ready."
        case .tunnelUnknown:
            if let typedMetadataSession = deviceAssessment?.typedMetadataSession,
               typedMetadataSession.state == .resolvedIdentity {
                return "Use resolved metadata session \(typedMetadataSession.sessionID) to infer tunnel requirement and replace legacy tunnel observation."
            }
            return "Add iOS version and transport state discovery before deciding whether tunnel setup is required."
        case .legacyTunnelObserved:
            return "A legacy tunnel process was observed, but the device-agent backend should not trust process presence as readiness."
        case .tunnelUnverified:
            return "Verify tunnel lifecycle through product-owned transport state before treating tunnel presence as ready."
        case .tunnelRequired:
            return "Bring up the required tunnel session before attempting injection."
        case .tunnelFailed:
            return "Retry the product-owned tunnel startup after inspecting the latest failure instead of relying on legacy tunnel observation."
        case .injectionMissing:
            return "The session can see \(snapshotName), but the active device-agent injection transport is still unavailable."
        case .none:
            return "The session is healthy and should accept location injection."
        case .degraded(let reason):
            return reason
        }
    }

    nonisolated static func summarizeLocationCommandRecord(
        _ record: LocationCommandRecord
    ) -> String {
        var parts: [String] = [
            "\(record.action.title)",
            "\(record.outcome.title)",
            record.backendTrack.shortLabel
        ]
        if let exitCode = record.exitCode {
            parts.append("exit \(exitCode)")
        }
        if !record.diagnosticLines.isEmpty {
            parts.append("\(record.diagnosticLines.count) diagnostics")
        }
        parts.append(record.summary)
        if let detail = record.detail, !detail.isEmpty {
            parts.append(detail)
        }
        return parts.joined(separator: " · ")
    }

    func resetRuntimeState() {
        backendAvailability = .unavailable("Backend not initialized")
        backendCapabilities = BackendCapabilities(
            canDiscoverDevices: false,
            canObserveTunnel: false,
            canInjectLocation: false
        )
        resolvedCLIPath = ""
        deviceSnapshot = DeviceSnapshot(
            isConnected: false,
            connectionSummary: "INITIALIZING...",
            iosVersion: nil,
            deviceName: nil,
            deviceIdentifier: nil,
            serialSuffix: nil,
            vendorID: nil,
            productID: nil,
            probeSource: nil,
            matchedDeviceCount: 0
        )
        tunnelState = .notRequired
        availabilityAssessment = nil
        deviceAssessment = nil
        tunnelAssessment = nil
        lastLocationCommandRecord = nil
    }
}
