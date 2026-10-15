import Foundation

/// AI 分析结果磁盘缓存（图像描述）
/// 按图片绝对路径索引，持久化到 ~/Pictures/Prism/.ai_analysis.json
enum AIAnalysisStore {
    private struct CachePayload: Codable {
        var descriptions: [String: String] = [:]
    }

    private static var storageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Prism/.ai_analysis.json")
    }

    private static let queue = DispatchQueue(label: "com.tienyeung.prism.ai-analysis-cache")

    // MARK: - 描述

    static func cachedDescription(for path: String) -> String? {
        queue.sync {
            loadPayload().descriptions[path]
        }
    }

    static func saveDescription(_ text: String, for path: String) {
        queue.sync {
            var payload = loadPayload()
            payload.descriptions[path] = text
            writePayload(payload)
        }
    }

    // MARK: - 清理

    /// 删除图片时同步清理对应缓存
    static func removeAll(for path: String) {
        queue.sync {
            var payload = loadPayload()
            payload.descriptions.removeValue(forKey: path)
            writePayload(payload)
        }
    }

    // MARK: - 磁盘读写

    private static func loadPayload() -> CachePayload {
        guard let data = try? Data(contentsOf: storageURL),
              let payload = try? JSONDecoder().decode(CachePayload.self, from: data) else {
            return CachePayload()
        }
        return payload
    }

    private static func writePayload(_ payload: CachePayload) {
        let dir = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(payload) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
}
