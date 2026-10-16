import Foundation

public final class HistoryStore: Sendable {
    public static let shared = HistoryStore()

    private var storageURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Prism")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    public init() {}

    public func load() -> [GenerationBatch] {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let list = try? JSONDecoder().decode([GenerationBatch].self, from: data) else {
            return []
        }

        // 批量检查文件存在性，避免重复调用 FileManager
        var existingFiles = Set<String>()
        for batch in list {
            for path in batch.imagePaths {
                if FileManager.default.fileExists(atPath: path) {
                    existingFiles.insert(path)
                }
            }
        }

        // 过滤掉本地图片已被删除的项
        return list.filter { batch in
            if batch.imagePaths.isEmpty { return false }
            return batch.imagePaths.contains { existingFiles.contains($0) }
        }
    }

    /// 异步加载历史记录，避免阻塞主线程
    public func loadAsync() async -> [GenerationBatch] {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.load()
                continuation.resume(returning: result)
            }
        }
    }

    public func save(_ batches: [GenerationBatch]) {
        let completed = batches.filter { $0.stage == .completed && !$0.imagePaths.isEmpty }
        guard let data = try? JSONEncoder().encode(completed) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    public func append(_ batch: GenerationBatch) {
        var current = load()
        current.removeAll(where: { $0.id == batch.id })
        current.insert(batch, at: 0)
        save(current)
    }

    // MARK: - 资源清理（删除批次时调用）

    /// 清理一个批次关联的全部本地资源
    /// - Parameters:
    ///   - moveImagesToTrash: `true` 时图片移入废纸篓（可恢复），`false` 时保留图片文件、仅清缓存
    /// - Returns: 被处理的原图数量
    @discardableResult
    public static func removeAssets(for batch: GenerationBatch, moveImagesToTrash: Bool = true) -> Int {
        let fm = FileManager.default
        var handled = 0

        for path in batch.imagePaths {
            let url = URL(fileURLWithPath: path)

            if moveImagesToTrash, fm.fileExists(atPath: path) {
                try? fm.trashItem(at: url, resultingItemURL: nil)
            }

            // 伴生元数据 gemini_xxx_n.json
            let metaURL = url.deletingPathExtension().appendingPathExtension("json")
            try? fm.removeItem(at: metaURL)

            // 缩略图缓存与 AI 描述缓存
            ThumbnailGenerator.shared.removeThumbnail(for: path)
            AIAnalysisStore.removeAll(for: path)
            ImageCache.shared.removeImage(for: path)
            handled += 1
        }

        return handled
    }
}
