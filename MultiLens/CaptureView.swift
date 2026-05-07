import SwiftUI
import AVFoundation

struct CaptureView: View {
    @StateObject private var camera = CameraManager()
    @State private var permissionGranted = false
    @State private var showSettings = false
    @State private var showManualControls = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if false {
                UnsupportedView()
            } else if !permissionGranted {
                PermissionView { requestPermissions() }
            } else {
                MainCameraView(camera: camera, showSettings: $showSettings, showManualControls: $showManualControls)
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

// MARK: - Main Camera View

struct MainCameraView: View {
    @ObservedObject var camera: CameraManager
    @Binding var showSettings: Bool
    @Binding var showManualControls: Bool
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Preview
                if let layer = camera.previewLayer {
                    CameraPreviewView(previewLayer: layer)
                        .ignoresSafeArea()
                        .scaleEffect(x: camera.settings.anamorphicDesqueeze.factor, y: 1.0)
                        .gesture(pinchGesture)
                        .gesture(tapGesture(in: geo.size))
                        .gesture(doubleTapGesture)
                        .gesture(swipeGesture)
                } else {
                    Color.black.ignoresSafeArea()
                }

                // Frame guide overlay
                if let ratio = camera.settings.frameGuide.aspectRatio {
                    FrameGuideOverlay(aspectRatio: ratio, viewSize: geo.size)
                }

                // Grid
                if camera.settings.gridEnabled {
                    GridOverlay().allowsHitTesting(false)
                }

                // Focus indicator
                if let point = camera.focusPoint {
                    FocusIndicator(point: point, locked: false)
                }

                // Top info bar
                VStack(spacing: 0) {
                    TopInfoBar(camera: camera, showSettings: $showSettings)
                    Spacer()
                }

                // Bottom controls
                VStack(spacing: 0) {
                    Spacer()


                    if case .countdown(let s) = camera.captureState {
                        CountdownDisplay(seconds: s).padding(.bottom, 16)
                    }

                    if camera.isRecording {
                        RecordingIndicator(duration: camera.recordingDuration)
                            .padding(.bottom, 12)
                    }

                    // Manual controls panel
                    if showManualControls {
                        ManualControlsPanel(camera: camera)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    BottomBar(camera: camera, showManualControls: $showManualControls)
                        .padding(.bottom, 20)
                }

                // Toast
                if camera.showToast {
                    VStack {
                        ToastView(message: camera.toastMessage)
                            .onAppear {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                    withAnimation { camera.showToast = false }
                                }
                            }
                        Spacer()
                    }.padding(.top, 60)
                }

                if case .error(let msg) = camera.captureState {
                    VStack { ErrorBanner(message: msg).padding(.top, 60); Spacer() }
                }
            }
        }
    }

    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { val in
                let delta = val / lastScale; lastScale = val
                camera.setZoom(camera.zoomFactor * delta)
            }
            .onEnded { _ in lastScale = 1.0 }
    }

    private func tapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture().onEnded { val in camera.focus(at: val.location, in: size) }
    }

    private var doubleTapGesture: some Gesture {
        TapGesture(count: 2).onEnded { camera.switchToNextLens() }
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 60).onEnded { val in
            if abs(val.translation.width) > abs(val.translation.height) {
                camera.switchToNextLens()
            } else {
                camera.adjustExposure(by: Float(-val.translation.height / 600))
            }
        }
    }
}

// MARK: - Top Info Bar

struct TopInfoBar: View {
    @ObservedObject var camera: CameraManager
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Flash
            Button {
                let modes = FlashMode.allCases
                let idx = modes.firstIndex(of: camera.settings.flashMode) ?? 0
                camera.settings.flashMode = modes[(idx + 1) % modes.count]
            } label: {
                Image(systemName: flashIcon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(camera.settings.flashMode == .off ? .white.opacity(0.6) : .yellow)
            }

            Spacer()

            // Status badges
            HStack(spacing: 4) {
                Badge(text: camera.settings.videoCodec.rawValue, color: .orange)
                Badge(text: camera.settings.videoResolution.rawValue, color: .white.opacity(0.7))
                Badge(text: "\(camera.settings.frameRate.rawValue)fps", color: .white.opacity(0.7))
                if camera.settings.colorSpace != .rec709 {
                    Badge(text: camera.settings.colorSpace.rawValue, color: .green)
                }
            }

            Spacer()

            Button { showSettings = true } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var flashIcon: String {
        switch camera.settings.flashMode {
        case .off: return "bolt.slash.fill"
        case .on: return "bolt.fill"
        case .auto: return "bolt.badge.automatic.fill"
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.12)))
    }
}

