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
}
