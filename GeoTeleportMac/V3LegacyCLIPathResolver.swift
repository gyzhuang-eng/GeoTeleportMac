import Foundation

protocol LegacyCLIPathResolving {
    func resolvedCLIPath() -> String?
}

struct V3LegacyCLIPathResolver: LegacyCLIPathResolving {
    private let runner = ShellCommandRunner()
    private let fileManager = FileManager.default

    func resolvedCLIPath() -> String? {
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

        if case .success(let result) = runner.run("/usr/bin/which", args: ["-a", "pymobiledevice3"]) {
            let discovered = result.stdout.split(separator: "\n").map(String.init)
            for path in discovered where !candidates.contains(path) {
                candidates.append(path)
            }
        }

        return candidates.first(where: { fileManager.fileExists(atPath: $0) })
    }
}
