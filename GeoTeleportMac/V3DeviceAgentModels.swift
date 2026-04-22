import Foundation

enum DeviceAgentErrorCode: String, Codable, Equatable {
    case agentUnavailable
    case transportUnimplemented
    case unsupportedOperation
    case invalidRequest
}

struct DeviceAgentFailure: Error, Codable, Equatable {
    let code: DeviceAgentErrorCode
    let message: String
}

enum DeviceAgentEventLevel: String, Codable, Equatable {
    case info
    case warning
    case error
}

struct DeviceAgentDiagnosticEvent: Codable, Equatable {
    let level: DeviceAgentEventLevel
    let message: String

    var logLine: String {
        let prefix: String
        switch level {
        case .info:
            prefix = "[AGENT]"
        case .warning:
            prefix = "[AGENT][WARN]"
        case .error:
            prefix = "[AGENT][ERR]"
        }
        return "\(prefix) \(message)"
    }
}

struct DeviceAgentAvailability: Codable, Equatable {
    let isReachable: Bool
    let summary: String
    let readinessGate: DeviceAgentReadinessGate
    let refreshIntent: DeviceAgentRefreshIntent?
    let recommendedProbeFocus: DeviceAgentProbeFocus?
    let nextAction: String
    let blockerCodes: [DeviceAgentAssessmentBlockerCode]
    let confidence: String
    let events: [DeviceAgentDiagnosticEvent]
}

enum DeviceAgentProbeFocus: String, Codable, Equatable {
    case attachment
    case selection
    case deviceInfo

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

enum DeviceAgentRefreshScope: String, Codable, Equatable {
    case deviceOnly
    case tunnelOnly
    case full

    var title: String {
        switch self {
        case .deviceOnly:
            return "Device Probe"
        case .tunnelOnly:
            return "Tunnel Probe"
        case .full:
            return "Full Probe"
        }
    }
}

struct DeviceAgentRefreshIntent: Codable, Equatable {
    let scope: DeviceAgentRefreshScope
    let probeFocus: DeviceAgentProbeFocus?
}

enum DeviceAgentAssessmentBlockerCode: String, Codable, Equatable {
    case noDevice
    case multipleDevices
    case deviceInfoMissing
    case injectionTransportMissing
    case tunnelUnknown
    case tunnelRequired
    case tunnelFailed
    case legacyTunnelObserved
    case tunnelUnverified

    var title: String {
        switch self {
        case .noDevice:
            return "No Device"
        case .multipleDevices:
            return "Multiple Devices"
        case .deviceInfoMissing:
            return "Device Info Missing"
        case .injectionTransportMissing:
            return "Injection Transport Missing"
        case .tunnelUnknown:
            return "Tunnel Requirement Unknown"
        case .tunnelRequired:
            return "Tunnel Required"
        case .tunnelFailed:
            return "Tunnel Failed"
        case .legacyTunnelObserved:
            return "Legacy Tunnel Observed"
        case .tunnelUnverified:
            return "Tunnel Unverified"
        }
    }
}

enum DeviceAgentTunnelRequirementState: String, Codable, Equatable {
    case undetermined
    case notRequired
    case required

    var title: String {
        switch self {
        case .undetermined:
            return "Undetermined"
        case .notRequired:
            return "Not Required"
        case .required:
            return "Required"
        }
    }
}

enum DeviceAgentTunnelLifecycleState: String, Codable, Equatable {
    case noProductOwnedTunnel
    case legacyObserved
    case productOwnedStarting
    case productOwnedActive
    case productOwnedFailed

    var title: String {
        switch self {
        case .noProductOwnedTunnel:
            return "No Product-Owned Tunnel"
        case .legacyObserved:
            return "Legacy Observed"
        case .productOwnedStarting:
            return "Product-Owned Starting"
        case .productOwnedActive:
            return "Product-Owned Active"
        case .productOwnedFailed:
            return "Product-Owned Failed"
        }
    }
}

enum DeviceAgentTunnelSessionState: String, Codable, Equatable {
    case productOwnedPending
    case productOwnedStarting
    case legacyObserved
    case productOwnedActive
    case productOwnedFailed

