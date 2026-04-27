import Foundation

struct NativeDeviceCoreFFIError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

/// Thin Swift wrapper around the Rust native-device-core C FFI dynamic library.
/// Replaces Process-based shell-out for enumerate, device-info, set-location,
/// and clear-location. The ios17-location-daemon is inherently a long-running
/// process and continues to use Process (it needs stdin/stdout pipes).
enum NativeDeviceCoreFFI {
    // MARK: - Library loading

    private static var dylibHandle: UnsafeMutableRawPointer? = {
        guard let path = resolveDylibPath() else { return nil }
        return dlopen(path, RTLD_NOW)
    }()

    private static func resolveDylibPath(filePath: String = #filePath) -> String? {
        // Shipped DMG: binary bundled at Contents/Helpers/
        let helpersURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/libgeoteleport_device_core.dylib")
        if FileManager.default.isExecutableFile(atPath: helpersURL.path) {
            return helpersURL.path
        }
        // Shipped DMG fallback: Contents/MacOS/
        if let auxURL = Bundle.main.url(forAuxiliaryExecutable: "libgeoteleport_device_core"),
           FileManager.default.isExecutableFile(atPath: auxURL.path) {
            return auxURL.path
        }
        // Developer build: binary lives next to the source tree
        let fileURL = URL(fileURLWithPath: filePath)
        let repoRoot = fileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let dylibURL = repoRoot
            .appendingPathComponent("native-device-core", isDirectory: true)
            .appendingPathComponent("target", isDirectory: true)
            .appendingPathComponent("debug", isDirectory: true)
            .appendingPathComponent("libgeoteleport_device_core.dylib", isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: dylibURL.path) ? dylibURL.path : nil
    }

    static var isAvailable: Bool { dylibHandle != nil }

    // MARK: - Function pointers

    private static func sym<T>(_ name: String) -> T? {
        guard let handle = dylibHandle,
              let ptr = dlsym(handle, name) else { return nil }
        return unsafeBitCast(ptr, to: T.self)
    }

    private typealias FFI_Enumerate = @convention(c) () -> UnsafeMutablePointer<CChar>?
    private typealias FFI_DeviceInfo = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias FFI_SetLocation = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias FFI_ClearLocation = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    private typealias FFI_FreeString = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

    private static let enumerateFn: FFI_Enumerate? = sym("gte_enumerate_ios_devices")
    private static let deviceInfoFn: FFI_DeviceInfo? = sym("gte_device_info")
    private static let setLocationFn: FFI_SetLocation? = sym("gte_set_location")
    private static let clearLocationFn: FFI_ClearLocation? = sym("gte_clear_location")
    private static let freeStringFn: FFI_FreeString? = sym("gte_free_string")

    // MARK: - Public API

    static func enumerateDevices() throws -> String {
        guard let fn = enumerateFn else {
            throw NativeDeviceCoreFFIError(message: "FFI: enumerate function not available")
        }
        guard let ptr = fn() else {
            throw NativeDeviceCoreFFIError(message: "FFI: enumerate returned null")
        }
        let result = String(cString: ptr)
        freeStringFn?(ptr)

        if result.contains("\"error\"") {
            throw NativeDeviceCoreFFIError(message: parseFFIError(result) ?? result)
        }
        return result
    }

    static func deviceInfo(udid: String) throws -> String {
        guard let fn = deviceInfoFn else {
            throw NativeDeviceCoreFFIError(message: "FFI: device-info function not available")
        }
        let result: String = udid.withCString { cUdid in
            guard let ptr = fn(cUdid) else { return "" }
            defer { freeStringFn?(ptr) }
            return String(cString: ptr)
        }
        if result.isEmpty {
            throw NativeDeviceCoreFFIError(message: "FFI: device-info returned empty")
        }
        if result.contains("\"error\"") {
            throw NativeDeviceCoreFFIError(message: parseFFIError(result) ?? result)
        }
        return result
    }

    static func setLocation(udid: String, lat: String, lon: String) throws -> String {
        guard let fn = setLocationFn else {
            throw NativeDeviceCoreFFIError(message: "FFI: set-location function not available")
        }
        let result: String = udid.withCString { cUdid in
            lat.withCString { cLat in
                lon.withCString { cLon in
                    guard let ptr = fn(cUdid, cLat, cLon) else { return "" }
                    defer { freeStringFn?(ptr) }
                    return String(cString: ptr)
                }
            }
        }
        if result.isEmpty {
            throw NativeDeviceCoreFFIError(message: "FFI: set-location returned empty")
        }
        if result.contains("\"error\"") {
            throw NativeDeviceCoreFFIError(message: parseFFIError(result) ?? result)
        }
        if result.contains("\"status\":\"ok\"") {
            return result
        }
        throw NativeDeviceCoreFFIError(message: "FFI: set-location unexpected response: \(result)")
    }

    static func clearLocation(udid: String) throws -> String {
        guard let fn = clearLocationFn else {
            throw NativeDeviceCoreFFIError(message: "FFI: clear-location function not available")
        }
        let result: String = udid.withCString { cUdid in
            guard let ptr = fn(cUdid) else { return "" }
            defer { freeStringFn?(ptr) }
            return String(cString: ptr)
        }
        if result.isEmpty {
            throw NativeDeviceCoreFFIError(message: "FFI: clear-location returned empty")
        }
        if result.contains("\"error\"") {
            throw NativeDeviceCoreFFIError(message: parseFFIError(result) ?? result)
        }
        if result.contains("\"status\":\"ok\"") {
            return result
        }
        throw NativeDeviceCoreFFIError(message: "FFI: clear-location unexpected response: \(result)")
    }

    // MARK: - Helpers

    private static func parseFFIError(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let error = obj["error"] else { return nil }
        return error
    }
}
