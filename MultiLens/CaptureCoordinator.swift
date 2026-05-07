import AVFoundation

final class CaptureCoordinator: NSObject, AVCapturePhotoCaptureDelegate {
    var onAllCaptured: (([LensType: AVCapturePhoto]) -> Void)?
    var onError: ((String) -> Void)?

    private var capturedPhotos: [LensType: AVCapturePhoto] = [:]
    private let lock = NSLock()

    func reset() {
        lock.lock()
        capturedPhotos.removeAll()
        lock.unlock()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            onError?("Capture failed: \(error.localizedDescription)")
            return
        }

        let lens = identifyLens(from: photo)

        lock.lock()
        capturedPhotos[lens] = photo
        let count = capturedPhotos.count
        let photos = capturedPhotos
        lock.unlock()

        if count == 3 {
            onAllCaptured?(photos)
        }
    }

    private func identifyLens(from photo: AVCapturePhoto) -> LensType {
        if let metadata = photo.metadata["{Exif}"] as? [String: Any],
           let focalLength = metadata["FocalLenIn35mmFilm"] as? Int {
            if focalLength <= 16 { return .ultraWide }
            if focalLength <= 30 { return .wide }
            return .telephoto
        }

        // Fallback by order
        lock.lock()
        let count = capturedPhotos.count
        lock.unlock()
        switch count {
        case 0: return .ultraWide
        case 1: return .wide
        default: return .telephoto
        }
    }
}
