import SwiftUI
import AppKit

public struct PreferencesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var sidecar = SidecarManager.shared

    // 选中的偏好设置分类
    enum Tab: String, CaseIterable {
        case ai = "AI 配置"
        case account = "账号与凭据"
    }

    @State private var selectedTab: Tab = .ai

    // AI 配置持久化
    @AppStorage("pref_use_custom_ai") private var useCustomAI: Bool = false
    @AppStorage("pref_custom_api_key") private var customApiKey: String = ""
    @AppStorage("pref_custom_base_url") private var customBaseUrl: String = ""
    @AppStorage("pref_custom_model") private var customModel: String = "gemini-1.5-flash"
    /// 图片描述专用模型（需支持视觉，如 qwen-vl-plus / gpt-4o）；留空则图像描述走内置 Gemini
    @AppStorage("pref_custom_vision_model") private var customVisionModel: String = ""

    // 同步/操作状态提示
    @State private var syncStatusMessage: String = ""
    @State private var isSyncing: Bool = false
    @State private var showAuthSheet: Bool = false
    @State private var showApiKeyPlain: Bool = false

    // 自定义 API 测试状态
    @State private var isTestingAPI: Bool = false
    @State private var apiTestResult: (success: Bool, message: String)? = nil

    // TypeSafe Jev（AI 配参）配置
    @State private var typesafeKey: String = AIConfigStore.typesafeKey()
    @State private var showJevKeyPlain: Bool = false
    @State private var isTestingJev: Bool = false
    @State private var jevTestResult: (success: Bool, message: String)? = nil
    @State private var keySaveTask: Task<Void, Never>? = nil

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // 顶部导航栏
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                    Text("偏好设置")
                        .font(.system(size: 14, weight: .bold))
                }

                Spacer()

                // 分类切换 Segment
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Spacer()

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.85))

            Divider()

            // 内容区
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch selectedTab {
                    case .ai:
                        aiConfigurationSection
                    case .account:
                        accountCredentialsSection
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 520, height: 520)
        .fixedSize(horizontal: true, vertical: false)
        .liquidGlassBackground(cornerRadius: DesignMetrics.radiusL)
        .sheet(isPresented: $showAuthSheet) {
            WebKitLoginView()
        }
        .task {
            _ = await sidecar.checkHealth()
        }
        .onChange(of: typesafeKey) { _, newValue in
            // 防抖落盘：避免逐字符写文件，也免去「忘记保存」
            keySaveTask?.cancel()
            keySaveTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                AIConfigStore.setTypesafeKey(newValue)
            }
        }
    }

    // MARK: - 1. AI 润色配置
    private var aiConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI 提示词润色引擎")
                    .font(.headline)
                Text("「AI 润色」「负面词推荐」使用文本模型；「AI 图像描述」使用图片描述模型（需支持视觉，二者分开配置）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                // 引擎选择
                Toggle(isOn: $useCustomAI) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("启用自定义 API (Gemini / OpenAI 兼容接口)")
                            .font(.system(size: 12, weight: .medium))
                        Text("未勾选时默认复用当前登录的 Google 账号免费体验 Gemini 大模型润色")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                if useCustomAI {
                    Divider().padding(.vertical, 4)

                    // Base URL
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API 接口基址 (Base URL)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("https://api.openai.com/v1 或 Gemini 端点", text: $customBaseUrl)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }

                    // API Key
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("API 密钥 (API Key)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(showApiKeyPlain ? "隐藏" : "显示") {
                                showApiKeyPlain.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                        }

                        if showApiKeyPlain {
                            TextField("AIzaSy... 或 sk-...", text: $customApiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                        } else {
                            SecureField("AIzaSy... 或 sk-...", text: $customApiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                        }
                    }

                    // 文本模型（润色 / 负面词推荐）
                    VStack(alignment: .leading, spacing: 4) {
                        Text("文本模型（润色 / 负面词推荐）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("例如 qwen-flash, gpt-4o-mini, gemini-1.5-flash", text: $customModel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }

                    // 图片描述模型（AI 图像描述专用，必须支持视觉）
                    VStack(alignment: .leading, spacing: 4) {
                        Text("图片描述模型（AI 图像描述专用，需支持视觉）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("例如 qwen3.7-flash, qwen-vl-plus, gpt-4o", text: $customVisionModel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Text("留空则图像描述走内置 Gemini；填写后 Prism 会直接使用该模型识图，不做任何拦截。请确保填写的是支持视觉的模型——纯文本模型无法理解图片：服务方会静默丢弃图片并返回与参考图无关的编造描述。")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }

                    // 测试连接按钮与反馈
                    HStack(spacing: 8) {
                        Button {
                            testCustomAPI()
                        } label: {
                            HStack(spacing: 5) {
                                if isTestingAPI {
                                    ProgressView().controlSize(.mini)
                                    Text("测试中...")
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                    Text("测试 API 连通性")
                                }
                            }
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                        .liquidGlassCard(cornerRadius: DesignMetrics.radiusS)
                        .disabled(isTestingAPI || customApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let res = apiTestResult {
                            HStack(spacing: 4) {
                                Image(systemName: res.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                    .foregroundStyle(res.success ? Color.green : Color.red)
                                    .font(.system(size: 11))
                                Text(res.message)
                                    .font(.system(size: 10))
                                    .foregroundStyle(res.success ? Color.primary : Color.red)
                                    .lineLimit(1)
                            }
                            .transition(.opacity)
                        }

                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
            .padding(14)
            .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)

            // —— 参数配参引擎（TypeSafe Jev）——
            VStack(alignment: .leading, spacing: 4) {
                Text("参数配参引擎 (TypeSafe Jev)")
                    .font(.headline)
                Text("参数栏的「AI 配参」按钮用 Jev 判定画风与画幅比例。Jev 是判定模型：只返回选项与概率，不生成文本，因此结果可直接作为参数使用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("TypeSafe API Key")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(showJevKeyPlain ? "隐藏" : "显示") {
                            showJevKeyPlain.toggle()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.accentColor)
                    }

                    if showJevKeyPlain {
                        TextField("apikey_...", text: $typesafeKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    } else {
                        SecureField("apikey_...", text: $typesafeKey)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                    }

                    Text("保存在本机 ~/Pictures/Prism/ai_config.json（权限 600），不进源码与安装包。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 5) {
                    Image(systemName: "network")
                        .font(.system(size: 10))
                    Text("TypeSafe 按出口地区限封：中国大陆直连会返回 451，需系统代理可用。")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        testJev()
                    } label: {
                        HStack(spacing: 5) {
                            if isTestingJev {
                                ProgressView().controlSize(.mini)
                                Text("测试中...")
                            } else {
                                Image(systemName: "wand.and.stars")
                                Text("测试 Jev 判定")
                            }
                        }
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .liquidGlassCard(cornerRadius: DesignMetrics.radiusS)
                    .disabled(isTestingJev || typesafeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let res = jevTestResult {
                        HStack(spacing: 4) {
                            Image(systemName: res.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                .foregroundStyle(res.success ? Color.green : Color.red)
                                .font(.system(size: 11))
                            Text(res.message)
                                .font(.system(size: 10))
                                .foregroundStyle(res.success ? Color.primary : Color.red)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .transition(.opacity)
                    }

                    Spacer()
                }
            }
            .padding(14)
            .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)
        }
    }

    /// 立即落盘 Jev Key（不依赖「保存」按钮），并做一次真实判定以验证 Key + 代理 + 链路
    private func testJev() {
        let key = typesafeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        AIConfigStore.setTypesafeKey(key)

        isTestingJev = true
        jevTestResult = nil

        let styleMap = Dictionary(uniqueKeysWithValues: ArtStyleOption.allCases.map {
            ($0.rawValue, $0.criteriaHint)
        })
        let aspectMap = Dictionary(uniqueKeysWithValues: AspectRatioOption.allCases.map {
            ($0.rawValue, $0.criteriaHint)
        })

        Task {
            let start = Date()
            do {
                let suggestion = try await GeminiSSEClient.shared.suggestParams(
                    description: "一只橘猫坐在窗台上，午后阳光",
                    styles: styleMap,
                    aspects: aspectMap,
                    port: sidecar.serverPort
                )
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                await MainActor.run {
                    withAnimation(.spring(duration: 0.2)) {
                        jevTestResult = (true, "判定可用：\(suggestion.style.choice) · \(suggestion.aspectRatio.choice)（\(ms) ms）")
                    }
                    isTestingJev = false
                }
            } catch {
                await MainActor.run {
                    withAnimation(.spring(duration: 0.2)) {
                        jevTestResult = (false, "失败: \(error.localizedDescription)")
                    }
                    isTestingJev = false
                }
            }
        }
    }

    private func testCustomAPI() {
        guard !customApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isTestingAPI = true
        apiTestResult = nil

        let textModel = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let visionModel = customVisionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        // 图片描述模型与文本模型不同且已填写时，一并测试（避免只验证一半配置）
        let modelsToTest: [(label: String, model: String)] = {
            var list: [(String, String)] = [("文本模型", textModel)]
            if !visionModel.isEmpty && visionModel != textModel {
                list.append(("图片描述模型", visionModel))
            }
            return list
        }()

        Task {
            var results: [String] = []
            var allSuccess = true
            for item in modelsToTest {
                do {
                    let res = try await GeminiSSEClient.shared.testAPI(
                        apiKey: customApiKey,
                        baseUrl: customBaseUrl,
                        model: item.model,
                        port: sidecar.serverPort
                    )
                    if modelsToTest.count == 1 {
                        results.append(res.message)
                    } else {
                        results.append("\(item.label) \(res.success ? "✓" : "✗ \(res.message)")")
                    }
                    if !res.success { allSuccess = false }
                } catch {
                    results.append(modelsToTest.count == 1
                        ? "失败: \(error.localizedDescription)"
                        : "\(item.label) ✗ \(error.localizedDescription)")
                    allSuccess = false
                }
            }
            await MainActor.run {
                withAnimation(.spring(duration: 0.2)) {
                    self.apiTestResult = (allSuccess, results.joined(separator: " ｜ "))
                }
                self.isTestingAPI = false
            }
        }
    }

    // MARK: - 2. 账号与凭据配置
    private var accountCredentialsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Google 账号与生图凭据")
                    .font(.headline)
                Text("用于直接与 Google Gemini Imagen 3 逆向网页端建立安全长连接生图。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 状态卡片
            HStack(spacing: 12) {
                Circle()
                    .fill(sidecar.hasAuth ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                    .overlay(
                        Circle()
                            .stroke(sidecar.hasAuth ? Color.green.opacity(0.3) : Color.orange.opacity(0.3), lineWidth: 4)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(sidecar.hasAuth ? "Google 凭据已就绪" : "未检测到有效登录凭据")
                        .font(.system(size: 13, weight: .semibold))
                    Text(sidecar.hasAuth ? "可直接进行原生 Imagen 3 极速超清渲染与免费提示词润色" : "请从 Chrome 自动同步或在内嵌窗口中完成登录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(14)
            .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)

            // 操作按键组
            VStack(spacing: 10) {
                // 1. 从 Chrome 一键同步
                Button {
                    Task {
                        isSyncing = true
                        let res = await sidecar.syncChromeCookies()
                        syncStatusMessage = res.message
                        isSyncing = false
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                        Text(isSyncing ? "正在从 Chrome 读取 Cookie..." : "一键从 Google Chrome 自动同步凭据")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .liquidGlassCard(cornerRadius: DesignMetrics.radiusS)

                // 2. 内嵌 WebKit 登录
                Button {
                    showAuthSheet = true
                } label: {
                    HStack {
                        Image(systemName: "safari")
                            .font(.system(size: 12, weight: .semibold))
                        Text("打开内嵌 Google 授权窗口重新登录")
                            .font(.system(size: 12, weight: .medium))
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .liquidGlassCard(cornerRadius: DesignMetrics.radiusS)

                // 3. 清除当前凭据
                if sidecar.hasAuth {
                    Button {
                        Task {
                            try? await GeminiSSEClient.shared.clearAuth(port: sidecar.serverPort)
                            _ = await sidecar.checkHealth()
                            syncStatusMessage = "凭据已安全清除"
                        }
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.red.opacity(0.85))
                            Text("退出并清除本地 Google 凭据")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.red.opacity(0.85))
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .liquidGlassCard(cornerRadius: DesignMetrics.radiusS)
                }
            }

            if !syncStatusMessage.isEmpty {
                Text(syncStatusMessage)
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 4)
            }
        }
    }
}
