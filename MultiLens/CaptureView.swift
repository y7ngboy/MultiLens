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
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .authorized {
            permissionGranted = true
            camera.configure()
            camera.startSession()
        }
    }

    private func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                permissionGranted = granted
                if granted {
                    camera.configure()
                    camera.startSession()
                }
            }
        }
    }
}

// MARK: - Main Viewfinder

struct ViewfinderView: View {
    @ObservedObject var camera: CameraManager
    @Binding var showSettings: Bool
    @State private var lastScale: CGFloat = 1.0
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Camera preview
                PreviewLayerView(camera: camera)
                    .ignoresSafeArea()
                    .gesture(pinchGesture)
                    .gesture(tapGesture(in: geo.size))
                    .gesture(longPressGesture(in: geo.size))
                    .gesture(swipeGesture)
                    .gesture(verticalDragGesture)

                // Grid overlay
                if camera.settings.gridEnabled {
                    GridOverlay()
                }

                // Focus indicator
                if let point = camera.focusPoint {
                    FocusIndicator(point: point, locked: camera.isExposureLocked)
                }

                // Top bar
                VStack(spacing: 0) {
                    TopBarView(camera: camera, showSettings: $showSettings)
                    Spacer()
                }

                // Bottom controls
                VStack(spacing: 0) {
                    Spacer()

                    if camera.thermalWarning {
                        ThermalWarningBanner()
                            .padding(.bottom, 8)
                    }

                    if case .encoding = camera.captureState {
                        EncodingProgressView(progress: camera.encodingProgress)
                            .padding(.horizontal, 32)
                            .padding(.bottom, 16)
                    }

                    if case .countdown(let sec) = camera.captureState {
                        CountdownView(seconds: sec)
                            .padding(.bottom, 16)
                    }

                    BottomControlsView(camera: camera)
                        .padding(.bottom, 20)
                }

                // Toast
                if camera.showToast, let size = camera.lastFileSize {
                    VStack {
                        ToastView(fileSize: size)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { camera.showToast = false }
                        }
                    }
                }

                // Error
                if case .error(let msg) = camera.captureState {
                    VStack {
                        ErrorBanner(message: msg)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: Gestures

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let delta = value / lastScale
                lastScale = value
                let newZoom = camera.zoomFactor * delta
                camera.setZoom(newZoom)
            }
            .onEnded { _ in lastScale = 1.0 }
    }

    private func tapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                camera.focus(at: value.location, in: size)
            }
    }

    private func longPressGesture(in size: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.8)
            .sequenced(before: SpatialTapGesture())
            .onEnded { value in
                switch value {
                case .second(true, let tap):
                    if let tap {
                        camera.lockExposure(at: tap.location, in: size)
                    }
                default: break
                }
            }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 50)
            .onEnded { value in
                if abs(value.translation.width) > abs(value.translation.height) {
                    camera.switchToNextLens()
                }
            }
    }

    private var verticalDragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                if abs(value.translation.height) > abs(value.translation.width) {
                    let delta = Float(-value.translation.height / 500)
                    camera.adjustExposure(by: delta - Float(dragOffset / 500))
                    dragOffset = value.translation.height
                }
            }
            .onEnded { _ in dragOffset = 0 }
    }
}

// MARK: - Top Bar (Final Cut Camera style)

struct TopBarView: View {
    @ObservedObject var camera: CameraManager
    @Binding var showSettings: Bool

    var body: some View {
        HStack {
            // Flash
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

            // Format badge
            Text(camera.settings.format.rawValue)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.15)))

            Text("ProRAW")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.yellow.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.yellow.opacity(0.1)))

            Spacer()

            // Settings gear
            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [.black.opacity(0.6), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var flashIcon: String {
        switch camera.settings.flashMode {
        case .off: return "bolt.slash.fill"
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.automatic.fill"
        }
    }
}

// MARK: - Bottom Controls

struct BottomControlsView: View {
    @ObservedObject var camera: CameraManager

    var body: some View {
        VStack(spacing: 16) {
            // Lens selector
            LensSelectorView(selected: $camera.previewLens, zoom: camera.zoomFactor)

            // Shutter row
            HStack(spacing: 50) {
                // Last capture thumbnail placeholder
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 44, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )

                // Shutter
                ShutterButton(state: camera.captureState) {
                    camera.captureAll()
                }

                // Exposure indicator
                ExposureIndicator(value: camera.exposureValue, locked: camera.isExposureLocked)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.5)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

// MARK: - Lens Selector

struct LensSelectorView: View {
    @Binding var selected: LensType
    var zoom: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            ForEach(LensType.allCases, id: \.self) { lens in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selected = lens }
                } label: {
                    Text(lens.rawValue)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(selected == lens ? .yellow : .white.opacity(0.6))
                        .frame(width: 48, height: 32)
                        .background(
                            Capsule()
                                .fill(selected == lens
                                      ? Color.yellow.opacity(0.15)
                                      : Color.white.opacity(0.08))
                        )
                }
            }
        }
    }
}

