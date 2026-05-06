import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

struct TIFFAssemblerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class TIFFAssembler {
    var onProgress: ((Double) -> Void)?

    private let ciContext = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
        .outputColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!
    ])

    func assemble(photos: [LensType: AVCapturePhoto]) -> Result<String, Error> {
        guard let uwPhoto = photos[.ultraWide],
              let wPhoto = photos[.wide],
              let tPhoto = photos[.telephoto]
        else {
            return .failure(TIFFAssemblerError(message: "Missing lens capture"))
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let fileName = "MultiLens_\(timestamp).tiff"

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(fileName)

        guard let dest = CGImageDestinationCreateWithURL(
            fileURL as CFURL, UTType.tiff.identifier as CFString, 3, nil
        ) else {
            return .failure(TIFFAssemblerError(message: "Failed to create TIFF destination"))
        }

        let orderedCaptures: [(LensType, AVCapturePhoto, Int)] = [
            (.ultraWide, uwPhoto, 0),
            (.wide, wPhoto, 1),
            (.telephoto, tPhoto, 2)
        ]

        let dateString = ISO8601DateFormatter().string(from: Date())

        for (lens, photo, pageIndex) in orderedCaptures {
            guard let cgImage = decodeToCGImage(photo: photo) else {
                return .failure(TIFFAssemblerError(
                    message: "Failed to decode \(lens.rawValue) image"))
            }

            let lensLabel: String
            switch lens {
            case .ultraWide: lensLabel = "MultiLens_0.5x"
            case .wide: lensLabel = "MultiLens_1x"
            case .telephoto: lensLabel = "MultiLens_4x"
            }

            let properties: [CFString: Any] = [
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFImageDescription: lensLabel,
                    kCGImagePropertyTIFFDateTime: dateString,
                    kCGImagePropertyTIFFMake: deviceMake(from: photo),
                    kCGImagePropertyTIFFModel: deviceModel(from: photo)
                ] as [CFString: Any],
                kCGImageDestinationLossyCompressionQuality: 1.0
            ]

            CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
            onProgress?(Double(pageIndex + 1) / 3.0 * 0.7)
        }

        onProgress?(0.75)

        guard CGImageDestinationFinalize(dest) else {
            return .failure(TIFFAssemblerError(message: "TIFF finalization failed"))
        }

        onProgress?(0.85)

        let fileSize = fileSizeString(url: fileURL)

        let semaphore = DispatchSemaphore(value: 0)
        var saveError: Error?

        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, fileURL: fileURL, options: nil)

            let fetchOptions = PHFetchOptions()
            fetchOptions.predicate = NSPredicate(format: "title == %@", "MultiLens")
            let album = PHAssetCollection.fetchAssetCollections(
                with: .album, subtype: .any, options: fetchOptions)

            if let existingAlbum = album.firstObject {
                let albumRequest = PHAssetCollectionChangeRequest(for: existingAlbum)
                guard let placeholder = request.placeholderForCreatedAsset else { return }
                albumRequest?.addAssets([placeholder] as NSArray)
            } else {
                let albumCreation = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: "MultiLens")
                guard let placeholder = request.placeholderForCreatedAsset else { return }
                albumCreation.addAssets([placeholder] as NSArray)
            }
        } completionHandler: { _, error in
            saveError = error
            semaphore.signal()
        }

        semaphore.wait()

        try? FileManager.default.removeItem(at: fileURL)

        onProgress?(1.0)

        if let saveError {
            return .failure(saveError)
        }

        return .success(fileSize)
    }

    private func decodeToCGImage(photo: AVCapturePhoto) -> CGImage? {
        if let dngData = photo.fileDataRepresentation() {
            let ciImage = CIImage(data: dngData, options: [
                .applyOrientationProperty: true
            ])
            if let ci = ciImage {
                return ciContext.createCGImage(ci, from: ci.extent, format: .RGBA16,
                    colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
            }
        }

        guard let pixelBuffer = photo.pixelBuffer else { return nil }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.createCGImage(ciImage, from: ciImage.extent, format: .RGBA16,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
    }

    private func deviceMake(from photo: AVCapturePhoto) -> String {
        guard let exif = photo.metadata["{Exif}"] as? [String: Any],
              let make = exif["Make"] as? String
        else { return "Apple" }
        return make
    }

    private func deviceModel(from photo: AVCapturePhoto) -> String {
        guard let exif = photo.metadata["{Exif}"] as? [String: Any],
              let model = exif["Model"] as? String
        else { return UIDevice.current.model }
        return model
    }

    private func fileSizeString(url: URL) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64
        else { return "unknown" }

        let mb = Double(size) / (1024 * 1024)
        if mb > 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}