// MARK: - Manual Controls Panel

struct ManualControlsPanel: View {
    @ObservedObject var camera: CameraManager

    var body: some View {
        VStack(spacing: 10) {
            // ISO
            HStack {
                Text("ISO").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.5)).frame(width: 40)
                Slider(value: Binding(
                    get: { camera.iso },
                    set: { camera.setISO($0) }
                ), in: camera.isoRange.0...camera.isoRange.1)
                .tint(.yellow)
                Text("\(Int(camera.iso))").font(.system(size: 10, design: .monospaced)).foregroundColor(.yellow).frame(width: 40)
            }

            // Shutter
            HStack {
                Text("SHT").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.5)).frame(width: 40)
                if camera.settings.shutterMode == .angle {
                    Slider(value: Binding(
                        get: { camera.shutterAngle },
                        set: { camera.setShutterAngle($0) }
                    ), in: 1...360)
                    .tint(.cyan)
                    Text("\(Int(camera.shutterAngle))°").font(.system(size: 10, design: .monospaced)).foregroundColor(.cyan).frame(width: 40)
                } else {
                    Slider(value: Binding(
                        get: { camera.shutterAngle },
                        set: { camera.setShutterAngle($0) }
                    ), in: 1...360)
                    .tint(.cyan)
                    Text("\(Int(camera.shutterAngle))°").font(.system(size: 10, design: .monospaced)).foregroundColor(.cyan).frame(width: 40)
                }
            }

            // White Balance
            HStack {
                Text("WB").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.5)).frame(width: 40)
                Slider(value: Binding(
                    get: { camera.whiteBalance },
                    set: { camera.setWhiteBalance(temperature: $0) }
                ), in: 2000...10000)
                .tint(.orange)
                Text("\(Int(camera.whiteBalance))K").font(.system(size: 10, design: .monospaced)).foregroundColor(.orange).frame(width: 40)
            }

            // Focus
            HStack {
                Text("FOC").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.white.opacity(0.5)).frame(width: 40)
                Slider(value: Binding(
                    get: { camera.manualFocusPosition },
                    set: { camera.setManualFocus($0) }
                ), in: 0...1)
                .tint(.green)
                Button(camera.isManualFocus ? "M" : "A") {
                    if camera.isManualFocus { camera.setAutoFocus() } else { camera.setManualFocus(0.5) }
                }
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(camera.isManualFocus ? .green : .white.opacity(0.5))
                .frame(width: 40)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.85)))
        .padding(.horizontal, 12)
    }
}

// MARK: - Bottom Bar

struct BottomBar: View {
    @ObservedObject var camera: CameraManager
    @Binding var showManualControls: Bool

