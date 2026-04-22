import SwiftUI

struct StatusDisplayModel {
    let title: String
    let subtitle: String?
    let icon: String
    let tint: Color
    let showSpinner: Bool
}

struct V3ViewPresentation {
    static func environmentBadgeText(appModel: V3AppModel) -> String {
        if appModel.backendTrack == .noPythonStub {
            switch appModel.effectiveRefreshScope {
            case .full:
                return "ENV: FULL PROBE"
            case .deviceOnly:
                return "ENV: DEVICE PROBE"
            case .tunnelOnly:
                return "ENV: TUNNEL PROBE"
            }
        }
        return appModel.isEnvironmentReady ? "ENV: READY" : "ENV: MISSING"
    }

    static func environmentTint(
        appModel: V3AppModel,
        terminalGreen: Color,
        alertRed: Color
    ) -> Color {
        if appModel.backendTrack == .noPythonStub {
            switch appModel.readinessGate {
            case .backendBootstrap:
                return alertRed
            case .deviceAttachment, .deviceSelection, .deviceInfoTransport, .tunnelOwnership, .injectionTransport:
                return Color(red: 1.0, green: 0.80, blue: 0.30)
            case .ready:
                return terminalGreen
            }
        }
        return appModel.isEnvironmentReady ? terminalGreen : alertRed
    }

    static func refreshActionLabel(appModel: V3AppModel) -> String {
        appModel.preferredRefreshHelpText
    }

