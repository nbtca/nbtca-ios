import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated struct ProcessedPhoto: Identifiable, Sendable {
    let id = UUID()
    let upload: Data
    let thumbnail: Data
}

nonisolated enum PhotoProcessingError: LocalizedError {
    case invalidImage
    var errorDescription: String? { "无法处理所选照片，请重新选择" }
}

nonisolated enum PhotoProcessor {
    static func process(_ data: Data) throws -> ProcessedPhoto {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw PhotoProcessingError.invalidImage }
        return ProcessedPhoto(upload: try jpeg(source, maxPixels: 2000), thumbnail: try jpeg(source, maxPixels: 160))
    }
    private static func jpeg(_ source: CGImageSource, maxPixels: Int) throws -> Data {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw PhotoProcessingError.invalidImage }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw PhotoProcessingError.invalidImage }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoProcessingError.invalidImage }
        return data as Data
    }
}

final class PhotoUploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let update: @Sendable (Double) -> Void
    init(update: @escaping @Sendable (Double) -> Void) { self.update = update }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                               totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if totalBytesExpectedToSend > 0 { update(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend))) }
    }
}
