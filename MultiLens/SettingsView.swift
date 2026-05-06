import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: CaptureSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Output") {
                    Picker("Format", selection: $settings.format) {
                        ForEach(OutputFormat.allCases, id: \.self) { format in
                            Text(format.rawValue).tag(format)
                        }
                    }

                    Toggle("LZW Compression", isOn: $settings.compressionEnabled)

                    Toggle("Save Original DNG", isOn: $settings.saveOriginalDNG)
                }

                Section("Capture") {
                    Picker("Flash", selection: $settings.flashMode) {
                        ForEach(FlashMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }

                    Picker("Timer", selection: $settings.timerSeconds) {
                        Text("Off").tag(0)
                        Text("3s").tag(3)
                        Text("5s").tag(5)
                        Text("10s").tag(10)
                    }

                    Toggle("Stabilization", isOn: $settings.stabilizationEnabled)
                }

                Section("Interface") {
                    Toggle("Rule of Thirds Grid", isOn: $settings.gridEnabled)
                    Toggle("Haptic Feedback", isOn: $settings.hapticEnabled)
                }

                Section("Gestures") {
                    HStack {
                        Text("Tap")
                        Spacer()
                        Text("Focus & Expose")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Long Press")
                        Spacer()
                        Text("Lock AE/AF")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Pinch")
                        Spacer()
                        Text("Zoom")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Swipe Left/Right")
                        Spacer()
                        Text("Switch Lens")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Drag Up/Down")
                        Spacer()
                        Text("Exposure Compensation")
                            .foregroundColor(.secondary)
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Output")
                        Spacer()
                        Text("3× 48MP TIFF Multi-Page")
                            .foregroundColor(.secondary)
                            .font(.system(size: 13))
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}
