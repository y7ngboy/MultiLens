import AVFoundation
import Photos
import SwiftUI
import CoreImage
import UniformTypeIdentifiers

enum LensType: String, CaseIterable {
    case ultraWide = "0.5x"
    case wide = "1x"
    case telephoto = "4x"
}

enum CaptureState {
    case idle
    case capturing
    case encoding
    case done
    case error(String)
}

final class CameraManager: NSObject, ObservableObject {
    @Published var captureState: CaptureState = .idle
    @Published var encodingProgress: Double = 0
    @Published var previewLens: LensType = .wide
    @Published var lastFileSize: String?
    @Published var showToast = false
    @Published var thermalWarning = false

    let multiCamSession = AVCaptureMultiCamSession()

    private var ultraWideInput: AVCaptureDeviceInput?
    private var wideInput: AVCaptureDeviceInput?
    private var telephotoInput: AVCaptureDeviceInput?

    private let ultraWideOutput = AVCapturePhotoOutput()
    private let wideOutput = AVCapturePhotoOutput()
    private let telephotoOutput = AVCapturePhotoOutput()

    private var ultraWidePreviewLayer: AVCaptureVideoPreviewLayer?
    private var widePreviewLayer: AVCaptureVideoPreviewLayer?
    private var telephotoPreviewLayer: AVCaptureVideoPreviewLayer?

    private let coordinator = CaptureCoordinator()
    private let sessionQueue = DispatchQueue(label: "com.multilens.session")

    var activePreviewLayer: AVCaptureVideoPreviewLayer? {
        switch previewLens {
        case .ultraWide: return ultraWidePreviewLayer
        case .wide: return widePreviewLayer
        case .telephoto: return telephotoPreviewLayer
        }
    }

    static var isSupported: Bool {
        AVCaptureMultiCamSession.isMultiCamSupported
    }

    func configure() {
        sessionQueue.async { [weak self] in
            self?.setupSession()
        }
        observeThermalState()
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            self?.multiCamSession.startRunning()
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.multiCamSession.stopRunning()
        }
    }

    func captureAll() {
        guard case .idle = captureState else { return }
        captureState = .capturing

        coordinator.reset()
        coordinator.onAllCaptured = { [weak self] photos in
            self?.assembleTIFF(photos: photos)
        }
        coordinator.onError = { [weak self] msg in
            DispatchQueue.main.async {
                self?.captureState = .error(msg)
            }
        }

        let settings = makePhotoSettings(for: ultraWideOutput)
        ultraWideOutput.capturePhoto(with: settings, delegate: coordinator)

        let settings2 = makePhotoSettings(for: wideOutput)
        wideOutput.capturePhoto(with: settings2, delegate: coordinator)

        let settings3 = makePhotoSettings(for: telephotoOutput)
        telephotoOutput.capturePhoto(with: settings3, delegate: coordinator)
    }

    // MARK: - Private

    private func setupSession() {
        multiCamSession.beginConfiguration()

        guard let ultraWideDev = AVCaptureDevice.default(
            .builtInUltraWideCamera, for: .video, position: .back),
              let wideDev = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: .back),
              let telephoneDev = AVCaptureDevice.default(
                .builtInTelephotoCamera, for: .video, position: .back)
        else {
            multiCamSession.commitConfiguration()
            DispatchQueue.main.async {
                self.captureState = .error("Required cameras not available")
            }
            return
        }

        do {
            let uwInput = try AVCaptureDeviceInput(device: ultraWideDev)
            let wInput = try AVCaptureDeviceInput(device: wideDev)
            let tInput = try AVCaptureDeviceInput(device: telephoneDev)

            for input in [uwInput, wInput, tInput] {
                if multiCamSession.canAddInput(input) {
                    multiCamSession.addInput(input)
                }
            }

            ultraWideInput = uwInput
            wideInput = wInput
            telephotoInput = tInput
        } catch {
            multiCamSession.commitConfiguration()
            DispatchQueue.main.async {
                self.captureState = .error("Camera input error: \(error.localizedDescription)")
            }
            return
        }

        for output in [ultraWideOutput, wideOutput, telephotoOutput] {
            if multiCamSession.canAddOutput(output) {
                multiCamSession.addOutput(output)
            }
            output.maxPhotoQualityPrioritization = .quality
            if output.isAppleProRAWSupported {
                output.isAppleProRAWEnabled = true
            }
        }

        if let uwInput = ultraWideInput {
            let connection = AVCaptureConnection(
                inputPorts: uwInput.ports, output: ultraWideOutput)
            if multiCamSession.canAddConnection(connection) {
                multiCamSession.addConnection(connection)
            }
        }
        if let wInput = wideInput {
            let connection = AVCaptureConnection(
                inputPorts: wInput.ports, output: wideOutput)
            if multiCamSession.canAddConnection(connection) {
                multiCamSession.addConnection(connection)
            }
        }
        if let tInput = telephotoInput {
            let connection = AVCaptureConnection(
                inputPorts: tInput.ports, output: telephotoOutput)
            if multiCamSession.canAddConnection(connection) {
                multiCamSession.addConnection(connection)
            }
        }

        // Preview layers
        let uwPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multiCamSession)
        if let port = ultraWideInput?.ports.first {
            let conn = AVCaptureConnection(inputPort: port, videoPreviewLayer: uwPreview)
            if multiCamSession.canAddConnection(conn) {
                multiCamSession.addConnection(conn)
            }
        }
        ultraWidePreviewLayer = uwPreview

        let wPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multiCamSession)
        if let port = wideInput?.ports.first {
            let conn = AVCaptureConnection(inputPort: port, videoPreviewLayer: wPreview)
            if multiCamSession.canAddConnection(conn) {
                multiCamSession.addConnection(conn)
            }
        }
        widePreviewLayer = wPreview

        let tPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multiCamSession)
        if let port = telephotoInput?.ports.first {
            let conn = AVCaptureConnection(inputPort: port, videoPreviewLayer: tPreview)
            if multiCamSession.canAddConnection(conn) {
                multiCamSession.addConnection(conn)
            }
        }
        telephotoPreviewLayer = tPreview

        multiCamSession.commitConfiguration()
    }

    private func makePhotoSettings(for output: AVCapturePhotoOutput) -> AVCapturePhotoSettings {
        if output.isAppleProRAWEnabled,
           let rawFormat = output.availableRawPhotoPixelFormatTypes.first {
            let processedFormat: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc
            ]
            let settings = AVCapturePhotoSettings(
                rawPixelFormatType: rawFormat,
                processedFormat: processedFormat)
            settings.photoQualityPrioritization = .quality
            return settings
        }
        let settings = AVCapturePhotoSettings(
            format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        settings.photoQualityPrioritization = .quality
        return settings
    }

    private func assembleTIFF(photos: [LensType: AVCapturePhoto]) {
        DispatchQueue.main.async {
            self.captureState = .encoding
            self.encodingProgress = 0
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let assembler = TIFFAssembler()
            assembler.onProgress = { progress in
                DispatchQueue.main.async {
                    self.encodingProgress = progress
                }
            }

            let result = assembler.assemble(photos: photos)

            DispatchQueue.main.async {
                switch result {
                case .success(let fileSize):
                    self.lastFileSize = fileSize
                    self.showToast = true
                    self.captureState = .idle
                    self.encodingProgress = 1.0
                case .failure(let error):
                    self.captureState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func observeThermalState() {
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            self?.thermalWarning = (state == .serious || state == .critical)
        }
    }
}
