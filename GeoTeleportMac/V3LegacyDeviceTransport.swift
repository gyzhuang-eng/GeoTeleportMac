import Foundation

struct V3LegacyDeviceTransport {
    private let runner = ShellCommandRunner()
    private let pathResolver: LegacyCLIPathResolving

    init(pathResolver: LegacyCLIPathResolving) {
        self.pathResolver = pathResolver
    }

    func fetchConnectedDevice() -> DeviceSnapshot {
        guard case .success(let result) = runner.run("/usr/sbin/ioreg", args: ["-p", "IOUSB", "-w0"]) else {
            return DeviceSnapshot(
                isConnected: false,
                connectionSummary: "USB probe failed",
                iosVersion: nil,
                deviceName: nil,
                deviceIdentifier: nil,
                serialSuffix: nil,
                vendorID: nil,
                productID: nil,
                probeSource: "legacy-cli",
                matchedDeviceCount: 0
            )
        }

        let connected = result.stdout.contains("iPhone")
        guard connected else {
            return DeviceSnapshot(
                isConnected: false,
                connectionSummary: "NO USB CONNECTION",
                iosVersion: nil,
                deviceName: nil,
                deviceIdentifier: nil,
                serialSuffix: nil,
                vendorID: nil,
                productID: nil,
                probeSource: "legacy-cli",
                matchedDeviceCount: 0
            )
        }

        return DeviceSnapshot(
            isConnected: true,
            connectionSummary: "HARDWARE CONNECTED",
            iosVersion: fetchIOSVersion(),
            deviceName: "iPhone",
            deviceIdentifier: nil,
            serialSuffix: nil,
            vendorID: nil,
            productID: nil,
            probeSource: "legacy-cli",
            matchedDeviceCount: 1
        )
    }

    func fetchTunnelState(for device: DeviceSnapshot) -> TunnelState {
        guard device.isConnected else { return .notRequired }
        guard let major = device.iosMajorVersion, major >= 17 else { return .notRequired }

        guard case .success(let result) = runner.run("/usr/bin/pgrep", args: ["-f", "pymobiledevice3.*remote.*tunneld"]) else {
            return .requiredInactive
        }

        return result.exitCode == 0 ? .active : .requiredInactive
    }

    private func fetchIOSVersion() -> String? {
        guard let cliPath = pathResolver.resolvedCLIPath() else { return nil }
        guard case .success(let result) = runner.run(cliPath, args: ["lockdown", "info"]) else {
            return nil
        }

        let pattern = #"ProductVersion["\s:=]+["']?([0-9]+(?:\.[0-9]+)*)"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: result.stdout,
                range: NSRange(result.stdout.startIndex..., in: result.stdout)
            ),
            match.numberOfRanges >= 2,
            let range = Range(match.range(at: 1), in: result.stdout)
        else {
            return nil
        }

        return String(result.stdout[range])
    }
}
