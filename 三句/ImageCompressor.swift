import Foundation
import UIKit

enum ImageCompressor {
    static func analysisJPEGData(from data: Data) throws -> Data {
        guard let image = UIImage(data: data) else {
            throw KimiServiceError.invalidImage
        }

        return try compressedJPEGData(
            from: image,
            targetByteCount: 45_000,
            maxDimensions: [512, 416, 352],
            compressionQualities: [0.07, 0.045, 0.03],
            fallbackMaxDimension: 352,
            fallbackQuality: 0.022
        )
    }

    static func memoryJPEGData(from data: Data) throws -> Data {
        guard let image = UIImage(data: data) else {
            throw KimiServiceError.invalidImage
        }

        return try compressedJPEGData(
            from: image,
            targetByteCount: 160_000,
            maxDimensions: [1280, 1120, 960],
            compressionQualities: [0.34, 0.28, 0.22],
            fallbackMaxDimension: 960,
            fallbackQuality: 0.2
        )
    }

    private static func compressedJPEGData(
        from image: UIImage,
        targetByteCount: Int,
        maxDimensions: [CGFloat],
        compressionQualities: [CGFloat],
        fallbackMaxDimension: CGFloat,
        fallbackQuality: CGFloat
    ) throws -> Data {
        for maxDimension in maxDimensions {
            let resizedImage = resizedImageIfNeeded(image, maxDimension: maxDimension)

            for quality in compressionQualities {
                if let jpegData = resizedImage.jpegData(compressionQuality: quality),
                   jpegData.count <= targetByteCount {
                    return jpegData
                }
            }
        }

        guard let fallbackData = resizedImageIfNeeded(image, maxDimension: fallbackMaxDimension)
            .jpegData(compressionQuality: fallbackQuality) else {
            throw KimiServiceError.invalidImage
        }

        return fallbackData
    }

    private static func resizedImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longestEdge = max(size.width, size.height)

        guard longestEdge > maxDimension else {
            return image
        }

        let scale = maxDimension / longestEdge
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1

        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
