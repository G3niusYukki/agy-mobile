import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ChatPhotoAttachment: Equatable, Sendable {
    public let data: Data?

    public func thumbnail() -> CGImage? {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return resizedPhoto(source, maxSide: 768)
    }
}

private func resizedPhoto(_ source: CGImageSource, maxSide: Int) -> CGImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxSide,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

public enum ChatAttachments {
    static let maxBytes = 2 * 1024 * 1024
    private static let maxPhotos = 8
    private static let formats = ["image/jpeg": UTType.jpeg, "image/png": .png, "image/gif": .gif, "image/webp": .webP]
    private static let unavailable = ChatPhotoAttachment(data: nil)

    static func caption(_ text: String) -> (text: String, hadHint: Bool) {
        return (text, false)
    }

    public static func promptJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let identifier = CGImageSourceGetType(source) as String?, let type = UTType(identifier),
              type.conforms(to: .image), !type.conforms(to: .svg) else { return nil }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.78,
                                           kCGImageDestinationBackgroundColor: CGColor(gray: 1, alpha: 1)]
        for maxSide in [2000, 1500, 1000] {
            let bytes = NSMutableData()
            guard let image = resizedPhoto(source, maxSide: maxSide),
                  let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if bytes.length <= maxBytes { return bytes as Data }
        }
        return nil
    }

    public static func localPhoto(_ data: Data) -> ChatPhotoAttachment {
        checkedPhoto(data, expectedType: nil)
    }

    private static func checkedPhoto(_ data: Data, expectedType: UTType?) -> ChatPhotoAttachment {
        guard !data.isEmpty, data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, formats.values.contains(where: { $0.identifier == type }),
              expectedType == nil || expectedType?.identifier == type,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
              (1...16_384).contains(width), (1...16_384).contains(height), width * height <= 64_000_000 else { return unavailable }
        return ChatPhotoAttachment(data: data)
    }

    public static func project(content: Any?, attachments: Any? = nil) -> (text: String, attachments: [ChatPhotoAttachment]) {
        let blocks = content as? [[String: Any]] ?? []
        let text = content as? String ?? blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
        let visible = caption(text)
        let candidates = attachments as? [[String: Any]] ?? blocks
        var photos: [ChatPhotoAttachment] = []
        var remaining = maxBytes
        for block in candidates where block["type"] as? String == "image" {
            var photo = unavailable
            if let mime = block["mimeType"] as? String, let type = formats[mime],
               let encoded = block["data"] as? String, encoded.utf8.count <= ((remaining + 2) / 3) * 4,
               let bytes = Data(base64Encoded: encoded), bytes.count <= remaining {
                photo = checkedPhoto(bytes, expectedType: type)
                remaining -= photo.data?.count ?? 0
            }
            photos.append(photo)
            if photos.count == maxPhotos { break }
        }
        if photos.isEmpty && visible.hadHint { photos.append(unavailable) }
        return (visible.text, photos)
    }
}
