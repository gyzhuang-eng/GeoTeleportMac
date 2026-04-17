import SwiftUI
import MapKit
import CoreLocation
import Combine
import AppKit

// MARK: - V9.2 · Glass UI · Bounded log · Rescan · Validated coords

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

                // 1b. iOS 17+ tunneld 提示横幅
                if isDeviceConnected && deviceIOSMajor >= 17 && !tunneldHintDismissed {
                    tunneldBanner
                        .padding(.horizontal, 15)
                }

                // 2. 地图区
                ZStack {
                    NativeMapView(region: $region) { newCenter in
                        self.latitude = String(format: "%.6f", newCenter.latitude)
                        self.longitude = String(format: "%.6f", newCenter.longitude)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.35), radius: 14, x: 0, y: 6)

                    ZStack {
                        Circle().stroke(accentBlue.opacity(0.85), lineWidth: 1.5).frame(width: 22, height: 22)
                        Image(systemName: "plus").font(.system(size: 14, weight: .regular)).foregroundColor(.white)
                        Image(systemName: "triangle.fill").font(.system(size: 10)).foregroundColor(.red).rotationEffect(.degrees(180)).offset(y: 14)
                    }.allowsHitTesting(false)
                }
                .frame(height: 220)
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
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    LocationButton(name: "DUBAI", lat: "25.185317", lon: "55.281516", color: .orange)
                    LocationButton(name: "Abu Dhabi", lat: "24.340142", lon: "54.518667", color: .blue)
                    LocationButton(name: "HANOI", lat: "20.992498", lon: "105.944606", color: .purple)
                    LocationButton(name: "TOKYO", lat: "35.6895", lon: "139.6917", color: .pink)
                    LocationButton(name: "NYC", lat: "40.7128", lon: "-74.0060", color: .cyan)
                    LocationButton(name: "LDN", lat: "51.5074", lon: "-0.1278", color: .green)
                    LocationButton(name: "PARIS", lat: "48.8566", lon: "2.3522", color: .indigo)
                    LocationButton(name: "SHENZHEN", lat: "22.5431", lon: "114.0579", color: .red)
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
                            if !isDeviceConnected || !isEnvironmentReady || !coordsValid {
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
                .disabled(isWorking || !isDeviceConnected || !isEnvironmentReady || !coordsValid)

                // 7. 日志区
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("SYSTEM_DEBUG_STREAM (VERBOSE)")
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
                .padding(.horizontal, 15)
                .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 450, minHeight: 750)
        .onReceive(timer) { _ in checkUSBConnection() }
        .onAppear {
            logSystemInfo()
            findDependency()
            checkUSBConnection()
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

    // iOS 17+ tunneld 提示横幅
    private var tunneldBanner: some View {
        let cmd = "sudo python3 -m pymobiledevice3 remote tunneld"
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
                    }
                    self.log("[SCAN] ✅ FOUND executable.")
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
        log("------------------------------------------")
        log("[GEO] Processing User Query: '\(query)'")
        log("[GEO] Querying MapKit Geocoder...")
        Task {
            do {
                let request = MKGeocodingRequest(addressString: query)
                guard let items = try await request?.mapItems, let item = items.first else {
                    self.log("[GEO] ❌ No results")
                    return
                }
                let coord = item.location.coordinate
                await MainActor.run {
                    self.region.center = coord
                    self.region.span = MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                    self.latitude = String(format: "%.6f", coord.latitude)
                    self.longitude = String(format: "%.6f", coord.longitude)
                }
                let name = item.name ?? "?"
                self.log("[GEO] ✅ Result: \(name)")
                self.log("[GEO] Coords: \(String(format: "%.6f", coord.latitude)), \(String(format: "%.6f", coord.longitude))")
            } catch {
                self.log("[GEO] ❌ ERROR: \(error.localizedDescription)")
            }
        }
    }

    func teleport() {
        if !isEnvironmentReady {
            log("[USER] ENV not ready — triggering rescan first")
            findDependency()
            return
        }
        guard coordsValid else {
            log("[USER] ❌ Coordinate validation failed — aborting")
            return
        }
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
            return
        }

        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            self.log("[SYS] Spawning Child Process...")
            self.log("[SYS] Executable: \(self.detectedCliPath)")
            self.log("[SYS] Arguments: \(args.joined(separator: " "))")

            if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
                Thread.sleep(forTimeInterval: 0.5)
                self.log("[PREVIEW] Simulation success."); DispatchQueue.main.async { self.isWorking = false }; return
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

                if task.terminationStatus == 0 { self.log("[RESULT] ✅ SUCCESS: Signal Injected.") }
                else { self.log("[RESULT] ❌ FAILURE: Non-zero exit code.") }
            } catch {
                self.log("[EXCEPTION] \(error.localizedDescription)")
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

    func LocationButton(name: String, lat: String, lon: String, color: Color) -> some View {
        Button(action: {
            if let lLat = Double(lat), let lLon = Double(lon) {
                self.region.center = CLLocationCoordinate2D(latitude: lLat, longitude: lLon)
                self.region.span = MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
                self.latitude = lat; self.longitude = lon
                self.log("[USER] Selected Preset: \(name)")
            }
        }) {
            Text(name)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(color.opacity(0.45))
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.regularMaterial)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(color.opacity(0.55), lineWidth: 1)
                )
        }.buttonStyle(.plain)
    }
}

// 原生地图引擎封装 (AppKit MKMapView)
struct NativeMapView: NSViewRepresentable {
    @Binding var region: MKCoordinateRegion
    var onRegionChange: (CLLocationCoordinate2D) -> Void
    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView(); mapView.delegate = context.coordinator; mapView.mapType = .standard; mapView.showsUserLocation = false; mapView.isRotateEnabled = false; mapView.isPitchEnabled = false; return mapView
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
