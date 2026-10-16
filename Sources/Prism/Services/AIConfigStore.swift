import Foundation

/// 本机 AI 引擎凭据存储（TypeSafe Jev 等）。
///
/// 存放于 `~/Pictures/Prism/ai_config.json` —— 与 `history.json` / `.ai_analysis.json`
/// 同一数据目录，随 App 数据走；**不进仓库、不进 App Bundle**（写 bundle 会破坏签名）。
/// Sidecar 侧由 `Sidecar/jev.py` 读同一路径；环境变量 `TYPESAFE_API_KEY` 优先级更高。
enum AIConfigStore {
    private static var storageURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Prism/ai_config.json")
    }

    private static let queue = DispatchQueue(label: "com.tienyeung.prism.ai-config")

    // MARK: - TypeSafe Jev

    static func typesafeKey() -> String {
        queue.sync {
            (loadPayload()["typesafe_api_key"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func setTypesafeKey(_ key: String) {
        queue.sync {
            var payload = loadPayload()
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                payload.removeValue(forKey: "typesafe_api_key")
            } else {
                payload["typesafe_api_key"] = trimmed
            }
            writePayload(payload)
        }
    }

    // MARK: - 磁盘读写

    private static func loadPayload() -> [String: Any] {
        guard let data = try? Data(contentsOf: storageURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func writePayload(_ payload: [String: Any]) {
        let dir = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: storageURL, options: .atomic)
        // 含明文密钥，收紧为仅所有者可读
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: storageURL.path
        )
    }
}
