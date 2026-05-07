import AVFoundation
import Photos
import UIKit
import CoreMedia

enum LensType: String, CaseIterable {
    case ultraWide = "0.5x"
    case wide = "1x"
    case telephoto = "4x"

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .ultraWide: return .builtInUltraWideCamera
        case .wide: return .builtInWideAngleCamera
        case .telephoto: return .builtInTelephotoCamera
        }
    }
}

enum CaptureState: Equatable {
    case idle
    case countdown(Int)
    case capturing
    case saving
    case recording
    case error(String)
}

final class CameraManager: NSObject, ObservableObject {
    @Published var captureState: CaptureState = .idle
    @Published var previewLens: LensType = .wide
    @Published var lastSaveCount = 0
    @Published var showToast = false
    @Published var toastMessage = ""
    @Published var thermalWarning = false

    @Published var iso: Float = 100
    @Published var shutterSpeed: Double = 1.0/48.0
    @Published var shutterAngle: Double = 180
    @Published var whiteBalance: Float = 5500
    @Published var tint: Float = 0
    @Published var manualFocusPosition: Float = 0.5
    @Published var zoomFactor: CGFloat = 1.0
    @Published var exposureValue: Float = 0
    @Published var focusPoint: CGPoint?
    @Published var isExposureLocked = false
    @Published var isManualExposure = false
    @Published var isManualFocus = false
    @Published var isManualWB = false

    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var isoRange: (Float, Float) = (32, 3200)
    @Published var currentFPS: Double = 24
    @Published var availableLenses: [LensType] = []

    let session = AVCaptureSession()
    private(set) var previewLayer: AVCaptureVideoPreviewLayer?

    private var currentInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()

    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingStartTime: CMTime?
    private var recordingTimer: Timer?
    private var frameCount: Int = 0

    private let sessionQueue = DispatchQueue(label: "com.multilens.session")
    private let recordingQueue = DispatchQueue(label: "com.multilens.recording")
    private var countdownTimer: Timer?
    private var capturedPhotos: [LensType: AVCapturePhoto] = [:]
    private var pendingLenses: [LensType] = []

    var settings = CaptureSettings()

    var activeDevice: AVCaptureDevice? {
        currentInput?.device
    }

    static var isSupported: Bool { true }

    override init() {
        super.init()
        session.sessionPreset = .photo
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer?.videoGravity = .resizeAspectFill
    }

