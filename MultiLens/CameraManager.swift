import AVFoundation
import Photos
import UIKit
import CoreMedia

enum LensType: String, CaseIterable, Identifiable {
    case ultraWide = "0.5x"
    case wide = "1x"
    case telephoto = "4x"
    var id: String { rawValue }

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
    case capturing
    case saving
    case recording
    case error(String)
}

final class CameraManager: NSObject, ObservableObject {
    @Published var captureState: CaptureState = .idle
    @Published var previewLens: LensType = .wide
    @Published var showToast = false
    @Published var toastMessage = ""
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var availableLenses: [LensType] = []
    @Published var zoomFactor: CGFloat = 1.0
    @Published var focusPoint: CGPoint?
    @Published var iso: Float = 100
    @Published var isoRange: (Float, Float) = (32, 3200)
    @Published var shutterAngle: Double = 180
    @Published var whiteBalance: Float = 5500
    @Published var manualFocusPosition: Float = 0.5
    @Published var isManualFocus = false
    @Published var isManualExposure = false

    private let session = AVCaptureSession()
    private var previewLayerBacking: AVCaptureVideoPreviewLayer?
    var previewLayer: AVCaptureVideoPreviewLayer? { previewLayerBacking }

    private var currentInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureMovieFileOutput()

    private let sessionQueue = DispatchQueue(label: "com.multilens.session")
    private var capturedPhotos: [LensType: AVCapturePhoto] = [:]
    private var pendingLenses: [LensType] = []
    private var currentCaptureLens: LensType = .wide
    private var recordingTimer: Timer?

    var settings = CaptureSettings()
    var activeDevice: AVCaptureDevice? { currentInput?.device }

    override init() {
        super.init()
    }

    func configure() {
        // Detect lenses on main thread
        var lenses: [LensType] = []
        for lens in LensType.allCases {
            if AVCaptureDevice.default(lens.deviceType, for: .video, position: .back) != nil {
                lenses.append(lens)
            }
        }
        availableLenses = lenses
        if !lenses.contains(previewLens), let first = lenses.first {
            previewLens = first
        }

        // Setup on session queue
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            // Input
            if let device = AVCaptureDevice.default(self.previewLens.deviceType, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
                self.currentInput = input
            }

            // Photo output
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
                self.photoOutput.maxPhotoQualityPrioritization = .quality
                if self.photoOutput.isAppleProRAWSupported {
                    self.photoOutput.isAppleProRAWEnabled = true
                }
            }

            // Video output for recording
            if self.session.canAddOutput(self.videoOutput) {
                self.session.addOutput(self.videoOutput)
            }

            self.session.commitConfiguration()
            self.session.startRunning()

