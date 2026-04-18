import SwiftUI
import MapKit
import CoreLocation
import Combine
import AppKit

// MARK: - V9.3 · Single-message status card · Collapsible debug log

enum AppStatus: Equatable {
    case idle
    case working(String, String?)
    case success(String, String?)
    case failure(String, String?)
}

struct ContentView: View {
    // 坐标（持久化）
    @AppStorage("latitude") private var latitude: String = "25.185317"
    @AppStorage("longitude") private var longitude: String = "55.281516"
    @AppStorage("citySearchText") private var citySearchText: String = ""

    // 运行时状态
    @State private var consoleLogs: [String] = [
        ">>> KERNEL BOOT SEQUENCE STARTED...",
        ">>> INITIALIZING LOGGING SUBSYSTEM..."
    ]
    private let maxLogLines = 500

    @State private var isWorking: Bool = false
    @State private var isDeviceConnected: Bool = false
    @State private var connectionStatusText: String = "INITIALIZING..."

    @State private var detectedCliPath: String = ""
    @State private var isEnvironmentReady: Bool = false
    @State private var isScanningDeps: Bool = false

    // iOS 版本（用于 iOS 17+ tunneld 提示）
    @State private var deviceIOSVersion: String = ""
    @State private var deviceIOSMajor: Int = 0
    @State private var tunneldHintDismissed: Bool = false
    @State private var tunneldRunning: Bool = false

    // iOS 17+ 未启 tunneld → 拒绝传送（否则 pymobiledevice3 会假成功）
    private var needsTunneld: Bool { deviceIOSMajor >= 17 && !tunneldRunning }

    // 组装 tunneld 命令：优先用已检测到的可执行文件绝对路径，避免多 Python
    // 解释器环境下 `python3 -m pymobiledevice3` 找不到模块的问题
    private var tunneldCommand: String {
        if !detectedCliPath.isEmpty {
            return "sudo \(detectedCliPath) remote tunneld"
        }
        return "sudo python3 -m pymobiledevice3 remote tunneld"
    }

