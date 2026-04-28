import SwiftUI
import MapKit
import CoreLocation
import Combine
import AppKit
import UniformTypeIdentifiers

// MARK: - V9.3 · Single-message status card · Collapsible debug log

enum AppStatus: Equatable {
    case idle
    case working(String, String?)
    case success(String, String?)
    case failure(String, String?)
}

struct ContentView: View {
    private enum LocationActionKind {
        case set
        case clear

        var recordAction: LocationCommandAction {
            switch self {
            case .set:
                return .set
            case .clear:
                return .clear
            }
        }

        var operationLabel: String {
            switch self {
            case .set:
                return "location set"
            case .clear:
                return "location clear"
            }
        }

        var needsValidCoordinates: Bool {
            switch self {
            case .set:
                return true
            case .clear:
                return false
            }
        }

        var backendRescanLog: String {
            switch self {
            case .set:
                return "[USER] ENV not ready — triggering rescan first"
            case .clear:
                return "[USER] ENV not ready for location clear — triggering rescan first"
            }
        }

        func tunnelAbortLog(deviceIOSVersion: String) -> String {
            switch self {
            case .set:
                return "[USER] ❌ iOS \(deviceIOSVersion) requires tunnel startup — aborting"
            case .clear:
                return "[USER] ❌ iOS \(deviceIOSVersion) requires tunnel startup before location clear — aborting"
            }
        }

        func tunnelAbortSubtitle(deviceIOSVersion: String) -> String {
            switch self {
            case .set:
                return "Bring up the tunnel first, then retry the location command through the same session."
            case .clear:
                return "Start the tunnel first, then clear the simulated location through the same session."
            }
        }

        var invalidCoordinatesLog: String {
            "[USER] ❌ Coordinate validation failed — aborting"
        }

        var invalidCoordinatesFailure: AppStatus {
            .failure("Invalid coordinates", "Fix LAT / LON before teleporting.")
        }

        var missingDeviceLog: String {
            "[USER] ❌ No connected device available for location clear"
        }

        var missingDeviceFailure: AppStatus {
            .failure("No device attached", "Attach and trust the iPhone before clearing simulated location.")
        }

        var workingStatus: AppStatus {
            switch self {
            case .set:
                return .working("Teleporting…", nil)
            case .clear:
                return .working("Clearing location…", "Requesting real GPS restore")
            }
        }

        func resolvedWorkingStatus(latitude: String, longitude: String) -> AppStatus {
            switch self {
            case .set:
                return .working("Teleporting…", "\(latitude), \(longitude)")
            case .clear:
                return workingStatus
            }
        }

        var actionLog: String {
            switch self {
            case .set:
                return "[USER] 🖱️ ACTION: EXECUTE JUMP CLICKED"
            case .clear:
                return "[USER] 🧹 ACTION: CLEAR LOCATION CLICKED"
            }
        }

        func kernelLogs(latitude: String, longitude: String) -> [String] {
            switch self {
            case .set:
                return [
                    "[KERNEL] 🛰️ TARGET LOCK ACQUIRED",
                    "[DATA] 📡 LATITUDE:  \(latitude)",
                    "[DATA] 📡 LONGITUDE: \(longitude)",
                    "[KERNEL] ⚡️ INITIATING INJECTION SEQUENCE..."
                ]
            case .clear:
                return ["[KERNEL] 📍 RESTORING REAL DEVICE LOCATION..."]
            }
        }

        func legacyArguments(latitude: String, longitude: String) -> String {
            switch self {
            case .set:
                return "developer simulate-location set -- \(latitude) \(longitude)"
            case .clear:
                return "developer simulate-location clear"
            }
        }

        var previewSuccessLog: String {
            switch self {
            case .set:
                return "[PREVIEW] Simulation success."
            case .clear:
                return "[PREVIEW] Clear-location simulation success."
            }
        }

        func successTitle(latitude: String, longitude: String) -> String {
            switch self {
            case .set:
                return "GPS moved"
            case .clear:
                return "GPS restored"
            }
        }

        func successSubtitle(latitude: String, longitude: String) -> String? {
            switch self {
            case .set:
                return "\(latitude), \(longitude)"
            case .clear:
                return "Real device location resumed"
            }
        }

        var failureTitle: String {
            switch self {
            case .set:
                return "Teleport failed"
            case .clear:
                return "Clear failed"
            }
        }
    }

    @StateObject private var appModel = V3AppModel()
    @StateObject private var diagnostics = V3DiagnosticsStore()
    @StateObject private var statusStore = V3StatusStore()
    @AppStorage("v3.backendTrack") private var backendTrackRaw: String = BackendTrack.primaryTrack.rawValue
    private let backendProvider = V3BackendProvider()
    private var activeBackend: DeviceBackend { backendProvider.backend(for: activeBackendTrack) }
    private var runtimeCoordinator: V3RuntimeCoordinator {
        V3RuntimeCoordinator(backend: activeBackend)
    }

    // 坐标（持久化）
    @AppStorage("v3.latitude") private var latitude: String = "25.185317"
    @AppStorage("v3.longitude") private var longitude: String = "55.281516"
    @AppStorage("v3.citySearchText") private var citySearchText: String = ""

    @State private var isWorking: Bool = false
    @State private var isScanningDeps: Bool = false

