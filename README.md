# MultiLens

Simultaneous triple-lens capture (0.5x, 1x, 4x) in ProRAW 48MP, assembled into a single multi-page TIFF.

## Requirements

- iPhone 14 Pro / 15 Pro / 16 Pro / 17 Pro
- iOS 17.0+
- Xcode 15+ (on the GitHub Actions runner)

## Build via GitHub Actions

Development happens on Windows. The iOS build runs on GitHub Actions (macOS runner).

### Setup GitHub Secrets

Go to your repo → Settings → Secrets and variables → Actions → New repository secret:

| Secret | Value |
|--------|-------|
| `CERTIFICATE_BASE64` | Your .p12 distribution certificate, base64-encoded. Generate with: `base64 -i cert.p12 \| pbcopy` (on macOS) or `certutil -encode cert.p12 cert.b64` (on Windows, then strip headers) |
| `CERTIFICATE_PASSWORD` | Password for the .p12 file |
| `KEYCHAIN_PASSWORD` | Any strong random string |
| `PROVISIONING_PROFILE_BASE64` | Your .mobileprovision file, base64-encoded |
| `TEAM_ID` | Your Apple Developer Team ID (e.g. AB12CD34EF) |

### Update ExportOptions.plist

Replace `VOTRE_TEAM_ID` with your actual Team ID and `com.votrecompte.multilens` with your bundle identifier.

### Trigger Build

Push to `main` or use "Run workflow" in the Actions tab. The IPA artifact will be available for download (retained 30 days).

### Install on Device (from Windows)

1. Download the IPA artifact from GitHub Actions
2. Install via [AltServer](https://altstore.io/) or [3uTools](http://www.3u.com/)

## Architecture

```
MultiLensApp.swift        — App entry point
CameraManager.swift       — AVMultiCamSession setup, capture orchestration
CaptureCoordinator.swift  — Collects 3 AVCapturePhoto callbacks
TIFFAssembler.swift       — DNG→CGImage decode, multi-page TIFF assembly, PHPhotoLibrary save
CaptureView.swift         — Full SwiftUI interface
```

## Output Format

Single `.tiff` file with 3 IFD pages:
- Page 0: Ultra-wide 0.5x (48MP, 16-bit, Display P3)
- Page 1: Wide 1x (48MP, 16-bit, Display P3)
- Page 2: Telephoto 4x (48MP, 16-bit, Display P3)

Compatible with Lightroom, Photoshop, Capture One, Affinity Photo, GIMP — no plugins needed.

Typical file size: 150–300 MB.

## Zero External Dependencies

No SPM packages, no CocoaPods, no Carthage. Pure Apple frameworks only:
- AVFoundation
- CoreImage
- ImageIO
- Photos
- SwiftUI
