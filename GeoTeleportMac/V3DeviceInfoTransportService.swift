import Foundation

protocol DeviceInfoTransportServing {
    var transportID: String { get }
    func probeTransport(from probe: DeviceAgentUSBIdentityProbe) -> DeviceAgentDeviceInfoTransportProbeResult
}

struct DeviceInfoTransportServiceStack: DeviceInfoTransportServing {
    let services: [any DeviceInfoTransportServing]

    var transportID: String {
        services.first?.transportID ?? "device-info.transport.none"
    }

    init(services: [any DeviceInfoTransportServing] = [
        ReservedTypedMetadataDeviceInfoTransportService(),
        StubDeviceInfoTransportService()
    ]) {
        self.services = services
    }

    func probeTransport(from probe: DeviceAgentUSBIdentityProbe) -> DeviceAgentDeviceInfoTransportProbeResult {
        let results = services.map { $0.probeTransport(from: probe) }
        if let ready = results.first(where: { $0.transportState == .bootstrapReady }) {
            return ready
        }
        return results.last ?? NullDeviceInfoTransportService().probeTransport(from: probe)
    }
}

struct ReservedTypedMetadataDeviceInfoTransportService: DeviceInfoTransportServing {
    let transportID = "device-info.transport.typed-metadata.reserved"

    func probeTransport(from probe: DeviceAgentUSBIdentityProbe) -> DeviceAgentDeviceInfoTransportProbeResult {
        let contract = DeviceAgentDeviceInfoTransportContract(
            contractID: "device-info.transport.typed-metadata",
            phase: probe.hasBootstrapCandidateIdentity ? .bootstrapCandidate : .probeOnly,
            summary: probe.hasBootstrapCandidateIdentity
                ? "A dedicated typed metadata transport slot is reserved and can accept a real implementation."
                : "The reserved typed metadata slot exists, but current USB identity is still too weak to seed it.",
            expectedArtifact: "Typed device metadata session"
        )

        if probe.hasBootstrapCandidateIdentity {
            let resolvedIdentity = probe.hasResolvedIdentity
            let typedMetadataArtifact = DeviceAgentTypedMetadataArtifact(
                artifactID: resolvedIdentity
                    ? "typed-metadata.resolved.usb-identity"
                    : "typed-metadata.seed.usb-identity",
                sourceTransportID: transportID,
                deviceName: probe.displayName,
                serialSuffix: probe.serialSuffix,
                vendorID: probe.vendorID,
                productID: probe.productID,
                iosVersion: probe.iosVersion,
                observedProperties: probe.observedProperties,
                summary: resolvedIdentity
                    ? "Resolved metadata artifact assembled from USB-visible identity so the backend can treat device identity as a typed session input."
                    : "Seed artifact assembled from USB-visible identity so a future typed metadata transport can promote it into a product-owned session."
            )
            let typedMetadataSession = DeviceAgentTypedMetadataSession(
                sessionID: resolvedIdentity
                    ? "typed-metadata.session.resolved.\(transportID)"
                    : "typed-metadata.session.seed.\(transportID)",
                sourceTransportID: transportID,
                artifactID: typedMetadataArtifact.artifactID,
                state: resolvedIdentity ? .resolvedIdentity : .seedOnly,
                summary: resolvedIdentity
                    ? "Reserved typed metadata slot resolved a device-identity metadata session from USB identity."
                    : "Reserved typed metadata slot created a seed-only metadata session boundary from USB identity.",
                nextAction: resolvedIdentity
                    ? "Use the resolved metadata session to drive tunnel requirement and lifecycle decisions."
                    : "Promote this seed-only metadata session into a resolved device metadata session once a real typed metadata transport is attached."
            )
            let typedMetadataResult = DeviceAgentTypedMetadataResult(
                state: resolvedIdentity ? .resolved : .bootstrapSeeded,
                artifact: typedMetadataArtifact,
                session: typedMetadataSession,
                summary: resolvedIdentity
                    ? "Reserved typed metadata slot resolved a typed metadata session directly from current USB identity signals."
                    : "Reserved typed metadata slot produced a bootstrap seed artifact and a seed-only metadata session from current USB identity signals.",
                nextAction: resolvedIdentity
                    ? "Thread this resolved metadata session into tunnel ownership and future injection planning."
                    : "Bind a real typed metadata transport to this reserved slot and promote the seed artifact into a live device metadata session.",
                confidence: resolvedIdentity ? "high" : (probe.observedProperties.count >= 3 ? "medium" : "low")
            )
            return DeviceAgentDeviceInfoTransportProbeResult(
                transportID: transportID,
                transportState: .bootstrapReady,
                contract: contract,
                typedMetadataResult: typedMetadataResult,
                summary: resolvedIdentity
                    ? "The reserved typed metadata slot resolved device identity strongly enough to act as the current metadata session source."
                    : "The reserved typed metadata slot is ready for a real backend implementation, but it is not wired yet.",
                nextAction: resolvedIdentity
                    ? "Promote the resolved metadata session into downstream tunnel and injection readiness decisions."
                    : "Attach a product-owned typed metadata transport implementation to the reserved slot and replace the bootstrap-only stub path.",
                confidence: resolvedIdentity ? "high" : "medium"
            )
        }

        return DeviceAgentDeviceInfoTransportProbeResult(
            transportID: transportID,
            transportState: .probeOnly,
            contract: contract,
            typedMetadataResult: DeviceAgentTypedMetadataResult(
                state: .unavailable,
                artifact: nil,
                session: nil,
                summary: "Reserved typed metadata slot did not create a seed artifact because USB identity is still too weak.",
                nextAction: "Strengthen USB identity inputs before expecting typed metadata seed artifacts from the reserved slot.",
                confidence: "low"
            ),
            summary: "The reserved typed metadata slot is present, but probe-only USB identity is not enough to activate it.",
            nextAction: "Strengthen USB identity inputs first, then bind a typed metadata transport implementation to this reserved slot.",
            confidence: "low"
        )
    }
}

