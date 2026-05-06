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
    @Published var previewLens: LensType = .wide {
        didSet { switchPreviewConnection() }
    }
    @Published var lastFileSize: String?
    @Published var showToast = false
    @Published var thermalWarning = false
    @Published var zoomFactor: CGFloat = 1.0
    @Published var focusPoint: CGPoint?
    @Published var exposureValue: Float = 0
    @Published var isExposureLocked = false
    @Published var sessionReady = false

    private let multiCamSession = AVCaptureMultiCamSession()

    private var ultraWideInput: AVCaptureDeviceInput?
    private var wideInput: AVCaptureDeviceInput?
    private var telephotoInput: AVCaptureDeviceInput?

    private let ultraWideOutput = AVCapturePhotoOutput()
    private let wideOutput = AVCapturePhotoOutput()
    private let telephotoOutput = AVCapturePhotoOutput()

    private(set) var previewLayer: AVCaptureVideoPreviewLayer!
    private var previewConnection: AVCaptureConnection?

    private let coordinator = CaptureCoordinator()
    private let sessionQueue = DispatchQueue(label: "com.multilens.session")
    private var countdownTimer: Timer?

    var settings = CaptureSettings()

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

    override init() {
        previewLayer = nil
        super.init()
        previewLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: multiCamSession)
        previewLayer.videoGravity = .resizeAspectFill
    }

    func configure() {
        sessionQueue.async { [weak self] in
            self?.setupSession()
        }
        observeThermalState()
    }

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.multiCamSession.startRunning()
            DispatchQueue.main.async {
                self.sessionReady = true
            }
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

        let devices = [ultraWideDev, wideDev, telephoneDev]
        let outputs = [ultraWideOutput, wideOutput, telephotoOutput]
        let inputs = [ultraWideInput!, wideInput!, telephotoInput!]
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera
        ]

        for i in 0..<3 {
            let output = outputs[i]
            let input = inputs[i]
            let device = devices[i]
            let deviceType = deviceTypes[i]

            if multiCamSession.canAddOutput(output) {
                multiCamSession.addOutput(output)
            }

            // Connect input video port to photo output
            let videoPorts = input.ports(for: .video, sourceDeviceType: deviceType, sourceDevicePosition: .back)
            if !videoPorts.isEmpty {
                let conn = AVCaptureConnection(inputPorts: videoPorts, output: output)
                if multiCamSession.canAddConnection(conn) {
                    multiCamSession.addConnection(conn)
                }
            }

            // Force highest resolution format
            if let maxFormat = device.formats
                .filter({ $0.isHighestPhotoQualitySupported })
                .max(by: {
                    let d0 = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                    let d1 = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                    return (Int(d0.width) * Int(d0.height)) < (Int(d1.width) * Int(d1.height))
                }) {
                do {
                    try device.lockForConfiguration()
                    device.activeFormat = maxFormat
                    device.unlockForConfiguration()
                } catch {}
            }

            output.maxPhotoQualityPrioritization = .quality
            if output.isAppleProRAWSupported {
                output.isAppleProRAWEnabled = true
            }
        }

        // Connect wide camera to preview layer by default
        connectPreview(for: .wide)

        multiCamSession.commitConfiguration()
    }

    private func connectPreview(for lens: LensType) {
        // Remove existing preview connection
        if let existing = previewConnection {
            multiCamSession.removeConnection(existing)
            previewConnection = nil
        }

        let input: AVCaptureDeviceInput?
        let deviceType: AVCaptureDevice.DeviceType

        switch lens {
        case .ultraWide:
            input = ultraWideInput
            deviceType = .builtInUltraWideCamera
        case .wide:
            input = wideInput
            deviceType = .builtInWideAngleCamera
        case .telephoto:
            input = telephotoInput
            deviceType = .builtInTelephotoCamera
        }

        guard let input,
              let port = input.ports(for: .video, sourceDeviceType: deviceType, sourceDevicePosition: .back).first
        else { return }

        let conn = AVCaptureConnection(inputPort: port, videoPreviewLayer: previewLayer)
        if multiCamSession.canAddConnection(conn) {
            multiCamSession.addConnection(conn)
            previewConnection = conn
        }
    }

    private func switchPreviewConnection() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.multiCamSession.beginConfiguration()
            self.connectPreview(for: self.previewLens)
            self.multiCamSession.commitConfiguration()
        }
    }

    private func makePhotoSettings(for output: AVCapturePhotoOutput) -> AVCapturePhotoSettings {
        let photoSettings: AVCapturePhotoSettings

        if output.isAppleProRAWEnabled,
           let rawFormat = output.availableRawPhotoPixelFormatTypes.last {
            let processedFormat: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc]
            photoSettings = AVCapturePhotoSettings(
                rawPixelFormatType: rawFormat, processedFormat: processedFormat)
        } else {
            photoSettings = AVCapturePhotoSettings(
                format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }

        photoSettings.photoQualityPrioritization = .quality

        switch self.settings.flashMode {
        case .off: photoSettings.flashMode = .off
        case .on: photoSettings.flashMode = .on
        case .auto: photoSettings.flashMode = .auto
        }

        return photoSettings
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
