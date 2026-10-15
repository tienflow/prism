import AppKit
import Foundation

/// 图片高性能内存缓存，极速从磁盘载入并缓存至内存（避免昂贵且阻塞的 tiffRepresentation）
public final class ImageCache: @unchecked Sendable {
    public static let shared = ImageCache()

    private let cache = NSCache<NSString, NSImage>()

    public init() {
        cache.countLimit = 80
    }

    /// 极速同步获取图片：优先命中内存缓存，未命中直接毫秒级读取本地磁盘并存入缓存
    public func image(for path: String) -> NSImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    public func setImage(_ image: NSImage, for path: String) {
        cache.setObject(image, forKey: path as NSString)
    }

    public func removeImage(for path: String) {
        cache.removeObject(forKey: path as NSString)
    }

    public func clearCache() {
        cache.removeAllObjects()
    }
}