    var title: String {
        switch self {
        case .productOwnedPending:
            return "Product-Owned Pending"
        case .productOwnedStarting:
            return "Product-Owned Starting"
        case .legacyObserved:
            return "Legacy Observed"
        case .productOwnedActive:
            return "Product-Owned Active"
        case .productOwnedFailed:
            return "Product-Owned Failed"
        }
    }
}

enum DeviceAgentTunnelHealthState: String, Codable, Equatable {
    case pending
    case verified
    case failed

    var title: String {
        switch self {
        case .pending:
            return "Pending"
        case .verified:
            return "Verified"
        case .failed:
            return "Failed"
        }
    }
}

enum DeviceAgentTunnelProtocolHint: String, Codable, Equatable {
    case listenerOnly
    case tcpConnectVerified
    case sessionHandshakeVerified
    case rsdMarkerObserved
    case expectedRSDConnectVerified
    case expectedRSDHandshakeVerified

    var title: String {
        switch self {
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
}

enum DeviceAgentReadinessGate: String, Codable, Equatable {
    case backendBootstrap
    case deviceAttachment
    case deviceSelection
    case deviceInfoTransport
    case tunnelOwnership
    case injectionTransport
    case ready

    var title: String {
        switch self {
        case .backendBootstrap:
            return "Backend Bootstrap"
        case .deviceAttachment:
            return "Device Attachment"
        case .deviceSelection:
            return "Device Selection"
        case .deviceInfoTransport:
            return "Device Info Transport"
        case .tunnelOwnership:
            return "Tunnel Ownership"
        case .injectionTransport:
            return "Injection Transport"
        case .ready:
            return "Ready"
        }
    }
}

enum DeviceAgentDeviceInfoReadiness: String, Codable, Equatable {
    case usbVisibilityOnly
    case usbIdentityObserved
    case typedMetadataMissing

    var title: String {
        switch self {
        case .usbVisibilityOnly:
            return "USB Visibility Only"
        case .usbIdentityObserved:
            return "USB Identity Observed"
        case .typedMetadataMissing:
            return "Typed Metadata Missing"
        }
    }
}

enum DeviceAgentDeviceInfoTransportState: String, Codable, Equatable {
    case probeOnly
    case bootstrapReady

    var title: String {
        switch self {
        case .probeOnly:
            return "Probe Only"
        case .bootstrapReady:
            return "Bootstrap Ready"
        }
    }
}

enum DeviceAgentTypedMetadataResultState: String, Codable, Equatable {
    case unavailable
    case bootstrapSeeded
    case resolved

    var title: String {
        switch self {
        case .unavailable:
            return "Unavailable"
        case .bootstrapSeeded:
            return "Bootstrap Seeded"
        case .resolved:
            return "Resolved"
        }
    }
}

enum DeviceAgentTypedMetadataSessionState: String, Codable, Equatable {
    case seedOnly
    case resolvedIdentity

    var title: String {
        switch self {
        case .seedOnly:
            return "Seed Only"
        case .resolvedIdentity:
            return "Resolved Identity"
        }
    }
}

enum DeviceAgentDeviceInfoContractPhase: String, Codable, Equatable {
    case probeOnly
    case bootstrapCandidate

    var title: String {
        switch self {
        case .probeOnly:
            return "Probe Only"
        case .bootstrapCandidate:
            return "Bootstrap Candidate"
        }
    }
}

struct DeviceAgentDeviceInfoTransportContract: Codable, Equatable {
    let contractID: String
    let phase: DeviceAgentDeviceInfoContractPhase
    let summary: String
    let expectedArtifact: String
}

struct DeviceAgentTypedMetadataArtifact: Codable, Equatable {
    let artifactID: String
    let sourceTransportID: String
    let deviceName: String?
    let serialSuffix: String?
    let vendorID: String?
    let productID: String?
    let iosVersion: String?
    let observedProperties: [String]
    let summary: String
}

struct DeviceAgentTypedMetadataSession: Codable, Equatable {
    let sessionID: String
    let sourceTransportID: String
    let artifactID: String
    let state: DeviceAgentTypedMetadataSessionState
    let summary: String
    let nextAction: String
}

struct DeviceAgentTypedMetadataResult: Codable, Equatable {
    let state: DeviceAgentTypedMetadataResultState
    let artifact: DeviceAgentTypedMetadataArtifact?
    let session: DeviceAgentTypedMetadataSession?
    let summary: String
    let nextAction: String
    let confidence: String
}

struct DeviceAgentTunnelRequirementResult: Codable, Equatable {
    let state: DeviceAgentTunnelRequirementState
    let sourceMetadataSessionID: String?
    let summary: String
    let nextAction: String
    let confidence: String
}

struct DeviceAgentTunnelLifecycleResult: Codable, Equatable {
    let state: DeviceAgentTunnelLifecycleState
    let summary: String
    let nextAction: String
    let confidence: String
}

struct DeviceAgentTunnelSession: Codable, Equatable {
    let sessionID: String
    let state: DeviceAgentTunnelSessionState
    let ownershipSummary: String
    let sourceMetadataSessionID: String?
    let summary: String
    let nextAction: String
}

struct DeviceAgentTunnelHealthResult: Codable, Equatable {
    let state: DeviceAgentTunnelHealthState
    let protocolHint: DeviceAgentTunnelProtocolHint?
    let endpointSummary: String?
    let summary: String
    let nextAction: String
    let confidence: String
}

struct DeviceAgentDeviceInfoTransportProbeResult: Codable, Equatable {
    let transportID: String
    let transportState: DeviceAgentDeviceInfoTransportState
    let contract: DeviceAgentDeviceInfoTransportContract
    let typedMetadataResult: DeviceAgentTypedMetadataResult?
    let summary: String
    let nextAction: String
    let confidence: String
}

struct DeviceAgentSessionAssessment: Codable, Equatable {
    let readinessGate: DeviceAgentReadinessGate
    let readinessSummary: String
    let refreshIntent: DeviceAgentRefreshIntent?
    let recommendedProbeFocus: DeviceAgentProbeFocus?
    let deviceInfoReadiness: DeviceAgentDeviceInfoReadiness?
    let deviceInfoTransportState: DeviceAgentDeviceInfoTransportState?
    let deviceInfoTransportContract: DeviceAgentDeviceInfoTransportContract?
    let deviceInfoTransportProbeResult: DeviceAgentDeviceInfoTransportProbeResult?
    let typedMetadataResult: DeviceAgentTypedMetadataResult?
    let typedMetadataSession: DeviceAgentTypedMetadataSession?
    let tunnelRequirementResult: DeviceAgentTunnelRequirementResult?
    let tunnelLifecycleResult: DeviceAgentTunnelLifecycleResult?
    let tunnelSession: DeviceAgentTunnelSession?
    let tunnelHealthResult: DeviceAgentTunnelHealthResult?
    let nextAction: String
    let blockerCodes: [DeviceAgentAssessmentBlockerCode]
    let blockers: [String]
    let confidence: String
}

struct DeviceAgentDeviceState: Codable, Equatable {
    let snapshot: DeviceSnapshot
    let assessment: DeviceAgentSessionAssessment
    let events: [DeviceAgentDiagnosticEvent]
}

struct DeviceAgentTunnelState: Codable, Equatable {
    let tunnelState: TunnelState
    let assessment: DeviceAgentSessionAssessment?
    let events: [DeviceAgentDiagnosticEvent]
}

struct DeviceAgentTeleportResult: Codable, Equatable {
    let response: TeleportResponse
    let events: [DeviceAgentDiagnosticEvent]
}