// MARK: - Shutter Button

struct ShutterButton: View {
    let state: CaptureState
    let action: () -> Void

    private var isActive: Bool {
        if case .idle = state { return true }
        return false
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 72, height: 72)

                Circle()
                    .fill(isActive ? Color.white : Color.white.opacity(0.3))
                    .frame(width: 62, height: 62)

                if case .capturing = state {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 62, height: 62)
                }
            }
        }
        .disabled(!isActive)
        .scaleEffect(isActive ? 1.0 : 0.95)
        .animation(.easeInOut(duration: 0.1), value: state)
    }
}

// MARK: - Focus Indicator

struct FocusIndicator: View {
    let point: CGPoint
    let locked: Bool
    @State private var scale: CGFloat = 1.5
    @State private var opacity: Double = 1.0

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(locked ? Color.yellow : Color.white, lineWidth: 1.5)
            .frame(width: 70, height: 70)
            .overlay(
                locked ? Text("AE/AF LOCK")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.yellow)
                    .offset(y: -44)
                : nil
            )
            .scaleEffect(scale)
            .opacity(opacity)
            .position(point)
            .onAppear {
                withAnimation(.easeOut(duration: 0.3)) { scale = 1.0 }
                if !locked {
                    withAnimation(.easeOut(duration: 1.5).delay(0.5)) { opacity = 0 }
                }
            }
    }
}

// MARK: - Exposure Indicator

struct ExposureIndicator: View {
    let value: Float
    let locked: Bool

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: locked ? "sun.max.fill" : "sun.max")
                .font(.system(size: 14))
                .foregroundColor(locked ? .yellow : .white.opacity(0.6))

            if abs(value) > 0.1 {
                Text(String(format: "%+.1f", value))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
    }
}

// MARK: - Grid Overlay

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            Path { path in
                path.move(to: CGPoint(x: w / 3, y: 0))
                path.addLine(to: CGPoint(x: w / 3, y: h))
                path.move(to: CGPoint(x: 2 * w / 3, y: 0))
                path.addLine(to: CGPoint(x: 2 * w / 3, y: h))
                path.move(to: CGPoint(x: 0, y: h / 3))
                path.addLine(to: CGPoint(x: w, y: h / 3))
                path.move(to: CGPoint(x: 0, y: 2 * h / 3))
                path.addLine(to: CGPoint(x: w, y: 2 * h / 3))
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Encoding Progress

struct EncodingProgressView: View {
    let progress: Double

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.white.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.yellow)
                        .frame(width: geo.size.width * CGFloat(progress))
                }
            }
            .frame(height: 4)

            Text("Encoding TIFF — \(Int(progress * 100))%")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
        }
    }
}

// MARK: - Countdown

struct CountdownView: View {
    let seconds: Int

    var body: some View {
        Text("\(seconds)")
            .font(.system(size: 72, weight: .thin, design: .rounded))
            .foregroundColor(.white)
            .shadow(color: .black.opacity(0.5), radius: 10)
    }
}

// MARK: - Toast

struct ToastView: View {
    let fileSize: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 14))
            Text("Saved")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Text(fileSize)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(Color(white: 0.15).opacity(0.95))
        )
        .padding(.top, 60)
    }
}

// MARK: - Error Banner

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
            .padding(.top, 60)
    }
}

// MARK: - Thermal Warning

struct ThermalWarningBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "thermometer.sun.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange)
            Text("Device is warm")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.orange.opacity(0.2)))
    }
}

// MARK: - Preview Layer Bridge

struct PreviewLayerView: UIViewRepresentable {
    @ObservedObject var camera: CameraManager

    func makeUIView(context: Context) -> PreviewUIView { PreviewUIView() }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.updateLayer(camera.activePreviewLayer)
    }
}

class PreviewUIView: UIView {
    private var currentLayer: AVCaptureVideoPreviewLayer?

    func updateLayer(_ layer: AVCaptureVideoPreviewLayer?) {
        if currentLayer !== layer {
            currentLayer?.removeFromSuperlayer()
            if let layer {
                layer.videoGravity = .resizeAspectFill
                self.layer.addSublayer(layer)
                layer.frame = bounds
            }
            currentLayer = layer
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        currentLayer?.frame = bounds
    }
}

// MARK: - Unsupported / Permission

struct UnsupportedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 48))
                .foregroundColor(.gray)
            Text("Multi-Camera Not Supported")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
            Text("Requires iPhone 14 Pro or later.")
                .font(.system(size: 14))
                .foregroundColor(.gray)
        }
    }
}

struct PermissionView: View {
    let onRequest: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundColor(.white.opacity(0.6))
            Text("Camera Access")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.white)
            Text("MultiLens needs access to all rear cameras.")
                .font(.system(size: 14))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
            Button("Allow Camera", action: onRequest)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.black)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(Capsule().fill(Color.white))
        }
    }
}
