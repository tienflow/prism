import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 缩略图预生成与缓存管理
/// 性能关键：使用 ImageIO 的 CGImageSourceCreateThumbnailAtIndex 直接解码，
/// 避免 NSImage.tiffRepresentation 将整图解压为未压缩位图（1024x1024 图会膨胀到 ~42MB）。
public final class ThumbnailGenerator: @unchecked Sendable {
    public static let shared = ThumbnailGenerator()

    private let cacheDir: URL
    private let thumbnailSize = CGSize(width: 256, height: 256)

    /// 内存缓存，避免重复从磁盘加载
    private let memoryCache = NSCache<NSString, NSImage>()

    public init() {
        let picturesDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Prism")
        cacheDir = picturesDir.appendingPathComponent(".thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        memoryCache.countLimit = 200
    }

    /// 获取缩略图磁盘缓存路径
    public func thumbnailPath(for imagePath: String) -> URL {
        let fileName = URL(fileURLWithPath: imagePath).lastPathComponent
        let baseName = (fileName as NSString).deletingPathExtension
        return cacheDir.appendingPathComponent("thumb_\(baseName).jpg")
    }

    /// 从内存缓存获取缩略图（同步，零开销）
    public func thumbnailFromCache(for imagePath: String) -> NSImage? {
        return memoryCache.object(forKey: imagePath as NSString)
    }

    /// 立即加载缩略图：
    /// 1. 内存缓存 → 直接返回
    /// 2. 磁盘缓存（~20KB）→ 同步读取，几乎无开销
    /// 3. 无缓存 → 后台生成，先返回 nil
    public func loadThumbnail(for imagePath: String) async -> NSImage? {
        if let cached = thumbnailFromCache(for: imagePath) {
            return cached
        }

        let thumbPath = thumbnailPath(for: imagePath)

        // 磁盘缓存只有 ~20KB，同步读取是最快的路径
        if let diskImage = NSImage(contentsOfFile: thumbPath.path) {
            memoryCache.setObject(diskImage, forKey: imagePath as NSString)
            return diskImage
        }

        // 无缓存时在后台队列生成（不阻塞主线程）
        return await generateThumbnail(from: imagePath, to: thumbPath)
    }

    /// 批量预热缩略图缓存（用于启动时加速历史面板）
    /// - 已有磁盘缓存 → 同步加载到内存（~20KB/张，几乎零开销）
    /// - 无缓存 → 用 ImageIO 高效后台生成并写入磁盘
    public func preloadThumbnails(for imagePaths: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for path in imagePaths {
                group.addTask { [weak self] in
                    guard let self else { return }
                    let thumbPath = self.thumbnailPath(for: path)

                    // 已有磁盘缓存，直接加载
                    if let diskImage = NSImage(contentsOfFile: thumbPath.path) {
                        self.memoryCache.setObject(diskImage, forKey: path as NSString)
                        return
                    }

                    // 无缓存，用 ImageIO 后台生成并写盘
                    DispatchQueue.global(qos: .userInitiated).async {
                        guard let cgImage = Self.makeCGThumbnail(at: path, maxPixelSize: 256) else { return }
                        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        self.memoryCache.setObject(nsImage, forKey: path as NSString)

                        // 写入磁盘缩略图缓存
                        if let tiffData = nsImage.tiffRepresentation,
                           let rep = NSBitmapImageRep(data: tiffData),
                           let jpegData = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) {
                            try? jpegData.write(to: thumbPath)
                        }
                    }
                }
            }
            await group.waitForAll()
        }
    }

    // MARK: - 私有：ImageIO 高效缩略图生成

    private func generateThumbnail(from imagePath: String, to thumbPath: URL) async -> NSImage? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let cgImage = Self.makeCGThumbnail(at: imagePath, maxPixelSize: 256) else {
                    continuation.resume(returning: nil)
                    return
                }
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                self.memoryCache.setObject(nsImage, forKey: imagePath as NSString)
                continuation.resume(returning: nsImage)
            }
        }
    }

    /// 使用 ImageIO 高效生成 CGImage 缩略图
    private static func makeCGThumbnail(at path: String, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return cgImage
    }

    /// 清理过期缩略图（超过 30 天）
    public func cleanExpiredThumbnails() {
        let expirationDate = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        for file in files {
            if let values = try? file.resourceValues(forKeys: [.contentModificationDateKey]),
               let modDate = values.contentModificationDate,
               modDate < expirationDate {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
