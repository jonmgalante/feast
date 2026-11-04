import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Re-encodes only the deliberately selected image, stripping EXIF/GPS metadata.
enum AskScreenshotPreparation {
    private nonisolated static func stripMetadata(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 255, bytes[1] == 216 else { throw AskError.unreadableImage }
        var clean = Data(bytes[0..<2]); var offset = 2
        while offset + 3 < bytes.count {
            guard bytes[offset] == 255 else { throw AskError.unreadableImage }
            let marker = bytes[offset + 1]
            if marker == 218 { clean.append(contentsOf: bytes[offset...]); return clean }
            let length = Int(bytes[offset + 2]) * 256 + Int(bytes[offset + 3])
            guard length >= 2, offset + length + 2 <= bytes.count else { throw AskError.unreadableImage }
            if !(225...239).contains(marker) && marker != 254 { clean.append(contentsOf: bytes[offset..<(offset + length + 2)]) }
            offset += length + 2
        }
        throw AskError.unreadableImage
    }
    nonisolated static func prepare(_ data: Data) throws -> AskScreenshot {
        guard data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 30_000_000 / height else { throw AskError.imageLimit }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1024]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw AskError.unreadableImage }
        for quality in [0.75, 0.55, 0.35] {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw AskError.unreadableImage }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw AskError.unreadableImage }
            let clean = try stripMetadata(output as Data)
            if clean.count <= 196608 { return try AskScreenshot(jpeg: clean).validated() }
        }
        throw AskError.imageLimit
    }
}
