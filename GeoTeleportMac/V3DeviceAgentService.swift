import Darwin
import Foundation

protocol DeviceAgentServicing {
    func handle(_ request: DeviceAgentRequest) -> DeviceAgentResponse
}

struct StubDeviceAgentService: DeviceAgentServicing {
    private let deviceInfoTransportService: DeviceInfoTransportServing
    private let injectionTransportService: InjectionTransportServing

    init(
        deviceInfoTransportService: DeviceInfoTransportServing = DeviceInfoTransportServiceStack(),
        injectionTransportService: InjectionTransportServing = InjectionTransportServiceStack()
    ) {
        self.deviceInfoTransportService = deviceInfoTransportService
        self.injectionTransportService = injectionTransportService
    }

    func handle(_ request: DeviceAgentRequest) -> DeviceAgentResponse {
        switch request {
        case .probeAvailability:
            let toolchainProbe = ToolchainProbe.run()
            let blockerCodes = toolchainProbe.availabilityBlockers
            let nextAction = NoPythonBackendStub.bootstrapNextAction(for: blockerCodes)
            let summary: String
            let events = [
                DeviceAgentDiagnosticEvent(
                    level: .info,
                    message: "Structured device-agent boundary initialized"
                )
            ] + toolchainProbe.events

            if blockerCodes.isEmpty {
                summary = "Child-process agent reachable; current developer build still depends on external tooling until the bundled device core replaces it."
            } else {
                summary = "Child-process agent reachable, but this developer build is blocked on missing external tooling and is not consumer-ready."
            }
            return .success(
                .availability(
                    DeviceAgentAvailability(
                        isReachable: true,
                        summary: summary,
                        readinessGate: blockerCodes.isEmpty ? .injectionTransport : .backendBootstrap,
                        refreshIntent: DeviceAgentRefreshIntent(
                            scope: .deviceOnly,
                            probeFocus: .attachment
                        ),
                        recommendedProbeFocus: .attachment,
                        nextAction: nextAction,
                        blockerCodes: blockerCodes,
                        confidence: blockerCodes.isEmpty ? "medium" : "high",
                        events: events
                    )
                )
            )
        case .fetchConnectedDevice:
            let probe = SystemUSBProbe.detectIPhone()
            return deviceStateResponse(from: probe)
        case .fetchTunnelState(let device):
            let assessment = DeviceAgentAssessmentFactory.makeTunnelAssessment(
                for: device,
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
                        events: []
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
                injectionTransportService: injectionTransportService
            )
            return injectionTransportService.clearLocation(
                snapshot: deviceState.snapshot,
                tunnelAssessment: tunnelAssessment
            )
        }
    }


