import SwiftUI
import AVFoundation

struct CaptureView: View {
    @StateObject private var camera = CameraManager()
    @State private var permissionGranted = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !CameraManager.isSupported {
                UnsupportedView()
            } else if !permissionGranted {
                PermissionView { requestPermissions() }
            } else {
                ViewfinderView(camera: camera, showSettings: $showSettings)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { checkPermissions() }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: camera.settings)
        }
    }

    private func checkPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            permissionGranted = true
            camera.configure()
        }
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                permissionGranted = granted
                if granted { camera.configure() }
            }
        }
    }
}

// MARK: - Viewfinder

struct ViewfinderView: View {
    @ObservedObject var camera: CameraManager
    @Binding var showSettings: Bool
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                CameraPreviewView(previewLayer: camera.previewLayer)
                    .ignoresSafeArea()
                    .gesture(pinchGesture)
                    .gesture(tapGesture(in: geo.size))
                    .gesture(doubleTapGesture)
                    .gesture(swipeGesture)

                if camera.settings.gridEnabled {
                    GridOverlay().allowsHitTesting(false)
                }

                if let point = camera.focusPoint {
                    FocusIndicator(point: point, locked: camera.isExposureLocked)
                }

                // Top bar
                VStack(spacing: 0) {
                    TopBarView(camera: camera, showSettings: $showSettings)
                    Spacer()
                }

                // Bottom
                VStack(spacing: 0) {
                    Spacer()

                    if camera.thermalWarning {
                        ThermalBanner().padding(.bottom, 8)
                    }

                    if case .countdown(let s) = camera.captureState {
                        Text("\(s)")
                            .font(.system(size: 72, weight: .thin, design: .rounded))
                            .foregroundColor(.white)
                            .padding(.bottom, 16)
                    }

                    if camera.isRecording {
                        RecordingIndicator(duration: camera.recordingDuration)
                            .padding(.bottom, 12)
                    }

                    BottomBar(camera: camera)
                        .padding(.bottom, 24)
                }

                // Toast
                if camera.showToast {
                    VStack {
                        ToastView(count: camera.lastSaveCount, recording: camera.captureState == .idle && camera.lastSaveCount == 0)
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                    withAnimation { camera.showToast = false }
                                }
                            }
                        Spacer()
                    }.padding(.top, 60)
                }

                if case .error(let msg) = camera.captureState {
                    VStack {
                        ErrorBanner(message: msg).padding(.top, 60)
                        Spacer()
                    }
                }
            }
        }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { val in
                let delta = val / lastScale
                lastScale = val
                camera.setZoom(camera.zoomFactor * delta)
            }
            .onEnded { _ in lastScale = 1.0 }
    }

    private func tapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { val in camera.focus(at: val.location, in: size) }
    }

    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded { camera.switchToNextLens() }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 60)
            .onEnded { val in
                if abs(val.translation.width) > abs(val.translation.height) {
                    camera.switchToNextLens()
                } else {
                    let delta = Float(-val.translation.height / 600)
                    camera.adjustExposure(by: delta)
                }
            }
    }
}

// MARK: - Camera Preview UIKit Bridge

struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> UIView {
        let view = PreviewHostView()
        view.layer.addSublayer(previewLayer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        previewLayer.frame = uiView.bounds
    }

    class PreviewHostView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.sublayers?.forEach { $0.frame = bounds }
        }
    }
}

// MARK: - Top Bar

struct TopBarView: View {
    @ObservedObject var camera: CameraManager
    @Binding var showSettings: Bool

    var body: some View {
        HStack {
            Button {
                let modes = FlashMode.allCases
                let idx = modes.firstIndex(of: camera.settings.flashMode) ?? 0
                camera.settings.flashMode = modes[(idx + 1) % modes.count]
            } label: {
                Image(systemName: flashIcon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(camera.settings.flashMode == .off ? .white : .yellow)
            }

            Spacer()

            HStack(spacing: 6) {
                Text("ProRAW")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.yellow)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.yellow.opacity(0.15)))

                Text("48MP")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }

            Spacer()

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var flashIcon: String {
        switch camera.settings.flashMode {
        case .off: return "bolt.slash.fill"
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.automatic.fill"
        }
    }
}

// MARK: - Bottom Bar

struct BottomBar: View {
    @ObservedObject var camera: CameraManager