    // 用户可见的单条状态
    @State private var status: AppStatus = .idle
    @State private var showDebugLog: Bool = false
    @State private var successToken: Int = 0

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 25.185317, longitude: 55.281516),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )

    // 主题
    let accentBlue = Color(red: 0.2, green: 0.62, blue: 1.0)
    let terminalGreen = Color(red: 0.25, green: 0.9, blue: 0.5)
    let alertRed = Color(red: 1.0, green: 0.35, blue: 0.35)

    let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.09, green: 0.10, blue: 0.16),
                    Color(red: 0.04, green: 0.05, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .edgesIgnoringSafeArea(.all)
            .overlay(
                Circle()
                    .fill(accentBlue.opacity(0.25))
                    .frame(width: 320, height: 320)
                    .blur(radius: 120)
                    .offset(x: -120, y: -260)
                    .allowsHitTesting(false)
            )
            .overlay(
                Circle()
                    .fill(Color.purple.opacity(0.22))
                    .frame(width: 280, height: 280)
                    .blur(radius: 120)
                    .offset(x: 140, y: 280)
                    .allowsHitTesting(false)
            )

            VStack(spacing: 10) {

                // 1. 顶部状态栏
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: isDeviceConnected ? "iphone.gen3" : "cable.connector.slash")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(isDeviceConnected ? terminalGreen : alertRed)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(isDeviceConnected ? "HARDWARE CONNECTED" : "NO USB CONNECTION")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(isDeviceConnected ? terminalGreen : alertRed)
                            Text(connectionStatusText)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(glassCapsule(tint: isDeviceConnected ? terminalGreen : alertRed))

                    Spacer()

                    // 环境状态胶囊 + Rescan 按钮
                    HStack(spacing: 6) {
                        Circle()
                            .fill(isEnvironmentReady ? terminalGreen : alertRed)
                            .frame(width: 7, height: 7)
                        Text(isEnvironmentReady ? "ENV: READY" : "ENV: MISSING")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.secondary)
                        Button(action: findDependency) {
                            Image(systemName: isScanningDeps ? "hourglass" : "arrow.clockwise")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(isScanningDeps)
                        .help("Rescan for pymobiledevice3")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(glassCapsule(tint: .white.opacity(0.25)))
                }
                .padding(.horizontal, 15)
                .padding(.top, 12)

                // 1b. iOS 17+ tunneld 提示横幅（tunneld 跑起来后自动收起）
                if isDeviceConnected && deviceIOSMajor >= 17 && !tunneldRunning && !tunneldHintDismissed {
                    tunneldBanner
                        .padding(.horizontal, 15)
                }

                // 2. 地图区 — 占据主要交互空间，随窗口高度自适应
                ZStack {
                    NativeMapView(region: $region) { newCenter in
                        self.latitude = String(format: "%.6f", newCenter.latitude)
                        self.longitude = String(format: "%.6f", newCenter.longitude)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.40), radius: 18, x: 0, y: 8)

                    // 中心准星 —— 带阴影 + 描边，任何底图上都清晰可见
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

                    // 左下角当前坐标 HUD —— 用户拖图时实时反馈
                    VStack {
                        Spacer()
                        HStack {
                            HStack(spacing: 6) {
                                Image(systemName: "location.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(accentBlue)
                                Text("\(latitude), \(longitude)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(.primary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(.regularMaterial)
                                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
                            )
                            Spacer()
                        }
                        .padding(10)
                    }
                    .allowsHitTesting(false)
                }
                .frame(minHeight: showDebugLog ? 240 : 320, maxHeight: .infinity)
                .layoutPriority(1)
                .padding(.horizontal, 15)

                // 3. 搜索栏
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
                .background(glassPanel(cornerRadius: 12))
                .padding(.horizontal, 15)

                // 4. 坐标栏
                HStack(spacing: 10) {
                    TechInput(title: "LAT", text: $latitude, valid: latValue != nil)
                    TechInput(title: "LON", text: $longitude, valid: lonValue != nil)
                }
                .padding(.horizontal, 15)

                // 5. 快捷按钮
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    LocationButton(flag: "🇦🇪", name: "DUBAI",      lat: "25.185317", lon: "55.281516",  color: .orange)
                    LocationButton(flag: "🇦🇪", name: "Abu Dhabi",  lat: "24.340142", lon: "54.518667",  color: .blue)
                    LocationButton(flag: "🇻🇳", name: "Hanoi",      lat: "20.992498", lon: "105.944606", color: .purple)
                    LocationButton(flag: "🇯🇵", name: "Tokyo",      lat: "35.6895",   lon: "139.6917",   color: .pink)
                    LocationButton(flag: "🇺🇸", name: "New York",   lat: "40.7128",   lon: "-74.0060",   color: .cyan)
                    LocationButton(flag: "🇬🇧", name: "London",     lat: "51.5074",   lon: "-0.1278",    color: .green)
                    LocationButton(flag: "🇫🇷", name: "Paris",      lat: "48.8566",   lon: "2.3522",     color: .indigo)
                    LocationButton(flag: "🇨🇳", name: "Shenzhen",   lat: "22.5431",   lon: "114.0579",   color: .red)
                }
                .padding(.horizontal, 15)

                // 6. 执行按钮
                Button(action: teleport) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: (isDeviceConnected && isEnvironmentReady && coordsValid)
                                        ? [Color.blue.opacity(0.95), Color.purple.opacity(0.95)]
                                        : [Color.gray.opacity(0.55), Color.gray.opacity(0.35)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            )
                            .shadow(color: Color.blue.opacity((isDeviceConnected && isEnvironmentReady && coordsValid) ? 0.35 : 0), radius: 12, x: 0, y: 4)

                        HStack(spacing: 6) {
                            if !isDeviceConnected || !isEnvironmentReady || !coordsValid || needsTunneld {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                            }
                            Text(buttonTitle())
                                .font(.system(size: 13, weight: .bold, design: .monospaced))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(height: 40)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 15)
                .disabled(isWorking || !isDeviceConnected || !isEnvironmentReady || !coordsValid || needsTunneld)

                // 7. 状态卡（用户只看这一条）
                statusCard
                    .padding(.horizontal, 15)

                // 8. 可选：Debug 日志（默认折叠, 固定高度 180, 内部滚动)
                if showDebugLog {
                    debugLogPanel
                        .frame(height: 180)
                        .padding(.horizontal, 15)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 12)
        }
        .frame(minWidth: 540, minHeight: 720)
        .onReceive(timer) { _ in
            checkUSBConnection()
            checkTunneld()
        }
        .onAppear {
            logSystemInfo()
            findDependency()
            checkUSBConnection()
            checkTunneld()
        }
    }

    // MARK: - Glass helpers

    func glassPanel(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
    }

    func glassCapsule(tint: Color) -> some View {
        Capsule()
            .fill(.regularMaterial)
            .overlay(
                Capsule().fill(tint.opacity(0.12))
            )
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1)
            )
    }

    // MARK: - Status card

    private struct StatusDisplay {
        let title: String
        let subtitle: String?
        let icon: String
        let tint: Color
        let showSpinner: Bool
    }

    private var statusDisplay: StatusDisplay {
        switch status {
        case .idle:
            if !isEnvironmentReady {
                return StatusDisplay(
                    title: "pymobiledevice3 is not installed",
                    subtitle: "Run `pip3 install pymobiledevice3` in Terminal, then press Rescan.",
                    icon: "wrench.adjustable",
                    tint: alertRed,
                    showSpinner: false)
            }
            if !isDeviceConnected {
                return StatusDisplay(
                    title: "Connect your iPhone",
                    subtitle: "Plug in via USB and trust this Mac on the device.",
                    icon: "iphone.gen3.slash",
                    tint: alertRed,
                    showSpinner: false)
            }
            if needsTunneld {
                return StatusDisplay(
                    title: "iOS \(deviceIOSVersion) needs the tunnel first",
                    subtitle: "Click Launch in the yellow banner — or run the command shown there in Terminal.",
                    icon: "lock.shield.fill",
                    tint: Color(red: 1.0, green: 0.80, blue: 0.30),
                    showSpinner: false)
            }
            if !coordsValid {
                return StatusDisplay(
                    title: "Invalid coordinates",
                    subtitle: "Latitude must be −90…90, longitude must be −180…180.",
                    icon: "exclamationmark.triangle.fill",
                    tint: Color(red: 1.0, green: 0.80, blue: 0.30),
                    showSpinner: false)
            }
            return StatusDisplay(
                title: "Ready to teleport",
                subtitle: "Drag the pin, search a city, or tap a preset.",
                icon: "checkmark.seal.fill",
                tint: terminalGreen,
                showSpinner: false)
        case .working(let t, let s):
            return StatusDisplay(title: t, subtitle: s, icon: "bolt.circle.fill", tint: accentBlue, showSpinner: true)
        case .success(let t, let s):
            return StatusDisplay(title: t, subtitle: s, icon: "checkmark.circle.fill", tint: terminalGreen, showSpinner: false)
        case .failure(let t, let s):
            return StatusDisplay(title: t, subtitle: s, icon: "xmark.octagon.fill", tint: alertRed, showSpinner: false)
        }
    }

    private var statusCard: some View {
        let d = statusDisplay
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
                Text("\(consoleLogs.count)/\(maxLogLines)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                Button(action: { consoleLogs = [">>> LOG CLEARED."] }) {
                    Image(systemName: "trash").font(.system(size: 10)).foregroundColor(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(consoleLogs.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(terminalGreen)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                        .id("logBottom")
                }
                .onChange(of: consoleLogs.count) { _, _ in
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
            withAnimation(.easeInOut(duration: 0.18)) { self.status = s }
            if case .success = s {
                self.successToken &+= 1
                let token = self.successToken
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if self.successToken == token, case .success = self.status {
                        withAnimation(.easeInOut(duration: 0.25)) { self.status = .idle }
                    }
                }
            }
        }
    }

    // 把 stderr/stdout 压成一句人话；识别最常见的几类错误
    private func humanize(stderr: String, stdout: String, exit: Int32) -> String {
        let combined = (stderr + "\n" + stdout).lowercased()
        if combined.contains("casefold") || combined.contains("tunnelprotocol")
            || (combined.contains("attributeerror") && combined.contains("click")) {
            return "pymobiledevice3 install is broken (Click/Typer version mismatch). Reinstall via: pipx install pymobiledevice3"
        }
        if combined.contains("no module named") && combined.contains("pymobiledevice3") {
            return "Python can't find pymobiledevice3. Reinstall cleanly: pipx install pymobiledevice3"
        }
        if combined.contains("traceback") && combined.contains("pymobiledevice3") {
            return "pymobiledevice3 crashed with a Python traceback — likely broken install. Try: pipx install pymobiledevice3"
        }
        if combined.contains("tunneld") || combined.contains("rsd") || combined.contains("no developer mode") {
            return "iOS 17+ tunnel isn't running. Start it in Terminal first."
        }
        if combined.contains("not paired") || combined.contains("pairing") {
            return "Device isn't paired — trust this Mac on the iPhone."
        }
        if combined.contains("permission") || combined.contains("denied") {
            return "Permission denied — check Developer Mode and pairing."
        }
        if combined.contains("no device") || combined.contains("not connected") {
            return "Device disappeared during injection."
        }
        let first = stderr
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !first.isEmpty {
            return first.count > 120 ? String(first.prefix(117)) + "…" : first
        }
        return "Exit code \(exit)."
    }

    // iOS 17+ tunneld 提示横幅
    private var tunneldBanner: some View {
        let cmd = tunneldCommand
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(.yellow)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("iOS \(deviceIOSVersion) detected — tunneld required")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                Text("In Terminal, run this once and keep it open:")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                HStack(spacing: 6) {
                    Text(cmd)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(terminalGreen)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(cmd, forType: .string)
                        log("[HINT] Copied tunneld command to clipboard")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(accentBlue)
                    }
                    .buttonStyle(.plain)
                    .help("Copy command")
                    Button {
                        launchTunneldInTerminal(cmd: cmd)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "terminal.fill").font(.system(size: 10))
                            Text("Launch").font(.system(size: 9, weight: .semibold, design: .monospaced))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(accentBlue.opacity(0.85)))
                    }
                    .buttonStyle(.plain)
                    .help("Open Terminal and run the command")
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                )
            }
            Spacer()
            Button {
                tunneldHintDismissed = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.yellow.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.yellow.opacity(0.45), lineWidth: 1)
                )
        )
    }

    // 一键打开 Terminal 并运行 tunneld 命令（只差用户输 sudo 密码）
    private func launchTunneldInTerminal(cmd: String) {
        // AppleScript 字符串中 \" 要二次转义
        let escaped = cmd.replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        var err: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&err)
        }
        if let err = err {
            log("[TERMINAL] ❌ Failed to launch: \(err[NSAppleScript.errorMessage] ?? "")")
            setStatus(.failure("Couldn't open Terminal", "Run the command manually — it's copied to your clipboard."))
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(cmd, forType: .string)
        } else {
            log("[TERMINAL] ✅ Launched Terminal with tunneld command")
            setStatus(.working("Waiting for tunneld…", "Enter your Mac password in the Terminal window that just opened."))

            // 12 秒看门狗：如果这期间 tunneld 始终没起来，很可能是 pymobiledevice3
            // 自己在 Terminal 里崩了（典型：Click/Typer 不兼容抛 AttributeError）
            DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
                if !self.tunneldRunning,
                   case .working(let title, _) = self.status,
                   title.lowercased().contains("tunneld") {
                    self.log("[TERMINAL] ⚠️ 12s elapsed, tunneld still down — likely install issue")
                    self.setStatus(.failure(
                        "Tunneld didn't start",
                        "Check the Terminal window. If you see AttributeError / Traceback, pymobiledevice3 is broken — fix with: pipx install pymobiledevice3"
                    ))
                }
            }
        }
    }

    // 查询 iOS 版本；仅在 CLI 已就位且设备连接时有意义
    private func fetchDeviceIOSVersion() {
        guard !detectedCliPath.isEmpty else { return }
        DispatchQueue.global(qos: .background).async {
            guard let out = self.runCaptured(self.detectedCliPath, args: ["lockdown", "info"]) else { return }
            // ProductVersion: "17.2.1" 或 ProductVersion = "26.0" 或 "ProductVersion": "26.0"
            let pattern = #"ProductVersion["\s:=]+["']?([0-9]+(?:\.[0-9]+)*)"#
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
                  m.numberOfRanges >= 2,
                  let r = Range(m.range(at: 1), in: out) else { return }
            let version = String(out[r])
            let major = Int(version.split(separator: ".").first ?? "0") ?? 0
            DispatchQueue.main.async {
                if self.deviceIOSVersion != version {
                    self.log("[DEVICE] iOS \(version) detected")
                    if major >= 17 {
                        self.log("[DEVICE] ⚠️ iOS 17+ requires tunneld — see banner")
                    }
                }
                self.deviceIOSVersion = version
                self.deviceIOSMajor = major
            }
        }
    }

    // MARK: - 逻辑

    func buttonTitle() -> String {
        if isWorking { return "EXECUTING..." }
        if !isEnvironmentReady { return "ERROR: TOOL NOT FOUND" }
        if !isDeviceConnected { return "WAITING FOR USB..." }
        if needsTunneld { return "START TUNNELD FIRST" }
        if !coordsValid { return "INVALID COORDS" }
        return ">>> CONFIRM & JUMP <<<"
    }

    func log(_ msg: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] \(msg)"
        DispatchQueue.main.async {
            self.consoleLogs.append(line)
            if self.consoleLogs.count > self.maxLogLines {
                self.consoleLogs.removeFirst(self.consoleLogs.count - self.maxLogLines)
            }
        }
    }

    func logSystemInfo() {
        log("[SYS] Getting Host Info...")
        let host = ProcessInfo.processInfo.hostName
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        log("[SYS] Host: \(host)")
        log("[SYS] OS: \(os)")
    }

    // 依赖扫描：先查硬编码候选路径，再用 `which -a` 兜底
    func findDependency() {
        if isScanningDeps { return }
        isScanningDeps = true
        setStatus(.working("Looking for pymobiledevice3…", nil))
        log("------------------------------------------")
        log("[INIT] Starting Dependency Scan...")

        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            let home = NSHomeDirectory()

            var candidates = [
                "/opt/homebrew/bin/pymobiledevice3",
                "/usr/local/bin/pymobiledevice3",
                "\(home)/Library/Python/3.9/bin/pymobiledevice3",
                "\(home)/Library/Python/3.10/bin/pymobiledevice3",
                "\(home)/Library/Python/3.11/bin/pymobiledevice3",
                "\(home)/Library/Python/3.12/bin/pymobiledevice3",
                "\(home)/Library/Python/3.13/bin/pymobiledevice3",
                "/usr/bin/pymobiledevice3"
            ]

            // which -a 兜底
            if let whichOutput = self.runCaptured("/usr/bin/which", args: ["-a", "pymobiledevice3"]) {
                let extra = whichOutput.split(separator: "\n").map { String($0) }
                for p in extra where !candidates.contains(p) { candidates.append(p) }
                if !extra.isEmpty { self.log("[SCAN] which -a returned \(extra.count) path(s)") }
            }

            for path in candidates {
                self.log("[SCAN] Checking: \(path)")
                if fileManager.fileExists(atPath: path) {
                    DispatchQueue.main.async {
                        self.detectedCliPath = path
                        self.isEnvironmentReady = true
                        self.isScanningDeps = false
                        // 若设备此时已插着但我们还没拿到 iOS 版本，补一次
                        if self.isDeviceConnected && self.deviceIOSVersion.isEmpty {
                            self.fetchDeviceIOSVersion()
                        }
                    }
                    self.log("[SCAN] ✅ FOUND executable.")
                    self.setStatus(.idle)
                    return
                } else {
                    self.log("[SCAN] ❌ Not found")
                }
            }

            DispatchQueue.main.async {
                self.isEnvironmentReady = false
                self.isScanningDeps = false
            }
            self.log("------------------------------------------")
            self.log("[INIT] CRITICAL FAILURE: 'pymobiledevice3' not found.")
            self.log("[HELP] Install via Terminal: pip3 install pymobiledevice3")
            self.log("------------------------------------------")
            self.setStatus(.idle)
        }
    }

    // 内部工具：同步运行进程并返回 stdout
    private func runCaptured(_ executable: String, args: [String]) -> String? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // 探测 tunneld 是否在跑（pgrep 匹配完整命令行）
    func checkTunneld() {
        DispatchQueue.global(qos: .background).async {
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            task.arguments = ["-f", "pymobiledevice3.*remote.*tunneld"]
            task.standardOutput = pipe
            task.standardError = Pipe()
            var running = false
            do {
                try task.run()
                task.waitUntilExit()
                running = task.terminationStatus == 0
            } catch { running = false }
            DispatchQueue.main.async {
                if running != self.tunneldRunning {
                    self.log(running ? "[TUNNELD] ✅ Detected running" : "[TUNNELD] ⚠️ Not running")
                    // tunneld 刚起来 → 如果卡在 "Waiting for tunneld…"，回到 idle
                    if running, case .working(let title, _) = self.status,
                       title.lowercased().contains("tunneld") {
                        self.setStatus(.idle)
                    }
                }
                self.tunneldRunning = running
            }
        }
    }

    func checkUSBConnection() {
        if isWorking { return }
        DispatchQueue.global(qos: .background).async {
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
            task.arguments = ["-p", "IOUSB", "-w0"]
            task.standardOutput = pipe
            do {
                try task.run(); task.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let hasDevice = output.contains("iPhone")
                DispatchQueue.main.async {
                    let becameConnected = hasDevice && !self.isDeviceConnected
                    if hasDevice != self.isDeviceConnected {
                        self.log("[HARDWARE] I/O Registry Update:")
                        self.log(hasDevice ? "[HARDWARE] + DEVICE ATTACHED (iPhone)" : "[HARDWARE] - DEVICE REMOVED")
                    }
                    self.isDeviceConnected = hasDevice
                    self.connectionStatusText = hasDevice ? "READY TO INJECT" : "CONNECT VIA USB CABLE"
                    if !hasDevice {
                        self.deviceIOSVersion = ""
                        self.deviceIOSMajor = 0
                        self.tunneldHintDismissed = false
                    } else if becameConnected && self.isEnvironmentReady {
                        self.fetchDeviceIOSVersion()
                    }
                }
            } catch {
                DispatchQueue.main.async { self.isDeviceConnected = false }
            }
        }
    }

    func searchCityOnly() {
        let query = citySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        setStatus(.working("Looking up \"\(query)\"…", nil))
        log("------------------------------------------")
        log("[GEO] Processing User Query: '\(query)'")
        log("[GEO] Querying MapKit Geocoder...")
        Task {
            do {
                let request = MKGeocodingRequest(addressString: query)
                guard let items = try await request?.mapItems, let item = items.first else {
                    self.log("[GEO] ❌ No results")
                    self.setStatus(.failure("Couldn't find \"\(query)\"", "Check spelling or try a nearby landmark."))
                    return
                }
                let coord = item.location.coordinate
                await MainActor.run {
                    self.region.center = coord
                    self.region.span = MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                    self.latitude = String(format: "%.6f", coord.latitude)
                    self.longitude = String(format: "%.6f", coord.longitude)
                }
                let name = item.name ?? query
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
        if !isEnvironmentReady {
            log("[USER] ENV not ready — triggering rescan first")
            findDependency()
            return
        }
        if needsTunneld {
            log("[USER] ❌ iOS \(deviceIOSVersion) requires tunneld — aborting")
            setStatus(.failure(
                "iOS \(deviceIOSVersion) tunnel isn't running",
                "pymobiledevice3 would silently no-op. Click Launch in the yellow banner."
            ))
            tunneldHintDismissed = false
            return
        }
        guard coordsValid else {
            log("[USER] ❌ Coordinate validation failed — aborting")
            setStatus(.failure("Invalid coordinates", "Fix LAT / LON before teleporting."))
            return
        }
        setStatus(.working("Teleporting…", "\(latitude), \(longitude)"))
        log("------------------------------------------")
        log("[USER] 🖱️ ACTION: EXECUTE JUMP CLICKED")
        log("[KERNEL] 🛰️ TARGET LOCK ACQUIRED")
        log("[DATA] 📡 LATITUDE:  \(latitude)")
        log("[DATA] 📡 LONGITUDE: \(longitude)")
        log("[KERNEL] ⚡️ INITIATING INJECTION SEQUENCE...")
        executeCommand(args: ["developer", "simulate-location", "set", "--", latitude, longitude])
    }

    func executeCommand(args: [String]) {
        guard !detectedCliPath.isEmpty else {
            log("[ERROR] Abort: CLI Path is empty.")
            setStatus(.failure("Teleport failed", "pymobiledevice3 path missing."))
            return
        }

        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            self.log("[SYS] Spawning Child Process...")
            self.log("[SYS] Executable: \(self.detectedCliPath)")
            self.log("[SYS] Arguments: \(args.joined(separator: " "))")

            if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
                Thread.sleep(forTimeInterval: 0.5)
                self.log("[PREVIEW] Simulation success.")
                self.setStatus(.success("GPS moved", "\(self.latitude), \(self.longitude)"))
                DispatchQueue.main.async { self.isWorking = false }
                return
            }

            let task = Process()
            let pipe = Pipe()
            let errorPipe = Pipe()

            task.executableURL = URL(fileURLWithPath: self.detectedCliPath)
            task.arguments = args

            var env = ProcessInfo.processInfo.environment
            env["LANG"] = "en_US.UTF-8"
            env["PYTHONIOENCODING"] = "utf-8"
            task.environment = env
            self.log("[SYS] ENV: LANG=en_US.UTF-8 set.")

            task.standardOutput = pipe; task.standardError = errorPipe

            do {
                self.log("[SYS] Calling run()...")
                try task.run()
                self.log("[SYS] PID: \(task.processIdentifier) (RUNNING)")

                task.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

                if output.isEmpty { self.log("[STDOUT] (Empty)") }
                else { self.log("[STDOUT] >> \(output.trimmingCharacters(in: .whitespacesAndNewlines))") }

                if errorOutput.isEmpty { self.log("[STDERR] (Empty)") }
                else { self.log("[STDERR] >> \(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))") }

                self.log("[SYS] Process Exited. Code: \(task.terminationStatus)")

                // 假成功检测：pymobiledevice3 在 iOS 17+ 无 tunneld 时可能 exit 0
                // 但 stderr 里会留下 rsd / tunneld / traceback 之类的痕迹
                let stderrLower = errorOutput.lowercased()
                let stdoutLower = output.lowercased()
                let suspicious = ["rsd", "tunneld", "traceback", "exception", "no device",
                                  "not paired", "permission denied", "connectionrefused",
                                  "connectionabort", "remoteserviced", "quic"]
                let looksBad = suspicious.contains { stderrLower.contains($0) || stdoutLower.contains($0) }

                if task.terminationStatus == 0 && !looksBad {
                    self.log("[RESULT] ✅ SUCCESS: Signal Injected.")
                    self.setStatus(.success("GPS moved", "\(self.latitude), \(self.longitude)"))
                } else if task.terminationStatus == 0 && looksBad {
                    self.log("[RESULT] ⚠️ Exit 0 but stderr looks bad — treating as failure.")
                    let reason = self.humanize(stderr: errorOutput, stdout: output, exit: 0)
                    self.setStatus(.failure("Teleport may not have worked", reason))
                } else {
                    self.log("[RESULT] ❌ FAILURE: Non-zero exit code.")
                    let reason = self.humanize(stderr: errorOutput, stdout: output, exit: task.terminationStatus)
                    self.setStatus(.failure("Teleport failed", reason))
                }
            } catch {
                self.log("[EXCEPTION] \(error.localizedDescription)")
                self.setStatus(.failure("Teleport failed", error.localizedDescription))
            }
            self.log("------------------------------------------")
            DispatchQueue.main.async { self.isWorking = false }
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

// 原生地图引擎封装 (AppKit MKMapView)
struct NativeMapView: NSViewRepresentable {
    @Binding var region: MKCoordinateRegion
    var onRegionChange: (CLLocationCoordinate2D) -> Void
    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.showsUserLocation = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsZoomControls = true
        mapView.showsCompass = true
        mapView.showsScale = true
        return mapView
    }
    func updateNSView(_ nsView: MKMapView, context: Context) {
        let d = abs(nsView.centerCoordinate.latitude - region.center.latitude) + abs(nsView.centerCoordinate.longitude - region.center.longitude)
        if d > 0.0001 || abs(nsView.region.span.latitudeDelta - region.span.latitudeDelta) > 0.001 { nsView.setRegion(region, animated: true) }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: NativeMapView; init(_ parent: NativeMapView) { self.parent = parent }
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            DispatchQueue.main.async {
                self.parent.region = mapView.region
                self.parent.onRegionChange(mapView.centerCoordinate)
            }
        }
    }
}

#Preview { ContentView().frame(width: 450, height: 750) }
