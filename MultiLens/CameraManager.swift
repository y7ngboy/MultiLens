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
    // MARK: - Published State
    @Published var captureState: CaptureState = .idle
    @Published var previewLens: LensType = .wide
    @Published var lastSaveCount = 0
    @Published var showToast = false
    @Published var toastMessage = ""
    @Published var thermalWarning = false

    // Manual controls
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

    // Recording
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0

    // Device info
    @Published var isoRange: (Float, Float) = (32, 3200)
    @Published var currentFPS: Double = 24

    private(set) var session: AVCaptureMultiCamSession!
    private(set) var previewLayer: AVCaptureVideoPreviewLayer!

    private var ultraWideInput: AVCaptureDeviceInput?
    private var wideInput: AVCaptureDeviceInput?
    private var telephotoInput: AVCaptureDeviceInput?

    private let ultraWidePhotoOutput = AVCapturePhotoOutput()
    private let widePhotoOutput = AVCapturePhotoOutput()
    private let telephotoPhotoOutput = AVCapturePhotoOutput()

    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var assetWriter: AVAssetWriter?
    private var videoWriterInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var recordingStartTime: CMTime?
    private var recordingTimer: Timer?
    private var frameCount: Int = 0

    private var previewConnection: AVCaptureConnection?
    private let captureCoordinator = CaptureCoordinator()
    private let sessionQueue = DispatchQueue(label: "com.multilens.session")
    private let recordingQueue = DispatchQueue(label: "com.multilens.recording")
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
        super.init()
    }

    func configure() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            DispatchQueue.main.async { self.captureState = .error("MultiCam not supported") }
            return
        }

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session = AVCaptureMultiCamSession()

            DispatchQueue.main.sync {
                self.previewLayer = AVCaptureVideoPreviewLayer(session: self.session)
                self.previewLayer.videoGravity = .resizeAspectFill
            }

            self.setupSession()
            self.session.startRunning()
            DispatchQueue.main.async {
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

    // MARK: - Manual Controls

    func setISO(_ value: Float) {
        guard let device = activeDevice else { return }
        let clamped = min(max(value, device.activeFormat.minISO), device.activeFormat.maxISO)
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: AVCaptureDevice.currentExposureDuration, iso: clamped)
            device.unlockForConfiguration()
            DispatchQueue.main.async {
                self.iso = clamped
                self.isManualExposure = true
            }
        } catch {}
    }

    func setShutterSpeed(_ duration: Double) {
        guard let device = activeDevice else { return }
        let cmTime = CMTimeMakeWithSeconds(duration, preferredTimescale: 1000000)
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: cmTime, iso: AVCaptureDevice.currentISO)
            device.unlockForConfiguration()
            DispatchQueue.main.async {
                self.shutterSpeed = duration
                self.isManualExposure = true
            }
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
        let temperatureAndTint = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
            temperature: temperature, tint: tint)
        var gains = device.deviceWhiteBalanceGains(for: temperatureAndTint)
        let maxGain = device.maxWhiteBalanceGain
        gains.redGain = min(max(gains.redGain, 1.0), maxGain)
        gains.greenGain = min(max(gains.greenGain, 1.0), maxGain)
        gains.blueGain = min(max(gains.blueGain, 1.0), maxGain)
        do {
            try device.lockForConfiguration()
            device.setWhiteBalanceModeLocked(with: gains)
            device.unlockForConfiguration()
            DispatchQueue.main.async {
                self.whiteBalance = temperature
                self.tint = tint
                self.isManualWB = true
            }
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
        let clamped = min(max(position, 0), 1)
        do {
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: clamped)
            device.unlockForConfiguration()
            DispatchQueue.main.async {
                self.manualFocusPosition = clamped
                self.isManualFocus = true
            }
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
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.currentFPS = fps }
        } catch {}
    }

    // MARK: - Photo Capture (3x ProRAW DNG)

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
                DispatchQueue.main.async { self?.captureState = .countdown(remaining) }
            }
        }
    }

    private func triggerCapture() {
        captureState = .capturing
        if settings.hapticEnabled {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }

        captureCoordinator.reset()
        captureCoordinator.onAllCaptured = { [weak self] photos in
            self?.savePhotos(photos)
        }
        captureCoordinator.onError = { [weak self] msg in
            DispatchQueue.main.async { self?.captureState = .error(msg) }
        }

        firePhoto(output: ultraWidePhotoOutput)
        firePhoto(output: widePhotoOutput)
        firePhoto(output: telephotoPhotoOutput)
    }

    private func firePhoto(output: AVCapturePhotoOutput) {
        let photoSettings: AVCapturePhotoSettings

        if output.isAppleProRAWEnabled,
           let rawFormat = output.availableRawPhotoPixelFormatTypes.first {
            photoSettings = AVCapturePhotoSettings(rawPixelFormatType: rawFormat)
        } else {
            photoSettings = AVCapturePhotoSettings(format: [
                AVVideoCodecKey: AVVideoCodecType.hevc
            ])
        }

        photoSettings.photoQualityPrioritization = .quality

        switch settings.flashMode {
        case .off: photoSettings.flashMode = .off
        case .on: photoSettings.flashMode = .on
        case .auto: photoSettings.flashMode = .auto
        }

        output.capturePhoto(with: photoSettings, delegate: captureCoordinator)
    }

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
                    let request = PHAssetCreationRequest.forAsset()
                    let resourceType: PHAssetResourceType = photo.isRawPhoto ? .alternatePhoto : .photo
                    request.addResource(with: resourceType, fileURL: tempURL, options: nil)
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

        do {
            assetWriter = try AVAssetWriter(outputURL: tempURL, fileType: .mov)
        } catch {
            captureState = .error("Cannot create writer: \(error.localizedDescription)")
            return
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)

        // Check if we got Bayer RAW frames
        let outputPixelFormat = videoDataOutput.videoSettings[
            kCVPixelBufferPixelFormatTypeKey as String] as? OSType ?? 0
        let bayerFormats: [OSType] = [
            kCVPixelFormatType_14Bayer_BGGR, kCVPixelFormatType_14Bayer_GBRG,
            kCVPixelFormatType_14Bayer_GRBG, kCVPixelFormatType_14Bayer_RGGB
        ]
        let isBayer = bayerFormats.contains(outputPixelFormat)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: isBayer ? AVVideoCodecType.proRes4444 : settings.videoCodec.avCodecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]

        if let colorProps = settings.colorSpace.videoColorProperties {
            videoSettings[AVVideoColorPropertiesKey] = colorProps
        }

        videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoWriterInput?.expectsMediaDataInRealTime = true

        let sourceAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: outputPixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoWriterInput!, sourcePixelBufferAttributes: sourceAttrs)

        if let writerInput = videoWriterInput, assetWriter!.canAdd(writerInput) {
            assetWriter!.add(writerInput)
        }

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
                DispatchQueue.main.async {
                    self?.captureState = .error("Recording failed: \(writer.error?.localizedDescription ?? "unknown")")
                }
                return
            }

            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: writer.outputURL)
            } completionHandler: { success, _ in
                try? FileManager.default.removeItem(at: writer.outputURL)
                DispatchQueue.main.async {
                    self?.captureState = .idle
                    if success {
                        self?.toastMessage = "Video saved (\(self?.settings.videoCodec.rawValue ?? "ProRes"))"
                        self?.showToast = true
                        if self?.settings.hapticEnabled == true {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Lens & Gestures

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
            DispatchQueue.main.async {
                self.focusPoint = point
                self.isExposureLocked = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.focusPoint = nil }
        } catch {}
    }

    func lockExposure(at point: CGPoint, in viewSize: CGSize) {
        guard let device = activeDevice, device.isExposurePointOfInterestSupported else { return }
        let ep = CGPoint(x: point.y / viewSize.height, y: 1.0 - point.x / viewSize.width)
        do {
            try device.lockForConfiguration()
            device.exposurePointOfInterest = ep
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
                              device.minExposureTargetBias), device.maxExposureTargetBias)
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
        previewLens = next
        switchPreview(to: next)
        updateDeviceInfo()
    }

    func switchPreview(to lens: LensType) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()

            if let existing = self.previewConnection {
                self.session.removeConnection(existing)
                self.previewConnection = nil
            }

            let input: AVCaptureDeviceInput?
            switch lens {
            case .ultraWide: input = self.ultraWideInput
            case .wide: input = self.wideInput
            case .telephoto: input = self.telephotoInput
            }

            if let input,
               let port = input.ports(for: .video, sourceDeviceType: lens.deviceType, sourceDevicePosition: .back).first {
                let conn = AVCaptureConnection(inputPort: port, videoPreviewLayer: self.previewLayer)
                if self.session.canAddConnection(conn) {
                    self.session.addConnection(conn)
                    self.previewConnection = conn
                }
            }

            self.session.commitConfiguration()
        }
    }

    // MARK: - Session Setup

    private func setupSession() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            DispatchQueue.main.async { self.captureState = .error("MultiCam not supported") }
            return
        }

        session.beginConfiguration()

        for lens in LensType.allCases {
            guard let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device)
            else { continue }

            if session.canAddInput(input) {
                session.addInput(input)
                switch lens {
                case .ultraWide: ultraWideInput = input
                case .wide: wideInput = input
                case .telephoto: telephotoInput = input
                }
            }
        }

        // Photo outputs
        let outputPairs: [(AVCapturePhotoOutput, AVCaptureDeviceInput?, LensType)] = [
            (ultraWidePhotoOutput, ultraWideInput, .ultraWide),
            (widePhotoOutput, wideInput, .wide),
            (telephotoPhotoOutput, telephotoInput, .telephoto)
        ]

        for (output, input, lens) in outputPairs {
            guard let input else { continue }
            if session.canAddOutput(output) { session.addOutput(output) }

            let ports = input.ports(for: .video, sourceDeviceType: lens.deviceType, sourceDevicePosition: .back)
            if !ports.isEmpty {
                let conn = AVCaptureConnection(inputPorts: ports, output: output)
                if session.canAddConnection(conn) { session.addConnection(conn) }
            }

            output.maxPhotoQualityPrioritization = .quality
            if output.isAppleProRAWSupported { output.isAppleProRAWEnabled = true }
        }

        // Video data output — try Bayer RAW first
        let availableFormats = videoDataOutput.availableVideoPixelFormatTypes
        let bayerFormats: [OSType] = [
            kCVPixelFormatType_14Bayer_RGGB, kCVPixelFormatType_14Bayer_BGGR,
            kCVPixelFormatType_14Bayer_GBRG, kCVPixelFormatType_14Bayer_GRBG
        ]
        let selectedFormat: OSType
        if let bayer = bayerFormats.first(where: { availableFormats.contains($0) }) {
            selectedFormat = bayer
        } else {
            selectedFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: selectedFormat]
        videoDataOutput.alwaysDiscardsLateVideoFrames = false

        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            videoDataOutput.setSampleBufferDelegate(self, queue: recordingQueue)

            if let wInput = wideInput {
                let ports = wInput.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .back)
                if !ports.isEmpty {
                    let conn = AVCaptureConnection(inputPorts: ports, output: videoDataOutput)
                    if session.canAddConnection(conn) { session.addConnection(conn) }
                }
            }
        }

        // Preview — start with wide
        if let wInput = wideInput,
           let port = wInput.ports(for: .video, sourceDeviceType: .builtInWideAngleCamera, sourceDevicePosition: .back).first {
            let conn = AVCaptureConnection(inputPort: port, videoPreviewLayer: previewLayer)
            if session.canAddConnection(conn) {
                session.addConnection(conn)
                previewConnection = conn
            }
        }

        session.commitConfiguration()

        // Set initial frame rate
        if let device = wideInput?.device {
            let fps = settings.frameRate.value
            let duration = CMTimeMake(value: 1, timescale: Int32(fps))
            do {
                try device.lockForConfiguration()
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
            } catch {}
        }
    }

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

// MARK: - Video Recording Delegate

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
        } else {
            writerInput.append(sampleBuffer)
        }
    }
}
