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
        // 只要已产出图片就持久化。早先按 `stage == .completed` 过滤，
        // 会把「出错/中断但已经出图」的批次在后续任意一次全量保存时静默抹掉（数据丢失）。
        let persistable = batches.filter { !$0.imagePaths.isEmpty }
        guard let data = try? JSONEncoder().encode(persistable) else { return }
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
        removeAssets(forPaths: batch.imagePaths, moveImagesToTrash: moveImagesToTrash)
    }

    /// 清理一组图片文件及其伴生缓存（元数据 json / 缩略图 / AI 描述 / 内存缓存）。
    /// 「删除当前稿」与「删除整条记录」共用此实现。
    public static func removeAssets(forPaths paths: [String], moveImagesToTrash: Bool = true) -> Int {
        let fm = FileManager.default
        var handled = 0

        for path in paths {
            let url = URL(fileURLWithPath: path)

            if moveImagesToTrash, fm.fileExists(atPath: path) {
                try? fm.trashItem(at: url, resultingItemURL: nil)

                // 伴生元数据 gemini_xxx_n.json —— 仅在图片一起移走时清理；
                // 「保留图片，仅移除记录」时保留它，否则用户会丢掉还原提示词的唯一依据。
                let metaURL = url.deletingPathExtension().appendingPathExtension("json")
                try? fm.removeItem(at: metaURL)
            }

            // 缩略图缓存与 AI 描述缓存（可重建，随记录一并回收避免孤儿缓存）
            ThumbnailGenerator.shared.removeThumbnail(for: path)
            AIAnalysisStore.removeAll(for: path)
            ImageCache.shared.removeImage(for: path)
            handled += 1
        }

        // 图片按 YYYY-MM 分目录后：整月图片删光时回收空目录（仅动形如 2026-10 的目录）
        if moveImagesToTrash {
            let monthDirs = Set(paths.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
            for dir in monthDirs {
                guard dir.lastPathComponent.range(
                    of: #"^\d{4}-\d{2}$"#, options: .regularExpression
                ) != nil else { continue }
                if let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
                   contents.isEmpty {
                    try? fm.removeItem(at: dir)
                }
            }
        }

        return handled
    }
}
