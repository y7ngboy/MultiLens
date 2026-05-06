import SwiftUI
import AVFoundation

struct CaptureView: View {
    @StateObject private var camera = CameraManager()
    @State private var permissionGranted = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !CameraManager.isSupported {
                UnsupportedView()
            } else if !permissionGranted {
                PermissionView {
                    requestPermissions()
                }
            } else {
                ViewfinderView(camera: camera)
            }
        }
        .onAppear {
            checkPermissions()
        }
    }

    private func checkPermissions() {
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraStatus == .authorized {
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

// MARK: - Viewfinder

struct ViewfinderView: View {
    @ObservedObject var camera: CameraManager

    var body: some View {
        ZStack {
            PreviewLayerView(camera: camera)
                .ignoresSafeArea()

            VStack {
                Spacer()

                if camera.thermalWarning {
                    ThermalWarningBanner()
                }

                if case .encoding = camera.captureState {
                    ProgressBarView(progress: camera.encodingProgress)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 20)
                }

                LensSelectorView(selected: $camera.previewLens)
                    .padding(.bottom, 16)

                StatusDotsView(state: camera.captureState)
                    .padding(.bottom, 12)

                ShutterButton {
                    camera.captureAll()
                }
                .disabled(!isIdle)
                .opacity(isIdle ? 1.0 : 0.5)
                .padding(.bottom, 40)
            }

            if camera.showToast, let size = camera.lastFileSize {
                ToastView(fileSize: size)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            camera.showToast = false
                        }
                    }
            }

            if case .error(let msg) = camera.captureState {
                ErrorBanner(message: msg)
            }
        }
    }

    private var isIdle: Bool {
        if case .idle = camera.captureState { return true }
        return false
    }
}

// MARK: - Preview Layer UIKit Bridge

struct PreviewLayerView: UIViewRepresentable {
    @ObservedObject var camera: CameraManager

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        return view
    }

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

// MARK: - Lens Selector

struct LensSelectorView: View {
    @Binding var selected: LensType

    var body: some View {
        HStack(spacing: 20) {
            ForEach(LensType.allCases, id: \.self) { lens in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selected = lens
                    }
                } label: {
                    Text(lens.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(selected == lens ? .yellow : .white)
                        .frame(width: 44, height: 44)
                        .background(
                            Circle()
                                .fill(selected == lens
                                      ? Color.white.opacity(0.2)
                                      : Color.clear)
                        )
                }
            }
        }
    }
}

// MARK: - Shutter Button

struct ShutterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                Circle()
                    .fill(Color.white)
                    .frame(width: 60, height: 60)
            }
        }
    }
}

// MARK: - Status Dots

struct StatusDotsView: View {
    let state: CaptureState

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(label: "UW", active: dotState(for: .ultraWide))
            StatusDot(label: "W", active: dotState(for: .wide))
            StatusDot(label: "T", active: dotState(for: .telephoto))
        }
    }

    private func dotState(for lens: LensType) -> DotState {
        switch state {
        case .idle: return .ready
        case .capturing: return .capturing
        case .encoding: return .encoding
        case .done: return .ready
        case .error: return .ready
        }
    }
}

enum DotState {
    case ready, capturing, encoding
}

struct StatusDot: View {
    let label: String
    let active: DotState

    var body: some View {
        VStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private var dotColor: Color {
        switch active {
        case .ready: return .green
        case .capturing: return .orange
        case .encoding: return .blue
        }
    }
}

// MARK: - Progress Bar

struct ProgressBarView: View {
    let progress: Double

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white)
                        .frame(width: geo.size.width * CGFloat(progress), height: 6)
                }
            }
            .frame(height: 6)

            Text("Encoding TIFF... \(Int(progress * 100))%")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.8))
        }
    }
}

// MARK: - Toast

struct ToastView: View {
    let fileSize: String

    var body: some View {
        VStack {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("TIFF saved (\(fileSize))")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.8))
            )
            Spacer()
        }
        .padding(.top, 60)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Error Banner

struct ErrorBanner: View {
    let message: String

    var body: some View {
        VStack {
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.red.opacity(0.8))
                )
                .padding(.horizontal, 20)
            Spacer()
        }
        .padding(.top, 60)
    }
}

// MARK: - Thermal Warning

struct ThermalWarningBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "thermometer.sun.fill")
                .foregroundColor(.orange)
            Text("Device is warm. Performance may be reduced.")
                .font(.system(size: 12))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.orange.opacity(0.3))
        )
        .padding(.bottom, 8)
    }
}

// MARK: - Unsupported / Permission

struct UnsupportedView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 48))
                .foregroundColor(.gray)
            Text("Multi-camera not supported")
                .font(.title3)
                .foregroundColor(.white)
            Text("This device does not support simultaneous multi-camera capture.")
                .font(.body)
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

struct PermissionView: View {
    let onRequest: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 48))
                .foregroundColor(.gray)
            Text("Camera Access Required")
                .font(.title3)
                .foregroundColor(.white)
            Button("Grant Access", action: onRequest)
                .buttonStyle(.borderedProminent)
        }
    }
}
