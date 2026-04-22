import Darwin
import Foundation

protocol DeviceAgentServicing {
    func handle(_ request: DeviceAgentRequest) -> DeviceAgentResponse
}

struct StubDeviceAgentService: DeviceAgentServicing {
    private let deviceInfoTransportService: DeviceInfoTransportServing
    private let tunnelController: TunnelStateControlling

    init(
        deviceInfoTransportService: DeviceInfoTransportServing = DeviceInfoTransportServiceStack(),
        tunnelController: TunnelStateControlling = TunnelStateControllerStack()
    ) {
        self.deviceInfoTransportService = deviceInfoTransportService
        self.tunnelController = tunnelController
    }

    func handle(_ request: DeviceAgentRequest) -> DeviceAgentResponse {
        switch request {
        case .probeAvailability:
            return .success(
                .availability(
                    DeviceAgentAvailability(
                        isReachable: true,
                        summary: "Child-process agent reachable; bootstrap transport is up, but product-owned session and injection layers are still missing",
                        readinessGate: .injectionTransport,
                        refreshIntent: DeviceAgentRefreshIntent(
                            scope: .deviceOnly,
                            probeFocus: .attachment
                        ),
                        recommendedProbeFocus: .attachment,
                        nextAction: "Keep the bootstrap boundary separate from session readiness: wire product-owned device-info, tunnel, and injection transports before treating the backend as teleport-ready.",
                        blockerCodes: [.injectionTransportMissing],
                        confidence: "medium",
                        events: [
                            DeviceAgentDiagnosticEvent(
                                level: .info,
                                message: "Structured device-agent boundary initialized"
                            ),
                            DeviceAgentDiagnosticEvent(
                                level: .warning,
                                message: "No-Python location injection has not been attached yet"
                            )
                        ]
                    )
                )
            )
        case .fetchConnectedDevice:
            let probe = SystemUSBProbe.detectIPhone()
            return deviceStateResponse(from: probe)
        case .fetchTunnelState(let device):
            let assessment = DeviceAgentAssessmentFactory.makeTunnelAssessment(
                for: device,
                tunnelController: tunnelController
            )
            return .success(
                .tunnelState(
                    DeviceAgentTunnelState(
                        tunnelState: assessment?.tunnelSession?.state == .productOwnedStarting
                            ? .starting
                            : (assessment?.tunnelLifecycleResult?.state == .productOwnedActive
                                ? .active
                                : (assessment?.tunnelLifecycleResult?.state == .productOwnedFailed
                                    ? .failed
                                    : (assessment?.tunnelRequirementResult?.state == .required
                                        ? .requiredInactive
                                        : .notRequired))),
                        assessment: assessment,
                        events: tunnelController.events(for: device)
                    )
                )
            )
        case .setLocation:
            return .failure(
                DeviceAgentFailure(
                    code: .unsupportedOperation,
                    message: "Location injection is not implemented in the no-Python agent yet."
                )
            )
        }
    }
}

private struct SystemUSBProbe {
    enum Source {
        case systemProfiler
        case ioregFallback
        case none
    }

    let isConnected: Bool
    let displayName: String?
    let serialSuffix: String?
    let speed: String?
    let vendorID: String?
    let productID: String?
    let iosVersion: String?
    let matchedDeviceCount: Int
    let source: Source
    let events: [DeviceAgentDiagnosticEvent]

    static func detectIPhone() -> SystemUSBProbe {
        switch detectViaSystemProfiler() {
        case .success(let probe):
            return enrichWithXcodeMetadata(probe)
        case .failure(let profilerFailure):
            let output = runCaptured(
                executable: "/usr/sbin/ioreg",
                arguments: ["-p", "IOUSB", "-w0"]
            )

            switch output {
            case .success(let text):
                let isConnected = text.localizedCaseInsensitiveContains("iPhone")
                let displayName = fallbackDisplayName(in: text)
                let fallbackProbe = SystemUSBProbe(
                    isConnected: isConnected,
                    displayName: displayName,
                    serialSuffix: nil,
                    speed: nil,
                    vendorID: nil,
                    productID: nil,
                    iosVersion: nil,
                    matchedDeviceCount: isConnected ? 1 : 0,
                    source: .ioregFallback,
                    events: [
                        DeviceAgentDiagnosticEvent(
                            level: .warning,
                            message: "Fell back to ioreg because system_profiler probe failed: \(profilerFailure.message)"
                        ),
                        DeviceAgentDiagnosticEvent(
                            level: .info,
                            message: isConnected
                                ? "Fallback USB probe found an attached iPhone"
                                : "Fallback USB probe did not find an attached iPhone"
                        )
                    ]
                )
                return enrichWithXcodeMetadata(fallbackProbe)
            case .failure(let failure):
                return SystemUSBProbe(
                    isConnected: false,
                    displayName: nil,
                    serialSuffix: nil,
                    speed: nil,
                    vendorID: nil,
                    productID: nil,
                    iosVersion: nil,
                    matchedDeviceCount: 0,
                    source: .none,
                    events: [
                        DeviceAgentDiagnosticEvent(
                            level: .error,
                            message: "System USB probe failed: \(failure.message)"
                        )
                    ]
                )
            }
        }
    }