    static func runToolchainProbeSelfCheckReport() -> String {
        let report = ToolchainProbe.run()

        struct Check {
            let name: String
            let passed: Bool
            let detail: String
        }

        let checks = [
            Check(
                name: "xcode-select-probe-machinery",
                passed: report.xcodeSelect.status != .broken,
                detail: report.xcodeSelect.detail
            ),
            Check(
                name: "xcodebuild-probe-machinery",
                passed: report.xcodebuild.status != .broken,
                detail: report.xcodebuild.detail
            ),

            Check(
                name: "native-device-core-probe-machinery",
                passed: report.nativeDeviceCore.status != .broken,
                detail: report.nativeDeviceCore.detail
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
            lines.append("Toolchain probe self-check passed (\(checks.count) cases).")
        } else {
            lines.append("Toolchain probe self-check failed (\(failureCount)/\(checks.count) cases).")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func runNativeDeviceCoreEnumerationSelfCheckReport() -> String {
        struct Check {
            let name: String
            let passed: Bool
            let detail: String
        }

        let binaryCheck = Check(
            name: "native-device-core-binary-present",
            passed: NativeDeviceCoreMetadataProbe.isBinaryAvailable,
            detail: NativeDeviceCoreMetadataProbe.binaryStatusDetail
        )

        let enumerationResult = NativeDeviceCoreMetadataProbe.fetchAttachedMobileDevices()
        let enumerationCheck: Check
        switch enumerationResult {
        case .success(let devices):
            let udids = devices.map(\.identifier).filter { !$0.isEmpty }
            let detail = udids.isEmpty
                ? "enumeration succeeded; no attached iPhone UDIDs were reported"
                : "enumeration succeeded; UDIDs: \(udids.joined(separator: ", "))"
            enumerationCheck = Check(
                name: "native-device-core-enumeration",
                passed: true,
                detail: detail
            )
        case .failure(let failure):
            enumerationCheck = Check(
                name: "native-device-core-enumeration",
                passed: false,
                detail: failure.message
            )
        }

        let checks = [binaryCheck, enumerationCheck]
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
            lines.append("Native device-core enumeration self-check passed (\(checks.count) cases).")
        } else {
            lines.append("Native device-core enumeration self-check failed (\(failureCount)/\(checks.count) cases).")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func runNativeDeviceCoreDeviceInfoSelfCheckReport() -> String {
        struct Check {
            let name: String
            let passed: Bool
            let detail: String
        }

        let binaryCheck = Check(
            name: "native-device-core-binary-present",
            passed: NativeDeviceCoreMetadataProbe.isBinaryAvailable,
            detail: NativeDeviceCoreMetadataProbe.binaryStatusDetail
        )

        var checks = [binaryCheck]

        if NativeDeviceCoreMetadataProbe.isBinaryAvailable {
            switch NativeDeviceCoreMetadataProbe.fetchAttachedMobileDevices() {
            case .success(let devices):
                let udids = devices.map(\.identifier).filter { !$0.isEmpty }
                if udids.isEmpty {
                    checks.append(Check(
                        name: "native-device-core-device-info",
                        passed: true,
                        detail: "no USB-attached device found; device-info query skipped (not a failure)"
                    ))
                } else {
                    let udid = udids[0]
                    let service = NativeDeviceCoreDeviceInfoTransportService()
                    let probe = DeviceAgentUSBIdentityProbe(
                        hasBootstrapCandidateIdentity: true,
                        udid: udid,
                        displayName: nil,
                        serialSuffix: nil,
                        vendorID: nil,
                        productID: nil,
                        speed: nil,
                        iosVersion: nil
                    )
                    let result = service.probeTransport(from: probe)
                    let passed = result.transportState == .bootstrapReady
                    checks.append(Check(
                        name: "native-device-core-device-info",
                        passed: passed,
                        detail: result.summary
                    ))
                }
            case .failure(let failure):
                checks.append(Check(
                    name: "native-device-core-device-info",
                    passed: false,
                    detail: "enumeration failed; skipping device-info: \(failure.message)"
                ))
            }
        }

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
            lines.append("Native device-core device-info self-check passed (\(checks.count) cases).")
        } else {
            lines.append("Native device-core device-info self-check failed (\(failureCount)/\(checks.count) cases).")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    static func runNativeDeviceCoreInjectionSelfCheckReport() -> String {
        struct Check {
            let name: String
            let passed: Bool
            let detail: String
        }

        let binaryCheck = Check(
            name: "native-device-core-binary-present",
            passed: NativeDeviceCoreMetadataProbe.isBinaryAvailable,
            detail: NativeDeviceCoreMetadataProbe.binaryStatusDetail
        )

        var checks = [binaryCheck]

        let adapter = NativeDeviceCoreInjectionTransportAdapter()

        let disconnectedSnapshot = DeviceSnapshot(
            isConnected: false,
            connectionSummary: "SELF-CHECK",
            iosVersion: nil,
            deviceName: nil,
            deviceIdentifier: nil,
            serialSuffix: nil,
            vendorID: nil,
            productID: nil,
            probeSource: "self-check",
            matchedDeviceCount: 0
        )
        let disconnectedProbe = adapter.probeTransport(snapshot: disconnectedSnapshot, tunnelEndpointResult: nil)
        checks.append(Check(
            name: "disconnected-snapshot-returns-unavailable",
            passed: disconnectedProbe.transportState == .unavailable,
            detail: "state=\(disconnectedProbe.transportState.rawValue)"
        ))

        let ios17Snapshot = DeviceSnapshot(
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
        let ios17Probe = adapter.probeTransport(snapshot: ios17Snapshot, tunnelEndpointResult: nil)
        checks.append(Check(
            name: "ios17-snapshot-returns-native-rsd",
            passed: ios17Probe.transportState == .nativeRsd,
            detail: "state=\(ios17Probe.transportState.rawValue)"
        ))

        let noUDIDSnapshot = DeviceSnapshot(
            isConnected: true,
            connectionSummary: "SELF-CHECK",
            iosVersion: "16.7",
            deviceName: "Self Check iPhone",
            deviceIdentifier: nil,
            serialSuffix: nil,
            vendorID: nil,
            productID: nil,
            probeSource: "self-check",
            matchedDeviceCount: 1
        )
        let noUDIDProbe = adapter.probeTransport(snapshot: noUDIDSnapshot, tunnelEndpointResult: nil)
        checks.append(Check(
            name: "ios16-no-udid-returns-unavailable",
            passed: noUDIDProbe.transportState == .unavailable,
            detail: "state=\(noUDIDProbe.transportState.rawValue)"
        ))

        if NativeDeviceCoreMetadataProbe.isBinaryAvailable {
            let ios16Snapshot = DeviceSnapshot(
                isConnected: true,
                connectionSummary: "SELF-CHECK",
                iosVersion: "16.7",
                deviceName: "Self Check iPhone",
                deviceIdentifier: "self-check-device-id",
                serialSuffix: "0000",
                vendorID: "0x05ac",
                productID: "0x12a8",
                probeSource: "self-check",
                matchedDeviceCount: 1
            )
            let ios16Probe = adapter.probeTransport(snapshot: ios16Snapshot, tunnelEndpointResult: nil)
            checks.append(Check(
                name: "ios16-with-udid-binary-present-returns-native-lockdown",
                passed: ios16Probe.transportState == .nativeLockdown,
                detail: "state=\(ios16Probe.transportState.rawValue)"
            ))
        }

        // Verify nativeRsd bypass: iOS 17+ tunnel assessment must reach readinessGate .ready
        // without invoking the external tunneld, regardless of tunnel controller state.
        let stack = InjectionTransportServiceStack()

        let ios17TunnelAssessment = DeviceAgentAssessmentFactory.makeTunnelAssessment(
            for: ios17Snapshot,
            injectionTransportService: stack
        )
        checks.append(Check(
            name: "ios17-nativeRsd-tunnel-bypasses-external-tunneld",
            passed: ios17TunnelAssessment?.readinessGate == .ready
                && ios17TunnelAssessment?.tunnelRequirementResult?.state == .notRequired
                && ios17TunnelAssessment?.blockerCodes.isEmpty == true,
            detail: "gate=\(ios17TunnelAssessment?.readinessGate.rawValue ?? "nil") req=\(ios17TunnelAssessment?.tunnelRequirementResult?.state.rawValue ?? "nil") blockers=\(ios17TunnelAssessment?.blockerCodes.map(\.rawValue) ?? [])"
        ))

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
            lines.append("Native device-core injection transport self-check passed (\(checks.count) cases).")
        } else {
            lines.append("Native device-core injection transport self-check failed (\(failureCount)/\(checks.count) cases).")
        }

        return lines.joined(separator: "\n") + "\n"
    }


    static func runAgentProtocolVersionSelfCheckReport() -> String {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let request = DeviceAgentRequest.probeAvailability
        let currentVersionRoundTrip: Bool
        let rejectsZero: Bool
        let rejectsFuture: Bool

        do {
            let data = try encoder.encode(request)
            currentVersionRoundTrip = (try decoder.decode(DeviceAgentRequest.self, from: data) == request)
            rejectsZero = rejectsSchemaVersion(
                in: data,
                replacement: 0,
                decoder: decoder
            )
            rejectsFuture = rejectsSchemaVersion(
                in: data,
                replacement: DeviceAgentProtocolVersion.currentSchemaVersion + 1,
                decoder: decoder
            )
        } catch {
            currentVersionRoundTrip = false
            rejectsZero = false
            rejectsFuture = false
        }

        let checks = [
            ("round-trips-current-schema-version", currentVersionRoundTrip, "request encoded and decoded at schema v\(DeviceAgentProtocolVersion.currentSchemaVersion)"),
            ("rejects-schema-version-0", rejectsZero, "decoder rejects schema version 0"),
            ("rejects-schema-version-future", rejectsFuture, "decoder rejects schema version \(DeviceAgentProtocolVersion.currentSchemaVersion + 1)")
        ]

        var lines: [String] = []
        var failureCount = 0
        for (name, passed, detail) in checks {
            if passed {
                lines.append("PASS \(name): \(detail)")
            } else {
                failureCount += 1
                lines.append("FAIL \(name): \(detail)")
            }
        }

        if failureCount == 0 {
            lines.append("Agent protocol version self-check passed (\(checks.count) cases).")
        } else {
            lines.append("Agent protocol version self-check failed (\(failureCount)/\(checks.count) cases).")
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
    var allDevices: [DevicePickerEntry] = []

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

        // Preferred UDID set by the main process (UserDefaults → env var) for multi-device selection.
        let preferredUDID = ProcessInfo.processInfo.environment["GTM_PREFERRED_DEVICE_UDID"]

        switch NativeDeviceCoreMetadataProbe.fetchAttachedMobileDevices() {
        case .success(let devices):
            let allEntries = devices.map {
                DevicePickerEntry(udid: $0.identifier, name: $0.name, iosVersion: $0.iosVersion)
            }

            // When multiple devices are found, prefer the user's selection if it matches.
            let effectiveMatch: XcodeAttachedAppleDevice?
            if devices.count > 1, let preferred = preferredUDID,
               let found = devices.first(where: { $0.identifier == preferred }) {
                effectiveMatch = found
            } else {
                effectiveMatch = XcodeDeviceMetadataProbe.match(for: probe, in: devices)
            }

            guard let match = effectiveMatch else {
                let message = devices.isEmpty
                    ? "Native device-core POC did not report a USB-attached iPhone/iPad session for metadata enrichment"
                    : "Native device-core POC metadata did not match the current USB probe strongly enough to enrich iOS version"
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
                    events: probe.events + [DeviceAgentDiagnosticEvent(level: .warning, message: message)],
                    allDevices: allEntries
                )
            }

            let event: DeviceAgentDiagnosticEvent
            if let iosVersion = match.iosVersion {
                event = DeviceAgentDiagnosticEvent(
                    level: .info,
                    message: "Native device-core POC enriched metadata with iOS \(iosVersion) from \(match.name)"
                )
            } else {
                event = DeviceAgentDiagnosticEvent(
                    level: .warning,
                    message: "Native device-core POC matched \(match.name), but it did not provide an iOS version"
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
                events: probe.events + [event],
                allDevices: allEntries
            )
        case .failure(let failure):
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
                        events: probe.events + [
                            DeviceAgentDiagnosticEvent(
                                level: .warning,
                                message: "Native device-core POC unavailable: \(failure.message)"
                            ),
                            DeviceAgentDiagnosticEvent(level: .warning, message: message)
                        ]
                    )
                }

                let event: DeviceAgentDiagnosticEvent
                if let iosVersion = match.iosVersion {
                    event = DeviceAgentDiagnosticEvent(
                        level: .info,
                        message: "xcdevice fallback enriched metadata with iOS \(iosVersion) from \(match.name)"
                    )
                } else {
                    event = DeviceAgentDiagnosticEvent(
                        level: .warning,
                        message: "xcdevice fallback matched \(match.name), but it did not provide an iOS version"
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
                    events: probe.events + [
                        DeviceAgentDiagnosticEvent(
                            level: .warning,
                            message: "Native device-core POC unavailable: \(failure.message)"
                        ),
                        event
                    ]
                )
            case .failure(let fallbackFailure):
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
                            message: "Native device-core POC unavailable: \(failure.message)"
                        ),
                        DeviceAgentDiagnosticEvent(
                            level: .warning,
                            message: "xcdevice metadata enrichment unavailable: \(fallbackFailure.message)"
                        )
                    ]
                )
            }
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
            return parseAttachedMobileDevices(from: text)
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

    static func parseAttachedMobileDevices(from text: String) -> Result<[XcodeAttachedAppleDevice], DeviceAgentFailure> {
        let payload = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return .failure(
                DeviceAgentFailure(
                    code: .agentUnavailable,
                    message: "Unable to parse device metadata JSON output."
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
    }
}

private enum NativeDeviceCoreMetadataProbe {
    static var isBinaryAvailable: Bool {
        resolveBinaryPath() != nil
    }

    static var binaryStatusDetail: String {
        if let binaryPath = resolveBinaryPath() {
            return "native device-core helper found at \(binaryPath)"
        }
        return "Bundled native device-core POC binary is not built yet."
    }

    static func fetchAttachedMobileDevices() -> Result<[XcodeAttachedAppleDevice], DeviceAgentFailure> {
        if NativeDeviceCoreFFI.isAvailable {
            do {
                let text = try NativeDeviceCoreFFI.enumerateDevices()
                return XcodeDeviceMetadataProbe.parseAttachedMobileDevices(from: text)
            } catch {
                V3TelemetryStore.shared.record(
                    type: .enumFailure,
                    summary: "native-device-core FFI enumerate failed",
                    errorMessage: error.localizedDescription
                )
                return .failure(DeviceAgentFailure(
                    code: .agentUnavailable,
                    message: "Bundled native device-core FFI failed to enumerate devices: \(error.localizedDescription)"
                ))
            }
        }
        // Fallback: shell out to the binary (development without FFI dylib)
        guard let binaryPath = resolveBinaryPath() else {
            return .failure(
                DeviceAgentFailure(
                    code: .agentUnavailable,
                    message: "Bundled native device-core POC binary is not built yet."
                )
            )
        }
        switch runCaptured(executable: binaryPath, arguments: ["enumerate-ios-devices"]) {
        case .success(let text):
            return XcodeDeviceMetadataProbe.parseAttachedMobileDevices(from: text)
        case .failure(let failure):
            V3TelemetryStore.shared.record(
                type: .enumFailure,
                summary: "native-device-core enumerate-ios-devices failed",
                errorMessage: failure.message
            )
            return .failure(
                DeviceAgentFailure(
                    code: .agentUnavailable,
                    message: "Bundled native device-core POC failed to enumerate devices: \(failure.message)"
                )
            )
        }
    }

    static func resolveBinaryPath(filePath: String = #filePath) -> String? {
        // Shipped DMG: binary bundled at Contents/Helpers/ (conventional helper location)
        let helpersURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/geoteleport-device-core")
        if FileManager.default.isExecutableFile(atPath: helpersURL.path) {
            return helpersURL.path
        }
        // Shipped DMG fallback: Contents/MacOS/ alongside the main executable
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

    init(services: [any InjectionTransportServing] = InjectionTransportServiceStack.defaultServices()) {
        self.services = services
    }

    static func defaultServices() -> [any InjectionTransportServing] {
        var services: [any InjectionTransportServing] = [
            NativeDeviceCoreInjectionTransportAdapter()
        ]
        return services
    }

    func probeTransport(
        snapshot: DeviceSnapshot,
        tunnelEndpointResult: DeviceAgentTunnelEndpointResult?
    ) -> DeviceAgentInjectionTransportProbeResult {
        let results = services.map {
            $0.probeTransport(snapshot: snapshot, tunnelEndpointResult: tunnelEndpointResult)
        }
        if let ready = results.first(where: { $0.transportState == .nativeLockdown }) {
            return ready
        }
        if let ready = results.first(where: { $0.transportState == .nativeRsd }) {
            return ready
        }
        if let ready = results.first(where: { $0.transportState == .xcodeTestHarness }) {
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




private struct NativeDeviceCoreInjectionTransportAdapter: InjectionTransportServing {
    let transportID = "injection.transport.native-lockdown"

    func probeTransport(
        snapshot: DeviceSnapshot,
        tunnelEndpointResult: DeviceAgentTunnelEndpointResult?
    ) -> DeviceAgentInjectionTransportProbeResult {
        guard snapshot.isConnected else {
            return unavailableProbe(
                summary: "No connected device for native lockdown injection.",
                nextAction: "Connect an iPhone over USB before probing native injection transport."
            )
        }

        guard NativeDeviceCoreMetadataProbe.isBinaryAvailable else {
            return unavailableProbe(
                summary: "Native device-core binary is not built yet.",
                nextAction: "Build the native-device-core binary before using native lockdown injection."
            )
        }

        if let major = snapshot.iosMajorVersion, major >= 17 {
            return DeviceAgentInjectionTransportProbeResult(
                transportID: transportID,
                transportState: .nativeRsd,
                contract: DeviceAgentInjectionTransportContract(
                    contractID: "injection.transport.native-rsd",
                    phase: .nativeRsd,
                    summary: "iOS \(major) detected: native RSD injection via ios17-location-daemon. NativeDeviceCoreIos17LocationController manages the persistent daemon in the main app process.",
                    expectedInput: "iOS 17+ device with UDID and built binary"
                ),
                sourceTunnelEndpointArtifactID: nil,
                summary: "iOS \(major) device: native RSD injection via ios17-location-daemon (NativeDeviceCoreIos17LocationController).",
                nextAction: "Call setLocation or clearLocation; the daemon will be started on first use.",
                confidence: "high"
            )
        }

        guard let udid = snapshot.deviceIdentifier, !udid.isEmpty else {
            return unavailableProbe(
                summary: "Device UDID is not available for native lockdown injection.",
                nextAction: "Ensure device-info transport has resolved the device UDID before probing injection."
            )
        }

        return DeviceAgentInjectionTransportProbeResult(
            transportID: transportID,
            transportState: .nativeLockdown,
            contract: DeviceAgentInjectionTransportContract(
                contractID: "injection.transport.native-lockdown",
                phase: .nativeLockdown,
                summary: "Native lockdown injection transport is ready. Device UDID available, binary present, iOS ≤ 16 confirmed.",
                expectedInput: "Teleport request"
            ),
            sourceTunnelEndpointArtifactID: nil,
            summary: "Native lockdown injection transport ready for UDID \(udid).",
            nextAction: "Proceed with location injection via native lockdown transport.",
            confidence: "high"
        )
    }

    func setLocation(
        _ request: TeleportRequest,
        snapshot: DeviceSnapshot,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> DeviceAgentResponse {
        guard snapshot.isConnected else {
            return .failure(DeviceAgentFailure(
                code: .invalidRequest,
                message: "No connected iPhone for native lockdown injection."
            ))
        }
        guard Double(request.latitude) != nil, Double(request.longitude) != nil else {
            return .failure(DeviceAgentFailure(
                code: .invalidRequest,
                message: "Invalid coordinates for native lockdown injection."
            ))
        }
        guard let udid = snapshot.deviceIdentifier, !udid.isEmpty else {
            return .failure(DeviceAgentFailure(
                code: .agentUnavailable,
                message: "Device UDID not available for native lockdown injection."
            ))
        }
        if let major = snapshot.iosMajorVersion, major >= 17 {
            // iOS 17+ injection is handled in the main app process via NativeDeviceCoreIos17LocationController
            // before reaching this single-shot agent. This branch is a safety net only.
            return .failure(DeviceAgentFailure(
                code: .transportUnimplemented,
                message: "iOS \(major) device: set-location must be routed through NativeDeviceCoreIos17LocationController in the main app process, not via the single-shot agent."
            ))
        }
        if NativeDeviceCoreFFI.isAvailable {
            do {
                _ = try NativeDeviceCoreFFI.setLocation(udid: udid, lat: request.latitude, lon: request.longitude)
                return .success(.teleportResult(DeviceAgentTeleportResult(
                    response: TeleportResponse(stdout: "", stderr: "", exitCode: 0),
                    events: [DeviceAgentDiagnosticEvent(
                        level: .info,
                        message: "Location set via native lockdown FFI to \(request.latitude),\(request.longitude) on \(udid)."
                    )]
                )))
            } catch {
                return .failure(DeviceAgentFailure(code: .transportExecutionFailed, message: error.localizedDescription))
            }
        }
        // Fallback: shell out to the binary
        guard let binaryPath = NativeDeviceCoreMetadataProbe.resolveBinaryPath() else {
            return .failure(DeviceAgentFailure(
                code: .agentUnavailable,
                message: "Native device-core binary is not built."
            ))
        }
        switch nativeDeviceCoreRunForInjection(
            binaryPath: binaryPath,
            arguments: ["set-location", udid, request.latitude, request.longitude]
        ) {
        case .success:
            return .success(.teleportResult(DeviceAgentTeleportResult(
                response: TeleportResponse(stdout: "", stderr: "", exitCode: 0),
                events: [DeviceAgentDiagnosticEvent(
                    level: .info,
                    message: "Location set via native lockdown to \(request.latitude),\(request.longitude) on \(udid)."
                )]
            )))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    func clearLocation(
        snapshot: DeviceSnapshot,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) -> DeviceAgentResponse {
        guard snapshot.isConnected else {
            return .failure(DeviceAgentFailure(
                code: .invalidRequest,
                message: "No connected iPhone for native lockdown location clear."
            ))
        }
        guard let udid = snapshot.deviceIdentifier, !udid.isEmpty else {
            return .failure(DeviceAgentFailure(
                code: .agentUnavailable,
                message: "Device UDID not available for native lockdown location clear."
            ))
        }
        if let major = snapshot.iosMajorVersion, major >= 17 {
            // Safety net: clear-location is handled by NativeDeviceCoreIos17LocationController in the main app.
            return .failure(DeviceAgentFailure(
                code: .transportUnimplemented,
                message: "iOS \(major) device: clear-location must be routed through NativeDeviceCoreIos17LocationController in the main app process, not via the single-shot agent."
            ))
        }
        if NativeDeviceCoreFFI.isAvailable {
            do {
                _ = try NativeDeviceCoreFFI.clearLocation(udid: udid)
                return .success(.teleportResult(DeviceAgentTeleportResult(
                    response: TeleportResponse(stdout: "", stderr: "", exitCode: 0),
                    events: [DeviceAgentDiagnosticEvent(
                        level: .info,
                        message: "Location cleared via native lockdown FFI on \(udid)."
                    )]
                )))
            } catch {
                return .failure(DeviceAgentFailure(code: .transportExecutionFailed, message: error.localizedDescription))
            }
        }
        // Fallback: shell out to the binary
        guard let binaryPath = NativeDeviceCoreMetadataProbe.resolveBinaryPath() else {
            return .failure(DeviceAgentFailure(
                code: .agentUnavailable,
                message: "Native device-core binary is not built."
            ))
        }
        switch nativeDeviceCoreRunForInjection(binaryPath: binaryPath, arguments: ["clear-location", udid]) {
        case .success:
            return .success(.teleportResult(DeviceAgentTeleportResult(
                response: TeleportResponse(stdout: "", stderr: "", exitCode: 0),
                events: [DeviceAgentDiagnosticEvent(
                    level: .info,
                    message: "Location cleared via native lockdown on \(udid)."
                )]
            )))
        case .failure(let failure):
            return .failure(failure)
        }
    }

    private func unavailableProbe(
        summary: String,
        nextAction: String
    ) -> DeviceAgentInjectionTransportProbeResult {
        DeviceAgentInjectionTransportProbeResult(
            transportID: transportID,
            transportState: .unavailable,
            contract: DeviceAgentInjectionTransportContract(
                contractID: "injection.transport.native-lockdown",
                phase: .probeOnly,
                summary: "Native lockdown injection transport is not yet available.",
                expectedInput: "Connected iOS ≤ 16 device with UDID and built binary"
            ),
            sourceTunnelEndpointArtifactID: nil,
            summary: summary,
            nextAction: nextAction,
            confidence: "high"
        )
    }
}

private func nativeDeviceCoreRunForInjection(
    binaryPath: String,
    arguments: [String]
) -> Result<Void, DeviceAgentFailure> {
    let task = Process()
    let stderrPipe = Pipe()
    task.executableURL = URL(fileURLWithPath: binaryPath)
    task.arguments = arguments
    task.standardOutput = FileHandle.nullDevice
    task.standardError = stderrPipe
    do {
        try task.run()
        task.waitUntilExit()
        let errorData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let status = task.terminationStatus
        guard status == 0 else {
            let msg = (String(data: errorData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let code: DeviceAgentErrorCode = status == 3
                ? .transportUnimplemented
                : .agentUnavailable
            V3TelemetryStore.shared.record(
                type: .injectionFailure,
                summary: "native-device-core \(arguments.first ?? "?") failed",
                exitCode: Int(status),
                errorMessage: msg.isEmpty ? "exited with code \(status)" : msg
            )
            return .failure(DeviceAgentFailure(
                code: code,
                message: msg.isEmpty ? "\(binaryPath) exited with code \(status)" : msg
            ))
        }
        return .success(())
    } catch {
        V3TelemetryStore.shared.record(
            type: .injectionFailure,
            summary: "native-device-core process launch failed",
            errorMessage: error.localizedDescription
        )
        return .failure(DeviceAgentFailure(code: .agentUnavailable, message: error.localizedDescription))
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

// Tunnel controller stub used in self-checks: always returns inactive/no-product-owned state
// so tests verify that the nativeRsd bypass fires before the controller is consulted.





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
                udid: probe.deviceIdentifier,
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
            var summary = "Typed metadata session resolved from USB identity; device-info transport is no longer the blocking layer"
            if let majorStr = probe.iosVersion, let major = Int(majorStr.split(separator: ".").first ?? ""), major >= 16 {
                summary += " Ensure Developer Mode is enabled on your iPhone (Settings → Privacy & Security → Developer Mode)."
            }
            readinessSummary = summary
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
            let deviceInfoBlockerMessage = deviceInfoTransportProbeResult.nextAction
            blockers.append(deviceInfoBlockerMessage)
            nextActions.append(deviceInfoBlockerMessage)
            // Overwrite readinessSummary with the user-facing reason when there's a meaningful one
            if deviceInfoTransportProbeResult.transportState == .probeOnly,
               !deviceInfoBlockerMessage.isEmpty {
                readinessSummary = deviceInfoBlockerMessage
            }
        } else {
            blockers.append("Device identity metadata resolved.")
            nextActions.append("Use resolved metadata session to drive tunnel requirement and lifecycle decisions.")
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
        injectionTransportService: InjectionTransportServing
    ) -> DeviceAgentSessionAssessment? {
        let metadataSession = inferredTypedMetadataSession(from: snapshot)
        let injectionTransportProbeResult = injectionTransportService.probeTransport(
            snapshot: snapshot,
            tunnelEndpointResult: nil
        )

        // nativeRsd = ios17-location-daemon owns the CDTunnel + RSD session internally.
        // No external tunnel daemon is needed.
        if injectionTransportProbeResult.transportState == .nativeRsd {
            let overriddenRequirement = DeviceAgentTunnelRequirementResult(
                state: .notRequired,
                sourceMetadataSessionID: metadataSession?.sessionID,
                summary: "iOS 17+ tunnel is managed internally by ios17-location-daemon (CDTunnel + jktcp + RSD); no external tunneld process is required.",
                nextAction: "No tunnel action needed. NativeDeviceCoreIos17LocationController starts the daemon on first set/clear call.",
                confidence: "high"
            )
            let internalLifecycleResult = DeviceAgentTunnelLifecycleResult(
                state: .noProductOwnedTunnel,
                summary: "ios17-location-daemon manages its own tunnel lifecycle internally; no product-owned external tunnel session is needed.",
                nextAction: "No external tunnel lifecycle action required for nativeRsd transport.",
                confidence: "high"
            )
            return DeviceAgentSessionAssessment(
                readinessGate: .ready,
                readinessSummary: "Native RSD injection via ios17-location-daemon is self-contained; the session is ready without an external tunneld.",
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
                tunnelRequirementResult: overriddenRequirement,
                tunnelLifecycleResult: internalLifecycleResult,
                tunnelSession: nil,
                tunnelHealthResult: nil,
                tunnelEndpointResult: nil,
                injectionTransportProbeResult: injectionTransportProbeResult,
                nextAction: "Call set or clear location; NativeDeviceCoreIos17LocationController will start the daemon on first use.",
                blockerCodes: [],
                blockers: [],
                confidence: "high"
            )
        }

        // No tunnel assessment needed for other transport states;
        // the native device core handles its own connectivity.
        return nil
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
                    matchedDeviceCount: probe.matchedDeviceCount,
                    availableDevices: probe.allDevices.isEmpty ? nil : probe.allDevices
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
    static func rejectsSchemaVersion(
        in data: Data,
        replacement: Int,
        decoder: JSONDecoder
    ) -> Bool {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        object["schemaVersion"] = replacement
        guard let mutated = try? JSONSerialization.data(withJSONObject: object) else {
            return false
        }
        do {
            _ = try decoder.decode(DeviceAgentRequest.self, from: mutated)
            return false
        } catch DeviceAgentProtocolCodingError.schemaVersionMismatch {
            return true
        } catch {
            return false
        }
    }

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

private struct ToolchainProbe {
    enum Status {
        case available
        case missing
        case broken
    }

    struct CheckResult {
        let status: Status
        let detail: String
    }

    let xcodeSelect: CheckResult
    let xcodebuild: CheckResult

    let nativeDeviceCore: CheckResult

    var availabilityBlockers: [DeviceAgentAssessmentBlockerCode] {
        var blockers: [DeviceAgentAssessmentBlockerCode] = []
        if xcodeSelect.status != .available || xcodebuild.status != .available {
            blockers.append(.xcodeToolchainMissing)
        }

        if nativeDeviceCore.status != .available {
            blockers.append(.bundledDeviceCoreMissing)
        }
        return blockers
    }

    var events: [DeviceAgentDiagnosticEvent] {
        [
            diagnosticEvent(prefix: "xcode-select", result: xcodeSelect),
            diagnosticEvent(prefix: "xcodebuild", result: xcodebuild),
            diagnosticEvent(prefix: "native-device-core", result: nativeDeviceCore)
        ]
    }

    static func run() -> ToolchainProbe {
        ToolchainProbe(
            xcodeSelect: probeXcodeSelect(),
            xcodebuild: probeXcodebuild(),
            nativeDeviceCore: probeNativeDeviceCore()
        )
    }

    private static func probeXcodeSelect() -> CheckResult {
        switch runCaptured(executable: "/usr/bin/xcode-select", arguments: ["-p"]) {
        case .success(let output):
            let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else {
                return CheckResult(status: .broken, detail: "xcode-select returned an empty developer directory.")
            }
            if path == "/Library/Developer/CommandLineTools" {
                return CheckResult(status: .missing, detail: "xcode-select points at Command Line Tools only (\(path)).")
            }
            return CheckResult(status: .available, detail: "xcode-select resolved full Xcode developer dir at \(path).")
        case .failure(let failure):
            return CheckResult(status: .missing, detail: failure.message)
        }
    }

    private static func probeXcodebuild() -> CheckResult {
        switch runCaptured(executable: "/usr/bin/xcrun", arguments: ["xcodebuild", "-version"]) {
        case .success(let output):
            let version = output
                .split(separator: "\n")
                .first
                .map(String.init) ?? "xcodebuild available"
            return CheckResult(status: .available, detail: version)
        case .failure(let failure):
            return CheckResult(status: .missing, detail: failure.message)
        }
    }

    private static func probeNativeDeviceCore() -> CheckResult {
        guard let binaryPath = NativeDeviceCoreMetadataProbe.resolveBinaryPath() else {
            return CheckResult(
                status: .missing,
                detail: "Bundled native device-core helper is not built yet at native-device-core/target/debug/geoteleport-device-core."
            )
        }
        return CheckResult(
            status: .available,
            detail: "Bundled native device-core helper found at \(binaryPath)."
        )
    }

    private func diagnosticEvent(prefix: String, result: CheckResult) -> DeviceAgentDiagnosticEvent {
        let level: DeviceAgentEventLevel
        switch result.status {
        case .available:
            level = .info
        case .missing:
            level = .warning
        case .broken:
            level = .error
        }
        return DeviceAgentDiagnosticEvent(level: level, message: "Toolchain probe \(prefix): \(result.detail)")
    }
}

// Manages a long-running ios17-location-daemon process with a persistent stdin/stdout pipe.
// Owned by the main app process (not the single-shot agent child process), so the DVT
// location-simulation connection stays alive across multiple set/clear commands.
final class NativeDeviceCoreIos17LocationController {

    // MARK: - Session

    private final class Session {
        let udid: String
        let process: Process
        let stdinHandle: FileHandle

        private let lock = NSLock()
        private var lineQueue: [String] = []
        private let lineSemaphore = DispatchSemaphore(value: 0)

        init(
            udid: String,
            process: Process,
            stdinHandle: FileHandle,
            stdoutHandle: FileHandle
        ) {
            self.udid = udid
            self.process = process
            self.stdinHandle = stdinHandle
            startReaderThread(handle: stdoutHandle)
        }

        private func startReaderThread(handle: FileHandle) {
            let t = Thread {
                var buffer = ""
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break } // EOF: process died or stdin was closed
                    if let chunk = String(data: data, encoding: .utf8) {
                        buffer += chunk
                        while let nl = buffer.firstIndex(of: "\n") {
                            let line = String(buffer[..<nl])
                            buffer.removeSubrange(...nl)
                            self.lock.lock()
                            self.lineQueue.append(line)
                            self.lock.unlock()
                            self.lineSemaphore.signal()
                        }
                    }
                }
                self.lineSemaphore.signal() // wake any waiter on EOF
            }
            t.qualityOfService = .userInitiated
            t.name = "ios17-location-daemon.stdout-reader"
            t.start()
        }

        func nextLine(timeout: TimeInterval) -> String? {
            guard lineSemaphore.wait(timeout: .now() + timeout) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return lineQueue.isEmpty ? nil : lineQueue.removeFirst()
        }

        func sendLine(_ text: String) {
            let data = (text + "\n").data(using: .utf8)!
            stdinHandle.write(data)
        }
    }

    // MARK: - State

    private var session: Session?

    // MARK: - Public interface

    func setLocation(
        udid: String,
        lat: String,
        lon: String
    ) -> Result<DeviceAgentTeleportResult, DeviceAgentFailure> {
        switch ensureSession(udid: udid) {
        case .failure(let f): return .failure(f)
        case .success: break
        }
        guard let s = session else {
            return .failure(DeviceAgentFailure(code: .agentUnavailable, message: "ios17-location-daemon: session unexpectedly nil after start."))
        }
        s.sendLine("set \(lat) \(lon)")
        return interpretResponse(s.nextLine(timeout: 10), op: "set(\(lat),\(lon))", udid: udid)
    }

    func clearLocation(udid: String) -> Result<DeviceAgentTeleportResult, DeviceAgentFailure> {
        switch ensureSession(udid: udid) {
        case .failure(let f): return .failure(f)
        case .success: break
        }
        guard let s = session else {
            return .failure(DeviceAgentFailure(code: .agentUnavailable, message: "ios17-location-daemon: session unexpectedly nil after start."))
        }
        s.sendLine("clear")
        return interpretResponse(s.nextLine(timeout: 10), op: "clear", udid: udid)
    }

    // Call when the device disconnects or the UDID changes to free the process.
    func invalidate() {
        guard let s = session else { return }
        try? s.stdinHandle.close() // signals EOF to daemon → daemon exits
        s.process.terminate()
        session = nil
    }

    // MARK: - Private helpers

    private func ensureSession(udid: String) -> Result<Void, DeviceAgentFailure> {
        if let s = session, s.udid == udid, s.process.isRunning {
            return .success(())
        }
        invalidate()
        return startSession(udid: udid)
    }

    private func startSession(udid: String) -> Result<Void, DeviceAgentFailure> {
        guard let binaryPath = NativeDeviceCoreMetadataProbe.resolveBinaryPath() else {
            V3TelemetryStore.shared.record(
                type: .ios17DaemonLaunchFailure,
                summary: "ios17-location-daemon: binary not built",
                errorMessage: "native device-core binary not found"
            )
            return .failure(DeviceAgentFailure(
                code: .agentUnavailable,
                message: "ios17-location-daemon: native device-core binary is not built."
            ))
        }

        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["ios17-location-daemon", udid]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            V3TelemetryStore.shared.record(
                type: .ios17DaemonLaunchFailure,
                summary: "ios17-location-daemon: process failed to launch",
                errorMessage: error.localizedDescription
            )
            return .failure(DeviceAgentFailure(
                code: .agentUnavailable,
                message: "ios17-location-daemon: failed to launch for \(udid): \(error.localizedDescription)"
            ))
        }

        let s = Session(
            udid: udid,
            process: process,
            stdinHandle: stdinPipe.fileHandleForWriting,
            stdoutHandle: stdoutPipe.fileHandleForReading
        )
        session = s

        guard let first = s.nextLine(timeout: 15) else {
            invalidate()
            V3TelemetryStore.shared.record(
                type: .ios17DaemonTimeout,
                summary: "ios17-location-daemon: did not become ready within 15 s",
                errorMessage: "Check USB connection and pairing"
            )
            return .failure(DeviceAgentFailure(
                code: .agentUnavailable,
                message: "ios17-location-daemon: did not become ready within 15 s for \(udid). Check USB connection and pairing."
            ))
        }
        guard first == "READY" else {
            invalidate()
            V3TelemetryStore.shared.record(
                type: .ios17DaemonUnexpectedOutput,
                summary: "ios17-location-daemon: unexpected startup output",
                errorMessage: first
            )
            return .failure(DeviceAgentFailure(
                code: .agentUnavailable,
                message: "ios17-location-daemon: unexpected startup output for \(udid): \(first)"
            ))
        }
        return .success(())
    }

    private func interpretResponse(
        _ response: String?,
        op: String,
        udid: String
    ) -> Result<DeviceAgentTeleportResult, DeviceAgentFailure> {
        guard let response else {
            invalidate()
            V3TelemetryStore.shared.record(
                type: .ios17DaemonNoResponse,
                summary: "ios17-location-daemon: no response to '\(op)'",
                errorMessage: "process may have died"
            )
            return .failure(DeviceAgentFailure(
                code: .transportExecutionFailed,
                message: "ios17-location-daemon: no response to '\(op)' on \(udid) (process may have died)."
            ))
        }
        if response == "OK" {
            return .success(DeviceAgentTeleportResult(
                response: TeleportResponse(stdout: "OK", stderr: "", exitCode: 0),
                events: [DeviceAgentDiagnosticEvent(level: .info, message: "ios17-location-daemon: \(op) succeeded on \(udid).")]
            ))
        }
        let detail = response.hasPrefix("ERROR: ") ? String(response.dropFirst(7)) : response
        V3TelemetryStore.shared.record(
            type: .ios17DaemonCommandFailure,
            summary: "ios17-location-daemon: \(op) failed",
            errorMessage: detail
        )
        return .failure(DeviceAgentFailure(
            code: .transportExecutionFailed,
            message: "ios17-location-daemon: \(op) on \(udid) failed: \(detail)"
        ))
    }
}
