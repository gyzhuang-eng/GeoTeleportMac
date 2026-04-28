import Foundation

enum BackendTrack: String, CaseIterable {
    case noPythonStub

    static var primaryTrack: BackendTrack { .noPythonStub }
    static var userSelectableCases: [BackendTrack] { [.noPythonStub] }

    nonisolated var displayName: String {
        switch self {
        case .noPythonStub:
            return "Device Agent"
        }
    }

    nonisolated var shortLabel: String {
        switch self {
        case .noPythonStub:
            return "AGENT"
        }
    }
}

struct BackendCapabilities: Equatable {
    let canDiscoverDevices: Bool
    let canObserveTunnel: Bool
    let canInjectLocation: Bool

    var summary: String {
        let device = canDiscoverDevices ? "device probe" : "device probe missing"
        let tunnel = canObserveTunnel ? "tunnel observe" : "tunnel observe missing"
        let inject = canInjectLocation ? "location inject" : "location inject missing"
        return [device, tunnel, inject].joined(separator: " · ")
    }
}

enum DeviceSessionState: Equatable {
    case backendUnavailable
    case disconnected
    case usbDetected
    case multipleDevices
    case deviceInfoPending
    case tunnelObservationOnly
    case tunnelRequired
    case injectionUnavailable
    case readyForInjection
    case degraded(String)

    nonisolated var title: String {
        switch self {
        case .backendUnavailable:
            return "Backend Unavailable"
        case .disconnected:
            return "No Device Session"
        case .usbDetected:
            return "USB Device Detected"
        case .multipleDevices:
            return "Multiple Devices Detected"
        case .deviceInfoPending:
            return "Device Info Pending"
        case .tunnelObservationOnly:
            return "Tunnel Observation Only"
        case .tunnelRequired:
            return "Tunnel Required"
        case .injectionUnavailable:
            return "Injection Unavailable"
        case .readyForInjection:
            return "Ready For Injection"
        case .degraded:
            return "Degraded Session"
        }
    }
}

enum SessionBlocker: Equatable {
    case backendUnavailable
    case noDevice
    case backendPartial
    case xcodeToolchainMissing
    case pymobiledevice3Missing
    case bundledDeviceCoreMissing
    case multipleDevices
    case deviceInfoMissing
    case injectionTransportMissing
    case tunnelUnknown
    case legacyTunnelObserved
    case tunnelUnverified
    case tunnelRequired
    case tunnelFailed
    case injectionMissing
    case degraded(String)
    case none

    nonisolated var title: String {
        switch self {
        case .backendUnavailable:
            return "Backend Unavailable"
        case .noDevice:
            return "No Device"
        case .backendPartial:
            return "Backend Partial"
        case .xcodeToolchainMissing:
            return "Deprecated Bootstrap Blocker"
        case .pymobiledevice3Missing:
            return "Deprecated Bootstrap Blocker"
        case .bundledDeviceCoreMissing:
            return "Bundled Device Core Missing"
        case .multipleDevices:
            return "Multiple Devices"
        case .deviceInfoMissing:
            return "Device Info Missing"
        case .injectionTransportMissing:
            return "Injection Transport Missing"
        case .tunnelUnknown:
            return "Tunnel Unknown"
        case .legacyTunnelObserved:
            return "Legacy Tunnel Observed"
        case .tunnelUnverified:
            return "Tunnel Unverified"
        case .tunnelRequired:
            return "Tunnel Required"
        case .tunnelFailed:
            return "Tunnel Failed"
        case .injectionMissing:
            return "Injection Missing"
        case .degraded:
            return "Session Degraded"
        case .none:
            return "No Blocker"
        }
    }
}

enum SessionReadinessGate: Equatable {
    case backendBootstrap
    case deviceAttachment
    case deviceSelection
    case deviceInfoTransport
    case tunnelOwnership
    case injectionTransport
    case ready

    nonisolated var title: String {
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

enum ConnectionHealth: Equatable {
    case offline
    case partial
    case unstable
    case degraded
    case healthy

    nonisolated var label: String {
        switch self {
        case .offline:
            return "OFFLINE"
        case .partial:
            return "PARTIAL"
        case .unstable:
            return "UNSTABLE"
        case .degraded:
            return "DEGRADED"
        case .healthy:
            return "HEALTHY"
        }
    }
}

enum BackendAvailability: Equatable {
    case unavailable(String)
    case partial(String)
    case ready

    nonisolated var summary: String? {
        switch self {
        case .unavailable(let value), .partial(let value):
            return value
        case .ready:
            return nil
        }
    }

    nonisolated var isReady: Bool {
        if case .ready = self {
            return true
        }
        return false
    }

    nonisolated var isUnavailable: Bool {
        if case .unavailable = self {
            return true
        }
        return false
    }

    nonisolated var canRefreshDeviceState: Bool {
        switch self {
        case .partial, .ready:
            return true
        case .unavailable:
            return false
        }
    }
}

struct DevicePickerEntry: Codable, Equatable, Identifiable {
    let udid: String
    let name: String
    let iosVersion: String?
    var id: String { udid }
}

struct DeviceSnapshot: Codable, Equatable {
    let isConnected: Bool
    let connectionSummary: String
    let iosVersion: String?
    let deviceName: String?
    let deviceIdentifier: String?
    let serialSuffix: String?
    let vendorID: String?
    let productID: String?
    let probeSource: String?
    let matchedDeviceCount: Int
    var availableDevices: [DevicePickerEntry]?

    nonisolated var iosMajorVersion: Int? {
        guard let iosVersion else { return nil }
        return Int(iosVersion.split(separator: ".").first ?? "")
    }

    nonisolated var displayName: String {
        let trimmedName = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedName.isEmpty {
            return trimmedName
        }
        return isConnected ? "iPhone" : "No Device"
    }
}

enum TunnelState: Codable, Equatable {
    case notRequired
    case requiredInactive
    case starting
    case active
    case failed
}

struct TeleportRequest: Codable, Equatable {
    let latitude: String
    let longitude: String
}

struct TeleportResponse: Codable, Equatable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

struct LocationCommandExecution: Equatable {
    let response: TeleportResponse
    let diagnosticLines: [String]
}

enum BackendFailure: Error, Equatable {
    case unavailable(String)
    case invalidRequest(String)
    case executionFailed(String)
}

enum LocationCommandAction: String, Equatable {
    case set
    case clear

    nonisolated var title: String {
        switch self {
        case .set:
            return "Set Location"
        case .clear:
            return "Clear Location"
        }
    }
}

enum LocationCommandOutcome: String, Equatable {
    case succeeded
    case failed

    nonisolated var title: String {
        switch self {
        case .succeeded:
            return "Succeeded"
        case .failed:
            return "Failed"
        }
    }
}

struct LocationCommandRecord: Equatable {
    let action: LocationCommandAction
    let backendTrack: BackendTrack
    let outcome: LocationCommandOutcome
    let summary: String
    let detail: String?
    let exitCode: Int32?
    let stdout: String?
    let stderr: String?
    let diagnosticLines: [String]
}

protocol DeviceBackend {
    var track: BackendTrack { get }
    var capabilities: BackendCapabilities { get }
    func probeAvailability() -> BackendAvailability
    func fetchConnectedDevice() -> DeviceSnapshot
    func fetchTunnelState(for device: DeviceSnapshot) -> TunnelState
    func setLocation(_ request: TeleportRequest) -> Result<LocationCommandExecution, BackendFailure>
    func clearLocation() -> Result<LocationCommandExecution, BackendFailure>
}
