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
        taskId: String = "",
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
            "max_kb": maxKb,
            "task_id": taskId
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

    /// 请求后台中止当前生图任务。
    /// - Returns: 是否被 Sidecar 确认（失败会重试；返回值供 UI 如实反馈，不再静默吞掉失败）。
    @discardableResult
    /// 停止生成任务。传 `taskId` 只停那一个（多任务并行）；留空则停全部（向后兼容）。
    public func cancel(port: Int = 5188, taskId: String = "", attempts: Int = 3) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/cancel") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        if !taskId.isEmpty {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["task_id": taskId])
        }

        let total = max(1, attempts)
        for attempt in 0..<total {
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
            if attempt < total - 1 {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        return false
    }

    /// 流式润色（SSE）：逐字回调 `onDelta`，最终返回归一化后的完整文本。
    /// - Parameter mode: "describe" = 扩写为完整画面；"instruction" = 精确化修改指令
    public func polishStream(
        prompt: String,
        style: String = "",
        customApiKey: String = "",
        customBaseUrl: String = "",
        customModel: String = "",
        mode: String = "describe",
        port: Int = 5188,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)/polish/stream") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 90
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "prompt": prompt,
            "style": style,
            "mode": mode,
            "custom_api_key": customApiKey,
            "custom_base_url": customBaseUrl,
            "custom_model": customModel
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        var finalText: String?
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let jsonString = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = jsonString.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(SSEChunk.self, from: data) else { continue }

            switch chunk.stage {
            case "delta":
                if !chunk.message.isEmpty { onDelta(chunk.message) }
            case "completed":
                finalText = chunk.message
            case "error":
                throw NSError(domain: "Prism", code: 400,
                              userInfo: [NSLocalizedDescriptionKey: chunk.message])
            default:
                break
            }
        }

        guard let finalText, !finalText.isEmpty else {
            throw NSError(domain: "Prism", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "润色未返回结果"])
        }
        return finalText
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
        taskId: String = "",
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
            "max_kb": maxKb,
            "task_id": taskId
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

    /// 图像自动描述/标注（图片描述模型与文本模型分开配置，见偏好设置 → AI 配置）
    public func describeImage(
        imagePath: String,
        style: String = "",
        customApiKey: String = "",
        customBaseUrl: String = "",
        customVisionModel: String = "",
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
            "custom_vision_model": customVisionModel
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

    /// 图像描述（SSE 流式）：逐块回调 `onDelta`，最终返回裁齐后的全文。
    /// 流结束时服务端会补一帧 `completed` 携带全文，以它覆盖增量拼接结果，
    /// 避免个别通道的换行/空白差异累积。
    public func describeImageStream(
        imagePath: String,
        style: String = "",
        customApiKey: String = "",
        customBaseUrl: String = "",
        customVisionModel: String = "",
        port: Int = 5188,
        onDelta: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        guard let url = URL(string: "http://127.0.0.1:\(port)/describe-image/stream") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "image_path": imagePath,
            "style": style,
            "custom_api_key": customApiKey,
            "custom_base_url": customBaseUrl,
            "custom_vision_model": customVisionModel
        ])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        var finalText: String?
        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let jsonString = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = jsonString.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(SSEChunk.self, from: data) else { continue }

            switch chunk.stage {
            case "delta":
                if !chunk.message.isEmpty { onDelta(chunk.message) }
            case "completed":
                finalText = chunk.message
            case "error":
                throw NSError(domain: "Prism", code: 400,
                              userInfo: [NSLocalizedDescriptionKey: chunk.message])
            default:
                break
            }
        }

        guard let finalText, !finalText.isEmpty else {
            throw NSError(domain: "Prism", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "描述未返回结果"])
        }
        return finalText
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
        taskId: String = "",
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
            "max_kb": maxKb,
            "task_id": taskId
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

    // MARK: - 画风 / 比例智能配参 (TypeSafe Jev 判定层)

    /// Jev 的单选项判定结果：选中项 + 置信度 + 次选（来自概率分布）
    public struct ParamPick: Sendable {
        public let choice: String
        public let confidence: Double
        public let runnerUp: String?
        public let runnerUpProbability: Double
    }

    public struct ParamSuggestion: Sendable {
        public let style: ParamPick
        public let aspectRatio: ParamPick
        /// 描述是否过于简略（Noul 概率，越高越需要先润色）
        public let needsPolish: Double
        public let cached: Bool
    }

    /// 用 Jev 对主体描述做画风 / 比例判定。
    /// - Note: Jev 不生成文本，只返回类型化选项与概率分布；需海外网络出口（见 Sidecar/jev.py）。
    public func suggestParams(
        description: String,
        styles: [String: String],
        aspects: [String: String],
        hasReferenceImage: Bool = false,
        port: Int = 5188
    ) async throws -> ParamSuggestion {
        guard let url = URL(string: "http://127.0.0.1:\(port)/suggest-params") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let payload: [String: Any] = [
            "description": description,
            "styles": styles,
            "aspects": aspects,
            "has_reference_image": hasReferenceImage
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }

        if (json["success"] as? Bool) != true {
            let msg = json["error"] as? String ?? "配参失败"
            throw NSError(domain: "Prism", code: 400, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        func pick(_ key: String) throws -> ParamPick {
            guard let obj = json[key] as? [String: Any],
                  let choice = obj["choice"] as? String else {
                throw NSError(domain: "Prism", code: 500,
                              userInfo: [NSLocalizedDescriptionKey: "解析 \(key) 判定失败"])
            }
            let runner = obj["runner_up"] as? [String: Any]
            return ParamPick(
                choice: choice,
                confidence: obj["confidence"] as? Double ?? 0,
                runnerUp: runner?["choice"] as? String,
                runnerUpProbability: runner?["probability"] as? Double ?? 0
            )
        }

        return ParamSuggestion(
            style: try pick("style"),
            aspectRatio: try pick("aspect_ratio"),
            needsPolish: json["needs_polish"] as? Double ?? 0,
            cached: json["cached"] as? Bool ?? false
        )
    }

    // MARK: - 一条龙：润色 + 配参 + 负面提示词

    public struct OptimizeResult: Sendable {
        public let polishedPrompt: String
        public let polishError: String?
        public let negativePrompt: String?
        public let negativeError: String?
        public let paramsError: String?
        public let style: ParamPick?
        public let aspectRatio: ParamPick?
    }

    /// 一次点击完成三件事：润色描述 → 判定画风与比例 → 推荐负面提示词。
    /// 后两步由服务端基于**润色后**的文本执行，所以比分别调用更准。
    /// - Parameter onStage: 服务端下发的中文阶段文案，用于按钮内展示进度。
    public func optimizeAll(
        description: String,
        style: String,
        styles: [String: String],
        aspects: [String: String],
        customApiKey: String = "",
        customBaseUrl: String = "",
        customModel: String = "",
        hasReferenceImage: Bool = false,
        /// "describe" = 润色成完整画面描述；"instruction" = 把修改指令写得更精确（历史上下文）
        polishMode: String = "describe",
        /// 配参与负面词的依据（＝当前画面是什么）。为空则用润色后的文本。
        analysisText: String = "",
        port: Int = 5188,
        onStage: @escaping @Sendable (String) -> Void,
        /// 润色文本逐字增量（打字机效果）
        onPolishDelta: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> OptimizeResult {
        guard let url = URL(string: "http://127.0.0.1:\(port)/optimize-all") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "description": description,
            "style": style,
            "styles": styles,
            "aspects": aspects,
            "custom_api_key": customApiKey,
            "custom_base_url": customBaseUrl,
            "custom_model": customModel,
            "has_reference_image": hasReferenceImage,
            "polish_mode": polishMode,
            "analysis_text": analysisText
        ] as [String: Any])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        var failure: String?
        var payload: [String: Any]?

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let jsonString = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = jsonString.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            switch obj["stage"] as? String ?? "" {
            case "error":
                failure = obj["message"] as? String ?? "AI 优化失败"
            case "completed":
                payload = obj["result"] as? [String: Any]
            case "polish_delta":
                onPolishDelta(obj["message"] as? String ?? "")
            default:
                onStage(obj["message"] as? String ?? "")
            }
        }

        if let failure {
            throw NSError(domain: "Prism", code: 400, userInfo: [NSLocalizedDescriptionKey: failure])
        }
        guard let result = payload else {
            throw NSError(domain: "Prism", code: 500,
                          userInfo: [NSLocalizedDescriptionKey: "AI 优化未返回结果"])
        }

        func pick(_ key: String) -> ParamPick? {
            guard let obj = result[key] as? [String: Any],
                  let choice = obj["choice"] as? String else { return nil }
            let runner = obj["runner_up"] as? [String: Any]
            return ParamPick(
                choice: choice,
                confidence: obj["confidence"] as? Double ?? 0,
                runnerUp: runner?["choice"] as? String,
                runnerUpProbability: runner?["probability"] as? Double ?? 0
            )
        }

        return OptimizeResult(
            polishedPrompt: result["polished_prompt"] as? String ?? description,
            polishError: result["polish_error"] as? String,
            negativePrompt: result["negative_prompt"] as? String,
            negativeError: result["negative_error"] as? String,
            paramsError: result["params_error"] as? String,
            style: pick("style"),
            aspectRatio: pick("aspect_ratio")
        )
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
