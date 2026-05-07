import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: CaptureSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Video Codec") {
                    Picker("Codec", selection: $settings.videoCodec) {
                        ForEach(VideoCodec.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }

                Section("Resolution & Frame Rate") {
                    Picker("Resolution", selection: $settings.videoResolution) {
                        ForEach(VideoResolution.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Frame Rate", selection: $settings.frameRate) {
                        ForEach(FrameRate.allCases, id: \.self) { Text("\($0.rawValue) fps").tag($0) }
                    }
                    Picker("Shutter Mode", selection: $settings.shutterMode) {
                        ForEach(ShutterMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }

                Section("Color") {
                    Picker("Color Space", selection: $settings.colorSpace) {
                        ForEach(ColorSpace.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }

                Section("Stabilization") {
                    Picker("Mode", selection: $settings.stabilization) {
                        ForEach(StabilizationMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }

                Section("Monitoring") {
                    Toggle("Focus Peaking", isOn: $settings.focusPeaking)
                    Toggle("Zebras", isOn: $settings.zebras)
                    if settings.zebras {
                        Stepper("Threshold: \(settings.zebraThreshold)%", value: $settings.zebraThreshold, in: 70...100)
                    }
                    Toggle("Histogram", isOn: $settings.histogram)
                    Toggle("False Color", isOn: $settings.falseColor)
                    Toggle("Audio Meters", isOn: $settings.audioMeters)
                }

                Section("Framing") {
                    Picker("Frame Guide", selection: $settings.frameGuide) {
                        ForEach(FrameGuide.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Rule of Thirds Grid", isOn: $settings.gridEnabled)
                    Picker("Anamorphic Desqueeze", selection: $settings.anamorphicDesqueeze) {
                        ForEach(AnamorphicMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }

                Section("Capture") {
                    Picker("Flash", selection: $settings.flashMode) {
                        ForEach(FlashMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Timer", selection: $settings.timerSeconds) {
                        Text("Off").tag(0)
                        Text("3s").tag(3)
                        Text("5s").tag(5)
                        Text("10s").tag(10)
                    }
                    Toggle("Haptic Feedback", isOn: $settings.hapticEnabled)
                }

                Section("Controls") {
                    row("Tap", "Focus & Expose")
                    row("Double Tap", "Switch Lens")
                    row("Pinch", "Zoom")
                    row("Swipe H", "Switch Lens")
                    row("Swipe V", "Exposure")
                    row("Long Press", "Lock AE/AF")
                }

                Section("Output") {
                    row("Photo", "3× ProRAW DNG (48MP)")
                    row("Video", "ProRes / Bayer RAW bypass")
                    row("Editable in", "Lightroom / Resolve / Capture One")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    private func row(_ left: String, _ right: String) -> some View {
        HStack {
            Text(left)
            Spacer()
            Text(right).foregroundColor(.secondary).font(.system(size: 13))
        }
    }
}
