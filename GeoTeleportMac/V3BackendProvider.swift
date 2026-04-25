import Foundation

final class V3BackendProvider {
    private lazy var noPythonBackendInstance = NoPythonBackendStub()

    func backend(for track: BackendTrack) -> DeviceBackend {
        switch track {
        case .noPythonStub:
            return noPythonBackendInstance
        }
    }
}
