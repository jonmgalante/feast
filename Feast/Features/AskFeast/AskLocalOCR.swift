import Foundation
import Vision
import ImageIO

/// Reads only the user-selected image in process. No photo-library enumeration or network.
enum AskLocalOCR {
    static func recognize(_ data: Data) async throws -> String {
        guard data.count <= 8 * 1_024 * 1_024 else { throw AskError.imageLimit }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 30_000_000 / height else { throw AskError.unreadableImage }
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_000
            ] as CFDictionary) else { throw AskError.unreadableImage }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            try Task.checkCancellation()
            let text = (request.results ?? []).prefix(100).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AskError.noText }
            return String(text.prefix(4_000))
        }
        return try await withTaskCancellationHandler {
            let text = try await worker.value
            try Task.checkCancellation()
            return text
        } onCancel: { worker.cancel() }
    }
}
