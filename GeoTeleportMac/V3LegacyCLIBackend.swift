import Foundation

struct LegacyCLIBackend: DeviceBackend {
    let track: BackendTrack = .legacyPreview
    let capabilities = BackendCapabilities(
        canDiscoverDevices: true,
        canObserveTunnel: true,
        canInjectLocation: true
    )
    private let pathResolver: LegacyCLIPathResolving
    private let deviceTransport: V3LegacyDeviceTransport
    private let locationTransport: V3LegacyLocationTransport

    init(pathResolver: LegacyCLIPathResolving = V3LegacyCLIPathResolver()) {
        self.pathResolver = pathResolver
        self.deviceTransport = V3LegacyDeviceTransport(pathResolver: pathResolver)
        self.locationTransport = V3LegacyLocationTransport(pathResolver: pathResolver)
    }

    func probeAvailability() -> BackendAvailability {
        if resolvedCLIPath() == nil {
            return .unavailable("Legacy device backend not found")
        }
        return .ready
    }

    func fetchConnectedDevice() -> DeviceSnapshot {
        deviceTransport.fetchConnectedDevice()
    }

    func fetchTunnelState(for device: DeviceSnapshot) -> TunnelState {
        deviceTransport.fetchTunnelState(for: device)
    }

    func setLocation(_ request: TeleportRequest) -> Result<TeleportResponse, BackendFailure> {
        locationTransport.setLocation(request)
    }

    func resolvedCLIPath() -> String? {
        pathResolver.resolvedCLIPath()
    }
}
