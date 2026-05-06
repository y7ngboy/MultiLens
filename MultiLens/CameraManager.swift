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

enum CaptureState: Equatable {
    case idle
    case countdown(Int)
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
    @Published var zoomFactor: CGFloat = 1.0
    @Published var focusPoint: CGPoint?
    @Published var exposureValue: Float = 0
    @Published var isExposureLocked = false

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
    private var countdownTimer: Timer?

    var settings = CaptureSettings()

    var activePreviewLayer: AVCaptureVideoPreviewLayer? {
        switch previewLens {
        case .ultraWide: return ultraWidePreviewLayer
        case .wide: return widePreviewLayer
        case .telephoto: return telephotoPreviewLayer
        }
    }

    var activeDevice: AVCaptureDevice? {
        switch previewLens {
        case .ultraWide: return ultraWideInput?.device
        case .wide: return wideInput?.device
        case .telephoto: return telephotoInput?.device
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

    // MARK: - Capture

    func captureAll() {
        guard case .idle = captureState else { return }

        if settings.timerSeconds > 0 {
            startCountdown()
        } else {
            triggerCapture()
        }
    }

    private func startCountdown() {
        var remaining = settings.timerSeconds
        captureState = .countdown(remaining)

        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            remaining -= 1
            if remaining <= 0 {
                timer.invalidate()
                self?.triggerCapture()
            } else {
                DispatchQueue.main.async {
                    self?.captureState = .countdown(remaining)
                }
            }
        }
    }

    private func triggerCapture() {
        captureState = .capturing

        if settings.hapticEnabled {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }

        coordinator.reset()
        coordinator.onAllCaptured = { [weak self] photos in
            self?.assembleTIFF(photos: photos)
        }
        coordinator.onError = { [weak self] msg in
            DispatchQueue.main.async {
                self?.captureState = .error(msg)
            }
        }

        let s1 = makePhotoSettings(for: ultraWideOutput)
        ultraWideOutput.capturePhoto(with: s1, delegate: coordinator)

        let s2 = makePhotoSettings(for: wideOutput)
        wideOutput.capturePhoto(with: s2, delegate: coordinator)

        let s3 = makePhotoSettings(for: telephotoOutput)
        telephotoOutput.capturePhoto(with: s3, delegate: coordinator)
    }

    // MARK: - Gestures

    func setZoom(_ factor: CGFloat) {
        guard let device = activeDevice else { return }
        let clamped = min(max(factor, 1.0), device.activeFormat.videoMaxZoomFactor)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.zoomFactor = clamped }
        } catch {}
    }

    func focus(at point: CGPoint, in viewSize: CGSize) {
        guard let device = activeDevice,
              device.isFocusPointOfInterestSupported else { return }

        let focusPoint = CGPoint(
            x: point.y / viewSize.height,
            y: 1.0 - point.x / viewSize.width
        )

        do {
            try device.lockForConfiguration()
            device.focusPointOfInterest = focusPoint
            device.focusMode = .autoFocus
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = focusPoint
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()

            DispatchQueue.main.async {
                self.focusPoint = point
                self.isExposureLocked = false
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.focusPoint = nil
            }
        } catch {}
    }

    func lockExposure(at point: CGPoint, in viewSize: CGSize) {
        guard let device = activeDevice,
              device.isExposurePointOfInterestSupported else { return }

        let expPoint = CGPoint(
            x: point.y / viewSize.height,
            y: 1.0 - point.x / viewSize.width
        )

        do {
            try device.lockForConfiguration()
            device.exposurePointOfInterest = expPoint
            device.exposureMode = .locked
            device.unlockForConfiguration()

            DispatchQueue.main.async {
                self.isExposureLocked = true
                self.focusPoint = point
            }
        } catch {}
    }

    func adjustExposure(by delta: Float) {
        guard let device = activeDevice else { return }
        let newBias = min(max(device.exposureTargetBias + delta,
                              device.minExposureTargetBias),
                         device.maxExposureTargetBias)
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(newBias) { _ in }
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.exposureValue = newBias }
        } catch {}
    }

    func switchToNextLens() {
        let all = LensType.allCases
        guard let idx = all.firstIndex(of: previewLens) else { return }
        let next = all[(idx + 1) % all.count]
        withAnimation(.easeInOut(duration: 0.2)) {
            previewLens = next
        }
    }

    func setFlash(_ mode: FlashMode) {
        settings.flashMode = mode
    }

    // MARK: - Private Setup

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
            let connection = AVCaptureConnection(inputPorts: uwInput.ports, output: ultraWideOutput)
            if multiCamSession.canAddConnection(connection) {
                multiCamSession.addConnection(connection)
            }
        }
        if let wInput = wideInput {
            let connection = AVCaptureConnection(inputPorts: wInput.ports, output: wideOutput)
            if multiCamSession.canAddConnection(connection) {
                multiCamSession.addConnection(connection)
            }
        }
        if let tInput = telephotoInput {
            let connection = AVCaptureConnection(inputPorts: tInput.ports, output: telephotoOutput)
            if multiCamSession.canAddConnection(connection) {
                multiCamSession.addConnection(connection)
            }
        }

        // Preview layers
        let uwPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multiCamSession)
        if let port = ultraWideInput?.ports.first {
            let conn = AVCaptureConnection(inputPort: port, videoPreviewLayer: uwPreview)
            if multiCamSession.canAddConnection(conn) { multiCamSession.addConnection(conn) }
        }
        ultraWidePreviewLayer = uwPreview

        let wPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multiCamSession)
        if let port = wideInput?.ports.first {
            let conn = AVCaptureConnection(inputPort: port, videoPreviewLayer: wPreview)
            if multiCamSession.canAddConnection(conn) { multiCamSession.addConnection(conn) }
        }
        widePreviewLayer = wPreview

        let tPreview = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multiCamSession)
        if let port = telephotoInput?.ports.first {
            let conn = AVCaptureConnection(inputPort: port, videoPreviewLayer: tPreview)
            if multiCamSession.canAddConnection(conn) { multiCamSession.addConnection(conn) }
        }
        telephotoPreviewLayer = tPreview

        // Stabilization
        for output in [ultraWideOutput, wideOutput, telephotoOutput] {
            if let conn = output.connection(with: .video),
               conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = .auto
            }
        }

        multiCamSession.commitConfiguration()
    }

    private func makePhotoSettings(for output: AVCapturePhotoOutput) -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings

        if output.isAppleProRAWEnabled,
           let rawFormat = output.availableRawPhotoPixelFormatTypes.first {
            let processedFormat: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc]
            settings = AVCapturePhotoSettings(
                rawPixelFormatType: rawFormat, processedFormat: processedFormat)
        } else {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }

        settings.photoQualityPrioritization = .quality

        switch self.settings.flashMode {
        case .off: settings.flashMode = .off
        case .on: settings.flashMode = .on
        case .auto: settings.flashMode = .auto
        }

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
                DispatchQueue.main.async { self.encodingProgress = progress }
            }

            let result = assembler.assemble(photos: photos)

            DispatchQueue.main.async {
                switch result {
                case .success(let fileSize):
                    self.lastFileSize = fileSize
                    self.showToast = true
                    self.captureState = .idle
                    self.encodingProgress = 1.0
                    if self.settings.hapticEnabled {
                        let gen = UINotificationFeedbackGenerator()
                        gen.notificationOccurred(.success)
                    }
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