    static func statusDisplay(
        status: AppStatus,
        appModel: V3AppModel,
        coordsValid: Bool,
        accentBlue: Color,
        terminalGreen: Color,
        alertRed: Color
    ) -> StatusDisplayModel {
        switch status {
        case .idle:
            if appModel.backendTrack == .noPythonStub {
                let capabilities = appModel.backendCapabilitySummary
                let blockerTitle = appModel.sessionBlocker.title
                let sessionTitle: String
                let icon: String
                let tint: Color
                if appModel.availabilityAssessment != nil,
                   appModel.deviceAssessment == nil,
                   appModel.tunnelAssessment == nil {
                    switch appModel.readinessGate {
                    case .backendBootstrap:
                        sessionTitle = "No-Python backend bootstrapping"
                        icon = "wrench.adjustable"
                        tint = alertRed
                    case .injectionTransport:
                        sessionTitle = "No-Python backend bootstrapped"
                        icon = "server.rack"
                        tint = Color(red: 1.0, green: 0.80, blue: 0.30)
                    default:
                        sessionTitle = "No-Python backend preparing"
                        icon = "server.rack"
                        tint = Color(red: 1.0, green: 0.80, blue: 0.30)
                    }
                } else if appModel.effectiveRefreshScope == .tunnelOnly {
                    switch appModel.readinessGate {
                    case .tunnelOwnership:
                        sessionTitle = "Tunnel ownership probe active"
                        icon = "network.badge.shield.half.filled"
                        tint = Color(red: 1.0, green: 0.80, blue: 0.30)
                    case .ready:
                        sessionTitle = "Tunnel probe holding ready session"
                        icon = "checkmark.shield.fill"
                        tint = terminalGreen
                    case .backendBootstrap, .deviceAttachment, .deviceSelection, .deviceInfoTransport, .injectionTransport:
                        sessionTitle = "Tunnel probe active"
                        icon = "network"
                        tint = Color(red: 1.0, green: 0.80, blue: 0.30)
                    }
                } else {
                    switch appModel.sessionState {
                    case .backendUnavailable:
                        sessionTitle = "No-Python backend unavailable"
                        icon = "wrench.adjustable"
                        tint = alertRed
                    case .disconnected:
                        sessionTitle = "No-Python backend waiting for device"
                        icon = "iphone.gen3.slash"
                        tint = alertRed
                    case .usbDetected:
                        sessionTitle = "USB session detected"
                        icon = "cable.connector"
                        tint = Color(red: 1.0, green: 0.80, blue: 0.30)
                    case .multipleDevices:
                        sessionTitle = "Multiple devices detected"
                        icon = "rectangle.on.rectangle.badge.person.crop"
                        tint = Color(red: 1.0, green: 0.80, blue: 0.30)
                    case .deviceInfoPending:
                        sessionTitle = "No-Python device info pending"
                        icon = "iphone.gen3.radiowaves.left.and.right"
                        tint = Color(red: 1.0, green: 0.80, blue: 0.30)
                    case .tunnelObservationOnly:
                        sessionTitle = "Tunnel observation only"
                        icon = "eye.trianglebadge.exclamationmark"
                        tint = Color(red: 1.0, green: 0.80, blue: 0.30)
                    case .tunnelRequired:
                        if appModel.sessionBlocker == .tunnelFailed {
                            sessionTitle = "No-Python tunnel startup failed"
                            icon = "xmark.shield.fill"
                            tint = alertRed
                        } else {
                            sessionTitle = "No-Python session needs tunnel"
                            icon = "lock.shield.fill"
                            tint = Color(red: 1.0, green: 0.80, blue: 0.30)
                        }
                    case .injectionUnavailable:
                        if appModel.readinessGate == .injectionTransport {
                            sessionTitle = "Ready session boundary held"
                            icon = "shield.lefthalf.filled"
                        } else {
                            sessionTitle = "No-Python session visible"
                            icon = "hammer.circle.fill"
                        }
                        tint = Color(red: 1.0, green: 0.80, blue: 0.30)
                    case .readyForInjection:
                        sessionTitle = "No-Python session ready"
                        icon = "checkmark.seal.fill"
                        tint = terminalGreen
                    case .degraded:
                        sessionTitle = "No-Python session degraded"
                        icon = "exclamationmark.triangle.fill"
                        tint = alertRed
                    }
                }
                return StatusDisplayModel(
                    title: sessionTitle,
                    subtitle: [
                        appModel.bootstrapSummary,
                        appModel.sessionSummary,
                        appModel.injectionStageSummary,
                        appModel.tunnelStageSummary,
                        appModel.healthSummary,
                        "Gate: \(appModel.readinessGate.title).",
                        appModel.refreshIntentSummary,
                        appModel.refreshIntentDetail,
                        appModel.refreshActionDetail,
                        appModel.probeFocusSummary,
                        appModel.probeFocusDetail,
                        appModel.deviceInfoStageSummary,
                        appModel.deviceInfoTransportSummary,
                        appModel.deviceInfoTransportSlotSummary,
                        appModel.deviceInfoProbeResultSummary,
                        appModel.deviceInfoContractSummary,
                        appModel.typedMetadataResultSummary,
                        appModel.typedMetadataArtifactSummary,
                        appModel.typedMetadataSessionSummary,
                        appModel.readinessGateSummary,
                        appModel.bootstrapNextAction.isEmpty ? "" : "Bootstrap: \(appModel.bootstrapNextAction)",
                        appModel.tunnelAssessmentSummary,
                        appModel.tunnelRequirementSummary,
                        appModel.tunnelLifecycleSummary,
                        appModel.tunnelSessionSummary,
                        appModel.tunnelHealthSummary,
                        appModel.tunnelIntentSummary,
                        appModel.injectionStageActionText,
                        appModel.tunnelStageActionText,
                        appModel.tunnelConfidenceSummary,
                        "Blocker: \(blockerTitle).",
                        "Next: \(appModel.nextActionText)",
                        appModel.assessmentConfidenceText,
                        "Capabilities: \(capabilities)."
                    ]
                        .filter { !$0.isEmpty }
                        .joined(separator: " "),
                    icon: icon,
                    tint: tint,
                    showSpinner: false
                )
            }
            if !appModel.isEnvironmentReady {
                return StatusDisplayModel(
                    title: "Device backend unavailable",
                    subtitle: "The current preview still depends on the legacy transport layer. Press Rescan to probe it again.",
                    icon: "wrench.adjustable",
                    tint: alertRed,
                    showSpinner: false
                )
            }
            if !appModel.isDeviceConnected {
                return StatusDisplayModel(
                    title: "Connect your iPhone",
                    subtitle: "Plug in via USB and trust this Mac on the device.",
                    icon: "iphone.gen3.slash",
                    tint: alertRed,
                    showSpinner: false
                )
            }
            if appModel.needsTunnel {
                return StatusDisplayModel(
                    title: "iOS \(appModel.deviceIOSVersion) needs the tunnel first",
                    subtitle: "Start the required tunnel session, then retry the teleport.",
                    icon: "lock.shield.fill",
                    tint: Color(red: 1.0, green: 0.80, blue: 0.30),
                    showSpinner: false
                )
            }
            if !coordsValid {
                return StatusDisplayModel(
                    title: "Invalid coordinates",
                    subtitle: "Latitude must be -90...90, longitude must be -180...180.",
                    icon: "exclamationmark.triangle.fill",
                    tint: Color(red: 1.0, green: 0.80, blue: 0.30),
                    showSpinner: false
                )
            }
            return StatusDisplayModel(
                title: "Ready to teleport",
                subtitle: "Drag the pin, search a city, or tap a preset.",
                icon: "checkmark.seal.fill",
                tint: terminalGreen,
                showSpinner: false
            )
        case .working(let title, let subtitle):
            return StatusDisplayModel(
                title: title,
                subtitle: subtitle,
                icon: "bolt.circle.fill",
                tint: accentBlue,
                showSpinner: true
            )
        case .success(let title, let subtitle):
            return StatusDisplayModel(
                title: title,
                subtitle: subtitle,
                icon: "checkmark.circle.fill",
                tint: terminalGreen,
                showSpinner: false
            )
        case .failure(let title, let subtitle):
            return StatusDisplayModel(
                title: title,
                subtitle: subtitle,
                icon: "xmark.octagon.fill",
                tint: alertRed,
                showSpinner: false
            )
        }
    }

