import SwiftUI

final class CaptureSettings: ObservableObject {
    @AppStorage("format") var format: OutputFormat = .tiff16
    @AppStorage("flashMode") var flashMode: FlashMode = .off
    @AppStorage("gridEnabled") var gridEnabled: Bool = false
    @AppStorage("hapticEnabled") var hapticEnabled: Bool = true
    @AppStorage("saveOriginalDNG") var saveOriginalDNG: Bool = false
    @AppStorage("compressionEnabled") var compressionEnabled: Bool = false
    @AppStorage("timerSeconds") var timerSeconds: Int = 0
    @AppStorage("stabilizationEnabled") var stabilizationEnabled: Bool = true
}

enum OutputFormat: String, CaseIterable {
    case tiff16 = "TIFF 16-bit"
    case tiff8 = "TIFF 8-bit"
    case heif = "HEIF"
}

enum FlashMode: String, CaseIterable {
    case off = "Off"
    case on = "On"
    case auto = "Auto"
}
