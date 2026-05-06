import AVFoundation

final class CaptureCoordinator: NSObject, AVCapturePhotoCaptureDelegate {
    var onAllCaptured: (([LensType: AVCapturePhoto]) -> Void)?
    var onError: ((String) -> Void)?

    private var capturedPhotos: [LensType: AVCapturePhoto] = [:]
    private let lock = NSLock()
    private var outputs: [AVCapturePhotoOutput: LensType] = [:]

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
        lock.unlock()

        if count == 3 {
            lock.lock()
            let photos = capturedPhotos
            lock.unlock()
            onAllCaptured?(photos)
        }
    }

    private func identifyLens(from photo: AVCapturePhoto) -> LensType {
        guard let metadata = photo.metadata["{Exif}"] as? [String: Any],
              let focalLength = metadata["FocalLenIn35mmFilm"] as? Int
        else {
            // Fallback: assign by order received
            lock.lock()
            let count = capturedPhotos.count
            lock.unlock()
            switch count {
            case 0: return .ultraWide
            case 1: return .wide
            default: return .telephoto
            }
        }

        // Approximate 35mm equiv focal lengths
        if focalLength <= 16 { return .ultraWide }
        if focalLength <= 30 { return .wide }
        return .telephoto
    }
}