    func configure() {
        detectAvailableLenses()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.setupSession(for: self.previewLens)
            self.session.startRunning()
            DispatchQueue.main.async {
                self.objectWillChange.send()
                self.updateDeviceInfo()
            }
        }
        observeThermalState()
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    private func detectAvailableLenses() {
        var lenses: [LensType] = []
        for lens in LensType.allCases {
            if AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) != nil {
                lenses.append(lens)
            }
        }
        DispatchQueue.main.async { self.availableLenses = lenses }
        if !lenses.contains(previewLens) {
            previewLens = lenses.first ?? .wide
        }
    }

    // MARK: - Session Setup

    private func setupSession(for lens: LensType) {
        session.beginConfiguration()

        // Remove old input
        if let old = currentInput {
            session.removeInput(old)
        }

        // Add new input
        guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device)
        else {
            session.commitConfiguration()
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
        }

        // Photo output (add only once)
        if photoOutput.connections.isEmpty && session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
            if photoOutput.isAppleProRAWSupported {
                photoOutput.isAppleProRAWEnabled = true
            }
        }

        // Video data output (add only once)
        if videoDataOutput.connections.isEmpty && session.canAddOutput(videoDataOutput) {
            videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            ]
            videoDataOutput.alwaysDiscardsLateVideoFrames = false
            session.addOutput(videoDataOutput)
            videoDataOutput.setSampleBufferDelegate(self, queue: recordingQueue)
        }

        session.commitConfiguration()
    }

    // MARK: - Switch Lens

    func switchPreview(to lens: LensType) {
        guard availableLenses.contains(lens) else { return }
        previewLens = lens
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.setupSession(for: lens)
            DispatchQueue.main.async { self.updateDeviceInfo() }
        }
    }

    func switchToNextLens() {
        let lenses = availableLenses
        guard let idx = lenses.firstIndex(of: previewLens) else { return }
        let next = lenses[(idx + 1) % lenses.count]
        switchPreview(to: next)
    }

    // MARK: - Manual Controls

    func setISO(_ value: Float) {
        guard let device = activeDevice else { return }
        let clamped = min(max(value, device.activeFormat.minISO), device.activeFormat.maxISO)
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration, iso: clamped)
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.iso = clamped; self.isManualExposure = true }
        } catch {}
    }

    func setShutterSpeed(_ duration: Double) {
        guard let device = activeDevice else { return }
        let cmTime = CMTimeMakeWithSeconds(duration, preferredTimescale: 1000000)
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: cmTime, iso: AVCaptureDevice.currentISO)
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.shutterSpeed = duration; self.isManualExposure = true }
        } catch {}
    }

    func setShutterAngle(_ angle: Double) {
        let fps = settings.frameRate.value
        let duration = angle / (360.0 * fps)
        setShutterSpeed(duration)
        DispatchQueue.main.async { self.shutterAngle = angle }
    }

    func setWhiteBalance(temperature: Float, tint: Float) {
        guard let device = activeDevice else { return }
        let tv = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: tint)
        var gains = device.deviceWhiteBalanceGains(for: tv)
        let maxG = device.maxWhiteBalanceGain
        gains.redGain = min(max(gains.redGain, 1.0), maxG)
        gains.greenGain = min(max(gains.greenGain, 1.0), maxG)
        gains.blueGain = min(max(gains.blueGain, 1.0), maxG)
        do {
            try device.lockForConfiguration()
            device.setWhiteBalanceModeLocked(with: gains)
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.whiteBalance = temperature; self.tint = tint; self.isManualWB = true }
        } catch {}
    }

    func setAutoWhiteBalance() {
        guard let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            device.whiteBalanceMode = .continuousAutoWhiteBalance
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.isManualWB = false }
        } catch {}
    }

    func setManualFocus(_ position: Float) {
        guard let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: min(max(position, 0), 1))
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.manualFocusPosition = position; self.isManualFocus = true }
        } catch {}
    }

    func setAutoFocus() {
        guard let device = activeDevice, device.isFocusModeSupported(.continuousAutoFocus) else { return }
        do {
            try device.lockForConfiguration()
            device.focusMode = .continuousAutoFocus
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.isManualFocus = false }
        } catch {}
    }

    func setAutoExposure() {
        guard let device = activeDevice else { return }
        do {
            try device.lockForConfiguration()
            device.exposureMode = .continuousAutoExposure
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.isManualExposure = false }
        } catch {}
    }

    func setFrameRate(_ fps: Double) {
        guard let device = activeDevice else { return }
        let duration = CMTimeMake(value: 1, timescale: Int32(fps))
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard ranges.contains(where: { fps >= $0.minFrameRate && fps <= $0.maxFrameRate }) else { return }
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.currentFPS = fps }
        } catch {}
    }

    // MARK: - Photo Capture

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
            if remaining <= 0 { timer.invalidate(); self?.triggerCapture() }
            else { DispatchQueue.main.async { self?.captureState = .countdown(remaining) } }
        }
    }

    private func triggerCapture() {
        captureState = .capturing
        if settings.hapticEnabled { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }

        // Capture from all available lenses sequentially
        capturedPhotos.removeAll()
        pendingLenses = availableLenses
        captureNextLens()
    }

    private func captureNextLens() {
        guard !pendingLenses.isEmpty else {
            // All done — save
            savePhotos(capturedPhotos)
            return
        }

        let lens = pendingLenses.removeFirst()

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.setupSession(for: lens)

            // Small delay for camera to stabilize
            Thread.sleep(forTimeInterval: 0.3)

            DispatchQueue.main.async {
                self.firePhoto(forLens: lens)
            }
        }
    }

    private func firePhoto(forLens lens: LensType) {
        let photoSettings: AVCapturePhotoSettings

        if photoOutput.isAppleProRAWEnabled,
           let rawFormat = photoOutput.availableRawPhotoPixelFormatTypes.first {
            photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        } else {
            photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        }

        photoSettings.photoQualityPrioritization = .quality

        switch settings.flashMode {
        case .off: photoSettings.flashMode = .off
        case .on: photoSettings.flashMode = .on
        case .auto: photoSettings.flashMode = .auto
        }

        currentCaptureLens = lens
        photoOutput.capturePhoto(with: photoSettings, delegate: self)
    }

    private var currentCaptureLens: LensType = .wide

    private func savePhotos(_ photos: [LensType: AVCapturePhoto]) {
        DispatchQueue.main.async { self.captureState = .saving }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var savedCount = 0
            let group = DispatchGroup()

            for (_, photo) in photos {
                guard let data = photo.fileDataRepresentation() else { continue }
                let ext = photo.isRawPhoto ? "dng" : "heic"
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MultiLens_\(UUID().uuidString).\(ext)")
                do { try data.write(to: tempURL) } catch { continue }

                group.enter()
                PHPhotoLibrary.shared().performChanges {
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: photo.isRawPhoto ? .alternatePhoto : .photo, fileURL: tempURL, options: nil)
                } completionHandler: { success, _ in
                    if success { savedCount += 1 }
                    try? FileManager.default.removeItem(at: tempURL)
                    group.leave()
                }
            }

            group.wait()

            DispatchQueue.main.async {
                self.lastSaveCount = savedCount
                self.toastMessage = "\(savedCount) ProRAW DNG saved"
                self.showToast = true
                self.captureState = .idle
                // Restore preview lens
                self.switchPreview(to: self.previewLens)
                if self.settings.hapticEnabled {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        }
    }

    // MARK: - Video Recording

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        guard let device = activeDevice else { return }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiLens_\(UUID().uuidString).mov")

        do { assetWriter = try AVAssetWriter(outputURL: tempURL, fileType: .mov) }
        catch { captureState = .error("Writer error"); return }

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: settings.videoCodec.avCodecType,
            AVVideoWidthKey: Int(dims.width),
            AVVideoHeightKey: Int(dims.height)
        ]
        if let colorProps = settings.colorSpace.videoColorProperties {
            videoSettings[AVVideoColorPropertiesKey] = colorProps
        }

        videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput?.expectsMediaDataInRealTime = true

        let pixelFormat = videoDataOutput.videoSettings[kCVPixelBufferPixelFormatTypeKey as String] as? OSType
            ?? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        let sourceAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: Int(dims.width),
            kCVPixelBufferHeightKey as String: Int(dims.height)
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput!, sourcePixelBufferAttributes: sourceAttrs)

        if let input = videoWriterInput, assetWriter!.canAdd(input) { assetWriter!.add(input) }

        assetWriter!.startWriting()
        recordingStartTime = nil
        frameCount = 0
        isRecording = true
        captureState = .recording
        recordingDuration = 0

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            let elapsed = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) - CMTimeGetSeconds(start)
            DispatchQueue.main.async { self.recordingDuration = elapsed }
        }
    }

    func stopRecording() {
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil

        guard let writer = assetWriter else { return }
        videoWriterInput?.markAsFinished()

        writer.finishWriting { [weak self] in
            guard writer.status == .completed else {
                DispatchQueue.main.async { self?.captureState = .error("Recording failed") }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: writer.outputURL)
            } completionHandler: { success, _ in
                try? FileManager.default.removeItem(at: writer.outputURL)
                DispatchQueue.main.async {
                    self?.captureState = .idle
                    if success {
                        self?.toastMessage = "Video saved (\(self?.settings.videoCodec.rawValue ?? ""))"
                        self?.showToast = true
                    }
                }
            }
        }
    }

    // MARK: - Gestures

    func setZoom(_ factor: CGFloat) {
        guard let device = activeDevice else { return }
        let clamped = min(max(factor, 1.0), min(device.activeFormat.videoMaxZoomFactor, 15.0))
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.zoomFactor = clamped }
        } catch {}
    }

    func focus(at point: CGPoint, in viewSize: CGSize) {
        guard let device = activeDevice, device.isFocusPointOfInterestSupported else { return }
        let fp = CGPoint(x: point.y / viewSize.height, y: 1.0 - point.x / viewSize.width)
        do {
            try device.lockForConfiguration()
            device.focusPointOfInterest = fp
            device.focusMode = .autoFocus
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = fp
                device.exposureMode = .autoExpose
            }
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.focusPoint = point; self.isExposureLocked = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.focusPoint = nil }
        } catch {}
    }

    func adjustExposure(by delta: Float) {
        guard let device = activeDevice else { return }
        let newBias = min(max(device.exposureTargetBias + delta,
                              device.minExposureTargetBias), device.maxExposureTargetBias)
        do {
            try device.lockForConfiguration()
            device.setExposureTargetBias(newBias) { _ in }
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.exposureValue = newBias }
        } catch {}
    }

    // MARK: - Helpers

    private func updateDeviceInfo() {
        guard let device = activeDevice else { return }
        isoRange = (device.activeFormat.minISO, device.activeFormat.maxISO)
        iso = device.iso
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

// MARK: - Photo Delegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil else {
            DispatchQueue.main.async { self.captureState = .error("Capture failed") }
            return
        }

        capturedPhotos[currentCaptureLens] = photo
        captureNextLens()
    }
}

// MARK: - Video Delegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isRecording,
              let writerInput = videoWriterInput,
              writerInput.isReadyForMoreMediaData,
              let adaptor = pixelBufferAdaptor
        else { return }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if recordingStartTime == nil {
            recordingStartTime = timestamp
            assetWriter?.startSession(atSourceTime: timestamp)
        }

        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            adaptor.append(pixelBuffer, withPresentationTime: timestamp)
            frameCount += 1
        }
    }
}
