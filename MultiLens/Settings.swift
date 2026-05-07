import SwiftUI
import AVFoundation

// MARK: - Capture Settings

final class CaptureSettings: ObservableObject {
    @AppStorage("flashMode") var flashMode: FlashMode = .off
    @AppStorage("gridEnabled") var gridEnabled: Bool = false
    @AppStorage("hapticEnabled") var hapticEnabled: Bool = true
    @AppStorage("timerSeconds") var timerSeconds: Int = 0

    // Video settings
    @AppStorage("videoCodec") var videoCodec: VideoCodec = .proRes422HQ
    @AppStorage("videoResolution") var videoResolution: VideoResolution = .uhd4K
    @AppStorage("frameRate") var frameRate: FrameRate = .fps24
    @AppStorage("colorSpace") var colorSpace: ColorSpace = .rec709
    @AppStorage("stabilization") var stabilization: StabilizationMode = .off

    // Monitoring
    @AppStorage("focusPeaking") var focusPeaking: Bool = false
    @AppStorage("zebras") var zebras: Bool = false
    @AppStorage("zebraThreshold") var zebraThreshold: Int = 95
    @AppStorage("histogram") var histogram: Bool = false
    @AppStorage("falseColor") var falseColor: Bool = false
    @AppStorage("audioMeters") var audioMeters: Bool = true

    // Anamorphic
    @AppStorage("anamorphicDesqueeze") var anamorphicDesqueeze: AnamorphicMode = .none

    // Frame guides
    @AppStorage("frameGuide") var frameGuide: FrameGuide = .none

    // Shutter mode
    @AppStorage("shutterMode") var shutterMode: ShutterMode = .angle
}

// MARK: - Enums

enum FlashMode: String, CaseIterable {
    case off = "Off"
    case on = "On"
    case auto = "Auto"
}

enum VideoCodec: String, CaseIterable {
    case proRes422HQ = "ProRes 422 HQ"
    case proRes422 = "ProRes 422"
    case proRes422LT = "ProRes 422 LT"
    case proResProxy = "ProRes Proxy"
    case hevc = "HEVC"
    case hevcHDR = "HEVC HDR"

    var avCodecType: AVVideoCodecType {
        switch self {
        case .proRes422HQ: return .proRes422HQ
        case .proRes422: return .proRes422
        case .proRes422LT: return .proRes422LT
        case .proResProxy: return .proRes422Proxy
        case .hevc, .hevcHDR: return .hevc
        }
    }
}

enum VideoResolution: String, CaseIterable {
    case hd720 = "720p"
    case hd1080 = "1080p"
    case uhd4K = "4K"

    var dimensions: (Int, Int) {
        switch self {
        case .hd720: return (1280, 720)
        case .hd1080: return (1920, 1080)
        case .uhd4K: return (3840, 2160)
        }
    }
}

enum FrameRate: String, CaseIterable {
    case fps23_98 = "23.98"
    case fps24 = "24"
    case fps25 = "25"
    case fps29_97 = "29.97"
    case fps30 = "30"
    case fps48 = "48"
    case fps50 = "50"
    case fps59_94 = "59.94"
    case fps60 = "60"
    case fps120 = "120"

    var value: Double {
        switch self {
        case .fps23_98: return 23.976
        case .fps24: return 24
        case .fps25: return 25
        case .fps29_97: return 29.97
        case .fps30: return 30
        case .fps48: return 48
        case .fps50: return 50
        case .fps59_94: return 59.94
        case .fps60: return 60
        case .fps120: return 120
        }
    }
}

enum ColorSpace: String, CaseIterable {
    case rec709 = "Rec. 709"
    case hlg = "HLG HDR"
    case appleLog = "Apple Log"
    case p3D65 = "P3 D65"

    var videoColorProperties: [String: String]? {
        switch self {
        case .rec709: return nil
        case .hlg: return [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
        ]
        case .appleLog: return [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_Linear,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020
        ]
        case .p3D65: return [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
        ]
        }
    }
}

enum StabilizationMode: String, CaseIterable {
    case off = "Off"
    case standard = "Standard"
    case cinematic = "Cinematic"

    var avMode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: return .off
        case .standard: return .standard
        case .cinematic: return .cinematic
        }
    }
}

enum AnamorphicMode: String, CaseIterable {
    case none = "None"
    case x1_33 = "1.33x"
    case x1_55 = "1.55x"
    case x2_0 = "2.0x"

    var factor: CGFloat {
        switch self {
        case .none: return 1.0
        case .x1_33: return 1.33
        case .x1_55: return 1.55
        case .x2_0: return 2.0
        }
    }
}

enum FrameGuide: String, CaseIterable {
    case none = "None"
    case ratio_16_9 = "16:9"
    case ratio_2_35 = "2.35:1"
    case ratio_2_39 = "2.39:1"
    case ratio_1_85 = "1.85:1"
    case ratio_4_3 = "4:3"
    case ratio_1_1 = "1:1"

    var aspectRatio: CGFloat? {
        switch self {
        case .none: return nil
        case .ratio_16_9: return 16.0 / 9.0
        case .ratio_2_35: return 2.35
        case .ratio_2_39: return 2.39
        case .ratio_1_85: return 1.85
        case .ratio_4_3: return 4.0 / 3.0
        case .ratio_1_1: return 1.0
        }
    }
}

enum ShutterMode: String, CaseIterable {
    case angle = "Angle"
    case speed = "Speed"
}