    private var activeBackendTrack: BackendTrack {
        guard let track = BackendTrack(rawValue: backendTrackRaw),
              BackendTrack.userSelectableCases.contains(track) else {
            return BackendTrack.primaryTrack
        }
        return track
    }

    private var isDeviceConnected: Bool { appModel.isDeviceConnected }
    private var hardwareStatusTitle: String { appModel.hardwareStatusTitle }
    private var connectionStatusText: String { appModel.connectionStatusText }
    private var isEnvironmentReady: Bool { appModel.isEnvironmentReady }
    private var deviceIOSVersion: String { appModel.deviceIOSVersion }
    private var deviceIOSMajor: Int { appModel.deviceIOSMajor }
    private var tunneldRunning: Bool { appModel.tunneldRunning }
    private var needsTunneld: Bool { appModel.needsTunnel }

    @State private var showDebugLog: Bool = false
    @State private var showDevicePicker: Bool = false

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 25.185317, longitude: 55.281516),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )

    // 主题
    let accentBlue = Color(red: 0.2, green: 0.62, blue: 1.0)
    let terminalGreen = Color(red: 0.25, green: 0.9, blue: 0.5)
    let alertRed = Color(red: 1.0, green: 0.35, blue: 0.35)

    // 坐标校验
    private var latValue: Double? {
        guard let v = Double(latitude), v >= -90, v <= 90 else { return nil }
        return v
    }
    private var lonValue: Double? {
        guard let v = Double(longitude), v >= -180, v <= 180 else { return nil }
        return v
    }
    private var coordsValid: Bool { latValue != nil && lonValue != nil }
    private var canClearSimulatedLocation: Bool {
        V3ViewPresentation.canClearLocation(
            isWorking: isWorking,
            appModel: appModel
        )
    }

    var body: some View {
        ZStack {
            // 1. 全屏沉浸式地图底层
            NativeMapView(region: $region) { newCenter in
                self.latitude = String(format: "%.6f", newCenter.latitude)
                self.longitude = String(format: "%.6f", newCenter.longitude)
            }
            .edgesIgnoringSafeArea(.all)

            // 中心准星 —— 悬浮在屏幕正中央
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.95), lineWidth: 2)
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
                Circle()
                    .fill(accentBlue)
                    .frame(width: 8, height: 8)
                    .shadow(color: accentBlue.opacity(0.9), radius: 6)
                Image(systemName: "mappin")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.red)
                    .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 2)
                    .offset(y: -18)
            }
            .allowsHitTesting(false)

            // 2. HUD 悬浮 UI 层
            VStack(spacing: 0) {
                // 顶部控制区
                HStack(alignment: .top, spacing: 20) {
                    // 左上角浮窗：设备与系统状态
                    VStack(alignment: .leading, spacing: 12) {
                        // 设备连接状态
                        HStack(spacing: 10) {
                            Image(systemName: isDeviceConnected ? "iphone.gen3" : "cable.connector.slash")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(isDeviceConnected ? terminalGreen : alertRed)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hardwareStatusTitle)
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(isDeviceConnected ? terminalGreen : alertRed)
                                Text(connectionStatusText)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(glassPanel(cornerRadius: 14).shadow(color: .black.opacity(0.3), radius: 10, y: 4))

                        // 环境及依赖状态
                        HStack(spacing: 8) {
                            Circle()
                                .fill(
                                    V3ViewPresentation.environmentTint(
                                        appModel: appModel,
                                        terminalGreen: terminalGreen,
                                        alertRed: alertRed
                                    )
                                )
                                .frame(width: 8, height: 8)
                            Text(V3ViewPresentation.environmentBadgeText(appModel: appModel))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)

                            Spacer(minLength: 10)

                            if BackendTrack.userSelectableCases.count > 1 {
                                Menu {
                                    ForEach(BackendTrack.userSelectableCases, id: \.rawValue) { track in
                                        Button(track.displayName) { switchBackend(to: track) }
                                    }
                                } label: {
                                    Text(activeBackendTrack.shortLabel)
                                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                .menuStyle(.borderlessButton)
                            } else {
                                Text(activeBackendTrack.shortLabel)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                            Button(action: manualRefresh) {
                                Image(systemName: isScanningDeps ? "hourglass" : "arrow.clockwise")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(isScanningDeps)
                            .help(V3ViewPresentation.refreshActionLabel(appModel: appModel))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .background(glassPanel(cornerRadius: 14).shadow(color: .black.opacity(0.3), radius: 10, y: 4))

                        if appModel.sessionState == .multipleDevices && !appModel.availableDevices.isEmpty {
                            multipleDevicesBanner
                        }
                    }
                    .frame(width: 320)

                    Spacer()

                    // 右上角浮窗：操作控制中心
                    VStack(spacing: 12) {
                        // 搜索与坐标聚合
                        VStack(spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").font(.system(size: 13, weight: .medium)).foregroundColor(.secondary)
                                TextField("Search city…", text: $citySearchText)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    .foregroundColor(.primary)
                                    .onSubmit { searchCityOnly() }
                                if !citySearchText.isEmpty {
                                    Button(action: { citySearchText = "" }) {
                                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                                    }.buttonStyle(.plain)
                                }
                                Button(action: searchCityOnly) {
                                    Image(systemName: "arrow.right.circle.fill").font(.system(size: 14)).foregroundColor(accentBlue)
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.black.opacity(0.2))
                            )

                            HStack(spacing: 10) {
                                TechInput(title: "LAT", text: $latitude, valid: latValue != nil)
                                TechInput(title: "LON", text: $longitude, valid: lonValue != nil)
                            }
                        }
                        .padding(14)
                        .background(glassPanel(cornerRadius: 16).shadow(color: .black.opacity(0.3), radius: 10, y: 4))

                        // 预设地点网络
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            LocationButton(flag: "🇦🇪", name: "DUBAI",      lat: "25.185317", lon: "55.281516",  color: .orange)
                            LocationButton(flag: "🇦🇪", name: "Abu Dhabi",  lat: "24.340142", lon: "54.518667",  color: .blue)
                            LocationButton(flag: "🇻🇳", name: "Hanoi",      lat: "20.992498", lon: "105.944606", color: .purple)
                            LocationButton(flag: "🇯🇵", name: "Tokyo",      lat: "35.6895",   lon: "139.6917",   color: .pink)
                            LocationButton(flag: "🇺🇸", name: "New York",   lat: "40.7128",   lon: "-74.0060",   color: .cyan)
                            LocationButton(flag: "🇬🇧", name: "London",     lat: "51.5074",   lon: "-0.1278",    color: .green)
                            LocationButton(flag: "🇫🇷", name: "Paris",      lat: "48.8566",   lon: "2.3522",     color: .indigo)
                            LocationButton(flag: "🇨🇳", name: "Shenzhen",   lat: "22.556336", lon: "113.916641", color: .red)
                        }
                        .padding(14)
                        .background(glassPanel(cornerRadius: 16).shadow(color: .black.opacity(0.3), radius: 10, y: 4))
                    }
                    .frame(width: 380)
                }
                .padding(20)

                Spacer()

                // 底部浮窗：核心执行按钮、状态卡片、日志
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Button(action: teleport) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: V3ViewPresentation.canTeleport(
                                                isWorking: isWorking,
                                                appModel: appModel,
                                                coordsValid: coordsValid
                                            )
                                                ? [Color.blue.opacity(0.95), Color.purple.opacity(0.95)]
                                                : [Color.gray.opacity(0.65), Color.gray.opacity(0.45)],
                                            startPoint: .leading, endPoint: .trailing
                                        )
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                                    )
                                    .shadow(
                                        color: Color.blue.opacity(
                                            V3ViewPresentation.canTeleport(
                                                isWorking: isWorking,
                                                appModel: appModel,
                                                coordsValid: coordsValid
                                            ) ? 0.5 : 0
                                        ),
                                        radius: 16,
                                        x: 0,
                                        y: 6
                                    )

                                HStack(spacing: 8) {
                                    if V3ViewPresentation.shouldShowButtonWarning(
                                        appModel: appModel,
                                        coordsValid: coordsValid
                                    ) {
                                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow).font(.system(size: 16))
                                    }
                                    Text(buttonTitle())
                                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                }
                            }
                            .frame(height: 48)
                        }
                        .buttonStyle(.plain)
                        .disabled(
                            !V3ViewPresentation.canTeleport(
                                isWorking: isWorking,
                                appModel: appModel,
                                coordsValid: coordsValid
                            )
                        )

                        Button(action: clearSimulatedLocation) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: canClearSimulatedLocation
                                                ? [Color.orange.opacity(0.90), Color.red.opacity(0.82)]
                                                : [Color.gray.opacity(0.60), Color.gray.opacity(0.40)],
                                            startPoint: .leading, endPoint: .trailing
                                        )
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                                    )
                                HStack(spacing: 8) {
                                    Image(systemName: "location.slash.fill")
                                        .foregroundColor(.white).font(.system(size: 14))
                                    Text(isWorking ? "WORKING..." : "CLEAR")
                                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                                        .foregroundColor(.white)
                                }
                            }
                            .frame(width: 140, height: 48)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canClearSimulatedLocation)
                    }

                    statusCard
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)

                    if showDebugLog {
                        debugLogPanel
                            .frame(height: 200)
                            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .frame(maxWidth: 600)
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 800, minHeight: 650)
        .onAppear {
            appModel.backendTrack = activeBackendTrack
            logSystemInfo()
            performInitialRefresh()

            // Set up event-driven USB monitoring instead of 2-second polling
            IOKitUSBMonitor.shared.onDeviceChange = {
                log("[SYS] USB hardware change detected via IOKit, refreshing state...")
                performScheduledRefresh()
            }
            IOKitUSBMonitor.shared.start()
        }
        .sheet(isPresented: $showDevicePicker) {
            DevicePickerSheet(
                devices: appModel.availableDevices,
                selectedUDID: appModel.selectedDeviceUDID
            ) { chosen in
                appModel.selectedDeviceUDID = chosen
                showDevicePicker = false
                performScheduledRefresh()
            }
        }
        .onChange(of: appModel.sessionState) { _, newState in
            if case .multipleDevices = newState, !appModel.availableDevices.isEmpty {
                showDevicePicker = true
            }
        }
    }



    // MARK: - Status card

    private var statusCard: some View {
        let d = V3ViewPresentation.statusDisplay(
            status: statusStore.status,
            appModel: appModel,
            coordsValid: coordsValid,
            accentBlue: accentBlue,
            terminalGreen: terminalGreen,
            alertRed: alertRed
        )
        return HStack(alignment: .center, spacing: 12) {
            ZStack {
                Circle()
                    .fill(d.tint.opacity(0.22))
                    .frame(width: 40, height: 40)
                if d.showSpinner {
                    ProgressView()
                        .controlSize(.small)
                        .progressViewStyle(.circular)
                        .tint(d.tint)
                } else {
                    Image(systemName: d.icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(d.tint)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(d.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let s = d.subtitle, !s.isEmpty {
                    Text(s)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showDebugLog.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text("Log")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                    Image(systemName: showDebugLog ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(
                    Capsule().fill(Color.white.opacity(0.06))
                )
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .help(showDebugLog ? "Hide debug log" : "Show debug log")
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(d.tint.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(d.tint.opacity(0.30), lineWidth: 1)
                )
        )
    }

    private var debugLogPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("DEBUG LOG")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundColor(.secondary)
                Spacer()
                Text("\(diagnostics.lines.count)/\(diagnostics.maxLines)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                Button(action: { exportDiagnostics() }) {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 10)).foregroundColor(accentBlue)
                }.buttonStyle(.plain)
                Button(action: { diagnostics.clear() }) {
                    Image(systemName: "trash").font(.system(size: 10)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            HStack(spacing: 6) {
                Image(systemName: V3TelemetryStore.shared.isOptedIn ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 9))
                    .foregroundColor(V3TelemetryStore.shared.isOptedIn ? accentBlue : .secondary.opacity(0.4))
                Toggle("Telemetry", isOn: Binding(
                    get: { V3TelemetryStore.shared.isOptedIn },
                    set: { V3TelemetryStore.shared.isOptedIn = $0 }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                Spacer()
                if V3TelemetryStore.shared.hasEntries() {
                    Text("\(V3TelemetryStore.shared.telemetryContent().split(separator: "\n").count) events")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))
                    Button(action: { V3TelemetryStore.shared.clear() }) {
                        Image(systemName: "trash").font(.system(size: 9)).foregroundColor(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(diagnostics.lines.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(terminalGreen)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                        .id("logBottom")
                }
                .onChange(of: diagnostics.lines.count) { _, _ in
                    withAnimation { proxy.scrollTo("logBottom", anchor: .bottom) }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // 设置用户可见状态；.success 会在 5s 后自动淡回 .idle（可被新状态打断）
    private func setStatus(_ s: AppStatus) {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.18)) { self.statusStore.set(s) }
        }
    }

    // MARK: - Multiple devices banner

    private var multipleDevicesBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone.gen3.badge.plus")
                .font(.system(size: 14))
                .foregroundColor(accentBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(appModel.availableDevices.count) iPhones connected")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                Text("Select which device to teleport.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                showDevicePicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet").font(.system(size: 10))
                    Text("Select").font(.system(size: 10, weight: .semibold, design: .monospaced))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(accentBlue.opacity(0.85)))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accentBlue.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(accentBlue.opacity(0.40), lineWidth: 1)
                )
        )
    }

    // MARK: - 逻辑

    func buttonTitle() -> String {
        V3ViewPresentation.buttonTitle(
            isWorking: isWorking,
            appModel: appModel,
            coordsValid: coordsValid
        )
    }

    func log(_ msg: String) {
        DispatchQueue.main.async {
            self.diagnostics.append(msg)
        }
    }

    func logSystemInfo() {
        log("[SYS] Getting Host Info...")
        let host = ProcessInfo.processInfo.hostName
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        log("[SYS] Host: \(host)")
        log("[SYS] OS: \(os)")
    }

    func exportDiagnostics() {
        let sessionLines = V3SessionDiagnostics.diagnosticLines(
            backendTrack: appModel.backendTrack,
            availability: appModel.backendAvailability,
            capabilities: appModel.backendCapabilities,
            snapshot: appModel.deviceSnapshot,
            tunnelState: appModel.tunnelState,
            sessionState: appModel.sessionState,
            health: appModel.connectionHealth,
            blocker: appModel.sessionBlocker,
            readinessGate: appModel.readinessGate,
            deviceProbeFocus: appModel.effectiveDeviceProbeFocus,
            availabilityAssessment: appModel.availabilityAssessment,
            deviceAssessment: appModel.deviceAssessment,
            tunnelAssessment: appModel.tunnelAssessment,
            lastLocationCommandRecord: appModel.lastLocationCommandRecord
        )

        var content = "GeoTeleport Diagnostics\n"
        content += "======================\n"
        content += "Date: \(ISO8601DateFormatter().string(from: Date()))\n"
        content += "Host: \(ProcessInfo.processInfo.hostName)\n"
        content += "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n\n"
        content += "--- Session State ---\n"
        content += sessionLines.joined(separator: "\n")
        content += "\n\n--- Debug Log (\(diagnostics.lines.count) lines) ---\n"
        content += diagnostics.lines.joined(separator: "\n")
        content += "\n\n--- Telemetry (device-core events) ---\n"
        let telemetry = V3TelemetryStore.shared.telemetryContent()
        if telemetry.isEmpty {
            content += "(telemetry opt-in: \(V3TelemetryStore.shared.isOptedIn ? "enabled, no events" : "disabled"))\n"
        } else {
            content += telemetry
        }
        content += "\n"

        let panel = NSSavePanel()
        panel.title = "Export Diagnostics"
        panel.nameFieldStringValue = "GeoTeleport_Diagnostics_\(formattedDateForFilename()).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        panel.begin { response in
            if response == .OK, let url = panel.url {
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                    self.log("[EXPORT] Diagnostics saved to \(url.lastPathComponent)")
                } catch {
                    self.log("[EXPORT] Failed to save: \(error.localizedDescription)")
                }
            }
        }
    }

    private func formattedDateForFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    private func currentSessionState() -> DeviceSessionState {
        V3AppModel.deriveSessionState(
            availability: appModel.backendAvailability,
            capabilities: appModel.backendCapabilities,
            snapshot: appModel.deviceSnapshot,
            tunnelState: appModel.tunnelState,
            backendTrack: appModel.backendTrack,
            deviceAssessment: appModel.deviceAssessment,
            tunnelAssessment: appModel.tunnelAssessment
        )
    }

    private func currentConnectionHealth() -> ConnectionHealth {
        V3AppModel.deriveConnectionHealth(
            for: currentSessionState(),
            backendTrack: appModel.backendTrack,
            availabilityAssessment: appModel.availabilityAssessment,
            deviceAssessment: appModel.deviceAssessment,
            tunnelAssessment: appModel.tunnelAssessment
        )
    }

    private func logSessionTransitionIfNeeded(
        previousState: DeviceSessionState,
        previousHealth: ConnectionHealth
    ) {
        let nextState = currentSessionState()
        let nextHealth = currentConnectionHealth()
        let previousBlocker = V3AppModel.deriveSessionBlocker(
            for: previousState,
            backendTrack: appModel.backendTrack,
            availabilityAssessment: appModel.availabilityAssessment,
            deviceAssessment: appModel.deviceAssessment,
            tunnelAssessment: appModel.tunnelAssessment
        )
        let nextBlocker = V3AppModel.deriveSessionBlocker(
            for: nextState,
            backendTrack: appModel.backendTrack,
            availabilityAssessment: appModel.availabilityAssessment,
            deviceAssessment: appModel.deviceAssessment,
            tunnelAssessment: appModel.tunnelAssessment
        )

        if nextState != previousState {
            log("[SESSION] \(previousState.title) -> \(nextState.title)")
            logSessionDiagnostics(state: nextState, health: nextHealth)
        }

        if nextHealth != previousHealth {
            log("[HEALTH] \(previousHealth.label) -> \(nextHealth.label)")
            if nextState == previousState {
                logSessionDiagnostics(state: nextState, health: nextHealth)
            }
        }

        if nextBlocker != previousBlocker {
            log("[BLOCKER] \(previousBlocker.title) -> \(nextBlocker.title)")
            if nextState == previousState, nextHealth == previousHealth {
                logSessionDiagnostics(state: nextState, health: nextHealth)
            }
        }
    }

    private func logSessionDiagnostics(
        state: DeviceSessionState? = nil,
        health: ConnectionHealth? = nil
    ) {
        let resolvedState = state ?? currentSessionState()
        let resolvedHealth = health ?? currentConnectionHealth()
        let resolvedBlocker = V3AppModel.deriveSessionBlocker(
            for: resolvedState,
            backendTrack: appModel.backendTrack,
            availabilityAssessment: appModel.availabilityAssessment,
            deviceAssessment: appModel.deviceAssessment,
            tunnelAssessment: appModel.tunnelAssessment
        )
        let readinessGate = V3AppModel.deriveReadinessGate(
            availability: appModel.backendAvailability,
            sessionState: resolvedState,
            blocker: resolvedBlocker,
            backendTrack: appModel.backendTrack,
            capabilities: appModel.backendCapabilities,
            availabilityAssessment: appModel.availabilityAssessment,
            deviceAssessment: appModel.deviceAssessment,
            tunnelAssessment: appModel.tunnelAssessment
        )
        let lines = V3SessionDiagnostics.diagnosticLines(
            backendTrack: appModel.backendTrack,
            availability: appModel.backendAvailability,
            capabilities: appModel.backendCapabilities,
            snapshot: appModel.deviceSnapshot,
            tunnelState: appModel.tunnelState,
            sessionState: resolvedState,
            health: resolvedHealth,
            blocker: resolvedBlocker,
            readinessGate: readinessGate,
            deviceProbeFocus: appModel.effectiveDeviceProbeFocus,
            availabilityAssessment: appModel.availabilityAssessment,
            deviceAssessment: appModel.deviceAssessment,
            tunnelAssessment: appModel.tunnelAssessment,
            lastLocationCommandRecord: appModel.lastLocationCommandRecord
        )
        for line in lines {
            log(line)
        }
    }

    private func applyDeviceSnapshot(_ snapshot: DeviceSnapshot) {
        let previousSessionState = currentSessionState()
        let previousHealth = currentConnectionHealth()
        let previousSnapshot = self.appModel.deviceSnapshot
        let becameConnected = snapshot.isConnected && !previousSnapshot.isConnected
        if snapshot.isConnected != previousSnapshot.isConnected {
            self.log("[HARDWARE] I/O Registry Update:")
            if snapshot.isConnected {
                self.log("[HARDWARE] + DEVICE ATTACHED (\(snapshot.displayName))")
                if let source = snapshot.probeSource, !source.isEmpty {
                    self.log("[HARDWARE] Probe source: \(source)")
                }
            } else {
                self.log("[HARDWARE] - DEVICE REMOVED")
            }
        }

        self.appModel.deviceSnapshot = snapshot

        let version = snapshot.iosVersion ?? ""
        let major = snapshot.iosMajorVersion ?? 0

        if version != (previousSnapshot.iosVersion ?? ""), !version.isEmpty {
            self.log("[DEVICE] iOS \(version) detected")
            if major >= 17 {
                self.log("[DEVICE] Tunnel requirement is now tracked through device-agent session state")
            }
        }

        if becameConnected && self.isEnvironmentReady && version.isEmpty {
            self.log("[DEVICE] Connected, waiting for version info...")
        }

        logSessionTransitionIfNeeded(
            previousState: previousSessionState,
            previousHealth: previousHealth
        )
    }

    private func applyTunnelState(_ tunnelState: TunnelState) {
        let previousSessionState = currentSessionState()
        let previousHealth = currentConnectionHealth()
        let previousTunnelState = self.appModel.tunnelState
        let running = tunnelState == .active
        if tunnelState != previousTunnelState {
            switch tunnelState {
            case .active:
                self.log("[TUNNELD] ✅ Detected running")
            case .starting:
                self.log("[TUNNELD] ⏳ Product-owned tunnel is starting")
            case .failed:
                self.log("[TUNNELD] ❌ Product-owned tunnel failed")
            case .requiredInactive, .notRequired:
                self.log("[TUNNELD] ⚠️ Not running")
            }
            if running, case .working(let title, _) = self.statusStore.status,
               title.lowercased().contains("tunnel") {
                self.setStatus(.idle)
            }
        }
        self.appModel.tunnelState = tunnelState
        logSessionTransitionIfNeeded(
            previousState: previousSessionState,
            previousHealth: previousHealth
        )
    }

    private func applyNoPythonAssessment(
        deviceAssessment: DeviceAgentSessionAssessment?,
        tunnelAssessment: DeviceAgentSessionAssessment?
    ) {
        appModel.deviceAssessment = deviceAssessment
        appModel.tunnelAssessment = tunnelAssessment
    }

    private func performInitialRefresh() {
        refreshForCurrentGate(trigger: "startup", isManual: false)
    }

    private func performScheduledRefresh() {
        refreshForCurrentGate(trigger: "timer", isManual: false)
    }

    private func manualRefresh() {
        refreshForCurrentGate(trigger: "manual", isManual: true)
    }

    private func refreshForCurrentGate(trigger: String, isManual: Bool) {
        if isWorking { return }

        if shouldProbeBackendBootstrap {
            if !isScanningDeps {
                if isManual {
                    log("[REFRESH] \(trigger.uppercased()) -> probing backend bootstrap")
                }
                findDependency()
            }
            return
        }

        if isManual {
            log("[REFRESH] \(trigger.uppercased()) -> \(appModel.manualRefreshLogSummary)")
        }
        refreshDeviceState(scope: appModel.effectiveRefreshScope, deviceFocus: appModel.effectiveDeviceProbeFocus)
    }

    private var shouldProbeBackendBootstrap: Bool {
        if appModel.backendTrack == .noPythonStub {
            return appModel.availabilityAssessment == nil ||
                appModel.readinessGate == .backendBootstrap ||
                appModel.backendAvailability.isUnavailable
        }
        return !appModel.isEnvironmentReady
    }

    private func refreshDeviceState(
        scope: SessionRefreshScope = .full,
        deviceFocus: DeviceProbeFocus = .attachment
    ) {
        if isWorking || isScanningDeps { return }
        let existingSnapshot = appModel.deviceSnapshot
        let existingDeviceAssessment = appModel.deviceAssessment
        let existingTunnelState = appModel.tunnelState
        let existingTunnelAssessment = appModel.tunnelAssessment
        DispatchQueue.global(qos: .background).async {
            let result = self.runtimeCoordinator.refreshDeviceState(
                scope: scope,
                deviceFocus: deviceFocus,
                existingSnapshot: existingSnapshot,
                existingDeviceAssessment: existingDeviceAssessment,
                existingTunnelState: existingTunnelState,
                existingTunnelAssessment: existingTunnelAssessment
            )
            DispatchQueue.main.async {
                self.applyNoPythonAssessment(
                    deviceAssessment: result.deviceAssessment,
                    tunnelAssessment: result.tunnelAssessment
                )
                self.applyDeviceSnapshot(result.snapshot)
                self.applyTunnelState(result.tunnelState)
            }
            for line in result.logLines {
                self.log(line)
            }
        }
    }

    // 依赖扫描：通过 backend 适配层探测现有 CLI 可用性
    func findDependency() {
        if isScanningDeps { return }
        isScanningDeps = true
        setStatus(.working("Probing \(activeBackendTrack.displayName)…", nil))

            DispatchQueue.global(qos: .userInitiated).async {
            let result = self.runtimeCoordinator.refreshDependencies()
            var nextRefreshScope: SessionRefreshScope?
            var nextDeviceFocus: DeviceProbeFocus?

            DispatchQueue.main.async {
                let previousSessionState = self.currentSessionState()
                let previousHealth = self.currentConnectionHealth()
                self.appModel.backendAvailability = result.availability
                self.appModel.backendCapabilities = result.capabilities
                self.appModel.availabilityAssessment = result.availabilityAssessment
                self.isScanningDeps = false
                nextRefreshScope = self.appModel.effectiveRefreshScope
                nextDeviceFocus = self.appModel.effectiveDeviceProbeFocus
                self.logSessionTransitionIfNeeded(
                    previousState: previousSessionState,
                    previousHealth: previousHealth
                )
            }

            for line in result.logLines {
                self.log(line)
            }

            if result.canRefreshDeviceState {
                DispatchQueue.main.async {
                    self.refreshDeviceState(
                        scope: nextRefreshScope ?? self.appModel.effectiveRefreshScope,
                        deviceFocus: nextDeviceFocus ?? self.appModel.effectiveDeviceProbeFocus
                    )
                }
            }
            self.setStatus(.idle)
        }
    }

    private func switchBackend(to track: BackendTrack) {
        guard track != activeBackendTrack else { return }
        backendTrackRaw = track.rawValue
        appModel.backendTrack = track
        appModel.resetRuntimeState()
        diagnostics.append("[BACKEND] Switched to \(track.displayName)")
        setStatus(.idle)
        performInitialRefresh()
    }

    func searchCityOnly() {
        let query = citySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        setStatus(.working("Looking up \"\(query)\"…", nil))
        log("------------------------------------------")
        log("[GEO] Processing User Query: '\(query)'")
        log("[GEO] Querying geocoder...")
        Task {
            do {
                let placemarks = try await CLGeocoder().geocodeAddressString(query)
                guard let placemark = placemarks.first, let location = placemark.location else {
                    self.log("[GEO] ❌ No results")
                    self.setStatus(.failure("Couldn't find \"\(query)\"", "Check spelling or try a nearby landmark."))
                    return
                }
                let coord = location.coordinate
                await MainActor.run {
                    self.region.center = coord
                    self.region.span = MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                    self.latitude = String(format: "%.6f", coord.latitude)
                    self.longitude = String(format: "%.6f", coord.longitude)
                }
                let name = placemark.name ?? placemark.locality ?? query
                self.log("[GEO] ✅ Result: \(name)")
                self.log("[GEO] Coords: \(String(format: "%.6f", coord.latitude)), \(String(format: "%.6f", coord.longitude))")
                self.setStatus(.idle)
            } catch {
                self.log("[GEO] ❌ ERROR: \(error.localizedDescription)")
                self.setStatus(.failure("Search failed", error.localizedDescription))
            }
        }
    }

    func teleport() {
        startLocationAction(.set)
    }

    func clearSimulatedLocation() {
        startLocationAction(.clear)
    }

    private func startLocationAction(_ action: LocationActionKind) {
        if !isEnvironmentReady {
            log(action.backendRescanLog)
            findDependency()
            return
        }
        if needsTunneld {
            log(action.tunnelAbortLog(deviceIOSVersion: deviceIOSVersion))
            setStatus(.failure(
                "iOS \(deviceIOSVersion) tunnel isn't running",
                action.tunnelAbortSubtitle(deviceIOSVersion: deviceIOSVersion)
            ))
            return
        }

        if action.needsValidCoordinates {
            guard coordsValid else {
                log(action.invalidCoordinatesLog)
                setStatus(action.invalidCoordinatesFailure)
                return
            }
        } else {
            guard isDeviceConnected else {
                log(action.missingDeviceLog)
                setStatus(action.missingDeviceFailure)
                return
            }
        }

        setStatus(action.resolvedWorkingStatus(latitude: latitude, longitude: longitude))
        log("------------------------------------------")
        log(action.actionLog)
        for line in action.kernelLogs(latitude: latitude, longitude: longitude) {
            log(line)
        }

        switch action {
        case .set:
            executeTeleport()
        case .clear:
            executeClearLocation()
        }
    }

    func executeTeleport() {
        let backend = activeBackend
        let request = TeleportRequest(latitude: latitude, longitude: longitude)
        performLocationCommand(
            action: .set,
            backend: backend,
            ) {
            backend.setLocation(request)
        }
    }

    func executeClearLocation() {
        let backend = activeBackend
        performLocationCommand(
            action: .clear,
            backend: backend,
        ) {
            backend.clearLocation()
        }
    }

    private func performLocationCommand(
        action: LocationActionKind,
        backend: DeviceBackend,
        command: @escaping () -> Result<LocationCommandExecution, BackendFailure>
    ) {
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            self.log("[SYS] Executing \(action.operationLabel) via device-agent transport...")

            if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
                Thread.sleep(forTimeInterval: 0.5)
                self.log(action.previewSuccessLog)
                let successTitle = action.successTitle(latitude: self.latitude, longitude: self.longitude)
                let successSubtitle = action.successSubtitle(latitude: self.latitude, longitude: self.longitude)
                let record = LocationCommandRecord(
                    action: action.recordAction,
                    backendTrack: backend.track,
                    outcome: .succeeded,
                    summary: successTitle,
                    detail: successSubtitle,
                    exitCode: 0,
                    stdout: nil,
                    stderr: nil,
                    diagnosticLines: []
                )
                self.setStatus(.success(successTitle, successSubtitle))
                DispatchQueue.main.async {
                    self.appModel.lastLocationCommandRecord = record
                    self.logSessionDiagnostics()
                    self.isWorking = false
                }
                return
            }

            let result = command()
            let execution = self.interpretLocationCommandResult(
                action: action,
                backendTrack: backend.track,
                result,
                successTitle: action.successTitle(latitude: self.latitude, longitude: self.longitude),
                successSubtitle: action.successSubtitle(latitude: self.latitude, longitude: self.longitude)
            )
            for line in execution.logLines {
                self.log(line)
            }
            DispatchQueue.main.async {
                self.appModel.lastLocationCommandRecord = execution.record
                self.logSessionDiagnostics()
                self.isWorking = false
            }
            self.setStatus(execution.status)
            self.log("------------------------------------------")
        }
    }

    private func interpretLocationCommandResult(
        action: LocationActionKind,
        backendTrack: BackendTrack,
        _ result: Result<LocationCommandExecution, BackendFailure>,
        successTitle: String,
        successSubtitle: String?
    ) -> (logLines: [String], status: AppStatus, record: LocationCommandRecord) {
        switch result {
        case .success(let execution):
            let response = execution.response
            var logLines: [String] = execution.diagnosticLines
            logLines.append(response.stdout.isEmpty ? "[STDOUT] (Empty)" : "[STDOUT] >> \(response.stdout)")
            logLines.append(response.stderr.isEmpty ? "[STDERR] (Empty)" : "[STDERR] >> \(response.stderr)")
            logLines.append("[SYS] Process Exited. Code: \(response.exitCode)")

            let stderrLowercased = response.stderr.lowercased()
            let stderrLooksBad = stderrLowercased.contains("traceback")
                || stderrLowercased.contains("error:")
                || stderrLowercased.contains("failed")
                || stderrLowercased.contains("exception")

            if response.exitCode == 0 && !stderrLooksBad {
                logLines.append("[RESULT] ✅ SUCCESS: Command completed.")
                return (
                    logLines,
                    .success(successTitle, successSubtitle),
                    LocationCommandRecord(
                        action: action.recordAction,
                        backendTrack: backendTrack,
                        outcome: .succeeded,
                        summary: successTitle,
                        detail: successSubtitle,
                        exitCode: response.exitCode,
                        stdout: response.stdout.isEmpty ? nil : response.stdout,
                        stderr: response.stderr.isEmpty ? nil : response.stderr,
                        diagnosticLines: execution.diagnosticLines
                    )
                )
            }

            let reason = !response.stderr.isEmpty
                ? response.stderr
                : (!response.stdout.isEmpty ? response.stdout : "Process exited with code \(response.exitCode)")
            logLines.append("[RESULT] ❌ FAILURE: Command returned a non-clean result.")
            return (
                logLines,
                .failure(action.failureTitle, reason),
                LocationCommandRecord(
                    action: action.recordAction,
                    backendTrack: backendTrack,
                    outcome: .failed,
                    summary: action.failureTitle,
                    detail: reason,
                    exitCode: response.exitCode,
                    stdout: response.stdout.isEmpty ? nil : response.stdout,
                    stderr: response.stderr.isEmpty ? nil : response.stderr,
                    diagnosticLines: execution.diagnosticLines
                )
            )
        case .failure(let failure):
            let message: String
            switch failure {
            case .unavailable(let value), .invalidRequest(let value), .executionFailed(let value):
                message = value
            }
            return (
                ["[EXCEPTION] \(String(describing: failure))"],
                .failure(action.failureTitle, message),
                LocationCommandRecord(
                    action: action.recordAction,
                    backendTrack: backendTrack,
                    outcome: .failed,
                    summary: action.failureTitle,
                    detail: message,
                    exitCode: nil,
                    stdout: nil,
                    stderr: nil,
                    diagnosticLines: []
                )
            )
        }
    }

    // MARK: - 辅助组件
    func TechInput(title: String, text: Binding<String>, valid: Bool) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .leading)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.thickMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(valid ? Color.white.opacity(0.10) : alertRed.opacity(0.85), lineWidth: 1)
                )
        }
    }

    func LocationButton(flag: String, name: String, lat: String, lon: String, color: Color) -> some View {
        Button(action: {
            if let lLat = Double(lat), let lLon = Double(lon) {
                self.region.center = CLLocationCoordinate2D(latitude: lLat, longitude: lLon)
                self.region.span = MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                self.latitude = lat; self.longitude = lon
                self.log("[USER] Selected Preset: \(name)")
            }
        }) {
            VStack(spacing: 3) {
                Text(flag)
                    .font(.system(size: 20))
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.55), color.opacity(0.28)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.regularMaterial)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.18), Color.clear],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(color.opacity(0.50), lineWidth: 1)
            )
            .shadow(color: color.opacity(0.18), radius: 5, x: 0, y: 2)
        }.buttonStyle(.plain)
    }
}
