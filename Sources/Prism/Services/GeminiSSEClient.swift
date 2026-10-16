import Foundation

public struct SSEChunk: Codable, Sendable {
    public let stage: String
    public let message: String
    public let total: Int?
    public let current: Int?
    public let path: String?
    public let files: [String]?
    public let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case stage, message, total, current, path, files
        case sessionId = "session_id"
    }
}

public final class GeminiSSEClient: Sendable {
    public static let shared = GeminiSSEClient()

    public init() {}

    public func generate(
        prompt: String,
        aspectRatio: String = "1:1",
        negativePrompt: String = "",
        styleContext: String = "",
        maxKb: Int = 0,
        port: Int = 5188,
        onEvent: @escaping @Sendable (SSEChunk) -> Void
    ) async throws {
        guard let url = URL(string: "http://127.0.0.1:\(port)/generate") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180 // 生成通常耗时 20~60s

        let payload: [String: Any] = [
            "prompt": prompt,
            "aspect_ratio": aspectRatio,
            "negative_prompt": negativePrompt,
            "style_context": styleContext,
            "max_kb": maxKb
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("data:") {
                let jsonString = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let data = jsonString.data(using: .utf8),
                   let chunk = try? JSONDecoder().decode(SSEChunk.self, from: data) {
                    onEvent(chunk)
                }
            }
        }
    }

    public func cancel(port: Int = 5188) async {
        guard let url = URL(string: "http://127.0.0.1:\(port)/cancel") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
    }

    public func polish(
        prompt: String,
        style: String = "",
        customApiKey: String = "",
        customBaseUrl: String = "",
        customModel: String = "",
        port: Int = 5188
    ) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)/polish") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let payload: [String: Any] = [
            "prompt": prompt,
            "style": style,
            "custom_api_key": customApiKey,
            "custom_base_url": customBaseUrl,
            "custom_model": customModel
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? String {
                throw NSError(domain: "Prism", code: 400, userInfo: [NSLocalizedDescriptionKey: err])
            }
            throw URLError(.badServerResponse)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let polished = json["polished_prompt"] as? String else {
            throw NSError(domain: "Prism", code: 500, userInfo: [NSLocalizedDescriptionKey: "解析润色结果失败"])
        }

        return polished
    }

    public func clearAuth(port: Int = 5188) async throws {
        guard let url = URL(string: "http://127.0.0.1:\(port)/auth/clear") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: request)
    }

    public func testAPI(
        apiKey: String,
        baseUrl: String = "",
        model: String = "",
        port: Int = 5188
    ) async throws -> (success: Bool, message: String) {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/test") else {
            return (false, "无效端点")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 8

        let payload: [String: Any] = [
            "custom_api_key": apiKey,
            "custom_base_url": baseUrl,
            "custom_model": model
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return (false, "测试服务响应失败")
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ok = (json["success"] as? Bool) ?? false
            let msg = (json["message"] as? String) ?? "未知响应"
            return (ok, msg)
        }
        return (false, "解析响应失败")
    }

    // MARK: - 多模态 AI 功能 API

    /// 参考图生图（SSE 流式）
    public func generateWithImage(
        imagePath: String,
        prompt: String,
        aspectRatio: String = "1:1",
        styleContext: String = "",
        negativePrompt: String = "",
        maxKb: Int = 0,
        port: Int = 5188,
        onEvent: @escaping @Sendable (SSEChunk) -> Void
    ) async throws {
        guard let url = URL(string: "http://127.0.0.1:\(port)/generate-with-image") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180

        let payload: [String: Any] = [
            "image_path": imagePath,
            "prompt": prompt,
            "aspect_ratio": aspectRatio,
            "style_context": styleContext,
            "negative_prompt": negativePrompt,
            "max_kb": maxKb
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("data:") {
                let jsonString = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let data = jsonString.data(using: .utf8),
                   let chunk = try? JSONDecoder().decode(SSEChunk.self, from: data) {
                    onEvent(chunk)
                }
            }
        }
    }

    /// 图像自动描述/标注
    public func describeImage(
        imagePath: String,
        style: String = "",
        customApiKey: String = "",
        customBaseUrl: String = "",
        customModel: String = "",
        port: Int = 5188
    ) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)/describe-image") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90

        let payload: [String: Any] = [
            "image_path": imagePath,
            "style": style,
            "custom_api_key": customApiKey,
            "custom_base_url": customBaseUrl,
            "custom_model": customModel
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? String {
                throw NSError(domain: "Prism", code: 400, userInfo: [NSLocalizedDescriptionKey: err])
            }
            throw URLError(.badServerResponse)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let description = json["description"] as? String else {
            throw NSError(domain: "Prism", code: 500, userInfo: [NSLocalizedDescriptionKey: "解析描述结果失败"])
        }

        return description
    }

    // MARK: - 多轮会话改图

    /// 多轮会话改图（SSE 流式）。同一 sessionId 内连续调用即在同一会话中修改，模型保留上一轮画面上下文；
    /// sessionId 为空或会话已失效时，后端会自动以 sourceImagePath 重新播种，前端无感。
    public func editImage(
        sourceImagePath: String,
        instruction: String,
        sessionId: String = "",
        aspectRatio: String = "1:1",
        styleContext: String = "",
        negativePrompt: String = "",
        maxKb: Int = 0,
        port: Int = 5188,
        onEvent: @escaping @Sendable (SSEChunk) -> Void
    ) async throws {
        let payload: [String: Any] = [
            "source_image_path": sourceImagePath,
            "instruction": instruction,
            "session_id": sessionId,
            "aspect_ratio": aspectRatio,
            "style_context": styleContext,
            "negative_prompt": negativePrompt,
            "max_kb": maxKb
        ]
        try await runSSE(path: "/session/edit", payload: payload, timeout: 180, port: port, onEvent: onEvent)
    }

    /// 关闭服务端的多轮会话（释放远端上下文）
    public func closeSession(sessionId: String, port: Int = 5188) async {
        guard !sessionId.isEmpty,
              let url = URL(string: "http://127.0.0.1:\(port)/session/close") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["session_id": sessionId])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// 负面提示词智能推荐（走自定义文本模型）
    public func suggestNegativePrompt(
        prompt: String,
        style: String = "",
        customApiKey: String = "",
        customBaseUrl: String = "",
        customModel: String = "",
        port: Int = 5188
    ) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)/suggest-negative") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let payload: [String: Any] = [
            "prompt": prompt,
            "style": style,
            "custom_api_key": customApiKey,
            "custom_base_url": customBaseUrl,
            "custom_model": customModel
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? String {
                throw NSError(domain: "Prism", code: 400, userInfo: [NSLocalizedDescriptionKey: err])
            }
            throw URLError(.badServerResponse)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let negative = json["negative_prompt"] as? String else {
            throw NSError(domain: "Prism", code: 500, userInfo: [NSLocalizedDescriptionKey: "解析负面提示词失败"])
        }
        return negative
    }

    /// SSE 通用执行器：POST 后逐行解析 `data:` 帧并回吐
    private func runSSE(
        path: String,
        payload: [String: Any],
        timeout: TimeInterval,
        port: Int,
        onEvent: @escaping @Sendable (SSEChunk) -> Void
    ) async throws {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("data:") {
                let jsonString = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if let data = jsonString.data(using: .utf8),
                   let chunk = try? JSONDecoder().decode(SSEChunk.self, from: data) {
                    onEvent(chunk)
                }
            }
        }
    }
}