struct StubDeviceInfoTransportService: DeviceInfoTransportServing {
    let transportID = "device-info.transport.usb-bootstrap.stub"

    func probeTransport(from probe: DeviceAgentUSBIdentityProbe) -> DeviceAgentDeviceInfoTransportProbeResult {
        if probe.hasBootstrapCandidateIdentity {
            let contract = DeviceAgentDeviceInfoTransportContract(
                contractID: "device-info.transport.bootstrap",
                phase: .bootstrapCandidate,
                summary: "USB identity is strong enough to seed a future typed metadata transport contract.",
                expectedArtifact: "Typed device metadata session"
            )
            return DeviceAgentDeviceInfoTransportProbeResult(
                transportID: transportID,
                transportState: .bootstrapReady,
                contract: contract,
                typedMetadataResult: DeviceAgentTypedMetadataResult(
                    state: .bootstrapSeeded,
                    artifact: {
                        DeviceAgentTypedMetadataArtifact(
                        artifactID: "typed-metadata.seed.bootstrap-stub",
                        sourceTransportID: transportID,
                        deviceName: probe.displayName,
                        serialSuffix: probe.serialSuffix,
                        vendorID: probe.vendorID,
                        productID: probe.productID,
                        iosVersion: probe.iosVersion,
                        observedProperties: probe.observedProperties,
                        summary: "Stub bootstrap artifact assembled from USB identity while the real typed metadata transport is still missing."
                        )
                    }(),
                    session: DeviceAgentTypedMetadataSession(
                        sessionID: "typed-metadata.session.seed.\(transportID)",
                        sourceTransportID: transportID,
                        artifactID: "typed-metadata.seed.bootstrap-stub",
                        state: .seedOnly,
                        summary: "USB bootstrap stub created a seed-only metadata session boundary from USB identity.",
                        nextAction: "Replace the stub-backed seed session with a real typed metadata session owned by the product backend."
                    ),
                    summary: "USB bootstrap stub created a temporary typed metadata seed artifact and a seed-only metadata session, but it cannot resolve a product-owned metadata session.",
                    nextAction: "Replace the stub artifact path with a real typed metadata transport implementation.",
                    confidence: probe.observedProperties.count >= 3 ? "medium" : "low"
                ),
                summary: "The USB bootstrap transport has enough identity to seed typed metadata, but it is still only a stub.",
                nextAction: "Replace the USB bootstrap stub with a typed metadata transport that resolves device identity into a product-owned session artifact.",
                confidence: "medium"
            )
        }

        let contract = DeviceAgentDeviceInfoTransportContract(
            contractID: "device-info.transport.bootstrap",
            phase: .probeOnly,
            summary: "The backend still needs stronger device identity signals before a typed metadata transport contract can bootstrap.",
            expectedArtifact: "USB identity bootstrap inputs"
        )
        return DeviceAgentDeviceInfoTransportProbeResult(
            transportID: transportID,
            transportState: .probeOnly,
            contract: contract,
            typedMetadataResult: DeviceAgentTypedMetadataResult(
                state: .unavailable,
                artifact: nil,
                session: nil,
                summary: "USB bootstrap stub cannot create a typed metadata seed artifact without stronger identity signals.",
                nextAction: "Strengthen device identity inputs or replace the stub with a typed metadata transport that can build a seed artifact.",
                confidence: "low"
            ),
            summary: "The USB bootstrap transport is still probe-only and cannot promote the USB snapshot into typed metadata yet.",
            nextAction: "Strengthen device identity inputs or wire a metadata transport so the backend can move beyond probe-only USB state.",
            confidence: "low"
        )
    }
}

