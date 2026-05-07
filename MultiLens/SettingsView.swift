import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: CaptureSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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
                }

                Section("Interface") {
                    Toggle("Rule of Thirds Grid", isOn: $settings.gridEnabled)
                    Toggle("Haptic Feedback", isOn: $settings.hapticEnabled)
                }

                Section("Gestures") {
                    row("Tap", "Focus & Expose")
                    row("Double Tap", "Switch Lens")
                    row("Pinch", "Zoom")
                    row("Swipe Left/Right", "Switch Lens")
                    row("Drag Up/Down", "Exposure")
                }

                Section("Output") {
                    row("Photo", "3× ProRAW DNG (48MP)")
                    row("Video", "ProRes 422 HQ (.mov)")
                    row("Editable in", "Lightroom / Capture One / Affinity")
                }

                Section("About") {
                    row("Version", "1.0")
                    row("Min Device", "iPhone 14 Pro")
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
