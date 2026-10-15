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

    // 同步/操作状态提示
    @State private var syncStatusMessage: String = ""
    @State private var isSyncing: Bool = false
    @State private var showAuthSheet: Bool = false
    @State private var showApiKeyPlain: Bool = false

    // 自定义 API 测试状态
    @State private var isTestingAPI: Bool = false
    @State private var apiTestResult: (success: Bool, message: String)? = nil

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
        .frame(width: 520, height: 440)
        .fixedSize(horizontal: true, vertical: false)
        .liquidGlassBackground(cornerRadius: DesignMetrics.radiusL)
        .sheet(isPresented: $showAuthSheet) {
            WebKitLoginView()
        }
        .task {
            _ = await sidecar.checkHealth()
        }
    }

    // MARK: - 1. AI 润色配置
    private var aiConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI 提示词润色引擎")
                    .font(.headline)
                Text("生图参数面板右下角的「AI 润色」按钮将使用此配置将简短描述扩写为高细节提示词。")
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

                    // Model Name
                    VStack(alignment: .leading, spacing: 4) {
                        Text("模型名称 (Model Name)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        TextField("例如 qwen3-vl-plus, gemini-1.5-flash, gpt-4o-mini", text: $customModel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
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
        }
    }

    private func testCustomAPI() {
        guard !customApiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isTestingAPI = true
        apiTestResult = nil

        Task {
            do {
                let res = try await GeminiSSEClient.shared.testAPI(
                    apiKey: customApiKey,
                    baseUrl: customBaseUrl,
                    model: customModel,
                    port: sidecar.serverPort
                )
                await MainActor.run {
                    withAnimation(.spring(duration: 0.2)) {
                        self.apiTestResult = (res.success, res.message)
                    }
                    self.isTestingAPI = false
                }
            } catch {
                await MainActor.run {
                    withAnimation(.spring(duration: 0.2)) {
                        self.apiTestResult = (false, "失败: \(error.localizedDescription)")
                    }
                    self.isTestingAPI = false
                }
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
