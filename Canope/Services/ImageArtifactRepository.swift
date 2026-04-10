import AppKit
import Foundation

@MainActor
final class ImageArtifactRepository {
    static let shared = ImageArtifactRepository()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 24
    }

    func cachedImage(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func removeImage(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    func loadImage(
        forKey key: String,
        from url: URL,
        forceReload: Bool = false
    ) async -> NSImage? {
        if !forceReload, let cached = cachedImage(forKey: key) {
            return cached
        }

        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value

        guard let data, let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}