    static func buttonTitle(
        isWorking: Bool,
        appModel: V3AppModel,
        coordsValid: Bool
    ) -> String {
        if isWorking { return "EXECUTING..." }
        if appModel.backendTrack == .noPythonStub {
            if appModel.availabilityAssessment != nil,
               appModel.deviceAssessment == nil,
               appModel.tunnelAssessment == nil {
                switch appModel.readinessGate {
                case .backendBootstrap:
                    return "BOOTSTRAPPING BACKEND"
                case .injectionTransport:
                    return appModel.isDeviceConnected ? "WIRE INJECTION TRANSPORT" : "ATTACH DEVICE TO CONTINUE"
                default:
                    return "PREPARING BACKEND"
                }
            }
            if appModel.effectiveRefreshScope == .tunnelOnly {
                switch appModel.readinessGate {
                case .tunnelOwnership:
                    return "VERIFY TUNNEL OWNERSHIP"
                case .ready:
                    return "HOLD READY SESSION BOUNDARY"
                case .backendBootstrap, .deviceAttachment, .deviceSelection, .deviceInfoTransport, .injectionTransport:
                    return "RUN TUNNEL PROBE"
                }
            }
            switch appModel.sessionBlocker {
            case .backendUnavailable:
                return "BACKEND UNAVAILABLE"
            case .noDevice:
                return "ATTACH & TRUST DEVICE"
            case .backendPartial:
                return "FINISH SESSION WIRING"
            case .multipleDevices:
                return "RESOLVE DEVICE SELECTION"
            case .deviceInfoMissing:
                return "WIRE DEVICE-INFO TRANSPORT"
            case .injectionTransportMissing:
                return "WIRE INJECTION TRANSPORT"
            case .tunnelUnknown:
                return "TUNNEL STATE UNKNOWN"
            case .legacyTunnelObserved:
                return "LEGACY TUNNEL OBSERVED"
            case .tunnelUnverified:
                return "VERIFY TUNNEL STATE"
            case .tunnelRequired:
                return "START TUNNEL FIRST"
            case .tunnelFailed:
                return "RETRY TUNNEL STARTUP"
            case .injectionMissing:
                return appModel.readinessGate == .injectionTransport
                    ? "WIRE INJECTION TRANSPORT"
                    : "INJECTION NOT IMPLEMENTED YET"
            case .degraded:
                return "SESSION DEGRADED"
            case .none:
                break
            }
        }
        if !appModel.isEnvironmentReady { return "BACKEND UNAVAILABLE" }
        if !appModel.isDeviceConnected { return "WAITING FOR USB..." }
        if appModel.needsTunnel { return "START TUNNEL FIRST" }
        if !coordsValid { return "INVALID COORDS" }
        return ">>> CONFIRM & JUMP <<<"
    }

    static func canTeleport(
        isWorking: Bool,
        appModel: V3AppModel,
        coordsValid: Bool
    ) -> Bool {
        if appModel.backendTrack == .noPythonStub {
            return !isWorking && appModel.sessionState == .readyForInjection && coordsValid
        }
        return !isWorking && appModel.isDeviceConnected && appModel.isEnvironmentReady && coordsValid && !appModel.needsTunnel
    }

    static func shouldShowButtonWarning(
        appModel: V3AppModel,
        coordsValid: Bool
    ) -> Bool {
        if appModel.backendTrack == .noPythonStub {
            return appModel.sessionState != .readyForInjection || !coordsValid
        }
        return !appModel.isDeviceConnected || !appModel.isEnvironmentReady || !coordsValid || appModel.needsTunnel
    }
}