    private static func detectViaSystemProfiler() -> Result<SystemUSBProbe, DeviceAgentFailure> {
        let output = runCaptured(
            executable: "/usr/sbin/system_profiler",
            arguments: ["SPUSBDataType", "-json"]
        )

        switch output {
        case .success(let text):
            let data = Data(text.utf8)
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let devices = json["SPUSBDataType"] as? [Any]
            else {
                return .failure(
                    DeviceAgentFailure(
                        code: .agentUnavailable,
                        message: "Unable to parse system_profiler USB JSON output."
                    )
                )
            }

            let matches = mobileAppleDevices(in: devices)
            if let match = matches.first {
                var messages = ["system_profiler found \(match.displayName)"]
                if let speed = match.speed, !speed.isEmpty {
                    messages.append("speed \(speed)")
                }
                if let vendorID = match.vendorID, let productID = match.productID {
                    messages.append("vendor \(vendorID) product \(productID)")
                }
                if let serialSuffix = match.serialSuffix {
                    messages.append("serial suffix \(serialSuffix)")
                }
                if matches.count > 1 {
                    messages.append("\(matches.count) Apple mobile devices attached")
                }
                return .success(
                    SystemUSBProbe(
                        isConnected: true,
                        displayName: match.displayName,
                        serialSuffix: match.serialSuffix,
                        speed: match.speed,
                        vendorID: match.vendorID,
                        productID: match.productID,
                        iosVersion: nil,
                        matchedDeviceCount: matches.count,
                        source: .systemProfiler,
                        events: [
                            DeviceAgentDiagnosticEvent(
                                level: .info,
                                message: messages.joined(separator: " · ")
                            )
                        ]
                    )
                )
            }

            return .success(
                SystemUSBProbe(
                    isConnected: false,
                    displayName: nil,
                    serialSuffix: nil,
                    speed: nil,
                    vendorID: nil,
                    productID: nil,
                    iosVersion: nil,
                    matchedDeviceCount: 0,
                    source: .systemProfiler,
                    events: [
                        DeviceAgentDiagnosticEvent(
                            level: .info,
                            message: "system_profiler did not find an attached iPhone"
                        )
                    ]
                )
            )
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private static func mobileAppleDevices(in nodes: [Any]) -> [USBMobileAppleDevice] {
        var matches: [USBMobileAppleDevice] = []
        collectMobileAppleDevices(in: nodes, into: &matches)
        return matches
    }

    private static func collectMobileAppleDevices(in nodes: [Any], into matches: inout [USBMobileAppleDevice]) {
        for node in nodes {
            guard let dictionary = node as? [String: Any] else { continue }
            let name = (dictionary["_name"] as? String) ?? (dictionary["device_name"] as? String)
            let manufacturer = dictionary["manufacturer"] as? String
            let serial = dictionary["serial_num"] as? String
            let speed = (dictionary["speed"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let vendorID = normalizeUSBIdentifier(dictionary["vendor_id"] as? String)
            let productID = normalizeUSBIdentifier(dictionary["product_id"] as? String)

            if let name, isSupportedAppleMobileName(name, manufacturer: manufacturer) {
                let suffix: String?
                if let serial {
                    let trimmed = serial.trimmingCharacters(in: .whitespacesAndNewlines)
                    suffix = trimmed.isEmpty ? nil : String(trimmed.suffix(4))
                } else {
                    suffix = nil
                }
                matches.append(
                    USBMobileAppleDevice(
                        displayName: name,
                        serialSuffix: suffix,
                        speed: speed?.isEmpty == true ? nil : speed,
                        vendorID: vendorID,
                        productID: productID
                    )
                )
            }

            if let children = dictionary["_items"] as? [Any] {
                collectMobileAppleDevices(in: children, into: &matches)
            }
        }
    }

    private static func fallbackDisplayName(in text: String) -> String? {
        let lines = text.split(separator: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lowercased = trimmed.lowercased()
            if lowercased.contains("iphone") || lowercased.contains("ipad") || lowercased.contains("ipod") {
                return trimmed.replacingOccurrences(of: "\"", with: "")
            }
        }
        return text.localizedCaseInsensitiveContains("iPhone") ? "iPhone" : nil
    }

    private static func isSupportedAppleMobileName(_ name: String, manufacturer: String?) -> Bool {
        let lowercasedName = name.lowercased()
        if lowercasedName.contains("iphone") || lowercasedName.contains("ipad") || lowercasedName.contains("ipod") {
            return true
        }
        if let manufacturer, manufacturer.lowercased().contains("apple"), lowercasedName == "iphone" {
            return true
        }
        return false
    }

    private static func normalizeUSBIdentifier(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func enrichWithXcodeMetadata(_ probe: SystemUSBProbe) -> SystemUSBProbe {
        guard probe.isConnected else { return probe }

        switch XcodeDeviceMetadataProbe.fetchAttachedMobileDevices() {
        case .success(let devices):
            guard let match = XcodeDeviceMetadataProbe.match(for: probe, in: devices) else {
                let message = devices.isEmpty
                    ? "xcdevice did not report a USB-attached iPhone/iPad session for metadata enrichment"
                    : "xcdevice metadata did not match the current USB probe strongly enough to enrich iOS version"
                return SystemUSBProbe(
                    isConnected: probe.isConnected,
                    displayName: probe.displayName,
                    serialSuffix: probe.serialSuffix,
                    speed: probe.speed,
                    vendorID: probe.vendorID,
                    productID: probe.productID,
                    iosVersion: probe.iosVersion,
                    matchedDeviceCount: probe.matchedDeviceCount,
                    source: probe.source,
                    events: probe.events + [DeviceAgentDiagnosticEvent(level: .warning, message: message)]
                )
            }

            let event: DeviceAgentDiagnosticEvent
            if let iosVersion = match.iosVersion {
                event = DeviceAgentDiagnosticEvent(
                    level: .info,
                    message: "xcdevice enriched metadata with iOS \(iosVersion) from \(match.name)"
                )
            } else {
                event = DeviceAgentDiagnosticEvent(
                    level: .warning,
                    message: "xcdevice matched \(match.name), but it did not provide an iOS version"
                )
            }

            return SystemUSBProbe(
                isConnected: probe.isConnected,
                displayName: probe.displayName ?? match.name,
                serialSuffix: probe.serialSuffix,
                speed: probe.speed,
                vendorID: probe.vendorID,
                productID: probe.productID,
                iosVersion: match.iosVersion ?? probe.iosVersion,
                matchedDeviceCount: probe.matchedDeviceCount,
                source: probe.source,
                events: probe.events + [event]
            )
        case .failure(let failure):
            return SystemUSBProbe(
                isConnected: probe.isConnected,
                displayName: probe.displayName,
                serialSuffix: probe.serialSuffix,
                speed: probe.speed,
                vendorID: probe.vendorID,
                productID: probe.productID,
                iosVersion: probe.iosVersion,
                matchedDeviceCount: probe.matchedDeviceCount,
                source: probe.source,
                events: probe.events + [
                    DeviceAgentDiagnosticEvent(
                        level: .warning,
                        message: "xcdevice metadata enrichment unavailable: \(failure.message)"
                    )
                ]
            )
        }
    }
}

private struct USBMobileAppleDevice {
    let displayName: String
    let serialSuffix: String?
    let speed: String?
    let vendorID: String?
    let productID: String?
}

private struct XcodeAttachedAppleDevice {
    let name: String
    let operatingSystemVersion: String?
    let interface: String?

    var iosVersion: String? {
        guard let operatingSystemVersion else { return nil }
        let trimmed = operatingSystemVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let version = trimmed.split(separator: " ").first else { return nil }
        let normalized = String(version)
        guard normalized.range(of: #"^\d+(?:\.\d+)*$"#, options: .regularExpression) != nil else {
            return nil
        }
        return normalized
    }
}

private enum XcodeDeviceMetadataProbe {
    static func fetchAttachedMobileDevices() -> Result<[XcodeAttachedAppleDevice], DeviceAgentFailure> {
        let output = runCaptured(
            executable: "/usr/bin/xcrun",
            arguments: ["xcdevice", "list"]
        )

        switch output {
        case .success(let text):
            let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return .failure(
                    DeviceAgentFailure(
                        code: .agentUnavailable,
                        message: "Unable to parse xcdevice JSON output."
                    )
                )
            }

            let devices = json.compactMap { dictionary -> XcodeAttachedAppleDevice? in
                guard (dictionary["simulator"] as? Bool) != true else { return nil }
                guard (dictionary["available"] as? Bool) != false else { return nil }
                let name = (dictionary["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty else { return nil }
                guard isSupportedMobilePlatform(dictionary["platform"] as? String) else { return nil }
                if let interface = dictionary["interface"] as? String,
                   !interface.isEmpty,
                   interface.lowercased() != "usb" {
                    return nil
                }
                return XcodeAttachedAppleDevice(
                    name: name,
                    operatingSystemVersion: dictionary["operatingSystemVersion"] as? String,
                    interface: dictionary["interface"] as? String
                )
            }
            return .success(devices)
        case .failure(let failure):
            return .failure(failure)
        }
    }

    static func match(
        for probe: SystemUSBProbe,
        in devices: [XcodeAttachedAppleDevice]
    ) -> XcodeAttachedAppleDevice? {
        guard !devices.isEmpty else { return nil }

        if let displayName = normalizedName(probe.displayName) {
            let exactMatches = devices.filter { normalizedName($0.name) == displayName }
            if exactMatches.count == 1 {
                return exactMatches[0]
            }
        }

        if probe.matchedDeviceCount == 1, devices.count == 1 {
            return devices[0]
        }

        return nil
    }

    private static func isSupportedMobilePlatform(_ platform: String?) -> Bool {
        guard let platform = platform?.lowercased() else { return false }
        return platform.contains("iphone") || platform.contains("ipad")
    }

    private static func normalizedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

private struct NoPythonDeviceSummary {
    static func connectionSummary(from probe: SystemUSBProbe) -> String {
        guard probe.isConnected else {
            return "NO IPHONE DETECTED BY AGENT"
        }
        var components: [String] = []
        if let displayName = probe.displayName, !displayName.isEmpty {
            components.append(displayName.uppercased())
        } else {
            components.append("APPLE MOBILE DEVICE")
        }
        if let speed = probe.speed, !speed.isEmpty {
            components.append(speed.uppercased())
        }
        if let serialSuffix = probe.serialSuffix, !serialSuffix.isEmpty {
            components.append("SN \(serialSuffix.uppercased())")
        }
        if probe.matchedDeviceCount > 1 {
            components.append("+\(probe.matchedDeviceCount - 1) MORE")
        }
        return "USB DEVICE DETECTED: \(components.joined(separator: " · "))"
    }
}

struct DeviceAgentTunnelControllerSnapshot {
    let tunnelState: TunnelState
    let lifecycleResult: DeviceAgentTunnelLifecycleResult
    let tunnelSession: DeviceAgentTunnelSession?
    let healthResult: DeviceAgentTunnelHealthResult?
    let events: [DeviceAgentDiagnosticEvent]
}

protocol TunnelStateControlling {
    func inspectTunnel(
        for snapshot: DeviceSnapshot,
        metadataSession: DeviceAgentTypedMetadataSession?,
        requirementResult: DeviceAgentTunnelRequirementResult
    ) -> DeviceAgentTunnelControllerSnapshot

    func events(for snapshot: DeviceSnapshot) -> [DeviceAgentDiagnosticEvent]
}

private struct TunnelStateControllerStack: TunnelStateControlling {
    func inspectTunnel(
        for snapshot: DeviceSnapshot,
        metadataSession: DeviceAgentTypedMetadataSession?,
        requirementResult: DeviceAgentTunnelRequirementResult
    ) -> DeviceAgentTunnelControllerSnapshot {
        let productOwned = ProductOwnedTunnelStateController.inspectTunnel(
            for: snapshot,
            metadataSession: metadataSession,
            requirementResult: requirementResult
        )
        if productOwned.lifecycleResult.state == .productOwnedActive {
            return productOwned
        }

        let legacyObserved = LegacyObservedTunnelStateController.inspectTunnel(
            for: snapshot,
            metadataSession: metadataSession,
            requirementResult: requirementResult
        )
        if legacyObserved.lifecycleResult.state == .legacyObserved {
            return legacyObserved
        }

        return productOwned
    }

    func events(for snapshot: DeviceSnapshot) -> [DeviceAgentDiagnosticEvent] {
        let productOwnedEvents = ProductOwnedTunnelStateController.events(for: snapshot)
        let legacyEvents = LegacyObservedTunnelStateController.events(for: snapshot)
        return productOwnedEvents + legacyEvents
    }
}

private enum ProductOwnedTunnelStateController {
    private enum OwnedTunnelControllerState {
        case inactive
        case starting
        case active
        case failed(String)
    }

    private enum TunnelHealthProbeState {
        case pending(summary: String?, protocolHint: DeviceAgentTunnelProtocolHint?, endpointSummary: String?)
        case ready(summary: String?, protocolHint: DeviceAgentTunnelProtocolHint?, endpointSummary: String?)
        case failed(String)
    }

    private struct TunnelNetworkProbeResult {
        let isReachable: Bool
        let protocolHint: DeviceAgentTunnelProtocolHint?
        let endpointSummary: String?
        let summary: String
    }

    private struct TunnelEndpointProbe {
        let host: String
        let port: UInt16
        let rawListener: String
    }

    private struct TunnelEndpointVerification {
        let protocolHint: DeviceAgentTunnelProtocolHint
        let endpointSummary: String
        let summary: String
    }

    private enum ExpectedRSDEndpointProbeResult {
        case notAdvertised(String)
        case advertisedButUnverified(endpointSummary: String, detail: String)
        case verified(TunnelEndpointVerification)

        var pendingSummary: String {
            switch self {
            case .notAdvertised(let detail):
                return detail
            case .advertisedButUnverified(let endpointSummary, let detail):
                return "Expected RSD endpoint \(endpointSummary) was advertised by tunneld, but the backend protocol probe has not verified it yet. \(detail)"
            case .verified(let verification):
                return verification.summary
            }
        }

        var endpointSummary: String? {
            switch self {
            case .notAdvertised:
                return nil
            case .advertisedButUnverified(let endpointSummary, _):
                return endpointSummary
            case .verified(let verification):
                return verification.endpointSummary
            }
        }
    }

    private enum StoredPhase: String, Codable {
        case starting
        case failed
    }

    private struct StoredAttempt: Codable {
        let phase: StoredPhase
        let startedAt: Date
        let updatedAt: Date
        let failureReason: String?
        let processID: Int32?
        let logPath: String?
    }

    private static let startupTimeout: TimeInterval = 6
    private static let retryCooldown: TimeInterval = 12
    private static let defaults = UserDefaults.standard
    private static let shellRunner = ShellCommandRunner()
    private static let pathResolver = V3LegacyCLIPathResolver()

    static func inspectTunnel(
        for snapshot: DeviceSnapshot,
        metadataSession: DeviceAgentTypedMetadataSession?,
        requirementResult: DeviceAgentTunnelRequirementResult
    ) -> DeviceAgentTunnelControllerSnapshot {
        switch currentState(for: snapshot, requirementResult: requirementResult) {
        case .inactive:
            let lifecycleResult = DeviceAgentTunnelLifecycleResult(
                state: .noProductOwnedTunnel,
                summary: "No product-owned tunnel session is active.",
                nextAction: "Introduce typed tunnel lifecycle management before treating tunnel state as readiness.",
                confidence: "medium"
            )

            let pendingSession: DeviceAgentTunnelSession?
            if requirementResult.state == .required {
                pendingSession = DeviceAgentTunnelSession(
                    sessionID: "tunnel.session.product-owned.pending",
                    state: .productOwnedPending,
                    ownershipSummary: "Product-owned tunnel session pending",
                    sourceMetadataSessionID: metadataSession?.sessionID,
                    summary: "The session requires a tunnel, but no product-owned tunnel session is active yet.",
                    nextAction: "Create a product-owned tunnel session boundary instead of delegating tunnel startup to an external process."
                )
            } else {
                pendingSession = nil
            }

            return DeviceAgentTunnelControllerSnapshot(
                tunnelState: requirementResult.state == .required ? .requiredInactive : .notRequired,
                lifecycleResult: lifecycleResult,
                tunnelSession: pendingSession,
                healthResult: nil,
                events: events(for: snapshot)
            )
        case .starting:
            return DeviceAgentTunnelControllerSnapshot(
                tunnelState: .starting,
                lifecycleResult: DeviceAgentTunnelLifecycleResult(
                    state: .productOwnedStarting,
                    summary: "A product-owned tunnel session is starting, but backend-managed health checks have not verified readiness yet.",
                    nextAction: "Keep the product-owned tunnel startup under backend control until the session becomes active or fails.",
                    confidence: "medium"
                ),
                tunnelSession: DeviceAgentTunnelSession(
                    sessionID: "tunnel.session.product-owned.starting",
                    state: .productOwnedStarting,
                    ownershipSummary: "Product-owned tunnel session starting",
                    sourceMetadataSessionID: metadataSession?.sessionID,
                    summary: "The backend has started creating a product-owned tunnel session.",
                    nextAction: "Wait for the product-owned tunnel controller to report active or failed state."
                ),
                healthResult: currentStoredHealthResult(for: snapshot),
                events: events(for: snapshot)
            )
        case .active:
            return DeviceAgentTunnelControllerSnapshot(
                tunnelState: .active,
                lifecycleResult: DeviceAgentTunnelLifecycleResult(
                    state: .productOwnedActive,
                    summary: "A product-owned tunnel session is active and has passed backend-managed readiness checks.",
                    nextAction: "Keep the product-owned tunnel healthy while injection transport remains separate.",
                    confidence: "high"
                ),
                tunnelSession: DeviceAgentTunnelSession(
                    sessionID: "tunnel.session.product-owned.active",
                    state: .productOwnedActive,
                    ownershipSummary: "Product-owned tunnel session",
                    sourceMetadataSessionID: metadataSession?.sessionID,
                    summary: "A product-owned tunnel session is active and has verified readiness, so it can be treated as backend state instead of a process-name observation.",
                    nextAction: "Keep the tunnel session healthy and separate from injection transport readiness."
                ),
                healthResult: currentStoredHealthResult(for: snapshot),
                events: events(for: snapshot)
            )
        case .failed(let message):
            return DeviceAgentTunnelControllerSnapshot(
                tunnelState: .failed,
                lifecycleResult: DeviceAgentTunnelLifecycleResult(
                    state: .productOwnedFailed,
                    summary: "A product-owned tunnel attempt failed before reaching an active session boundary.",
                    nextAction: "Surface the failure as backend-owned tunnel state and offer a retry path from the controller.",
                    confidence: "medium"
                ),
                tunnelSession: DeviceAgentTunnelSession(
                    sessionID: "tunnel.session.product-owned.failed",
                    state: .productOwnedFailed,
                    ownershipSummary: "Product-owned tunnel session failed",
                    sourceMetadataSessionID: metadataSession?.sessionID,
                    summary: message,
                    nextAction: "Retry tunnel startup through the product-owned controller instead of falling back to an external process."
                ),
                healthResult: currentStoredHealthResult(for: snapshot),
                events: events(for: snapshot)
            )
        }
    }

    static func events(for snapshot: DeviceSnapshot) -> [DeviceAgentDiagnosticEvent] {
        guard snapshot.isConnected else { return [] }
        let attempt = loadAttempt(forKey: attemptKey(for: snapshot))
        switch currentStoredState(for: snapshot) {
        case .starting:
            let detail = attempt.flatMap { attemptDescription(from: $0) } ?? "backend-managed startup attempt"
            return [
                DeviceAgentDiagnosticEvent(
                    level: .info,
                    message: "Product-owned tunnel controller is holding a startup attempt for this session (\(detail))"
                )
            ] + (attempt.map { diagnosticEvents(for: healthProbeState(from: $0)) } ?? [])
        case .failed(let reason):
            let detail = attempt.flatMap { attemptDescription(from: $0) }
            return [
                DeviceAgentDiagnosticEvent(
                    level: .warning,
                    message: detail.map {
                        "Product-owned tunnel controller recorded a failed startup attempt (\($0)): \(reason)"
                    } ?? "Product-owned tunnel controller recorded a failed startup attempt: \(reason)"
                )
            ]
        case .active:
            let detail = attempt.flatMap { attemptDescription(from: $0) } ?? "backend-managed tunnel process"
            return [
                DeviceAgentDiagnosticEvent(
                    level: .info,
                    message: "Product-owned tunnel controller reports an active tunnel session (\(detail))"
                )
            ] + (attempt.map { diagnosticEvents(for: healthProbeState(from: $0)) } ?? [])
        case .inactive:
            return [
                DeviceAgentDiagnosticEvent(
                    level: .info,
                    message: "Product-owned tunnel controller inspected the session, but no owned tunnel instance is active yet"
                )
            ]
        }
    }

    private static func attemptDescription(from attempt: StoredAttempt) -> String? {
        let pid = attempt.processID.map { "pid \($0)" }
        let log = attempt.logPath.map { "log \($0)" }
        let parts = [pid, log].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func currentStoredHealthResult(for snapshot: DeviceSnapshot) -> DeviceAgentTunnelHealthResult? {
        guard let attempt = loadAttempt(forKey: attemptKey(for: snapshot)) else {
            return nil
        }
        return makeHealthResult(from: healthProbeState(from: attempt))
    }

    private static func makeHealthResult(
        from state: TunnelHealthProbeState
    ) -> DeviceAgentTunnelHealthResult {
        switch state {
        case .pending(let detail, let protocolHint, let endpointSummary):
            return DeviceAgentTunnelHealthResult(
                state: .pending,
                protocolHint: protocolHint,
                endpointSummary: endpointSummary,
                summary: detail.map {
                    "Backend-managed tunnel startup is still waiting for protocol-specific readiness. Detail: \($0)"
                } ?? "Backend-managed tunnel startup is still waiting for protocol-specific readiness.",
                nextAction: "Keep the owned tunnel under backend control until expected-RSD endpoint checks verify readiness or record a failure.",
                confidence: "medium"
            )
        case .ready(let detail, let protocolHint, let endpointSummary):
            return DeviceAgentTunnelHealthResult(
                state: .verified,
                protocolHint: protocolHint,
                endpointSummary: endpointSummary,
                summary: detail.map {
                    "Backend-managed tunnel health checks verified protocol-specific readiness: \($0)"
                } ?? "Backend-managed tunnel health checks verified protocol-specific readiness.",
                nextAction: "Hold the verified tunnel session and keep injection transport separate from tunnel ownership.",
                confidence: "high"
            )
        case .failed(let message):
            return DeviceAgentTunnelHealthResult(
                state: .failed,
                protocolHint: nil,
                endpointSummary: nil,
                summary: message,
                nextAction: "Inspect the backend-managed tunnel failure and retry startup instead of trusting process presence alone.",
                confidence: "medium"
            )
        }
    }

    private static func extractEndpointSummary(from detail: String?) -> String? {
        guard let detail else { return nil }
        let pattern = #"((?:\d{1,3}\.){3}\d{1,3}|\[?[A-Fa-f0-9:]+\]?)(?::)(\d{1,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(detail.startIndex..., in: detail)
        guard let match = regex.firstMatch(in: detail, range: range),
              match.numberOfRanges == 3,
              let hostRange = Range(match.range(at: 1), in: detail),
              let portRange = Range(match.range(at: 2), in: detail) else {
            return nil
        }
        return "\(detail[hostRange]):\(detail[portRange])"
    }

    private static func currentState(
        for snapshot: DeviceSnapshot,
        requirementResult: DeviceAgentTunnelRequirementResult
    ) -> OwnedTunnelControllerState {
        guard snapshot.isConnected, requirementResult.state == .required else {
            clearAttempt(for: snapshot)
            return .inactive
        }
        let key = attemptKey(for: snapshot)
        let now = Date()

        guard let attempt = loadAttempt(forKey: key) else {
            return beginStartupAttempt(for: snapshot, key: key, now: now)
        }

        switch attempt.phase {
        case .starting:
            switch healthProbeState(from: attempt) {
            case .ready:
                return .active
            case .pending:
                if now.timeIntervalSince(attempt.startedAt) < startupTimeout {
                    return .starting
                }
            case .failed(let message):
                saveAttempt(
                    StoredAttempt(
                        phase: .failed,
                        startedAt: attempt.startedAt,
                        updatedAt: now,
                        failureReason: message,
                        processID: attempt.processID,
                        logPath: attempt.logPath
                    ),
                    forKey: key
                )
                return .failed(message)
            }

            let reason = failureReason(
                from: attempt,
                fallback: "Product-owned tunnel controller did not reach an active session within \(Int(startupTimeout))s."
            )
            saveAttempt(
                StoredAttempt(
                    phase: .failed,
                    startedAt: attempt.startedAt,
                    updatedAt: now,
                    failureReason: reason,
                    processID: attempt.processID,
                    logPath: attempt.logPath
                ),
                forKey: key
            )
            return .failed(reason)
        case .failed:
            if now.timeIntervalSince(attempt.updatedAt) >= retryCooldown {
                return beginStartupAttempt(for: snapshot, key: key, now: now)
            }
            return .failed(attempt.failureReason ?? "Product-owned tunnel controller is holding a failed startup state.")
        }
    }

    private static func currentStoredState(for snapshot: DeviceSnapshot) -> OwnedTunnelControllerState {
        guard let attempt = loadAttempt(forKey: attemptKey(for: snapshot)) else {
            return .inactive
        }
        switch attempt.phase {
        case .starting:
            if case .ready = healthProbeState(from: attempt) {
                return .active
            }
            return .starting
        case .failed:
            return .failed(attempt.failureReason ?? "Product-owned tunnel controller is holding a failed startup state.")
        }
    }

    private static func beginStartupAttempt(
        for snapshot: DeviceSnapshot,
        key: String,
        now: Date
    ) -> OwnedTunnelControllerState {
        switch launchTunnelProcess(for: snapshot) {
        case .success(let launch):
            saveAttempt(
                StoredAttempt(
                    phase: .starting,
                    startedAt: now,
                    updatedAt: now,
                    failureReason: nil,
                    processID: launch.processID,
                    logPath: launch.logPath
                ),
                forKey: key
            )
            return .starting
        case .failure(let failure):
            let reason: String
            switch failure {
            case .message(let value):
                reason = value
            }
            saveAttempt(
                StoredAttempt(
                    phase: .failed,
                    startedAt: now,
                    updatedAt: now,
                    failureReason: reason,
                    processID: nil,
                    logPath: nil
                ),
                forKey: key
            )
            return .failed(reason)
        }
    }

    private struct TunnelLaunch {
        let processID: Int32
        let logPath: String
    }

    private enum TunnelLaunchFailure: Error {
        case message(String)
    }

    private static func launchTunnelProcess(
        for snapshot: DeviceSnapshot
    ) -> Result<TunnelLaunch, TunnelLaunchFailure> {
        guard let cliPath = pathResolver.resolvedCLIPath(), !cliPath.isEmpty else {
            return .failure(.message("Product-owned tunnel startup could not begin because pymobiledevice3 was not found."))
        }

        let identifier = sanitizedIdentifier(for: snapshot)
        let logPath = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("geoteleport-v3-tunnel-\(identifier).log")
        FileManager.default.createFile(atPath: logPath, contents: nil)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: cliPath)
        task.arguments = ["remote", "tunneld"]
        task.standardInput = FileHandle.nullDevice

        guard let writer = FileHandle(forWritingAtPath: logPath) else {
            return .failure(.message("Product-owned tunnel startup could not create a log file for backend-managed output."))
        }
        task.standardOutput = writer
        task.standardError = writer
        task.environment = mergedEnvironment()

        do {
            try task.run()
            let processID = task.processIdentifier
            writer.closeFile()
            guard processID > 0 else {
                return .failure(.message("Product-owned tunnel startup did not yield a valid process identifier."))
            }
            return .success(TunnelLaunch(processID: processID, logPath: logPath))
        } catch {
            writer.closeFile()
            return .failure(.message("Product-owned tunnel startup could not launch \(cliPath): \(error.localizedDescription)"))
        }
    }

    private static func failureReason(
        from attempt: StoredAttempt,
        fallback: String
    ) -> String {
        switch healthProbeState(from: attempt) {
        case .failed(let message):
            return message
        case .pending(let detail, _, let endpointSummary):
            let endpoint = endpointSummary.map { " Endpoint: \($0)." } ?? ""
            return detail.map {
                "Product-owned tunnel controller timed out before protocol-specific readiness.\(endpoint) Last probe detail: \($0)"
            } ?? "Product-owned tunnel controller timed out before protocol-specific readiness.\(endpoint)"
        case .ready:
            break
        }
        if let processID = attempt.processID, !isProcessRunning(processID) {
            if let logPath = attempt.logPath,
               let logExcerpt = readLogExcerpt(at: logPath),
               !logExcerpt.isEmpty {
                return "Product-owned tunnel process \(processID) exited before readiness. Last log: \(logExcerpt)"
            }
            return "Product-owned tunnel process \(processID) exited before readiness."
        }
        return attempt.failureReason ?? fallback
    }

    private static func healthProbeState(from attempt: StoredAttempt) -> TunnelHealthProbeState {
        guard let processID = attempt.processID else {
            return .failed("Product-owned tunnel startup never yielded a process identifier.")
        }

        let logText = attempt.logPath.flatMap(readLogExcerpt(at:))
        let expectedRSDProbe = probeExpectedRSDEndpoint(in: logText, timeout: 0.35)
        switch expectedRSDProbe {
        case .verified(let verified):
            return .ready(
                summary: verified.summary,
                protocolHint: verified.protocolHint,
                endpointSummary: verified.endpointSummary
            )
        case .advertisedButUnverified, .notAdvertised:
            break
        }

        switch expectedRSDProbe {
        case .advertisedButUnverified(let endpointSummary, let detail):
            let listenerProbe = networkProbe(for: processID)
            if isProcessRunning(processID) {
                let listenerDetail = listenerProbe?.summary ?? "No backend listener has been observed yet."
                return .pending(
                    summary: "\(detail) \(listenerDetail)",
                    protocolHint: .rsdMarkerObserved,
                    endpointSummary: endpointSummary
                )
            }
        case .notAdvertised, .verified:
            break
        }

        let network = networkProbe(for: processID)
        if let network, network.isReachable {
            return .pending(
                summary: "\(expectedRSDProbe.pendingSummary) A backend listener accepted a socket probe, but no expected RSD endpoint has been verified yet. \(network.summary)",
                protocolHint: network.protocolHint,
                endpointSummary: network.endpointSummary
            )
        }
        if let marker = readyMarker(in: logText) {
            return .pending(
                summary: "Startup output contains a tunnel-ready marker, but protocol-specific RSD endpoint verification is still pending. \(expectedRSDProbe.pendingSummary) Last marker: \(marker)",
                protocolHint: marker.lowercased().contains("rsd") ? .rsdMarkerObserved : nil,
                endpointSummary: expectedRSDProbe.endpointSummary ?? extractEndpointSummary(from: marker)
            )
        }
        if let failure = failureMarker(in: logText) {
            return .failed("Product-owned tunnel health probe observed a startup failure: \(failure)")
        }
        if isProcessRunning(processID) {
            return .pending(
                summary: logText ?? network?.summary,
                protocolHint: network?.protocolHint,
                endpointSummary: network?.endpointSummary
            )
        }
        if let logText, !logText.isEmpty {
            return .failed("Product-owned tunnel process \(processID) exited before readiness. Last log: \(logText)")
        }
        return .failed("Product-owned tunnel process \(processID) exited before readiness.")
    }

    private static func readyMarker(in logText: String?) -> String? {
        guard let logText else { return nil }
        let lines = logText.split(whereSeparator: \.isNewline).map(String.init)
        let readyHints = ["ready", "listening", "serving", "tunnel established", "accepted", "rsd"]
        return lines.last(where: { line in
            let lower = line.lowercased()
            return readyHints.contains(where: { lower.contains($0) }) &&
                !lower.contains("not ready") &&
                !lower.contains("waiting")
        })
    }

    private static func failureMarker(in logText: String?) -> String? {
        guard let logText else { return nil }
        let lines = logText.split(whereSeparator: \.isNewline).map(String.init)
        let failureHints = ["traceback", "error", "failed", "exception", "permission denied", "no such file", "fatal"]
        return lines.last(where: { line in
            let lower = line.lowercased()
            return failureHints.contains(where: { lower.contains($0) })
        })
    }

    private static func diagnosticEvents(for health: TunnelHealthProbeState) -> [DeviceAgentDiagnosticEvent] {
        switch health {
        case .pending(let detail, let protocolHint, let endpointSummary):
            let hints = [protocolHint.map(diagnosticLabel(for:)), endpointSummary]
                .compactMap { $0 }
                .joined(separator: ", ")
            return [
                DeviceAgentDiagnosticEvent(
                    level: .info,
                    message: detail.map {
                        "Product-owned tunnel health probe is still waiting for protocol-specific readiness. Detail: \($0)"
                    } ?? "Product-owned tunnel health probe is still waiting for protocol-specific readiness."
                    + (hints.isEmpty ? "" : " Probe detail: \(hints)")
                )
            ]
        case .ready(let detail, let protocolHint, let endpointSummary):
            let hints = [protocolHint.map(diagnosticLabel(for:)), endpointSummary]
                .compactMap { $0 }
                .joined(separator: ", ")
            return [
                DeviceAgentDiagnosticEvent(
                    level: .info,
                    message: detail.map {
                        "Product-owned tunnel health probe verified protocol-specific readiness: \($0)"
                    } ?? "Product-owned tunnel health probe verified protocol-specific readiness."
                    + (hints.isEmpty ? "" : " Probe detail: \(hints)")
                )
            ]
        case .failed(let message):
            return [
                DeviceAgentDiagnosticEvent(
                    level: .warning,
                    message: message
                )
            ]
        }
    }

    private static func networkProbe(for processID: Int32) -> TunnelNetworkProbeResult? {
        guard processID > 0 else { return nil }
        switch shellRunner.run(
            "/usr/sbin/lsof",
            args: ["-Pan", "-p", String(processID), "-iTCP", "-sTCP:LISTEN"]
        ) {
        case .success(let result):
            let lines = result.stdout
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard lines.count > 1 else {
                return TunnelNetworkProbeResult(
                    isReachable: false,
                    protocolHint: nil,
                    endpointSummary: nil,
                    summary: "No listening TCP sockets observed yet for product-owned tunnel process \(processID)."
                )
            }
            let listeners = Array(lines.dropFirst())
            let endpoints = listenerEndpoints(from: listeners)
            if let verified = endpoints.compactMap({ verifyEndpointSession($0, timeout: 0.2) }).first(where: {
                $0.protocolHint == .sessionHandshakeVerified
            }) ?? endpoints.compactMap({ verifyEndpointSession($0, timeout: 0.2) }).first {
                return TunnelNetworkProbeResult(
                    isReachable: true,
                    protocolHint: verified.protocolHint,
                    endpointSummary: verified.endpointSummary,
                    summary: verified.summary
                )
            }
            return TunnelNetworkProbeResult(
                isReachable: false,
                protocolHint: endpoints.isEmpty ? nil : .listenerOnly,
                endpointSummary: endpoints.first.map { "\($0.host):\($0.port)" },
                summary: "Product-owned tunnel process \(processID) exposed listeners, but backend TCP connect probes did not succeed yet: \(listeners.joined(separator: " | "))"
            )
        case .failure(let error):
            return TunnelNetworkProbeResult(
                isReachable: false,
                protocolHint: nil,
                endpointSummary: nil,
                summary: "TCP listener probe for product-owned tunnel process \(processID) failed: \(error.localizedDescription)"
            )
        }
    }

    private static func probeExpectedRSDEndpoint(
        in logText: String?,
        timeout: TimeInterval
    ) -> ExpectedRSDEndpointProbeResult {
        guard let logText, !logText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .notAdvertised("Tunnel startup has not emitted enough output to advertise an expected RSD endpoint yet.")
        }

        guard let endpoint = expectedRSDEndpoint(in: logText) else {
            return .notAdvertised("Tunnel startup output does not advertise an expected RSD endpoint yet, so generic listener evidence is not enough to verify readiness.")
        }

        if let verification = verifyExpectedRSDEndpoint(endpoint, timeout: timeout) {
            return .verified(verification)
        }

        return .advertisedButUnverified(
            endpointSummary: "\(endpoint.host):\(endpoint.port)",
            detail: "Expected RSD endpoint was parsed from \(endpoint.rawListener), but a backend connection probe to \(endpoint.host):\(endpoint.port) did not complete."
        )
    }

    private static func expectedRSDEndpoint(in logText: String?) -> TunnelEndpointProbe? {
        guard let logText, !logText.isEmpty else { return nil }

        let hostToken = #"(\[?[A-Za-z0-9:\.%-]+\]?)"#
        let rsdArgumentPattern = #"(?i)(?:--rsd|rsd)\s+"# + hostToken + #"\s+(\d{1,5})"#
        if let match = firstRegexMatch(in: logText, pattern: rsdArgumentPattern, groups: 2),
           let endpoint = makeExpectedRSDEndpoint(
            host: match[0],
            port: match[1],
            rawListener: "advertised RSD endpoint from --rsd \(match[0]) \(match[1])"
           ) {
            return endpoint
        }

        let bracketedEndpointPattern = #"(?i)rsd[^\n]*"# + hostToken + #":(\d{1,5})"#
        if let match = firstRegexMatch(in: logText, pattern: bracketedEndpointPattern, groups: 2),
           let endpoint = makeExpectedRSDEndpoint(
            host: match[0],
            port: match[1],
            rawListener: "advertised RSD endpoint \(match[0]):\(match[1])"
           ) {
            return endpoint
        }

        let addressPattern = #"(?i)rsd[^\n]*(?:address|host)\s*[:=]\s*"# + hostToken
        let portPattern = #"(?i)rsd[^\n]*port\s*[:=]\s*(\d{1,5})"#
        if let address = firstRegexMatch(in: logText, pattern: addressPattern, groups: 1)?.first,
           let port = firstRegexMatch(in: logText, pattern: portPattern, groups: 1)?.first,
           let endpoint = makeExpectedRSDEndpoint(
            host: address,
            port: port,
            rawListener: "advertised RSD address \(address) port \(port)"
           ) {
            return endpoint
        }

        return nil
    }

    private static func firstRegexMatch(
        in text: String,
        pattern: String,
        groups: Int
    ) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > groups else {
            return nil
        }
        var values: [String] = []
        for index in 1...groups {
            guard let range = Range(match.range(at: index), in: text) else {
                return nil
            }
            values.append(String(text[range]))
        }
        return values
    }

    private static func makeExpectedRSDEndpoint(
        host: String,
        port: String,
        rawListener: String
    ) -> TunnelEndpointProbe? {
        guard let port = UInt16(port) else { return nil }
        let normalizedHost = normalizeEndpointHost(host)
        guard !normalizedHost.isEmpty else { return nil }
        return TunnelEndpointProbe(
            host: normalizedHost,
            port: port,
            rawListener: rawListener
        )
    }

    private static func normalizeEndpointHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\r\n,;"))
        if trimmed == "*" {
            return "127.0.0.1"
        }
        return trimmed
    }

    private static func verifyExpectedRSDEndpoint(
        _ endpoint: TunnelEndpointProbe,
        timeout: TimeInterval
    ) -> TunnelEndpointVerification? {
        guard let connection = connectSocket(host: endpoint.host, port: endpoint.port, timeout: timeout) else {
            return nil
        }
        defer { close(connection) }

        if let observedPayload = observeInitialPayload(on: connection, timeout: timeout), !observedPayload.isEmpty {
            return TunnelEndpointVerification(
                protocolHint: .expectedRSDHandshakeVerified,
                endpointSummary: "\(endpoint.host):\(endpoint.port)",
                summary: "Connected to the expected RSD endpoint advertised by tunneld and observed protocol payload \(observedPayload) on \(endpoint.host):\(endpoint.port)."
            )
        }

        return TunnelEndpointVerification(
            protocolHint: .expectedRSDConnectVerified,
            endpointSummary: "\(endpoint.host):\(endpoint.port)",
            summary: "Connected to the expected RSD endpoint advertised by tunneld at \(endpoint.host):\(endpoint.port). This is protocol-specific endpoint verification, not a generic listener check."
        )
    }

    private static func verifyEndpointSession(
        _ endpoint: TunnelEndpointProbe,
        timeout: TimeInterval
    ) -> TunnelEndpointVerification? {
        guard let connection = connectSocket(host: endpoint.host, port: endpoint.port, timeout: timeout) else {
            return nil
        }
        defer { close(connection) }

        if let observedPayload = observeInitialPayload(on: connection, timeout: timeout), !observedPayload.isEmpty {
            return TunnelEndpointVerification(
                protocolHint: .sessionHandshakeVerified,
                endpointSummary: "\(endpoint.host):\(endpoint.port)",
                summary: "Product-owned tunnel process exposed \(endpoint.rawListener) and completed a backend session probe with initial payload \(observedPayload) on \(endpoint.host):\(endpoint.port)"
            )
        }

        return TunnelEndpointVerification(
            protocolHint: .tcpConnectVerified,
            endpointSummary: "\(endpoint.host):\(endpoint.port)",
            summary: "Product-owned tunnel process \(endpoint.rawListener) accepted a backend TCP probe on \(endpoint.host):\(endpoint.port), but no protocol payload was observed yet"
        )
    }

    private static func listenerEndpoints(from listeners: [String]) -> [TunnelEndpointProbe] {
        let pattern = #"([A-Fa-f0-9\.\:\*\[\]]+):([0-9]+)\s*\(LISTEN\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        return listeners.compactMap { line in
            let range = NSRange(line.startIndex..., in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges == 3,
                  let hostRange = Range(match.range(at: 1), in: line),
                  let portRange = Range(match.range(at: 2), in: line),
                  let port = UInt16(line[portRange]) else {
                return nil
            }

            let rawHost = String(line[hostRange])
            let normalizedHost: String
            if rawHost == "*" {
                normalizedHost = "127.0.0.1"
            } else if rawHost == "[::1]" {
                normalizedHost = "::1"
            } else if rawHost.hasPrefix("[") && rawHost.hasSuffix("]") {
                normalizedHost = String(rawHost.dropFirst().dropLast())
            } else {
                normalizedHost = rawHost
            }

            return TunnelEndpointProbe(
                host: normalizedHost,
                port: port,
                rawListener: line
            )
        }
    }

    private static func connectSocket(host: String, port: UInt16, timeout: TimeInterval) -> Int32? {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var infoPointer: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &infoPointer)
        guard status == 0, let firstInfo = infoPointer else {
            return nil
        }
        defer { freeaddrinfo(firstInfo) }

        var current: UnsafeMutablePointer<addrinfo>? = firstInfo
        while let info = current {
            let socketFD = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if socketFD >= 0 {
                let flags = fcntl(socketFD, F_GETFL, 0)
                _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)

                let connectResult = connect(socketFD, info.pointee.ai_addr, info.pointee.ai_addrlen)
                if connectResult == 0 {
                    return socketFD
                }

                if errno == EINPROGRESS {
                    var pollDescriptor = pollfd(
                        fd: socketFD,
                        events: Int16(POLLOUT),
                        revents: 0
                    )
                    let timeoutMilliseconds = Int32((timeout * 1_000).rounded())
                    let pollResult = poll(&pollDescriptor, 1, timeoutMilliseconds)
                    if pollResult > 0 {
                        var socketError: Int32 = 0
                        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
                        if getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0,
                           socketError == 0 {
                            return socketFD
                        }
                    }
                }

                close(socketFD)
            }
            current = info.pointee.ai_next
        }

        return nil
    }

    private static func observeInitialPayload(on socketFD: Int32, timeout: TimeInterval) -> String? {
        var pollDescriptor = pollfd(
            fd: socketFD,
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )
        let timeoutMilliseconds = Int32((timeout * 1_000).rounded())
        let pollResult = poll(&pollDescriptor, 1, timeoutMilliseconds)
        guard pollResult > 0,
              (pollDescriptor.revents & Int16(POLLIN)) != 0 else {
            return nil
        }

        var buffer = [UInt8](repeating: 0, count: 24)
        let received = recv(socketFD, &buffer, buffer.count, MSG_PEEK)
        guard received > 0 else {
            return nil
        }

        let payload = Data(buffer.prefix(Int(received)))
        if let ascii = String(data: payload, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !ascii.isEmpty {
            return "\"\(ascii.prefix(24))\""
        }

        return payload.map { String(format: "%02x", $0) }.joined(separator: " ").prefix(47).description
    }

    nonisolated private static func diagnosticLabel(for hint: DeviceAgentTunnelProtocolHint) -> String {
        switch hint {
        case .listenerOnly:
            return "listener observed"
        case .tcpConnectVerified:
            return "tcp connect verified"
        case .sessionHandshakeVerified:
            return "session handshake verified"
        case .rsdMarkerObserved:
            return "rsd marker observed"
        case .expectedRSDConnectVerified:
            return "expected rsd connect verified"
        case .expectedRSDHandshakeVerified:
            return "expected rsd handshake verified"
        }
    }

    nonisolated private static func readLogExcerpt(at path: String) -> String? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return nil
        }
        return content
            .split(whereSeparator: \.isNewline)
            .suffix(3)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isProcessRunning(_ processID: Int32) -> Bool {
        guard processID > 0 else { return false }
        return kill(processID, 0) == 0 || errno == EPERM
    }

    private static func sanitizedIdentifier(for snapshot: DeviceSnapshot) -> String {
        let raw = [
            snapshot.deviceName,
            snapshot.serialSuffix,
            snapshot.vendorID,
            snapshot.productID
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        let base = raw.isEmpty ? "device" : raw
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        return String(base.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    }

    private static func mergedEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    private static func attemptKey(for snapshot: DeviceSnapshot) -> String {
        let name = snapshot.deviceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let serial = snapshot.serialSuffix ?? ""
        let vendor = snapshot.vendorID ?? ""
        let product = snapshot.productID ?? ""
        let version = snapshot.iosVersion ?? ""
        return "v3.noPythonTunnelAttempt.\(name)|\(serial)|\(vendor)|\(product)|\(version)"
    }

    private static func loadAttempt(forKey key: String) -> StoredAttempt? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(StoredAttempt.self, from: data)
    }

    private static func saveAttempt(_ attempt: StoredAttempt, forKey key: String) {
        guard let data = try? JSONEncoder().encode(attempt) else { return }
        defaults.set(data, forKey: key)
    }

    private static func clearAttempt(for snapshot: DeviceSnapshot) {
        defaults.removeObject(forKey: attemptKey(for: snapshot))
    }
}

private enum LegacyObservedTunnelStateController {
    static func inspectTunnel(
        for snapshot: DeviceSnapshot,
        metadataSession: DeviceAgentTypedMetadataSession?,
        requirementResult: DeviceAgentTunnelRequirementResult
    ) -> DeviceAgentTunnelControllerSnapshot {
        guard SystemProcessProbe.isLegacyTunnelRunning() else {
            return DeviceAgentTunnelControllerSnapshot(
                tunnelState: requirementResult.state == .required ? .requiredInactive : .notRequired,
                lifecycleResult: DeviceAgentTunnelLifecycleResult(
                    state: .noProductOwnedTunnel,
                    summary: "No legacy tunnel process was observed, and product-owned tunnel lifecycle is still absent.",
                    nextAction: "Keep tunnel ownership under product control instead of relying on external tunnel processes.",
                    confidence: "medium"
                ),
                tunnelSession: nil,
                healthResult: nil,
                events: events(for: snapshot)
            )
        }

        return DeviceAgentTunnelControllerSnapshot(
            tunnelState: .requiredInactive,
            lifecycleResult: DeviceAgentTunnelLifecycleResult(
                state: .legacyObserved,
                summary: "A legacy tunnel process is visible, but tunnel lifecycle is not product-owned.",
                nextAction: "Replace legacy process observation with product-owned tunnel session state.",
                confidence: "low"
            ),
            tunnelSession: DeviceAgentTunnelSession(
                sessionID: "tunnel.session.legacy.observed",
                state: .legacyObserved,
                ownershipSummary: "Legacy external tunnel session",
                sourceMetadataSessionID: metadataSession?.sessionID,
                summary: "An external legacy tunnel process was observed, but the product does not own its lifecycle.",
                nextAction: "Replace this external tunnel observation with product-owned tunnel session management."
            ),
            healthResult: nil,
            events: events(for: snapshot)
        )
    }

    static func events(for snapshot: DeviceSnapshot) -> [DeviceAgentDiagnosticEvent] {
        guard snapshot.isConnected else { return [] }
        if SystemProcessProbe.isLegacyTunnelRunning() {
            return [
                DeviceAgentDiagnosticEvent(
                    level: .warning,
                    message: "Observed an existing legacy tunnel process, but it is not yet treated as product-owned tunnel readiness"
                )
            ]
        }
        return [
            DeviceAgentDiagnosticEvent(
                level: .info,
                message: "No legacy tunnel process observed during no-Python probe"
            )
        ]
    }
}

private struct DeviceAgentAssessmentFactory {
    static func makeDeviceAssessment(
        from probe: SystemUSBProbe,
        deviceInfoTransportService: DeviceInfoTransportServing
    ) -> DeviceAgentSessionAssessment {
        guard probe.isConnected else {
            return DeviceAgentSessionAssessment(
                readinessGate: .deviceAttachment,
                readinessSummary: "No USB-visible iPhone session",
                refreshIntent: DeviceAgentRefreshIntent(
                    scope: .deviceOnly,
                    probeFocus: .attachment
                ),
                recommendedProbeFocus: .attachment,
                deviceInfoReadiness: nil,
                deviceInfoTransportState: nil,
                deviceInfoTransportContract: nil,
                deviceInfoTransportProbeResult: nil,
                typedMetadataResult: nil,
                typedMetadataSession: nil,
                tunnelRequirementResult: nil,
                tunnelLifecycleResult: nil,
                tunnelSession: nil,
                tunnelHealthResult: nil,
                nextAction: "Keep the probe on attachment: connect one iPhone over USB, unlock it, and trust this Mac before probing deeper services.",
                blockerCodes: [.noDevice],
                blockers: ["No connected iPhone detected"],
                confidence: "high"
            )
        }

        var blockerCodes: [DeviceAgentAssessmentBlockerCode] = []
        var blockers: [String] = []
        var nextActions: [String] = []
        let hasUSBIdentity = hasUSBIdentitySignals(probe)
        let deviceInfoTransportProbeResult = deviceInfoTransportService.probeTransport(
            from: DeviceAgentUSBIdentityProbe(
                hasBootstrapCandidateIdentity: hasUSBIdentity,
                displayName: probe.displayName,
                serialSuffix: probe.serialSuffix,
                vendorID: probe.vendorID,
                productID: probe.productID,
                speed: probe.speed,
                iosVersion: probe.iosVersion
            )
        )
        let typedMetadataResult = deviceInfoTransportProbeResult.typedMetadataResult
        let typedMetadataSession = typedMetadataResult?.session
        let deviceInfoTransportState = deviceInfoTransportProbeResult.transportState
        let deviceInfoTransportContract = deviceInfoTransportProbeResult.contract
        let deviceInfoReadiness: DeviceAgentDeviceInfoReadiness
        if !hasUSBIdentity {
            deviceInfoReadiness = .usbVisibilityOnly
        } else if typedMetadataResult?.state == .bootstrapSeeded {
            deviceInfoReadiness = .typedMetadataMissing
        } else {
            deviceInfoReadiness = .usbIdentityObserved
        }
        var readinessSummary = hasUSBIdentity
            ? "USB identity observed, but typed session metadata is still missing"
            : "USB visibility established, but typed session metadata is still missing"
        var readinessGate: DeviceAgentReadinessGate = .deviceInfoTransport

        if typedMetadataResult?.state == .bootstrapSeeded {
            readinessSummary = "Seed-only typed metadata session prepared, but a live resolved metadata session is still missing"
        } else if typedMetadataResult?.state == .resolved {
            readinessSummary = "Typed metadata session resolved from USB identity; device-info transport is no longer the blocking layer"
            readinessGate = .ready
        }

        if probe.matchedDeviceCount > 1 {
            blockerCodes.append(.multipleDevices)
            blockers.append("Multiple Apple mobile devices are attached")
            nextActions.append("Keep the probe on selection: disconnect extra devices or add explicit device selection before deeper transport work.")
            readinessSummary = "Multiple USB-visible devices require session selection"
            readinessGate = .deviceSelection
        }

        if typedMetadataResult?.state != .resolved {
            blockerCodes.append(.deviceInfoMissing)
            blockers.append("Device info transport is not implemented yet")
            nextActions.append(deviceInfoTransportProbeResult.nextAction)
        } else {
            blockers.append("Device identity metadata resolved; tunnel ownership is the next missing layer")
            nextActions.append("Use resolved metadata session outputs to infer tunnel requirement and replace legacy tunnel observation.")
        }

        let orderedNextAction = deduplicated(nextActions).joined(separator: " ")
        return DeviceAgentSessionAssessment(
            readinessGate: readinessGate,
            readinessSummary: readinessSummary,
            refreshIntent: DeviceAgentRefreshIntent(
                scope: .deviceOnly,
                probeFocus: probe.matchedDeviceCount > 1 ? .selection : .deviceInfo
            ),
            recommendedProbeFocus: probe.matchedDeviceCount > 1 ? .selection : .deviceInfo,
            deviceInfoReadiness: readinessGate == .deviceInfoTransport ? deviceInfoReadiness : nil,
            deviceInfoTransportState: readinessGate == .deviceInfoTransport ? deviceInfoTransportState : nil,
            deviceInfoTransportContract: readinessGate == .deviceInfoTransport ? deviceInfoTransportContract : nil,
            deviceInfoTransportProbeResult: readinessGate == .deviceInfoTransport ? deviceInfoTransportProbeResult : nil,
            typedMetadataResult: readinessGate == .deviceInfoTransport ? typedMetadataResult : nil,
            typedMetadataSession: readinessGate == .deviceInfoTransport ? typedMetadataSession : nil,
            tunnelRequirementResult: nil,
            tunnelLifecycleResult: nil,
            tunnelSession: nil,
            tunnelHealthResult: nil,
            nextAction: orderedNextAction,
            blockerCodes: blockerCodes,
            blockers: blockers,
            confidence: probe.source == .systemProfiler ? "medium" : "low"
        )
    }

    static func makeTunnelAssessment(
        for snapshot: DeviceSnapshot,
        tunnelController: TunnelStateControlling
    ) -> DeviceAgentSessionAssessment? {
        let metadataSession = inferredTypedMetadataSession(from: snapshot)
        let requirementResult = inferTunnelRequirement(from: snapshot, metadataSession: metadataSession)
        let controllerSnapshot = tunnelController.inspectTunnel(
            for: snapshot,
            metadataSession: metadataSession,
            requirementResult: requirementResult
        )
        let lifecycleResult = controllerSnapshot.lifecycleResult
        let tunnelSession = controllerSnapshot.tunnelSession
        let tunnelHealthResult = controllerSnapshot.healthResult

        if requirementResult.state == .notRequired {
            return DeviceAgentSessionAssessment(
                readinessGate: .ready,
                readinessSummary: "Resolved metadata is strong enough to decide that this session does not require a tunnel.",
                refreshIntent: DeviceAgentRefreshIntent(
                    scope: .tunnelOnly,
                    probeFocus: nil
                ),
                recommendedProbeFocus: nil,
                deviceInfoReadiness: nil,
                deviceInfoTransportState: nil,
                deviceInfoTransportContract: nil,
                deviceInfoTransportProbeResult: nil,
                typedMetadataResult: nil,
                typedMetadataSession: nil,
                tunnelRequirementResult: requirementResult,
                tunnelLifecycleResult: lifecycleResult,
                tunnelSession: tunnelSession,
                tunnelHealthResult: tunnelHealthResult,
                nextAction: "Hold tunnel requirement as a typed decision and keep injection transport separate from tunnel lifecycle.",
                blockerCodes: [],
                blockers: [],
                confidence: requirementResult.confidence
            )
        }

        if lifecycleResult.state == .legacyObserved {
            let readinessSummary: String
            if requirementResult.state == .required {
                readinessSummary = "Resolved metadata says a tunnel is required, but lifecycle is still legacy-observed and unverified"
            } else if metadataSession?.state == .resolvedIdentity {
                readinessSummary = "Resolved metadata session is available, but tunnel lifecycle is still legacy-observed and unverified"
            } else {
                readinessSummary = "Observed a legacy tunnel process, but readiness is still unverified"
            }

            return DeviceAgentSessionAssessment(
                readinessGate: .tunnelOwnership,
                readinessSummary: readinessSummary,
                refreshIntent: DeviceAgentRefreshIntent(
                    scope: .tunnelOnly,
                    probeFocus: nil
                ),
                recommendedProbeFocus: nil,
                deviceInfoReadiness: nil,
                deviceInfoTransportState: nil,
                deviceInfoTransportContract: nil,
                deviceInfoTransportProbeResult: nil,
                typedMetadataResult: nil,
                typedMetadataSession: nil,
                tunnelRequirementResult: requirementResult,
                tunnelLifecycleResult: lifecycleResult,
                tunnelSession: tunnelSession,
                tunnelHealthResult: tunnelHealthResult,
                nextAction: metadataSession?.state == .resolvedIdentity
                    ? "Use the resolved metadata session to hold the tunnel requirement as a typed decision, then replace legacy process-name observation with product-owned tunnel lifecycle state."
                    : "Replace process-name observation with product-owned tunnel session management before treating tunnel presence as readiness.",
                blockerCodes: requirementResult.state == .required
                    ? [.tunnelRequired, .legacyTunnelObserved, .tunnelUnverified]
                    : [.legacyTunnelObserved, .tunnelUnverified],
                blockers: requirementResult.state == .required
                    ? [
                        "Tunnel is required for the current iOS session",
                        "Tunnel observation is legacy-derived",
                        "Tunnel readiness is not yet verified by the no-Python backend"
                    ]
                    : [
                        "Tunnel observation is legacy-derived",
                        "Tunnel readiness is not yet verified by the no-Python backend"
                    ],
                confidence: "low"
            )
        }

        if lifecycleResult.state == .productOwnedFailed {
            return DeviceAgentSessionAssessment(
                readinessGate: .tunnelOwnership,
                readinessSummary: "Tunnel requirement is typed, but the product-owned tunnel controller most recently failed to bring the session up.",
                refreshIntent: DeviceAgentRefreshIntent(
                    scope: .tunnelOnly,
                    probeFocus: nil
                ),
                recommendedProbeFocus: nil,
                deviceInfoReadiness: nil,
                deviceInfoTransportState: nil,
                deviceInfoTransportContract: nil,
                deviceInfoTransportProbeResult: nil,
                typedMetadataResult: nil,
                typedMetadataSession: nil,
                tunnelRequirementResult: requirementResult,
                tunnelLifecycleResult: lifecycleResult,
                tunnelSession: tunnelSession,
                tunnelHealthResult: tunnelHealthResult,
                nextAction: "Inspect the product-owned tunnel startup failure, then retry the owned tunnel session instead of relying on legacy tunnel observation.",
                blockerCodes: [.tunnelFailed],
                blockers: ["Product-owned tunnel startup failed for the current session"],
                confidence: "medium"
            )
        }

        return DeviceAgentSessionAssessment(
            readinessGate: .tunnelOwnership,
            readinessSummary: requirementResult.state == .required
                ? "Tunnel requirement is typed and active, but no product-owned tunnel lifecycle is available yet"
                : "Tunnel requirement has a typed assessment, but it is still undetermined without stronger session inputs",
            refreshIntent: DeviceAgentRefreshIntent(
                scope: .tunnelOnly,
                probeFocus: nil
            ),
            recommendedProbeFocus: nil,
            deviceInfoReadiness: nil,
            deviceInfoTransportState: nil,
            deviceInfoTransportContract: nil,
            deviceInfoTransportProbeResult: nil,
            typedMetadataResult: nil,
            typedMetadataSession: nil,
            tunnelRequirementResult: requirementResult,
            tunnelLifecycleResult: lifecycleResult,
            tunnelSession: tunnelSession,
            tunnelHealthResult: tunnelHealthResult,
            nextAction: requirementResult.nextAction + " " + lifecycleResult.nextAction,
            blockerCodes: requirementResult.state == .required ? [.tunnelRequired] : [.tunnelUnknown],
            blockers: requirementResult.state == .required
                ? ["Tunnel is required for the current iOS session, but no product-owned tunnel is active"]
                : ["Tunnel requirement has not been satisfied by product-owned lifecycle state"],
            confidence: requirementResult.confidence
        )
    }

    private static func hasUSBIdentitySignals(_ probe: SystemUSBProbe) -> Bool {
        let hasDisplayName = !(probe.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasSerial = !(probe.serialSuffix?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasSpeed = !(probe.speed?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasVendor = !(probe.vendorID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasProduct = !(probe.productID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return hasDisplayName || hasSerial || hasSpeed || hasVendor || hasProduct
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for value in values where seen.insert(value).inserted {
            ordered.append(value)
        }
        return ordered
    }

    private static func inferredTypedMetadataSession(from snapshot: DeviceSnapshot) -> DeviceAgentTypedMetadataSession? {
        let hasHumanIdentity = !(snapshot.deviceName?.isEmpty ?? true) || !(snapshot.serialSuffix?.isEmpty ?? true)
        let hasStableIdentifiers = !(snapshot.vendorID?.isEmpty ?? true) && !(snapshot.productID?.isEmpty ?? true)
        guard snapshot.isConnected, hasHumanIdentity else { return nil }
        let state: DeviceAgentTypedMetadataSessionState = hasStableIdentifiers ? .resolvedIdentity : .seedOnly
        let sessionID = state == .resolvedIdentity
            ? "typed-metadata.session.resolved.snapshot"
            : "typed-metadata.session.seed.snapshot"
        return DeviceAgentTypedMetadataSession(
            sessionID: sessionID,
            sourceTransportID: "device-snapshot",
            artifactID: state == .resolvedIdentity
                ? "typed-metadata.resolved.snapshot"
                : "typed-metadata.seed.snapshot",
            state: state,
            summary: state == .resolvedIdentity
                ? "Snapshot carries enough typed identity to represent a resolved metadata session."
                : "Snapshot carries only seed-level identity for tunnel planning.",
            nextAction: state == .resolvedIdentity
                ? "Use the resolved snapshot metadata session to drive tunnel requirement decisions."
                : "Promote snapshot identity beyond seed level before depending on it for tunnel planning."
        )
    }

    private static func inferTunnelRequirement(
        from snapshot: DeviceSnapshot,
        metadataSession: DeviceAgentTypedMetadataSession?
    ) -> DeviceAgentTunnelRequirementResult {
        if let iosVersion = snapshot.iosVersion,
           let major = Int(iosVersion.split(separator: ".").first ?? "") {
            if major >= 17 {
                return DeviceAgentTunnelRequirementResult(
                    state: .required,
                    sourceMetadataSessionID: metadataSession?.sessionID,
                    summary: "iOS \(iosVersion) requires tunnel support for the current transport path.",
                    nextAction: "Bring tunnel lifecycle under product ownership and verify that the required tunnel is active.",
                    confidence: "high"
                )
            }
            return DeviceAgentTunnelRequirementResult(
                state: .notRequired,
                sourceMetadataSessionID: metadataSession?.sessionID,
                summary: "iOS \(iosVersion) does not require a tunnel for the current transport path.",
                nextAction: "Keep tunnel lifecycle separate from injection transport, but this session does not need an active tunnel.",
                confidence: "high"
            )
        }
        if metadataSession?.state == .resolvedIdentity {
            return DeviceAgentTunnelRequirementResult(
                state: .undetermined,
                sourceMetadataSessionID: metadataSession?.sessionID,
                summary: "Resolved device metadata is available, but iOS version is still missing so tunnel requirement cannot be decided yet.",
                nextAction: "Add iOS version discovery to the resolved metadata session so tunnel requirement can become a typed decision.",
                confidence: "medium"
            )
        }
        return DeviceAgentTunnelRequirementResult(
            state: .undetermined,
            sourceMetadataSessionID: metadataSession?.sessionID,
            summary: "Tunnel requirement is still undetermined because metadata inputs are not resolved enough.",
            nextAction: "Strengthen metadata inputs before expecting a typed tunnel requirement decision.",
            confidence: "low"
        )
    }

}

private struct SystemUSBProbeResultAdapter {
    static func makeState(
        from probe: SystemUSBProbe,
        deviceInfoTransportService: DeviceInfoTransportServing
    ) -> DeviceAgentDeviceState {
        DeviceAgentDeviceState(
                snapshot: DeviceSnapshot(
                    isConnected: probe.isConnected,
                    connectionSummary: NoPythonDeviceSummary.connectionSummary(from: probe),
                    iosVersion: probe.iosVersion,
                    deviceName: probe.displayName,
                    serialSuffix: probe.serialSuffix,
                    vendorID: probe.vendorID,
                    productID: probe.productID,
                    probeSource: probeSourceLabel(for: probe.source),
                    matchedDeviceCount: probe.matchedDeviceCount
                ),
            assessment: DeviceAgentAssessmentFactory.makeDeviceAssessment(
                from: probe,
                deviceInfoTransportService: deviceInfoTransportService
            ),
            events: probe.events
        )
    }

    private static func probeSourceLabel(for source: SystemUSBProbe.Source) -> String {
        switch source {
        case .systemProfiler:
            return "system_profiler"
        case .ioregFallback:
            return "ioreg"
        case .none:
            return "none"
        }
    }
}

private extension StubDeviceAgentService {
    func deviceStateResponse(from probe: SystemUSBProbe) -> DeviceAgentResponse {
        .success(
            .deviceState(
                SystemUSBProbeResultAdapter.makeState(
                    from: probe,
                    deviceInfoTransportService: deviceInfoTransportService
                )
            )
        )
    }
}

private enum SystemProcessProbe {
    static func isLegacyTunnelRunning() -> Bool {
        let output = runCaptured(
            executable: "/usr/bin/pgrep",
            arguments: ["-f", "pymobiledevice3.*remote.*tunneld"]
        )

        switch output {
        case .success:
            return true
        case .failure:
            return false
        }
    }
}

private func runCaptured(
    executable: String,
    arguments: [String]
) -> Result<String, DeviceAgentFailure> {
    let task = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    task.executableURL = URL(fileURLWithPath: executable)
    task.arguments = arguments
    task.standardOutput = stdout
    task.standardError = stderr

    do {
        try task.run()
        task.waitUntilExit()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()

        guard task.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(
                DeviceAgentFailure(
                    code: .agentUnavailable,
                    message: message?.isEmpty == false
                        ? message!
                        : "\(executable) exited with code \(task.terminationStatus)"
                )
            )
        }

        let output = String(data: outputData, encoding: .utf8) ?? ""
        return .success(output)
    } catch {
        return .failure(
            DeviceAgentFailure(
                code: .agentUnavailable,
                message: error.localizedDescription
            )
        )
    }
}
