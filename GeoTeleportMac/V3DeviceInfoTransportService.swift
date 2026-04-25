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
        NativeDeviceCoreDeviceInfoTransportService(),
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
    let udid: String?
    let displayName: String?
    let serialSuffix: String?
    let vendorID: String?
    let productID: String?
    let speed: String?
    let iosVersion: String?

    var observedProperties: [String] {
        var properties: [String] = []
        if let udid, !udid.isEmpty {
            properties.append("udid")
        }
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

struct NativeDeviceCoreDeviceInfoTransportService: DeviceInfoTransportServing {
    let transportID = "device-info.transport.native-lockdown"

    func probeTransport(from probe: DeviceAgentUSBIdentityProbe) -> DeviceAgentDeviceInfoTransportProbeResult {
        guard let udid = probe.udid, !udid.isEmpty else {
            return makeProbeOnlyResult(reason: "No UDID available; native lockdown transport requires a UDID from device enumeration.")
        }
        guard let binaryPath = nativeDeviceCoreBinaryPath() else {
            return makeProbeOnlyResult(reason: "Native device-core binary is not built; cannot query lockdown device info.")
        }
        switch nativeDeviceCoreRun(binaryPath: binaryPath, arguments: ["device-info", udid]) {
        case .success(let output):
            return parseLockdownOutput(output, udid: udid)
        case .failure(let failure):
            return makeProbeOnlyResult(reason: classifyDeviceInfoError(failure.message))
        }
    }

    private func parseLockdownOutput(_ output: String, udid: String) -> DeviceAgentDeviceInfoTransportProbeResult {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return makeProbeOnlyResult(reason: "Failed to parse device-info JSON from native device-core.")
        }

        let deviceName = json["deviceName"] as? String
        let productVersion = json["productVersion"] as? String
        let deviceClass = json["deviceClass"] as? String
        let productType = json["productType"] as? String

        var observedProperties: [String] = ["udid"]
        if let v = deviceName, !v.isEmpty { observedProperties.append("deviceName") }
        if let v = productVersion, !v.isEmpty { observedProperties.append("productVersion") }
        if let v = deviceClass, !v.isEmpty { observedProperties.append("deviceClass") }
        if let v = productType, !v.isEmpty { observedProperties.append("productType") }

        let shortID = String(udid.prefix(8))
        let artifact = DeviceAgentTypedMetadataArtifact(
            artifactID: "typed-metadata.lockdown.\(shortID)",
            sourceTransportID: transportID,
            deviceName: deviceName,
            serialSuffix: nil,
            vendorID: nil,
            productID: nil,
            iosVersion: productVersion,
            observedProperties: observedProperties,
            summary: "Authoritative device identity resolved via native lockdown transport."
        )
        let session = DeviceAgentTypedMetadataSession(
            sessionID: "typed-metadata.session.lockdown.\(shortID)",
            sourceTransportID: transportID,
            artifactID: artifact.artifactID,
            state: .resolvedIdentity,
            summary: "Native lockdown transport resolved an authoritative device-identity metadata session.",
            nextAction: "Use this resolved session to drive tunnel requirement and lifecycle decisions."
        )
        let typedMetadataResult = DeviceAgentTypedMetadataResult(
            state: .resolved,
            artifact: artifact,
            session: session,
            summary: "Native lockdown transport resolved authoritative device identity for UDID \(shortID)…",
            nextAction: "Thread this lockdown-resolved session into tunnel ownership and injection planning.",
            confidence: "high"
        )
        return DeviceAgentDeviceInfoTransportProbeResult(
            transportID: transportID,
            transportState: .bootstrapReady,
            contract: DeviceAgentDeviceInfoTransportContract(
                contractID: "device-info.transport.native-lockdown",
                phase: .bootstrapCandidate,
                summary: "Native lockdown transport resolved authoritative device identity via usbmuxd.",
                expectedArtifact: "Authoritative device metadata from lockdown"
            ),
            typedMetadataResult: typedMetadataResult,
            summary: "Native lockdown transport resolved authoritative device identity for UDID \(shortID)…",
            nextAction: "Promote the lockdown-resolved session into tunnel and injection readiness decisions.",
            confidence: "high"
        )
    }

    private func classifyDeviceInfoError(_ msg: String) -> String {
        let normalized = msg.lowercased()
        if normalized.contains("locked") || normalized.contains("password") || normalized.contains("passcode") {
            return "iPhone is locked. Unlock the device and try again."
        }
        if normalized.contains("not paired") || normalized.contains("pairing") || normalized.contains("trust")
            || normalized.contains("ssl") || normalized.contains("certificate") {
            return "iPhone has not trusted this Mac. Unlock the device, then tap \"Trust\" on the trust-this-computer prompt."
        }
        return "Could not read device info from iPhone (\(msg)). Ensure the device is unlocked and has trusted this Mac."
    }

    private func makeProbeOnlyResult(reason: String) -> DeviceAgentDeviceInfoTransportProbeResult {
        DeviceAgentDeviceInfoTransportProbeResult(
            transportID: transportID,
            transportState: .probeOnly,
            contract: DeviceAgentDeviceInfoTransportContract(
                contractID: "device-info.transport.native-lockdown",
                phase: .probeOnly,
                summary: reason,
                expectedArtifact: "UDID and native device-core binary"
            ),
            typedMetadataResult: DeviceAgentTypedMetadataResult(
                state: .unavailable,
                artifact: nil,
                session: nil,
                summary: "Native lockdown transport is probe-only: \(reason)",
                nextAction: "Ensure a UDID is available from device enumeration and the native device-core binary is built.",
                confidence: "low"
            ),
            summary: "Native lockdown transport is probe-only.",
            nextAction: reason,
            confidence: "low"
        )
    }
}

private func nativeDeviceCoreBinaryPath(filePath: String = #filePath) -> String? {
    // Shipped DMG: binary bundled at Contents/Helpers/
    let helpersURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/geoteleport-device-core")
    if FileManager.default.isExecutableFile(atPath: helpersURL.path) {
        return helpersURL.path
    }
    if let auxURL = Bundle.main.url(forAuxiliaryExecutable: "geoteleport-device-core"),
       FileManager.default.isExecutableFile(atPath: auxURL.path) {
        return auxURL.path
    }
    // Developer build: binary lives next to the source tree
    let fileURL = URL(fileURLWithPath: filePath)
    let repositoryRoot = fileURL
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let binaryURL = repositoryRoot
        .appendingPathComponent("native-device-core", isDirectory: true)
        .appendingPathComponent("target", isDirectory: true)
        .appendingPathComponent("debug", isDirectory: true)
        .appendingPathComponent("geoteleport-device-core", isDirectory: false)
    return FileManager.default.isExecutableFile(atPath: binaryURL.path) ? binaryURL.path : nil
}

private func nativeDeviceCoreRun(
    binaryPath: String,
    arguments: [String]
) -> Result<String, DeviceAgentFailure> {
    let task = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    task.executableURL = URL(fileURLWithPath: binaryPath)
    task.arguments = arguments
    task.standardOutput = stdoutPipe
    task.standardError = stderrPipe
    do {
        try task.run()
        task.waitUntilExit()
        let outputData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        guard task.terminationStatus == 0 else {
            let msg = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(DeviceAgentFailure(
                code: .agentUnavailable,
                message: msg?.isEmpty == false ? msg! : "\(binaryPath) exited with code \(task.terminationStatus)"
            ))
        }
        return .success(String(data: outputData, encoding: .utf8) ?? "")
    } catch {
        return .failure(DeviceAgentFailure(code: .agentUnavailable, message: error.localizedDescription))
    }
}