            DispatchQueue.main.async {
                self.previewLayerBacking = AVCaptureVideoPreviewLayer(session: self.session)
                self.previewLayerBacking?.videoGravity = .resizeAspectFill
                self.objectWillChange.send()
                self.updateDeviceInfo()
            }
        }
    }

    // MARK: - Switch Lens

    func switchPreview(to lens: LensType) {
        guard availableLenses.contains(lens) else { return }
        previewLens = lens

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()

            if let old = self.currentInput {
                self.session.removeInput(old)
                self.currentInput = nil
            }

            if let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
                self.currentInput = input
            }

            self.session.commitConfiguration()
            DispatchQueue.main.async { self.updateDeviceInfo() }
        }
    }

    func switchToNextLens() {
        let lenses = availableLenses
        guard let idx = lenses.firstIndex(of: previewLens) else { return }
        switchPreview(to: lenses[(idx + 1) % lenses.count])
    }

    // MARK: - Photo Capture (all lenses)

    func captureAll() {
        guard captureState == .idle else { return }
        captureState = .capturing
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        capturedPhotos.removeAll()
        pendingLenses = availableLenses
        captureNextLens()
    }

    private func captureNextLens() {
        guard !pendingLenses.isEmpty else {
            saveAllPhotos()
            return
        }

        let lens = pendingLenses.removeFirst()
        currentCaptureLens = lens

        sessionQueue.async { [weak self] in
            guard let self else { return }

            // Switch to this lens
            self.session.beginConfiguration()
            if let old = self.currentInput {
                self.session.removeInput(old)
                self.currentInput = nil
            }
            if let device = AVCaptureDevice.default(lens.deviceType, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
                self.currentInput = input
            }
            self.session.commitConfiguration()

            // Wait for camera to stabilize
            Thread.sleep(forTimeInterval: 0.4)

            // Capture
            DispatchQueue.main.async {
                let settings: AVCapturePhotoSettings
                if self.photoOutput.isAppleProRAWEnabled,
                   let raw = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                    settings = AVCapturePhotoSettings(rawPixelFormatType: raw)
                } else {
                    settings = AVCapturePhotoSettings()
                }
                settings.photoQualityPrioritization = .quality
                self.photoOutput.capturePhoto(with: settings, delegate: self)
            }
        }
    }

    private func saveAllPhotos() {
        captureState = .saving

        // Restore preview lens
        switchPreview(to: previewLens)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var count = 0
            let group = DispatchGroup()

            for (_, photo) in self.capturedPhotos {
                guard let data = photo.fileDataRepresentation() else { continue }
                let ext = photo.isRawPhoto ? "dng" : "heic"
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).\(ext)")
                guard (try? data.write(to: url)) != nil else { continue }

                group.enter()
                PHPhotoLibrary.shared().performChanges {
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: photo.isRawPhoto ? .alternatePhoto : .photo, fileURL: url, options: nil)
                } completionHandler: { ok, _ in
                    if ok { count += 1 }
                    try? FileManager.default.removeItem(at: url)
                    group.leave()
                }
            }
            group.wait()

            DispatchQueue.main.async {
                self.toastMessage = "\(count) photos saved"
                self.showToast = true
                self.captureState = .idle
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    // MARK: - Video Recording (ProRes 422 HQ via MovieFileOutput)

    func toggleRecording() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MultiLens_\(UUID().uuidString).mov")

        // Set ProRes codec if available
        if let conn = videoOutput.connection(with: .video) {
            if videoOutput.availableVideoCodecTypes.contains(.proRes422HQ) {
                videoOutput.setOutputSettings(
                    [AVVideoCodecKey: AVVideoCodecType.proRes422HQ], for: conn)
            }
        }

        videoOutput.startRecording(to: url, recordingDelegate: self)
        isRecording = true
        captureState = .recording
        recordingDuration = 0
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.recordingDuration = self.videoOutput.recordedDuration.seconds
            }
        }
    }

    func stopRecording() {
        videoOutput.stopRecording()
        recordingTimer?.invalidate()
        recordingTimer = nil
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

    func setShutterAngle(_ angle: Double) {
        guard let device = activeDevice else { return }
        let fps = Double(device.activeVideoMinFrameDuration.timescale) / Double(device.activeVideoMinFrameDuration.value)
        let duration = CMTimeMakeWithSeconds(angle / (360.0 * fps), preferredTimescale: 1000000)
        do {
            try device.lockForConfiguration()
            device.setExposureModeCustom(duration: duration, iso: AVCaptureDevice.currentISO)
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.shutterAngle = angle; self.isManualExposure = true }
        } catch {}
    }

    func setWhiteBalance(temperature: Float) {
        guard let device = activeDevice else { return }
        let tv = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: 0)
        var gains = device.deviceWhiteBalanceGains(for: tv)
        let m = device.maxWhiteBalanceGain
        gains.redGain = min(max(gains.redGain, 1.0), m)
        gains.greenGain = min(max(gains.greenGain, 1.0), m)
        gains.blueGain = min(max(gains.blueGain, 1.0), m)
        do {
            try device.lockForConfiguration()
            device.setWhiteBalanceModeLocked(with: gains)
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.whiteBalance = temperature }
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
            DispatchQueue.main.async { self.focusPoint = point }
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
        } catch {}
    }

    private func updateDeviceInfo() {
        guard let device = activeDevice else { return }
        isoRange = (device.activeFormat.minISO, device.activeFormat.maxISO)
        iso = device.iso
    }
}

// MARK: - Photo Delegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if error == nil {
            capturedPhotos[currentCaptureLens] = photo
        }
        captureNextLens()
    }
}

// MARK: - Video Delegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async { self.isRecording = false; self.captureState = .idle }

        guard error == nil else {
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }

        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputFileURL)
        } completionHandler: { [weak self] ok, _ in
            try? FileManager.default.removeItem(at: outputFileURL)
            if ok {
                DispatchQueue.main.async {
                    self?.toastMessage = "Video saved (ProRes 422 HQ)"
                    self?.showToast = true
                }
            }
        }
    }
}
