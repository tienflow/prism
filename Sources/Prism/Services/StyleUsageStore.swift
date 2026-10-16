import Foundation

/// 画风使用统计 —— 供参数栏「常用优先」排序使用。
///
/// 存放于 `~/Pictures/Prism/style_usage.json`（与 history.json / ai_config.json 同目录）。
/// 只影响画风网格的排列顺序，不改动任何生成行为。
enum StyleUsageStore {
    private struct Entry: Codable {
        var count: Int = 0
        var lastUsed: Double = 0
    }

    private static var storageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Prism/style_usage.json")
    }

    private static let queue = DispatchQueue(label: "com.tienyeung.prism.style-usage")

    /// 记录一次「用户选中了某画风」（手动点选或采纳 AI 建议时调用）。
    /// 「无预设」是「取消指定」而非画风，不计入。
    static func record(_ style: ArtStyleOption) {
        guard style != .none else { return }
        queue.sync {
            var map = load()
            var entry = map[style.rawValue] ?? Entry()
            entry.count += 1
            entry.lastUsed = Date().timeIntervalSince1970
            map[style.rawValue] = entry
            save(map)
        }
    }

    /// 排序：常用优先（次数降序 → 最近使用降序 → 枚举原顺序兜底）。
    /// 「无预设」固定在首位，让「取消指定」永远在同一个位置。
    static func rankedStyles() -> [ArtStyleOption] {
        let map = queue.sync { load() }
        let ordered = ArtStyleOption.allCases.enumerated()
            .filter { $0.element != .none }
            .sorted { lhs, rhs in
                let l = map[lhs.element.rawValue] ?? Entry()
                let r = map[rhs.element.rawValue] ?? Entry()
                if l.count != r.count { return l.count > r.count }
                if l.lastUsed != r.lastUsed { return l.lastUsed > r.lastUsed }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
        return [.none] + ordered
    }

    // MARK: - 磁盘读写

    private static func load() -> [String: Entry] {
        guard let data = try? Data(contentsOf: storageURL),
              let map = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return [:]
        }
        return map
    }

    private static func save(_ map: [String: Entry]) {
        let dir = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(map) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