    var body: some View {
        VStack(spacing: 16) {
            // Lens selector
            HStack(spacing: 4) {
                ForEach(LensType.allCases, id: \.self) { lens in
                    Button {
                        camera.previewLens = lens
                        camera.switchPreview(to: lens)
                    } label: {
                        Text(lens.rawValue)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(camera.previewLens == lens ? .yellow : .white.opacity(0.5))
                            .frame(width: 48, height: 32)
                            .background(
                                Capsule().fill(camera.previewLens == lens
                                    ? Color.yellow.opacity(0.15)
                                    : Color.white.opacity(0.06))
                            )
                    }
                }
            }

            // Capture controls
            HStack(spacing: 40) {
                // Record button (ProRes)
                Button { camera.toggleRecording() } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.red, lineWidth: 2.5)
                            .frame(width: 44, height: 44)
                        if camera.isRecording {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.red)
                                .frame(width: 18, height: 18)
                        } else {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 18, height: 18)
                        }
                    }
                }

                // Photo shutter (3x capture)
                Button { camera.captureAll() } label: {
                    ZStack {
                        Circle()
                            .stroke(Color.white, lineWidth: 3.5)
                            .frame(width: 72, height: 72)
                        Circle()
                            .fill(captureActive ? Color.white : Color.white.opacity(0.3))
                            .frame(width: 60, height: 60)
                    }
                }
                .disabled(!captureActive)

                // Exposure indicator
                VStack(spacing: 2) {
                    Image(systemName: camera.isExposureLocked ? "sun.max.fill" : "sun.max")
                        .font(.system(size: 14))
                        .foregroundColor(camera.isExposureLocked ? .yellow : .white.opacity(0.5))
                    if abs(camera.exposureValue) > 0.1 {
                        Text(String(format: "%+.1f", camera.exposureValue))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 20)
    }

    private var captureActive: Bool {
        camera.captureState == .idle
    }
}

// MARK: - Supporting Views

struct RecordingIndicator: View {
    let duration: TimeInterval
    @State private var blinking = true

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(blinking ? 1 : 0.3)
                .animation(.easeInOut(duration: 0.6).repeatForever(), value: blinking)
                .onAppear { blinking.toggle() }

            Text(formatTime(duration))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.red.opacity(0.3)))
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct FocusIndicator: View {
    let point: CGPoint
    let locked: Bool
    @State private var scale: CGFloat = 1.4

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(locked ? Color.yellow : Color.white, lineWidth: 1.5)
            .frame(width: 70, height: 70)
            .overlay(alignment: .top) {
                if locked {
                    Text("AE/AF LOCK")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.yellow)
                        .offset(y: -16)
                }
            }
            .scaleEffect(scale)
            .position(point)
            .onAppear {
                withAnimation(.easeOut(duration: 0.2)) { scale = 1.0 }
            }
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            Path { p in
                p.move(to: CGPoint(x: w/3, y: 0)); p.addLine(to: CGPoint(x: w/3, y: h))
                p.move(to: CGPoint(x: 2*w/3, y: 0)); p.addLine(to: CGPoint(x: 2*w/3, y: h))
                p.move(to: CGPoint(x: 0, y: h/3)); p.addLine(to: CGPoint(x: w, y: h/3))
                p.move(to: CGPoint(x: 0, y: 2*h/3)); p.addLine(to: CGPoint(x: w, y: 2*h/3))
            }
            .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        }
    }
}

struct ToastView: View {
    let count: Int
    let recording: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green).font(.system(size: 14))
            if recording {
                Text("Video saved")
            } else {
                Text("\(count) photos saved (ProRAW DNG)")
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color(white: 0.12)))
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.red.opacity(0.85)))
            .padding(.horizontal, 20)
    }
}

struct ThermalBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "thermometer.sun.fill").font(.system(size: 12)).foregroundColor(.orange)
            Text("Device warm").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(Color.orange.opacity(0.2)))
    }
}

struct UnsupportedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.badge.ellipsis").font(.system(size: 48)).foregroundColor(.gray)
            Text("Multi-Camera Not Supported").font(.system(size: 18, weight: .semibold)).foregroundColor(.white)
            Text("Requires iPhone 14 Pro or later.").font(.system(size: 14)).foregroundColor(.gray)
        }
    }
}

struct PermissionView: View {
    let onRequest: () -> Void
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill").font(.system(size: 48)).foregroundColor(.white.opacity(0.6))
            Text("Camera Access").font(.system(size: 20, weight: .semibold)).foregroundColor(.white)
            Button("Allow Camera", action: onRequest)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(Capsule().fill(Color.white))
        }
    }
}
