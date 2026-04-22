import Foundation

final class V3BackendProvider {
    private let legacyPathResolver = V3LegacyCLIPathResolver()
    private lazy var legacyPreviewBackendInstance = LegacyCLIBackend(pathResolver: legacyPathResolver)
    private lazy var noPythonBackendInstance = NoPythonBackendStub()

    func legacyPreviewBackend() -> LegacyCLIBackend {
        legacyPreviewBackendInstance
    }

    func backend(for track: BackendTrack) -> DeviceBackend {
        switch track {
        case .legacyPreview:
            return legacyPreviewBackend()
        case .noPythonStub:
            return noPythonBackendInstance
        }
    }
}
