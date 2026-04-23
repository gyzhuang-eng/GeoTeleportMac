import Darwin
import Foundation

protocol DeviceAgentServicing {
    func handle(_ request: DeviceAgentRequest) -> DeviceAgentResponse
}

struct StubDeviceAgentService: DeviceAgentServicing {
    private let deviceInfoTransportService: DeviceInfoTransportServing
    private let tunnelController: TunnelStateControlling
    private let injectionTransportService: InjectionTransportServing

    init(
        deviceInfoTransportService: DeviceInfoTransportServing = DeviceInfoTransportServiceStack(),
        tunnelController: TunnelStateControlling = TunnelStateControllerStack(),
        injectionTransportService: InjectionTransportServing = InjectionTransportServiceStack()
    ) {
        self.deviceInfoTransportService = deviceInfoTransportService
        self.tunnelController = tunnelController
        self.injectionTransportService = injectionTransportService
    }

    func handle(_ request: DeviceAgentRequest) -> DeviceAgentResponse {
        switch request {
        case .probeAvailability:
            return .success(
                .availability(
                    DeviceAgentAvailability(
                        isReachable: true,
                        summary: "Child-process agent reachable; bootstrap transport is up, while session readiness and injection transport still depend on later typed probes.",
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
                                message: "Injection transport is now typed, but real execution still depends on later device-identifier and harness readiness probes"
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
                tunnelController: tunnelController,
                injectionTransportService: injectionTransportService
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
        case .setLocation(let request):
            let probe = SystemUSBProbe.detectIPhone()
            let deviceState = SystemUSBProbeResultAdapter.makeState(
                from: probe,
                deviceInfoTransportService: deviceInfoTransportService
            )
            let tunnelAssessment = DeviceAgentAssessmentFactory.makeTunnelAssessment(
                for: deviceState.snapshot,
                tunnelController: tunnelController,
                injectionTransportService: injectionTransportService
            )
            return injectionTransportService.setLocation(
                request,
                snapshot: deviceState.snapshot,
                tunnelAssessment: tunnelAssessment
            )
        case .clearLocation:
            let probe = SystemUSBProbe.detectIPhone()
            let deviceState = SystemUSBProbeResultAdapter.makeState(
                from: probe,
                deviceInfoTransportService: deviceInfoTransportService
            )
            let tunnelAssessment = DeviceAgentAssessmentFactory.makeTunnelAssessment(
                for: deviceState.snapshot,
                tunnelController: tunnelController,
                injectionTransportService: injectionTransportService
            )
            return injectionTransportService.clearLocation(
                snapshot: deviceState.snapshot,
                tunnelAssessment: tunnelAssessment
            )
        }
    }

    static func runExpectedRSDEndpointSelfCheckReport() -> String {
        ProductOwnedTunnelStateController.runExpectedRSDEndpointSelfCheckReport()
    }

    static func runInjectionTransportSelfCheckReport() -> String {
        let unavailableService = EndpointBackedInjectionTransportCommandAdapter(
            resolveCLIPath: { nil }
        )
        let availableService = EndpointBackedInjectionTransportCommandAdapter(
            resolveCLIPath: { "/opt/homebrew/bin/pymobiledevice3" }
        )
        let syntheticSnapshot = DeviceSnapshot(
            isConnected: true,
            connectionSummary: "SELF-CHECK",
            iosVersion: "17.4",
            deviceName: "Self Check iPhone",
            deviceIdentifier: "self-check-device-id",
            serialSuffix: "0000",
            vendorID: "0x05ac",
            productID: "0x12a8",
            probeSource: "self-check",
            matchedDeviceCount: 1
        )
        let unavailableProbe = unavailableService.probeTransport(
            snapshot: syntheticSnapshot,
            tunnelEndpointResult: nil
        )
        let verifiedEndpoint = DeviceAgentTunnelEndpointResult(
            state: .verified,
            artifact: DeviceAgentTunnelEndpointArtifact(
                artifactID: "tunnel.endpoint.self-check",
                host: "127.0.0.1",
                port: 60123,
                sourceTunnelSessionID: "tunnel.session.self-check",
                sourceHealthState: .verified,
                sourceProtocolHint: .expectedRSDHandshakeVerified,
                summary: "Synthetic verified tunnel endpoint for injection-transport self-check."
            ),
            summary: "Synthetic verified tunnel endpoint is available for injection-transport self-check.",
            nextAction: "Consume the verified endpoint artifact directly.",
            confidence: "high"
        )
        let endpointBackedProbe = availableService.probeTransport(
            snapshot: syntheticSnapshot,
            tunnelEndpointResult: verifiedEndpoint
        )
        let invocation = availableService.makeSetLocationInvocation(
            request: TeleportRequest(latitude: "1.23", longitude: "4.56"),
            tunnelEndpointResult: verifiedEndpoint
        )
        let clearInvocation = availableService.makeClearLocationInvocation(
            tunnelEndpointResult: verifiedEndpoint
        )
        let serviceUnavailableFailure = invocation.map {
            availableService.classifyCommandFailure(
                result: ShellCommandResult(
                    stdout: "",
                    stderr: "Failed to start service. Possible reasons are:\n- Make sure you passed the --rsd option to the subcommand",
                    exitCode: 1
                ),
                invocation: $0
            )
        }
        let transportMismatchFailure = invocation.map {
            availableService.classifyCommandFailure(
                result: ShellCommandResult(
                    stdout: "",
                    stderr: "Error: No such option: --rsd",
                    exitCode: 2
                ),
                invocation: $0
            )
        }
        let genericExecutionFailure = invocation.map {
            availableService.classifyCommandFailure(
                result: ShellCommandResult(
                    stdout: "",
                    stderr: "Traceback: unexpected failure",
                    exitCode: 7
                ),
                invocation: $0
            )
        }

        struct Check {
            let name: String
            let passed: Bool
            let detail: String
        }

        let checks: [Check] = [
            Check(
                name: "nil-endpoint-remains-unavailable",
                passed: unavailableProbe.transportState == .unavailable
                    && unavailableProbe.contract.phase == .probeOnly
                    && unavailableProbe.sourceTunnelEndpointArtifactID == nil,
                detail: "state=\(unavailableProbe.transportState.rawValue) phase=\(unavailableProbe.contract.phase.rawValue) artifact=\(unavailableProbe.sourceTunnelEndpointArtifactID ?? "nil")"
            ),
            Check(
                name: "verified-endpoint-enables-endpoint-backed-command",
                passed: endpointBackedProbe.transportState == .endpointBackedCommand
                    && endpointBackedProbe.contract.phase == .endpointBackedCommand
                    && endpointBackedProbe.sourceTunnelEndpointArtifactID == verifiedEndpoint.artifact.artifactID,
                detail: "state=\(endpointBackedProbe.transportState.rawValue) phase=\(endpointBackedProbe.contract.phase.rawValue) artifact=\(endpointBackedProbe.sourceTunnelEndpointArtifactID ?? "nil")"
            ),
            Check(
                name: "verified-endpoint-summary-mentions-endpoint",
                passed: endpointBackedProbe.summary.contains("127.0.0.1:60123"),
                detail: endpointBackedProbe.summary
            ),
            Check(
                name: "invocation-builds-rsd-command",
                passed: invocation?.arguments == [
                    "developer",
                    "dvt",
                    "simulate-location",
                    "set",
                    "--rsd",
                    "127.0.0.1",
                    "60123",
                    "--",
                    "1.23",
                    "4.56"
                ],
                detail: invocation.map { "\($0.executable) \($0.arguments.joined(separator: " "))" } ?? "nil"
            ),
            Check(
                name: "clear-invocation-builds-rsd-command",
                passed: clearInvocation?.arguments == [
                    "developer",
                    "dvt",
                    "simulate-location",
                    "clear",
                    "--rsd",
                    "127.0.0.1",
                    "60123"
                ],
                detail: clearInvocation.map { "\($0.executable) \($0.arguments.joined(separator: " "))" } ?? "nil"
            ),
            Check(
                name: "classifier-recognizes-session-unavailable",
                passed: serviceUnavailableFailure?.code == .agentUnavailable,
                detail: serviceUnavailableFailure.map { "\($0.code.rawValue): \($0.message)" } ?? "nil"
            ),
            Check(
                name: "classifier-recognizes-transport-mismatch",
                passed: transportMismatchFailure?.code == .transportUnimplemented,
                detail: transportMismatchFailure.map { "\($0.code.rawValue): \($0.message)" } ?? "nil"
            ),
            Check(
                name: "classifier-keeps-generic-command-failures-typed",
                passed: genericExecutionFailure?.code == .transportExecutionFailed,
                detail: genericExecutionFailure.map { "\($0.code.rawValue): \($0.message)" } ?? "nil"
            )
        ]

        var lines: [String] = []
        var failureCount = 0

        for check in checks {
            if check.passed {
                lines.append("PASS \(check.name): \(check.detail)")
            } else {
                failureCount += 1
                lines.append("FAIL \(check.name): \(check.detail)")
            }
        }

        if failureCount == 0 {
            lines.append("Injection transport self-check passed (\(checks.count) cases).")
        } else {
            lines.append("Injection transport self-check failed (\(failureCount)/\(checks.count) cases).")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func runXcodeLocationHarnessSelfCheckReport() -> String {
        let service = XcodeTestLocationInjectionTransportAdapter()
        let disconnectedProbe = service.probeTransport(
            snapshot: DeviceSnapshot(
                isConnected: false,
                connectionSummary: "NO DEVICE",
                iosVersion: nil,
                deviceName: nil,
                deviceIdentifier: nil,
                serialSuffix: nil,
                vendorID: nil,
                productID: nil,
                probeSource: "self-check",
                matchedDeviceCount: 0
            ),
            tunnelEndpointResult: nil
        )
        let connectedSnapshot = DeviceSnapshot(
            isConnected: true,
            connectionSummary: "SELF-CHECK",
            iosVersion: "17.4",
            deviceName: "Self Check iPhone",
            deviceIdentifier: "self-check-device-id",
            serialSuffix: "0000",
            vendorID: "0x05ac",
            productID: "0x12a8",
            probeSource: "self-check",
            matchedDeviceCount: 1
        )
        let readyProbe = service.probeTransport(
            snapshot: connectedSnapshot,
            tunnelEndpointResult: nil
        )
        let buildCheck = service.runHarnessBuildSelfCheck()
        let signingFailure = service.classifyFailure(
            result: ShellCommandResult(
                stdout: "",
                stderr: "No profiles for 'GeoTeleportLocationHarnessTests' were found: Xcode couldn't find any iOS App Development provisioning profiles matching 'GeoTeleportLocationHarnessTests'.",
                exitCode: 65
            ),
            invocation: InjectionTransportCommandInvocation(
                executable: "/usr/bin/xcrun",
                arguments: [
                    "xcodebuild",
                    "test",
                    "-scheme", XcodeLocationHarnessPackage.packageName
                ],
                environment: [:],
                workingDirectory: "/tmp",
                commandSummary: "xcodebuild test -scheme \(XcodeLocationHarnessPackage.packageName)"
            )
        )
        let destinationFailure = service.classifyFailure(
            result: ShellCommandResult(
                stdout: "",
                stderr: "Unable to find a destination matching the provided destination specifier.",
                exitCode: 70
            ),
            invocation: InjectionTransportCommandInvocation(
                executable: "/usr/bin/xcrun",
                arguments: [
                    "xcodebuild",
                    "test",
                    "-scheme", XcodeLocationHarnessPackage.packageName
                ],
                environment: [:],
                workingDirectory: "/tmp",
                commandSummary: "xcodebuild test -scheme \(XcodeLocationHarnessPackage.packageName)"
            )
        )

        struct Check {
            let name: String
            let passed: Bool
            let detail: String
        }

        let checks: [Check] = [
            Check(
                name: "disconnected-device-keeps-harness-unavailable",
                passed: disconnectedProbe.transportState == .unavailable,
                detail: disconnectedProbe.summary
            ),
            Check(
                name: "connected-device-with-identifier-enables-harness-probe",
                passed: readyProbe.transportState == .xcodeTestHarness
                    && readyProbe.contract.phase == .xcodeTestHarness,
                detail: readyProbe.summary
            ),
            Check(
                name: "harness-package-builds-for-generic-ios",
                passed: buildCheck.exitCode == 0,
                detail: buildCheck.detail
            ),
            Check(
                name: "harness-classifier-recognizes-signing-failures",
                passed: signingFailure.code == .transportExecutionFailed,
                detail: "\(signingFailure.code.rawValue): \(signingFailure.message)"
            ),
            Check(
                name: "harness-classifier-recognizes-destination-failures",
                passed: destinationFailure.code == .agentUnavailable,
                detail: "\(destinationFailure.code.rawValue): \(destinationFailure.message)"
            )
        ]

        var lines: [String] = []
        var failureCount = 0
        for check in checks {
            if check.passed {
                lines.append("PASS \(check.name): \(check.detail)")
            } else {
                failureCount += 1
                lines.append("FAIL \(check.name): \(check.detail)")
            }
        }

        if failureCount == 0 {
            lines.append("Xcode location harness self-check passed (\(checks.count) cases).")
        } else {
            lines.append("Xcode location harness self-check failed (\(failureCount)/\(checks.count) cases).")
        }

        return lines.joined(separator: "\n") + "\n"
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
    let deviceIdentifier: String?
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
                    deviceIdentifier: nil,
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
                    deviceIdentifier: nil,
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
                        deviceIdentifier: nil,
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
                    deviceIdentifier: nil,
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
                    deviceIdentifier: probe.deviceIdentifier,
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
                deviceIdentifier: match.identifier.isEmpty ? probe.deviceIdentifier : match.identifier,
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
                deviceIdentifier: probe.deviceIdentifier,
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
    let identifier: String
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
                    identifier: (dictionary["identifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
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
    let endpointResult: DeviceAgentTunnelEndpointResult?
    let events: [DeviceAgentDiagnosticEvent]
}

protocol InjectionTransportServing {
    var transportID: String { get }
    func probeTransport(
        snapshot: DeviceSnapshot,
        tunnelEndpointResult: DeviceAgentTunnelEndpointResult?
    ) -> DeviceAgentInjectionTransportProbeResult
    func setLocation(
        _ request: TeleportRequest,
        snapshot: DeviceSnapshot,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> DeviceAgentResponse
    func clearLocation(
        snapshot: DeviceSnapshot,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> DeviceAgentResponse
}

struct InjectionTransportServiceStack: InjectionTransportServing {
    let services: [any InjectionTransportServing]

    var transportID: String {
        services.first?.transportID ?? "injection.transport.none"
    }

    init(services: [any InjectionTransportServing] = [
        XcodeTestLocationInjectionTransportAdapter(),
        EndpointBackedInjectionTransportCommandAdapter()
    ]) {
        self.services = services
    }

    func probeTransport(
        snapshot: DeviceSnapshot,
        tunnelEndpointResult: DeviceAgentTunnelEndpointResult?
    ) -> DeviceAgentInjectionTransportProbeResult {
        let results = services.map {
            $0.probeTransport(snapshot: snapshot, tunnelEndpointResult: tunnelEndpointResult)
        }
        if let ready = results.first(where: { $0.transportState == .xcodeTestHarness }) {
            return ready
        }
        if let ready = results.first(where: { $0.transportState == .endpointBackedCommand }) {
            return ready
        }
        if let ready = results.first(where: { $0.transportState == .endpointBackedStub }) {
            return ready
        }
        return results.last ?? NullInjectionTransportService().probeTransport(
            snapshot: snapshot,
            tunnelEndpointResult: tunnelEndpointResult
        )
    }

    func setLocation(
        _ request: TeleportRequest,
        snapshot: DeviceSnapshot,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> DeviceAgentResponse {
        guard snapshot.isConnected else {
            return .failure(
                DeviceAgentFailure(
                    code: .invalidRequest,
                    message: "No connected iPhone session is available for device-agent injection."
                )
            )
        }
        let service = preferredService(snapshot: snapshot, tunnelAssessment: tunnelAssessment)
        return service.setLocation(request, snapshot: snapshot, tunnelAssessment: tunnelAssessment)
    }

    func clearLocation(
        snapshot: DeviceSnapshot,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> DeviceAgentResponse {
        guard snapshot.isConnected else {
            return .failure(
                DeviceAgentFailure(
                    code: .invalidRequest,
                    message: "No connected iPhone session is available for device-agent location clear."
                )
            )
        }
        let service = preferredService(snapshot: snapshot, tunnelAssessment: tunnelAssessment)
        return service.clearLocation(snapshot: snapshot, tunnelAssessment: tunnelAssessment)
    }

    private func preferredService(
        snapshot: DeviceSnapshot,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> any InjectionTransportServing {
        let tunnelEndpointResult = tunnelAssessment?.tunnelEndpointResult
        return services.first {
            let state = $0.probeTransport(
                snapshot: snapshot,
                tunnelEndpointResult: tunnelEndpointResult
            ).transportState
            return state != .unavailable
        } ?? services.first ?? NullInjectionTransportService()
    }
}

fileprivate struct InjectionTransportCommandInvocation {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: String?
    let commandSummary: String
}

fileprivate enum InjectionTransportCommandFailureKind {
    case invalidRequest
    case sessionUnavailable
    case transportUnavailable
    case executionFailed
}

private enum XcodeLocationHarnessPackage {
    static let packageName = "GeoTeleportLocationHarness"
    static let testSelector = "GeoTeleportLocationHarnessTests/GeoTeleportLocationHarnessTests/testApplyRequestedLocation"

    static func packageDirectory(filePath: String = #filePath) -> String? {
        if let materialized = materializedPackageDirectory() {
            return materialized
        }

        let fileURL = URL(fileURLWithPath: filePath)
        let repositoryRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let packageURL = repositoryRoot.appendingPathComponent(packageName, isDirectory: true)
        let manifestURL = packageURL.appendingPathComponent("Package.swift", isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            return nil
        }
        return packageURL.path
    }

    static func preferredMaterializedPackageDirectoryPath() -> String? {
        let fileManager = FileManager.default
        guard let baseDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "GeoTeleportMacV3"
        return baseDirectory
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("GeneratedArtifacts", isDirectory: true)
            .appendingPathComponent(packageName, isDirectory: true)
            .path
    }

    static func isMaterializedPackageDirectory(_ path: String) -> Bool {
        guard let expectedPath = preferredMaterializedPackageDirectoryPath() else {
            return false
        }
        return NSString(string: path).standardizingPath == NSString(string: expectedPath).standardizingPath
    }

    private static func materializedPackageDirectory() -> String? {
        guard let packagePath = preferredMaterializedPackageDirectoryPath() else {
            return nil
        }

        let fileManager = FileManager.default
        let packageURL = URL(fileURLWithPath: packagePath, isDirectory: true)
        let sourcesURL = packageURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(packageName, isDirectory: true)
        let testsURL = packageURL
            .appendingPathComponent("Tests", isDirectory: true)
            .appendingPathComponent("\(packageName)Tests", isDirectory: true)

        do {
            try fileManager.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: testsURL, withIntermediateDirectories: true)
            try writeIfNeeded(packageManifest, to: packageURL.appendingPathComponent("Package.swift", isDirectory: false))
            try writeIfNeeded(librarySource, to: sourcesURL.appendingPathComponent("\(packageName).swift", isDirectory: false))
            try writeIfNeeded(testSource, to: testsURL.appendingPathComponent("\(packageName)Tests.swift", isDirectory: false))
            return packageURL.path
        } catch {
            return nil
        }
    }

    private static func writeIfNeeded(_ contents: String, to url: URL) throws {
        let data = Data(contents.utf8)
        if let existing = try? Data(contentsOf: url), existing == data {
            return
        }
        try data.write(to: url, options: .atomic)
    }

    private static let packageManifest = """
    // swift-tools-version: 5.10
    import PackageDescription

    let package = Package(
        name: "\(packageName)",
        platforms: [
            .iOS(.v16)
        ],
        products: [
            .library(
                name: "\(packageName)",
                targets: ["\(packageName)"]
            )
        ],
        targets: [
            .target(
                name: "\(packageName)"
            ),
            .testTarget(
                name: "\(packageName)Tests",
                dependencies: ["\(packageName)"]
            )
        ]
    )
    """

    private static let librarySource = """
    public enum \(packageName) {}
    """

    private static let testSource = """
    import CoreLocation
    import XCUIAutomation
    import XCTest

    final class \(packageName)Tests: XCTestCase {
        func testApplyRequestedLocation() throws {
            guard #available(iOS 16.4, *) else {
                XCTFail("Xcode-backed location injection requires iOS 16.4 or later.")
                return
            }

            let environment = ProcessInfo.processInfo.environment
            guard let action = environment["GTM_ACTION"]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !action.isEmpty else {
                XCTFail("Missing GTM_ACTION for \(packageName) test invocation.")
                return
            }

            switch action {
            case "set":
                guard let latitudeRaw = environment["GTM_LAT"],
                      let longitudeRaw = environment["GTM_LON"],
                      let latitude = Double(latitudeRaw),
                      let longitude = Double(longitudeRaw) else {
                    XCTFail("Invalid coordinates supplied through GTM_LAT / GTM_LON.")
                    return
                }
                XCUIDevice.shared.location = XCUILocation(
                    location: CLLocation(latitude: latitude, longitude: longitude)
                )
            case "clear":
                XCUIDevice.shared.location = nil
            default:
                XCTFail("Unsupported GTM_ACTION: \\(action)")
            }
        }
    }
    """
}

private struct XcodeHarnessBuildSelfCheckResult {
    let exitCode: Int32
    let detail: String
}

private struct XcodeTestLocationInjectionTransportAdapter: InjectionTransportServing {
    let transportID = "injection.transport.xcode-test-harness"
    private let runner: ShellCommandRunner
    private let resolveHarnessDirectory: () -> String?

    init(
        runner: ShellCommandRunner = ShellCommandRunner(),
        resolveHarnessDirectory: @escaping () -> String? = { XcodeLocationHarnessPackage.packageDirectory() }
    ) {
        self.runner = runner
        self.resolveHarnessDirectory = resolveHarnessDirectory
    }

    func probeTransport(
        snapshot: DeviceSnapshot,
        tunnelEndpointResult: DeviceAgentTunnelEndpointResult?
    ) -> DeviceAgentInjectionTransportProbeResult {
        guard snapshot.isConnected else {
            return unavailableProbe(
                summary: "Xcode test harness injection cannot start because no connected device session is available.",
                nextAction: "Connect exactly one trusted iPhone before expecting direct Xcode-backed location injection."
            )
        }

        guard let deviceIdentifier = normalizedDeviceIdentifier(from: snapshot) else {
            return unavailableProbe(
                summary: "Xcode test harness injection needs a resolved device identifier from xcdevice, but the current snapshot does not carry one yet.",
                nextAction: "Refresh device metadata until xcdevice contributes a stable device identifier for the attached iPhone."
            )
        }

        guard let harnessDirectory = resolveHarnessDirectory() else {
            return unavailableProbe(
                summary: "Xcode test harness injection is selected as the primary no-Python path, but the local harness package is missing.",
                nextAction: "Allow the app to materialize the GeoTeleportLocationHarness package under Application Support, or restore the fallback source-tree copy for development."
            )
        }

        let packageOriginSummary: String
        let nextAction: String
        if XcodeLocationHarnessPackage.isMaterializedPackageDirectory(harnessDirectory) {
            packageOriginSummary = "The local harness package is materialized under Application Support at \(harnessDirectory)."
            nextAction = "Run set/clear through that materialized Xcode location harness without rediscovering tunnel state or falling back to the compatibility CLI bridge."
        } else {
            packageOriginSummary = "The source-tree fallback harness package is available at \(harnessDirectory)."
            nextAction = "Run set/clear through the fallback Xcode location harness while keeping the compatibility CLI bridge as a non-primary path."
        }

        return DeviceAgentInjectionTransportProbeResult(
            transportID: transportID,
            transportState: .xcodeTestHarness,
            contract: DeviceAgentInjectionTransportContract(
                contractID: "injection.transport.xcode-test-harness",
                phase: .xcodeTestHarness,
                summary: "Injection transport is ready to drive location simulation through an Xcode XCTest harness without relying on the compatibility CLI bridge.",
                expectedInput: "Teleport request + resolved device identifier + materialized local Xcode harness package"
            ),
            sourceTunnelEndpointArtifactID: tunnelEndpointResult?.artifact.artifactID,
            summary: "Xcode test harness is ready for device \(deviceIdentifier). \(packageOriginSummary) Direct injection no longer depends on rediscovering or holding the compatibility tunnel path.",
            nextAction: nextAction,
            confidence: "medium"
        )
    }

    func setLocation(
        _ request: TeleportRequest,
        snapshot: DeviceSnapshot,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> DeviceAgentResponse {
        guard snapshot.isConnected else {
            return .failure(
                DeviceAgentFailure(
                    code: .invalidRequest,
                    message: "No connected iPhone session is available for direct Xcode-backed location injection."
                )
            )
        }
        guard Double(request.latitude) != nil, Double(request.longitude) != nil else {
            return .failure(
                DeviceAgentFailure(
                    code: .invalidRequest,
                    message: "Invalid coordinates supplied to the Xcode test harness injection transport."
                )
            )
        }
        guard let invocation = makeSetLocationInvocation(request: request, snapshot: snapshot) else {
            return .failure(
                DeviceAgentFailure(
                    code: .transportUnimplemented,
                    message: "Xcode test harness injection could not build a runnable xcodebuild test invocation for the current device."
                )
            )
        }

        return runInvocation(
            invocation,
            successEvents: successEvents(
                for: snapshot,
                harnessDirectory: invocation.workingDirectory,
                commandSummary: invocation.commandSummary,
                operationSummary: "location set"
            )
        )
    }

    func clearLocation(
        snapshot: DeviceSnapshot,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> DeviceAgentResponse {
        guard snapshot.isConnected else {
            return .failure(
                DeviceAgentFailure(
                    code: .invalidRequest,
                    message: "No connected iPhone session is available for direct Xcode-backed location clear."
                )
            )
        }
        guard let invocation = makeClearLocationInvocation(snapshot: snapshot) else {
            return .failure(
                DeviceAgentFailure(
                    code: .transportUnimplemented,
                    message: "Xcode test harness injection could not build a runnable clear-location invocation for the current device."
                )
            )
        }

        return runInvocation(
            invocation,
            successEvents: successEvents(
                for: snapshot,
                harnessDirectory: invocation.workingDirectory,
                commandSummary: invocation.commandSummary,
                operationSummary: "location clear"
            )
        )
    }

    fileprivate func runHarnessBuildSelfCheck() -> XcodeHarnessBuildSelfCheckResult {
        guard let harnessDirectory = resolveHarnessDirectory() else {
            return XcodeHarnessBuildSelfCheckResult(
                exitCode: 1,
                detail: "GeoTeleportLocationHarness package directory is missing."
            )
        }

        let arguments = [
            "xcodebuild",
            "-scheme", XcodeLocationHarnessPackage.packageName,
            "-destination", "generic/platform=iOS",
            "build-for-testing",
            "CODE_SIGNING_ALLOWED=NO"
        ]

        switch runner.run(
            "/usr/bin/xcrun",
            args: arguments,
            environment: ProcessInfo.processInfo.environment,
            workingDirectory: harnessDirectory
        ) {
        case .failure(let error):
            return XcodeHarnessBuildSelfCheckResult(
                exitCode: 1,
                detail: "Unable to launch xcodebuild: \(shellCommandErrorMessage(error))"
            )
        case .success(let result):
            let combined = [result.stdout, result.stderr]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return XcodeHarnessBuildSelfCheckResult(
                exitCode: result.exitCode,
                detail: combined.isEmpty ? "exit=\(result.exitCode)" : combined
            )
        }
    }

    private func unavailableProbe(summary: String, nextAction: String) -> DeviceAgentInjectionTransportProbeResult {
        DeviceAgentInjectionTransportProbeResult(
            transportID: transportID,
            transportState: .unavailable,
            contract: DeviceAgentInjectionTransportContract(
                contractID: "injection.transport.xcode-test-harness",
                phase: .probeOnly,
                summary: "Direct Xcode-backed injection is reserved for sessions with a resolved device identifier and a materialized local harness package.",
                expectedInput: "Connected device snapshot with xcdevice identifier + materialized local Xcode harness package"
            ),
            sourceTunnelEndpointArtifactID: nil,
            summary: summary,
            nextAction: nextAction,
            confidence: "medium"
        )
    }

    private func makeSetLocationInvocation(
        request: TeleportRequest,
        snapshot: DeviceSnapshot
    ) -> InjectionTransportCommandInvocation? {
        guard let harnessDirectory = resolveHarnessDirectory(),
              let deviceIdentifier = normalizedDeviceIdentifier(from: snapshot) else {
            return nil
        }

        var environment = ProcessInfo.processInfo.environment
        environment["GTM_ACTION"] = "set"
        environment["GTM_LAT"] = request.latitude
        environment["GTM_LON"] = request.longitude

        return InjectionTransportCommandInvocation(
            executable: "/usr/bin/xcrun",
            arguments: [
                "xcodebuild",
                "test",
                "-scheme", XcodeLocationHarnessPackage.packageName,
                "-destination", "id=\(deviceIdentifier)",
                "-only-testing:\(XcodeLocationHarnessPackage.testSelector)"
            ],
            environment: environment,
            workingDirectory: harnessDirectory,
            commandSummary: "xcodebuild test -scheme \(XcodeLocationHarnessPackage.packageName) -destination id=\(deviceIdentifier) -only-testing:\(XcodeLocationHarnessPackage.testSelector) [set \(request.latitude), \(request.longitude)]"
        )
    }

    private func makeClearLocationInvocation(
        snapshot: DeviceSnapshot
    ) -> InjectionTransportCommandInvocation? {
        guard let harnessDirectory = resolveHarnessDirectory(),
              let deviceIdentifier = normalizedDeviceIdentifier(from: snapshot) else {
            return nil
        }

        var environment = ProcessInfo.processInfo.environment
        environment["GTM_ACTION"] = "clear"
        environment.removeValue(forKey: "GTM_LAT")
        environment.removeValue(forKey: "GTM_LON")

        return InjectionTransportCommandInvocation(
            executable: "/usr/bin/xcrun",
            arguments: [
                "xcodebuild",
                "test",
                "-scheme", XcodeLocationHarnessPackage.packageName,
                "-destination", "id=\(deviceIdentifier)",
                "-only-testing:\(XcodeLocationHarnessPackage.testSelector)"
            ],
            environment: environment,
            workingDirectory: harnessDirectory,
            commandSummary: "xcodebuild test -scheme \(XcodeLocationHarnessPackage.packageName) -destination id=\(deviceIdentifier) -only-testing:\(XcodeLocationHarnessPackage.testSelector) [clear]"
        )
    }

    private func runInvocation(
        _ invocation: InjectionTransportCommandInvocation,
        successEvents: [DeviceAgentDiagnosticEvent]
    ) -> DeviceAgentResponse {
        switch runner.run(
            invocation.executable,
            args: invocation.arguments,
            environment: invocation.environment,
            workingDirectory: invocation.workingDirectory
        ) {
        case .failure(let error):
            return .failure(
                DeviceAgentFailure(
                    code: .transportExecutionFailed,
                    message: "Xcode test harness could not launch \(invocation.executable): \(shellCommandErrorMessage(error))."
                )
            )
        case .success(let result):
            guard result.exitCode == 0 else {
                return .failure(classifyFailure(result: result, invocation: invocation))
            }
            return .success(
                .teleportResult(
                    DeviceAgentTeleportResult(
                        response: TeleportResponse(
                            stdout: result.stdout,
                            stderr: result.stderr,
                            exitCode: result.exitCode
                        ),
                        events: successEvents
                    )
                )
            )
        }
    }

    fileprivate func classifyFailure(
        result: ShellCommandResult,
        invocation: InjectionTransportCommandInvocation
    ) -> DeviceAgentFailure {
        let details = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let normalized = details.lowercased()

        let code: DeviceAgentErrorCode
        let prefix: String
        if normalized.contains("invalid coordinates")
            || normalized.contains("gtm_lat")
            || normalized.contains("gtm_lon")
            || normalized.contains("missing gtm_action") {
            code = .invalidRequest
            prefix = "Xcode test harness rejected the requested location payload."
        } else if normalized.contains("unable to find a destination matching")
            || normalized.contains("failed to prepare device")
            || normalized.contains("developer mode")
            || normalized.contains("device is busy")
            || normalized.contains("device not available")
            || normalized.contains("no devices are available") {
            code = .agentUnavailable
            prefix = "Xcode test harness could not open the requested device session."
        } else if normalized.contains("requires a development team")
            || normalized.contains("no profiles for")
            || normalized.contains("code signing")
            || normalized.contains("failed to build module")
            || normalized.contains("package.swift") {
            code = .transportExecutionFailed
            prefix = "Xcode test harness could not build or sign the local harness package."
        } else {
            code = .transportExecutionFailed
            prefix = "Xcode test harness failed unexpectedly."
        }

        let detailSuffix = details.isEmpty ? "" : " Detail: \(details)"
        return DeviceAgentFailure(
            code: code,
            message: "\(prefix) Exit code \(result.exitCode). Command: \(invocation.commandSummary).\(detailSuffix)"
        )
    }

    private func normalizedDeviceIdentifier(from snapshot: DeviceSnapshot) -> String? {
        guard let identifier = snapshot.deviceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !identifier.isEmpty else {
            return nil
        }
        return identifier
    }

    private func successEvents(
        for snapshot: DeviceSnapshot,
        harnessDirectory: String?,
        commandSummary: String,
        operationSummary: String
    ) -> [DeviceAgentDiagnosticEvent] {
        var events: [DeviceAgentDiagnosticEvent] = [
            DeviceAgentDiagnosticEvent(
                level: .info,
                message: "Xcode test harness executed \(commandSummary)"
            ),
            DeviceAgentDiagnosticEvent(
                level: .info,
                message: "Direct device identifier input remained the only device-side routing input for \(operationSummary)."
            )
        ]

        if let deviceIdentifier = normalizedDeviceIdentifier(from: snapshot) {
            events.append(
                DeviceAgentDiagnosticEvent(
                    level: .info,
                    message: "Resolved device identifier \(deviceIdentifier) was reused without any parallel tunnel rediscovery."
                )
            )
        }

        if let harnessDirectory {
            let originSummary = XcodeLocationHarnessPackage.isMaterializedPackageDirectory(harnessDirectory)
                ? "Materialized harness package"
                : "Source-tree fallback harness package"
            events.append(
                DeviceAgentDiagnosticEvent(
                    level: .info,
                    message: "\(originSummary) at \(harnessDirectory) backed the Xcode transport."
                )
            )
        }

        return events
    }

    private func shellCommandErrorMessage(_ error: ShellCommandError) -> String {
        switch error {
        case .launchFailed(let message):
            return message
        }
    }
}

private struct EndpointBackedInjectionTransportCommandAdapter: InjectionTransportServing {
    let transportID = "injection.transport.endpoint-backed.command"
    private let runner: ShellCommandRunner
    private let resolveCLIPath: () -> String?

    init(
        runner: ShellCommandRunner = ShellCommandRunner(),
        resolveCLIPath: @escaping () -> String? = { V3LegacyCLIPathResolver().resolvedCLIPath() }
    ) {
        self.runner = runner
        self.resolveCLIPath = resolveCLIPath
    }

    func probeTransport(
        snapshot: DeviceSnapshot,
        tunnelEndpointResult: DeviceAgentTunnelEndpointResult?
    ) -> DeviceAgentInjectionTransportProbeResult {
        guard let tunnelEndpointResult,
              tunnelEndpointResult.state == .verified else {
            return DeviceAgentInjectionTransportProbeResult(
                transportID: transportID,
                transportState: .unavailable,
                contract: DeviceAgentInjectionTransportContract(
                    contractID: "injection.transport.endpoint-backed",
                    phase: .probeOnly,
                    summary: "Injection transport is reserved to consume a verified product-owned tunnel endpoint, but that endpoint is not verified yet.",
                    expectedInput: "Verified tunnel endpoint artifact"
                ),
                sourceTunnelEndpointArtifactID: tunnelEndpointResult?.artifact.artifactID,
                summary: "Injection transport cannot bootstrap yet because no verified product-owned tunnel endpoint artifact is available.",
                nextAction: "Verify the product-owned tunnel endpoint first, then bind injection transport to that artifact instead of rediscovering tunnel state.",
                confidence: "low"
            )
        }

        guard let cliPath = resolveCLIPath(), !cliPath.isEmpty else {
            let endpoint = "\(tunnelEndpointResult.artifact.host):\(tunnelEndpointResult.artifact.port)"
            return DeviceAgentInjectionTransportProbeResult(
                transportID: transportID,
                transportState: .unavailable,
                contract: DeviceAgentInjectionTransportContract(
                    contractID: "injection.transport.endpoint-backed",
                    phase: .probeOnly,
                    summary: "Injection transport has a verified tunnel endpoint input, but no command adapter is available yet.",
                    expectedInput: "Teleport request + verified tunnel endpoint artifact + command adapter"
                ),
                sourceTunnelEndpointArtifactID: tunnelEndpointResult.artifact.artifactID,
                summary: "Verified tunnel endpoint \(endpoint) is available, but the endpoint-backed command adapter cannot start because the temporary CLI bridge was not found.",
                nextAction: "Resolve the temporary CLI bridge or replace this endpoint-backed adapter with a native injection transport.",
                confidence: "medium"
            )
        }

        let endpoint = "\(tunnelEndpointResult.artifact.host):\(tunnelEndpointResult.artifact.port)"
        return DeviceAgentInjectionTransportProbeResult(
            transportID: transportID,
            transportState: .endpointBackedCommand,
            contract: DeviceAgentInjectionTransportContract(
                contractID: "injection.transport.endpoint-backed",
                phase: .endpointBackedCommand,
                summary: "Injection transport now has the correct typed input boundary and a temporary command adapter for endpoint-backed execution.",
                expectedInput: "Teleport request + verified tunnel endpoint artifact"
            ),
            sourceTunnelEndpointArtifactID: tunnelEndpointResult.artifact.artifactID,
            summary: "Endpoint-backed injection command adapter is ready to consume verified tunnel endpoint \(endpoint) without rediscovering tunnel state in a parallel path.",
            nextAction: "Run location injection through the endpoint-backed command adapter while planning a native replacement for the temporary CLI bridge at \(cliPath).",
            confidence: "medium"
        )
    }

    func setLocation(
        _ request: TeleportRequest,
        snapshot: DeviceSnapshot,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> DeviceAgentResponse {
        guard snapshot.isConnected else {
            return .failure(
                DeviceAgentFailure(
                    code: .invalidRequest,
                    message: "No connected iPhone session is available for device-agent injection."
                )
            )
        }
        guard Double(request.latitude) != nil, Double(request.longitude) != nil else {
            return .failure(
                DeviceAgentFailure(
                    code: .invalidRequest,
                    message: "Invalid coordinates supplied to the device-agent injection transport."
                )
            )
        }

        let probeResult = probeTransport(
            snapshot: snapshot,
            tunnelEndpointResult: tunnelAssessment?.tunnelEndpointResult
        )
        switch probeResult.transportState {
        case .unavailable:
            return .failure(
                DeviceAgentFailure(
                    code: .transportUnimplemented,
                    message: "\(probeResult.summary) \(probeResult.nextAction)"
                )
            )
        case .endpointBackedStub:
            return .failure(
                DeviceAgentFailure(
                    code: .transportUnimplemented,
                    message: "Injection transport is still stuck on the older endpoint-backed stub path. \(probeResult.nextAction)"
                )
            )
        case .xcodeTestHarness:
            return .failure(
                DeviceAgentFailure(
                    code: .transportUnimplemented,
                    message: "Xcode test harness transport was selected by the stack, so the endpoint-backed command adapter should not execute. \(probeResult.nextAction)"
                )
            )
        case .endpointBackedCommand:
            guard let invocation = makeSetLocationInvocation(
                request: request,
                tunnelEndpointResult: tunnelAssessment?.tunnelEndpointResult
            ) else {
                return .failure(
                    DeviceAgentFailure(
                        code: .transportUnimplemented,
                        message: "Endpoint-backed injection command adapter could not build a command invocation from the current verified tunnel endpoint."
                    )
                )
            }

        switch runner.run(
            invocation.executable,
            args: invocation.arguments,
            environment: invocation.environment,
            workingDirectory: invocation.workingDirectory
        ) {
            case .failure(let error):
                return .failure(
                    DeviceAgentFailure(
                        code: .transportExecutionFailed,
                        message: "Endpoint-backed injection command could not launch \(invocation.executable): \(shellCommandErrorMessage(error))."
                    )
                )
            case .success(let result):
                guard result.exitCode == 0 else {
                    return .failure(
                        classifyCommandFailure(
                            result: result,
                            invocation: invocation
                        )
                    )
                }

                return .success(
                    .teleportResult(
                        DeviceAgentTeleportResult(
                            response: TeleportResponse(
                                stdout: result.stdout,
                                stderr: result.stderr,
                                exitCode: result.exitCode
                            ),
                            events: [
                                DeviceAgentDiagnosticEvent(
                                    level: .info,
                                    message: "Injection transport executed \(invocation.commandSummary)"
                                ),
                                DeviceAgentDiagnosticEvent(
                                    level: .info,
                                    message: "Verified tunnel endpoint artifact \(probeResult.sourceTunnelEndpointArtifactID ?? "unknown") remained the only tunnel-side input."
                                )
                            ]
                        )
                    )
                )
            }
        }
    }

    func clearLocation(
        snapshot: DeviceSnapshot,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> DeviceAgentResponse {
        guard snapshot.isConnected else {
            return .failure(
                DeviceAgentFailure(
                    code: .invalidRequest,
                    message: "No connected iPhone session is available for device-agent location clear."
                )
            )
        }

        let probeResult = probeTransport(
            snapshot: snapshot,
            tunnelEndpointResult: tunnelAssessment?.tunnelEndpointResult
        )
        switch probeResult.transportState {
        case .unavailable:
            return .failure(
                DeviceAgentFailure(
                    code: .transportUnimplemented,
                    message: "\(probeResult.summary) \(probeResult.nextAction)"
                )
            )
        case .endpointBackedStub:
            return .failure(
                DeviceAgentFailure(
                    code: .transportUnimplemented,
                    message: "Injection transport is still stuck on the older endpoint-backed stub path. \(probeResult.nextAction)"
                )
            )
        case .xcodeTestHarness:
            return .failure(
                DeviceAgentFailure(
                    code: .transportUnimplemented,
                    message: "Xcode test harness transport was selected by the stack, so the endpoint-backed command adapter should not execute. \(probeResult.nextAction)"
                )
            )
        case .endpointBackedCommand:
            guard let invocation = makeClearLocationInvocation(
                tunnelEndpointResult: tunnelAssessment?.tunnelEndpointResult
            ) else {
                return .failure(
                    DeviceAgentFailure(
                        code: .transportUnimplemented,
                        message: "Endpoint-backed injection command adapter could not build a clear-location invocation from the current verified tunnel endpoint."
                    )
                )
            }

        switch runner.run(
            invocation.executable,
            args: invocation.arguments,
            environment: invocation.environment,
            workingDirectory: invocation.workingDirectory
        ) {
            case .failure(let error):
                return .failure(
                    DeviceAgentFailure(
                        code: .transportExecutionFailed,
                        message: "Endpoint-backed clear-location command could not launch \(invocation.executable): \(shellCommandErrorMessage(error))."
                    )
                )
            case .success(let result):
                guard result.exitCode == 0 else {
                    return .failure(
                        classifyCommandFailure(
                            result: result,
                            invocation: invocation
                        )
                    )
                }

                return .success(
                    .teleportResult(
                        DeviceAgentTeleportResult(
                            response: TeleportResponse(
                                stdout: result.stdout,
                                stderr: result.stderr,
                                exitCode: result.exitCode
                            ),
                            events: [
                                DeviceAgentDiagnosticEvent(
                                    level: .info,
                                    message: "Injection transport executed \(invocation.commandSummary)"
                                ),
                                DeviceAgentDiagnosticEvent(
                                    level: .info,
                                    message: "Verified tunnel endpoint artifact \(probeResult.sourceTunnelEndpointArtifactID ?? "unknown") remained the only tunnel-side input while clearing location simulation."
                                )
                            ]
                        )
                    )
                )
            }
        }
    }

    fileprivate func makeSetLocationInvocation(
        request: TeleportRequest,
        tunnelEndpointResult: DeviceAgentTunnelEndpointResult?
    ) -> InjectionTransportCommandInvocation? {
        guard let tunnelEndpointResult,
              tunnelEndpointResult.state == .verified,
              let cliPath = resolveCLIPath(),
              !cliPath.isEmpty else {
            return nil
        }

        let endpoint = tunnelEndpointResult.artifact
        let arguments = [
            "developer",
            "dvt",
            "simulate-location",
            "set",
            "--rsd",
            endpoint.host,
            String(endpoint.port),
            "--",
            request.latitude,
            request.longitude
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["PYTHONUNBUFFERED"] = "1"

        return InjectionTransportCommandInvocation(
            executable: cliPath,
            arguments: arguments,
            environment: environment,
            workingDirectory: nil,
            commandSummary: "pymobiledevice3 developer dvt simulate-location set --rsd \(endpoint.host) \(endpoint.port) -- \(request.latitude) \(request.longitude)"
        )
    }

    fileprivate func makeClearLocationInvocation(
        tunnelEndpointResult: DeviceAgentTunnelEndpointResult?
    ) -> InjectionTransportCommandInvocation? {
        guard let tunnelEndpointResult,
              tunnelEndpointResult.state == .verified,
              let cliPath = resolveCLIPath(),
              !cliPath.isEmpty else {
            return nil
        }

        let endpoint = tunnelEndpointResult.artifact
        let arguments = [
            "developer",
            "dvt",
            "simulate-location",
            "clear",
            "--rsd",
            endpoint.host,
            String(endpoint.port)
        ]

        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "en_US.UTF-8"
        environment["PYTHONIOENCODING"] = "utf-8"
        environment["PYTHONUNBUFFERED"] = "1"

        return InjectionTransportCommandInvocation(
            executable: cliPath,
            arguments: arguments,
            environment: environment,
            workingDirectory: nil,
            commandSummary: "pymobiledevice3 developer dvt simulate-location clear --rsd \(endpoint.host) \(endpoint.port)"
        )
    }

    private func shellCommandErrorMessage(_ error: ShellCommandError) -> String {
        switch error {
        case .launchFailed(let message):
            return message
        }
    }

    fileprivate func classifyCommandFailure(
        result: ShellCommandResult,
        invocation: InjectionTransportCommandInvocation
    ) -> DeviceAgentFailure {
        let details = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let normalized = details.lowercased()

        let kind: InjectionTransportCommandFailureKind
        let prefix: String

        if normalized.contains("invalid coordinates")
            || normalized.contains("latitude")
            || normalized.contains("longitude")
            || normalized.contains("no such value") {
            kind = .invalidRequest
            prefix = "Endpoint-backed injection command rejected the teleport request."
        } else if normalized.contains("make sure you passed the --rsd option")
            || normalized.contains("unable to connect to tunneld")
            || normalized.contains("trying again over tunneld since rsd is required")
            || normalized.contains("got an invalidserviceerror")
            || normalized.contains("failed to start service")
            || normalized.contains("device not found")
            || normalized.contains("device is password protected")
            || normalized.contains("developer mode is disabled") {
            kind = .sessionUnavailable
            prefix = "Endpoint-backed injection command could not open the required developer-session service over the verified tunnel endpoint."
        } else if normalized.contains("no such option: --rsd")
            || normalized.contains("no such command 'dvt'")
            || normalized.contains("no such command 'simulate-location'")
            || normalized.contains("unknown option") {
            kind = .transportUnavailable
            prefix = "Endpoint-backed injection command adapter is incompatible with the installed CLI bridge surface."
        } else {
            kind = .executionFailed
            prefix = "Endpoint-backed injection command failed unexpectedly."
        }

        let detailSuffix = details.isEmpty ? "" : " Detail: \(details)"
        switch kind {
        case .invalidRequest:
            return DeviceAgentFailure(
                code: .invalidRequest,
                message: "\(prefix)\(detailSuffix)"
            )
        case .sessionUnavailable:
            return DeviceAgentFailure(
                code: .agentUnavailable,
                message: "\(prefix) Command: \(invocation.commandSummary).\(detailSuffix)"
            )
        case .transportUnavailable:
            return DeviceAgentFailure(
                code: .transportUnimplemented,
                message: "\(prefix) Command: \(invocation.commandSummary).\(detailSuffix)"
            )
        case .executionFailed:
            return DeviceAgentFailure(
                code: .transportExecutionFailed,
                message: "\(prefix) Exit code \(result.exitCode). Command: \(invocation.commandSummary).\(detailSuffix)"
            )
        }
    }
}

private struct NullInjectionTransportService: InjectionTransportServing {
    let transportID = "injection.transport.none"

    func probeTransport(
        snapshot: DeviceSnapshot,
        tunnelEndpointResult: DeviceAgentTunnelEndpointResult?
    ) -> DeviceAgentInjectionTransportProbeResult {
        DeviceAgentInjectionTransportProbeResult(
            transportID: transportID,
            transportState: .unavailable,
            contract: DeviceAgentInjectionTransportContract(
                contractID: "injection.transport.none",
                phase: .probeOnly,
                summary: "No injection transport service has been registered.",
                expectedInput: "Registered injection transport"
            ),
            sourceTunnelEndpointArtifactID: tunnelEndpointResult?.artifact.artifactID,
            summary: "No injection transport service is active.",
            nextAction: "Register at least one injection transport service before expecting device-agent location injection.",
            confidence: "low"
        )
    }

    func setLocation(
        _ request: TeleportRequest,
        snapshot: DeviceSnapshot,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> DeviceAgentResponse {
        .failure(
            DeviceAgentFailure(
                code: .transportUnimplemented,
                message: "No injection transport service is active."
            )
        )
    }

    func clearLocation(
        snapshot: DeviceSnapshot,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> DeviceAgentResponse {
        .failure(
            DeviceAgentFailure(
                code: .transportUnimplemented,
                message: "No injection transport service is active."
            )
        )
    }
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

    private enum ExpectedRSDEndpointSourceKind: Int {
        case disconnectedTunnel
        case genericRSDArgument
        case addressPortPair
        case createdTunnel
    }

    private struct ExpectedRSDEndpointCandidate {
        let endpoint: TunnelEndpointProbe
        let lineIndex: Int
        let sourceKind: ExpectedRSDEndpointSourceKind
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
                endpointResult: nil,
                events: events(for: snapshot)
            )
        case .starting:
            let tunnelSession = DeviceAgentTunnelSession(
                sessionID: "tunnel.session.product-owned.starting",
                state: .productOwnedStarting,
                ownershipSummary: "Product-owned tunnel session starting",
                sourceMetadataSessionID: metadataSession?.sessionID,
                summary: "The backend has started creating a product-owned tunnel session.",
                nextAction: "Wait for the product-owned tunnel controller to report active or failed state."
            )
            let healthResult = currentStoredHealthResult(for: snapshot)
            return DeviceAgentTunnelControllerSnapshot(
                tunnelState: .starting,
                lifecycleResult: DeviceAgentTunnelLifecycleResult(
                    state: .productOwnedStarting,
                    summary: "A product-owned tunnel session is starting, but backend-managed health checks have not verified readiness yet.",
                    nextAction: "Keep the product-owned tunnel startup under backend control until the session becomes active or fails.",
                    confidence: "medium"
                ),
                tunnelSession: tunnelSession,
                healthResult: healthResult,
                endpointResult: currentStoredEndpointResult(for: snapshot, tunnelSession: tunnelSession, healthResult: healthResult),
                events: events(for: snapshot)
            )
        case .active:
            let tunnelSession = DeviceAgentTunnelSession(
                sessionID: "tunnel.session.product-owned.active",
                state: .productOwnedActive,
                ownershipSummary: "Product-owned tunnel session",
                sourceMetadataSessionID: metadataSession?.sessionID,
                summary: "A product-owned tunnel session is active and has verified readiness, so it can be treated as backend state instead of a process-name observation.",
                nextAction: "Keep the tunnel session healthy and separate from injection transport readiness."
            )
            let healthResult = currentStoredHealthResult(for: snapshot)
            return DeviceAgentTunnelControllerSnapshot(
                tunnelState: .active,
                lifecycleResult: DeviceAgentTunnelLifecycleResult(
                    state: .productOwnedActive,
                    summary: "A product-owned tunnel session is active and has passed backend-managed readiness checks.",
                    nextAction: "Keep the product-owned tunnel healthy while injection transport remains separate.",
                    confidence: "high"
                ),
                tunnelSession: tunnelSession,
                healthResult: healthResult,
                endpointResult: currentStoredEndpointResult(for: snapshot, tunnelSession: tunnelSession, healthResult: healthResult),
                events: events(for: snapshot)
            )
        case .failed(let message):
            let tunnelSession = DeviceAgentTunnelSession(
                sessionID: "tunnel.session.product-owned.failed",
                state: .productOwnedFailed,
                ownershipSummary: "Product-owned tunnel session failed",
                sourceMetadataSessionID: metadataSession?.sessionID,
                summary: message,
                nextAction: "Retry tunnel startup through the product-owned controller instead of falling back to an external process."
            )
            let healthResult = currentStoredHealthResult(for: snapshot)
            return DeviceAgentTunnelControllerSnapshot(
                tunnelState: .failed,
                lifecycleResult: DeviceAgentTunnelLifecycleResult(
                    state: .productOwnedFailed,
                    summary: "A product-owned tunnel attempt failed before reaching an active session boundary.",
                    nextAction: "Surface the failure as backend-owned tunnel state and offer a retry path from the controller.",
                    confidence: "medium"
                ),
                tunnelSession: tunnelSession,
                healthResult: healthResult,
                endpointResult: currentStoredEndpointResult(for: snapshot, tunnelSession: tunnelSession, healthResult: healthResult),
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

    private static func currentStoredEndpointResult(
        for snapshot: DeviceSnapshot,
        tunnelSession: DeviceAgentTunnelSession?,
        healthResult: DeviceAgentTunnelHealthResult?
    ) -> DeviceAgentTunnelEndpointResult? {
        guard let attempt = loadAttempt(forKey: attemptKey(for: snapshot)) else {
            return nil
        }
        return makeTunnelEndpointResult(
            from: attempt,
            tunnelSession: tunnelSession,
            healthResult: healthResult
        )
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

    private static func makeTunnelEndpointResult(
        from attempt: StoredAttempt,
        tunnelSession: DeviceAgentTunnelSession?,
        healthResult: DeviceAgentTunnelHealthResult?
    ) -> DeviceAgentTunnelEndpointResult? {
        let logText = attempt.logPath.flatMap(readLogExcerpt(at:))
        guard let endpoint = expectedRSDEndpoint(in: logText) else {
            return nil
        }

        let summaryEndpoint = "\(endpoint.host):\(endpoint.port)"
        let artifact = DeviceAgentTunnelEndpointArtifact(
            artifactID: "tunnel.endpoint.\(endpoint.host.replacingOccurrences(of: ":", with: "_")).\(endpoint.port)",
            host: endpoint.host,
            port: endpoint.port,
            sourceTunnelSessionID: tunnelSession?.sessionID,
            sourceHealthState: healthResult?.state,
            sourceProtocolHint: healthResult?.protocolHint,
            summary: "Product-owned tunnel endpoint candidate \(summaryEndpoint) is available as structured backend state."
        )

        let verification = probeExpectedRSDEndpoint(in: logText, timeout: 0.35)
        switch verification {
        case .verified:
            return DeviceAgentTunnelEndpointResult(
                state: .verified,
                artifact: artifact,
                summary: "Expected RSD endpoint \(summaryEndpoint) is protocol-verified and can become the future product-owned injection input boundary.",
                nextAction: "Use verified tunnel endpoint \(summaryEndpoint) as the future injection transport input instead of rediscovering tunnel state in a parallel path.",
                confidence: "high"
            )
        case .advertisedButUnverified:
            return DeviceAgentTunnelEndpointResult(
                state: .advertised,
                artifact: artifact,
                summary: "Expected RSD endpoint \(summaryEndpoint) has been advertised by the product-owned tunnel startup logs, but protocol verification is still pending.",
                nextAction: "Keep the product-owned tunnel under backend control until expected endpoint \(summaryEndpoint) is verified before wiring injection transport to it.",
                confidence: "medium"
            )
        case .notAdvertised:
            return nil
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
            return .failure(.message("Product-owned tunnel startup could not begin because the temporary CLI bridge was not found."))
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
        return expectedRSDEndpointCandidates(in: logText)
            .sorted {
                if $0.lineIndex == $1.lineIndex {
                    return $0.sourceKind.rawValue < $1.sourceKind.rawValue
                }
                return $0.lineIndex < $1.lineIndex
            }
            .last?
            .endpoint
    }

    private static func expectedRSDEndpointCandidates(in logText: String) -> [ExpectedRSDEndpointCandidate] {
        let hostToken = #"(\[?[A-Za-z0-9:\.%-]+\]?)"#
        let rsdArgumentPattern = #"(?i)(?:--rsd|rsd)\s+"# + hostToken + #"\s+(\d{1,5})"#
        let bracketedEndpointPattern = #"(?i)rsd[^\n]*"# + hostToken + #":(\d{1,5})"#
        let addressPattern = #"(?i)\brsd\s+(?:address|host)\s*[:=]\s*"# + hostToken
        let portPattern = #"(?i)\brsd\s+port\s*[:=]\s*(\d{1,5})"#

        let lines = logText.components(separatedBy: .newlines)
        var candidates: [ExpectedRSDEndpointCandidate] = []
        var latestAddress: (host: String, lineIndex: Int, rawLine: String)?
        var latestPort: (port: String, lineIndex: Int, rawLine: String)?

        for (lineIndex, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let lowercase = line.lowercased()

            if let match = firstRegexMatch(in: line, pattern: rsdArgumentPattern, groups: 2),
               let endpoint = makeExpectedRSDEndpoint(
                host: match[0],
                port: match[1],
                rawListener: "advertised RSD endpoint from \(line)"
               ) {
                let sourceKind: ExpectedRSDEndpointSourceKind
                if lowercase.contains("created tunnel") {
                    sourceKind = .createdTunnel
                } else if lowercase.contains("disconnected from tunnel") {
                    sourceKind = .disconnectedTunnel
                } else {
                    sourceKind = .genericRSDArgument
                }
                candidates.append(
                    ExpectedRSDEndpointCandidate(
                        endpoint: endpoint,
                        lineIndex: lineIndex,
                        sourceKind: sourceKind
                    )
                )
            }

            if !lowercase.contains("--rsd"),
               let match = firstRegexMatch(in: line, pattern: bracketedEndpointPattern, groups: 2),
               let endpoint = makeExpectedRSDEndpoint(
                host: match[0],
                port: match[1],
                rawListener: "advertised RSD endpoint \(match[0]):\(match[1]) from \(line)"
               ) {
                candidates.append(
                    ExpectedRSDEndpointCandidate(
                        endpoint: endpoint,
                        lineIndex: lineIndex,
                        sourceKind: .genericRSDArgument
                    )
                )
            }

            if let address = firstRegexMatch(in: line, pattern: addressPattern, groups: 1)?.first {
                latestAddress = (address, lineIndex, line)
            }

            if let port = firstRegexMatch(in: line, pattern: portPattern, groups: 1)?.first {
                latestPort = (port, lineIndex, line)
            }

            if let address = latestAddress,
               let port = latestPort,
               abs(address.lineIndex - port.lineIndex) <= 3,
               let endpoint = makeExpectedRSDEndpoint(
                host: address.host,
                port: port.port,
                rawListener: "advertised RSD address from \(address.rawLine) / \(port.rawLine)"
               ) {
                candidates.append(
                    ExpectedRSDEndpointCandidate(
                        endpoint: endpoint,
                        lineIndex: max(address.lineIndex, port.lineIndex),
                        sourceKind: .addressPortPair
                    )
                )
                latestAddress = nil
                latestPort = nil
            }
        }

        return candidates.filter { $0.sourceKind != .disconnectedTunnel } + candidates.filter {
            $0.sourceKind == .disconnectedTunnel
        }
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
        let trimmed = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]()\"' \t\r\n,;"))
            .replacingOccurrences(of: "%25", with: "%")
        if trimmed == "*" {
            return "127.0.0.1"
        }
        return trimmed
    }

    static func runExpectedRSDEndpointSelfCheckReport() -> String {
        struct Case {
            let name: String
            let logText: String
            let expectedHost: String
            let expectedPort: UInt16
        }

        let cases: [Case] = [
            Case(
                name: "created-tunnel-ipv6",
                logText: "uvicorn.error[6253] INFO Started server process [6253]\n[tunnel] Created tunnel --rsd fd7b:e5b:6f53::1 64337\n",
                expectedHost: "fd7b:e5b:6f53::1",
                expectedPort: 64337
            ),
            Case(
                name: "latest-created-tunnel-wins",
                logText: "[task] Created tunnel --rsd fd7b:e5b:6f53::1 64337\n[task] Disconnected from tunnel --rsd fd7b:e5b:6f53::1 64337\n[task] Created tunnel --rsd fd7b:e5b:6f53::2 64338\n",
                expectedHost: "fd7b:e5b:6f53::2",
                expectedPort: 64338
            ),
            Case(
                name: "rsd-address-port-pair",
                logText: "Identifier: 00008110-001978382E53801E\nRSD Address: [fd7b:e5b:6f53::1]\nRSD Port: 64337\nUse the follow connection option:\n--rsd [fd7b:e5b:6f53::1] 64337\n",
                expectedHost: "fd7b:e5b:6f53::1",
                expectedPort: 64337
            ),
            Case(
                name: "percent-encoded-scope-id",
                logText: "[task] Created tunnel --rsd fe80::1234%25utun5 60123\n",
                expectedHost: "fe80::1234%utun5",
                expectedPort: 60123
            )
        ]

        var lines: [String] = []
        var failureCount = 0

        for testCase in cases {
            let actual = expectedRSDEndpoint(in: testCase.logText)
            let passed = actual?.host == testCase.expectedHost && actual?.port == testCase.expectedPort
            if passed {
                lines.append("PASS \(testCase.name): \(testCase.expectedHost):\(testCase.expectedPort)")
            } else {
                failureCount += 1
                let actualSummary = actual.map { "\($0.host):\($0.port)" } ?? "nil"
                lines.append(
                    "FAIL \(testCase.name): expected \(testCase.expectedHost):\(testCase.expectedPort), got \(actualSummary)"
                )
            }
        }

        if failureCount == 0 {
            lines.append("Tunnel log parser self-check passed (\(cases.count) cases).")
        } else {
            lines.append("Tunnel log parser self-check failed (\(failureCount)/\(cases.count) cases).")
        }

        return lines.joined(separator: "\n") + "\n"
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
            .suffix(40)
            .joined(separator: "\n")
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
                endpointResult: nil,
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
            endpointResult: nil,
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
                message: "No legacy tunnel process observed during device-agent probe"
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
                tunnelEndpointResult: nil,
                injectionTransportProbeResult: nil,
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
            tunnelEndpointResult: nil,
            injectionTransportProbeResult: nil,
            nextAction: orderedNextAction,
            blockerCodes: blockerCodes,
            blockers: blockers,
            confidence: probe.source == .systemProfiler ? "medium" : "low"
        )
    }

    static func makeTunnelAssessment(
        for snapshot: DeviceSnapshot,
        tunnelController: TunnelStateControlling,
        injectionTransportService: InjectionTransportServing
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
        let tunnelEndpointResult = controllerSnapshot.endpointResult
        let injectionTransportProbeResult = injectionTransportService.probeTransport(
            snapshot: snapshot,
            tunnelEndpointResult: tunnelEndpointResult
        )

        if injectionTransportProbeResult.transportState == .xcodeTestHarness {
            let tunnelRequirementResult = DeviceAgentTunnelRequirementResult(
                state: .notRequired,
                sourceMetadataSessionID: metadataSession?.sessionID,
                summary: "The primary Xcode-backed injection path for this session does not require the compatibility tunnel transport.",
                nextAction: "Keep the resolved device identifier stable and run location injection through the Xcode test harness.",
                confidence: "medium"
            )
            let tunnelLifecycleResult = DeviceAgentTunnelLifecycleResult(
                state: .noProductOwnedTunnel,
                summary: "No product-owned tunnel lifecycle is required while the Xcode-backed injection harness is the active primary transport.",
                nextAction: "Refresh device metadata and harness readiness instead of starting the compatibility tunnel path.",
                confidence: "medium"
            )
            return DeviceAgentSessionAssessment(
                readinessGate: .ready,
                readinessSummary: "Direct Xcode-backed location injection is ready, so the primary transport no longer depends on Python or compatibility tunnel ownership for this session.",
                refreshIntent: DeviceAgentRefreshIntent(
                    scope: .deviceOnly,
                    probeFocus: .deviceInfo
                ),
                recommendedProbeFocus: .deviceInfo,
                deviceInfoReadiness: nil,
                deviceInfoTransportState: nil,
                deviceInfoTransportContract: nil,
                deviceInfoTransportProbeResult: nil,
                typedMetadataResult: nil,
                typedMetadataSession: nil,
                tunnelRequirementResult: tunnelRequirementResult,
                tunnelLifecycleResult: tunnelLifecycleResult,
                tunnelSession: nil,
                tunnelHealthResult: nil,
                tunnelEndpointResult: nil,
                injectionTransportProbeResult: injectionTransportProbeResult,
                nextAction: injectionTransportProbeResult.nextAction,
                blockerCodes: [],
                blockers: [],
                confidence: injectionTransportProbeResult.confidence
            )
        }

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
                tunnelEndpointResult: tunnelEndpointResult,
                injectionTransportProbeResult: injectionTransportProbeResult,
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
                tunnelEndpointResult: tunnelEndpointResult,
                injectionTransportProbeResult: injectionTransportProbeResult,
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
                        "Tunnel readiness is not yet verified by the device-agent backend"
                    ]
                    : [
                        "Tunnel observation is legacy-derived",
                        "Tunnel readiness is not yet verified by the device-agent backend"
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
                tunnelEndpointResult: tunnelEndpointResult,
                injectionTransportProbeResult: injectionTransportProbeResult,
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
            tunnelEndpointResult: tunnelEndpointResult,
            injectionTransportProbeResult: injectionTransportProbeResult,
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
                    deviceIdentifier: probe.deviceIdentifier,
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
