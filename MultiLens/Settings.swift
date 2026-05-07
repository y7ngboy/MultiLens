import SwiftUI

final class CaptureSettings: ObservableObject {
    @AppStorage("flashMode") var flashMode: FlashMode = .off
    @AppStorage("gridEnabled") var gridEnabled: Bool = false
    @AppStorage("hapticEnabled") var hapticEnabled: Bool = true
    @AppStorage("timerSeconds") var timerSeconds: Int = 0
}

enum FlashMode: String, CaseIterable {
    case off = "Off"
    case on = "On"
    case auto = "Auto"
}