    var body: some View {
        VStack(spacing: 14) {
            // Lens selector
            HStack(spacing: 4) {
                ForEach(camera.availableLenses, id: \.self) { lens in
                    Button {
                        camera.previewLens = lens
                        camera.switchPreview(to: lens)
                    } label: {
                        Text(lens.rawValue)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(camera.previewLens == lens ? .yellow : .white.opacity(0.4))
                            .frame(width: 48, height: 30)
                            .background(
                                Capsule().fill(camera.previewLens == lens
                                    ? Color.yellow.opacity(0.15)
                                    : Color.white.opacity(0.05))
                            )
                    }
                }
            }

            // Main controls row
            HStack(spacing: 32) {
                // Record button
                Button { camera.toggleRecording() } label: {
                    ZStack {
                        Circle().stroke(Color.red, lineWidth: 2.5).frame(width: 42, height: 42)
                        if camera.isRecording {
                            RoundedRectangle(cornerRadius: 4).fill(Color.red).frame(width: 16, height: 16)
                        } else {
                            Circle().fill(Color.red).frame(width: 16, height: 16)
                        }
                    }
                }

                // Photo shutter
                Button { camera.captureAll() } label: {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 3.5).frame(width: 70, height: 70)
                        Circle().fill(captureActive ? Color.white : Color.white.opacity(0.3)).frame(width: 58, height: 58)
                    }
                }
                .disabled(!captureActive)

                // Manual controls toggle
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) { showManualControls.toggle() }
                } label: {
                    ZStack {
                        Circle().fill(showManualControls ? Color.yellow.opacity(0.2) : Color.white.opacity(0.08))
                            .frame(width: 42, height: 42)
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(showManualControls ? .yellow : .white.opacity(0.6))
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private var captureActive: Bool { camera.captureState == .idle }
}

// MARK: - Frame Guide Overlay

struct FrameGuideOverlay: View {
    let aspectRatio: CGFloat
    let viewSize: CGSize

    var body: some View {
        let viewRatio = viewSize.width / viewSize.height
        let guideRect: CGRect
        if aspectRatio > viewRatio {
            let h = viewSize.width / aspectRatio
            guideRect = CGRect(x: 0, y: (viewSize.height - h) / 2, width: viewSize.width, height: h)
        } else {
            let w = viewSize.height * aspectRatio
            guideRect = CGRect(x: (viewSize.width - w) / 2, y: 0, width: w, height: viewSize.height)
        }

        return ZStack {
            // Darken outside
            Path { p in
                p.addRect(CGRect(origin: .zero, size: viewSize))
                p.addRect(guideRect)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))

            // Border
            Rectangle()
                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                .frame(width: guideRect.width, height: guideRect.height)
                .position(x: guideRect.midX, y: guideRect.midY)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Preview Bridge

struct CameraPreviewView: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    func makeUIView(context: Context) -> UIView {
        let view = PreviewHostView()
        view.layer.addSublayer(previewLayer)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) { previewLayer.frame = uiView.bounds }

    class PreviewHostView: UIView {
        override func layoutSubviews() {
            super.layoutSubviews()
            layer.sublayers?.forEach { $0.frame = bounds }
        }
    }
}

// MARK: - Supporting Views

struct CountdownDisplay: View {
    let seconds: Int
    var body: some View {
        Text("\(seconds)")
            .font(.system(size: 72, weight: .thin, design: .rounded))
            .foregroundColor(.white)
    }
}

struct RecordingIndicator: View {
    let duration: TimeInterval
    @State private var blink = true
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
                .opacity(blink ? 1 : 0.3)
                .animation(.easeInOut(duration: 0.6).repeatForever(), value: blink)
                .onAppear { blink.toggle() }
            Text(String(format: "%02d:%02d", Int(duration) / 60, Int(duration) % 60))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Capsule().fill(Color.red.opacity(0.3)))
    }
}

struct FocusIndicator: View {
    let point: CGPoint; let locked: Bool
    @State private var scale: CGFloat = 1.4
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .stroke(locked ? Color.yellow : Color.white, lineWidth: 1.5)
            .frame(width: 70, height: 70)
            .overlay(alignment: .top) {
                if locked {
                    Text("AE/AF LOCK").font(.system(size: 9, weight: .bold)).foregroundColor(.yellow).offset(y: -16)
                }
            }
            .scaleEffect(scale).position(point)
            .onAppear { withAnimation(.easeOut(duration: 0.2)) { scale = 1.0 } }
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width; let h = geo.size.height
            Path { p in
                p.move(to: CGPoint(x: w/3, y: 0)); p.addLine(to: CGPoint(x: w/3, y: h))
                p.move(to: CGPoint(x: 2*w/3, y: 0)); p.addLine(to: CGPoint(x: 2*w/3, y: h))
                p.move(to: CGPoint(x: 0, y: h/3)); p.addLine(to: CGPoint(x: w, y: h/3))
                p.move(to: CGPoint(x: 0, y: 2*h/3)); p.addLine(to: CGPoint(x: w, y: 2*h/3))
            }.stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        }
    }
}

struct ToastView: View {
    let message: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.system(size: 14))
            Text(message).font(.system(size: 13, weight: .medium)).foregroundColor(.white)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Capsule().fill(Color(white: 0.12)))
    }
}

struct ErrorBanner: View {
    let message: String
    var body: some View {
        Text(message).font(.system(size: 12, weight: .medium)).foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(Color.red.opacity(0.85))).padding(.horizontal, 20)
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
                .font(.system(size: 15, weight: .semibold)).foregroundColor(.black)
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(Capsule().fill(Color.white))
        }
    }
}