private struct NullDeviceInfoTransportService: DeviceInfoTransportServing {
    let transportID = "device-info.transport.none"

    func probeTransport(from probe: DeviceAgentUSBIdentityProbe) -> DeviceAgentDeviceInfoTransportProbeResult {
        DeviceAgentDeviceInfoTransportProbeResult(
            transportID: transportID,
            transportState: .probeOnly,
            contract: DeviceAgentDeviceInfoTransportContract(
                contractID: "device-info.transport.none",
                phase: .probeOnly,
                summary: "No device-info transport service has been registered.",
                expectedArtifact: "Registered device-info transport"
            ),
            typedMetadataResult: DeviceAgentTypedMetadataResult(
                state: .unavailable,
                artifact: nil,
                session: nil,
                summary: "No typed metadata seed artifact is available because no device-info transport service is registered.",
                nextAction: "Register at least one device-info transport service before expecting typed metadata artifacts.",
                confidence: "low"
            ),
            summary: "No device-info transport service is active.",
            nextAction: "Register at least one device-info transport service before probing typed metadata readiness.",
            confidence: "low"
        )
    }
}

struct DeviceAgentUSBIdentityProbe {
    let hasBootstrapCandidateIdentity: Bool
    let displayName: String?
    let serialSuffix: String?
    let vendorID: String?
    let productID: String?
    let speed: String?
    let iosVersion: String?

    var observedProperties: [String] {
        var properties: [String] = []
        if let displayName, !displayName.isEmpty {
            properties.append("deviceName")
        }
        if let serialSuffix, !serialSuffix.isEmpty {
            properties.append("serialSuffix")
        }
        if let vendorID, !vendorID.isEmpty {
            properties.append("vendorID")
        }
        if let productID, !productID.isEmpty {
            properties.append("productID")
        }
        if let speed, !speed.isEmpty {
            properties.append("speed")
        }
        if let iosVersion, !iosVersion.isEmpty {
            properties.append("iosVersion")
        }
        return properties
    }

    var hasResolvedIdentity: Bool {
        let hasStableIdentifiers = !(vendorID?.isEmpty ?? true) && !(productID?.isEmpty ?? true)
        let hasHumanIdentity = !(displayName?.isEmpty ?? true) || !(serialSuffix?.isEmpty ?? true)
        return hasBootstrapCandidateIdentity && hasStableIdentifiers && hasHumanIdentity
    }
}
