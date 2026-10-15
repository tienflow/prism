import SwiftUI
import WebKit

public struct WebKitLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var statusMessage: String = "请在下方登录 Google 账号，或使用本地 Chrome 一键同步"
    @State private var isExtracting: Bool = false
    @State private var isSyncingChrome: Bool = false
    @State private var isLoadingWeb: Bool = true
    @State private var showManualInput: Bool = false
    @State private var manualPsid: String = ""
    @State private var manualPsidts: String = ""

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            // 顶栏控制面板 (采用 LiquidGlassCard 风格)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Google 账号凭据绑定")
                            .font(.headline)
                        if SidecarManager.shared.hasAuth {
                            Text("已就绪")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.2))
                                .foregroundStyle(Color.green)
                                .clipShape(Capsule())
                        }
                    }
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    Task {
                        isSyncingChrome = true
                        let res = await SidecarManager.shared.syncChromeCookies()
                        statusMessage = res.message
                        isSyncingChrome = false
                        if res.success {
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            dismiss()
                        }
                    }
                } label: {
                    Label(isSyncingChrome ? "正在读取..." : "一键从本地 Chrome 同步", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSyncingChrome)

                Button {
                    withAnimation {
                        showManualInput.toggle()
                    }
                } label: {
                    Label("手动凭据", systemImage: "slider.horizontal.2.square")
                }
                .buttonStyle(.bordered)

                Button("完成/关闭") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)
            .padding([.top, .horizontal])

            // 手动输入凭据折叠面板
            if showManualInput {
                VStack(alignment: .leading, spacing: 8) {
                    Text("手动注入 Google Cookie (高级)")
                        .font(.caption.bold())
                    HStack {
                        TextField("__Secure-1PSID", text: $manualPsid)
                            .textFieldStyle(.roundedBorder)
                        TextField("__Secure-1PSIDTS (可选)", text: $manualPsidts)
                            .textFieldStyle(.roundedBorder)
                        Button("保存并生效") {
                            Task {
                                await uploadCookies(psid: manualPsid.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   psidts: manualPsidts.trimmingCharacters(in: .whitespacesAndNewlines))
                            }
                        }
                        .disabled(manualPsid.isEmpty)
                    }
                }
                .padding(12)
                .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)
                .padding(.horizontal)
            }

            // WebKit 登录容器
            ZStack {
                GeminiWebView(isLoading: $isLoadingWeb, onCookiesDetected: { psid, psidts in
                    Task { @MainActor in
                        statusMessage = "检测到 Cookie！正在绑定..."
                        await uploadCookies(psid: psid, psidts: psidts)
                    }
                })
                .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusM))

                if isLoadingWeb {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                        Text("正在加载 Google Gemini 页面...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)
                }
            }
            .padding([.horizontal, .bottom])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 650)
        .liquidGlassBackground(cornerRadius: DesignMetrics.radiusL)
    }

    private func uploadCookies(psid: String, psidts: String) async {
        guard let url = URL(string: "http://127.0.0.1:\(SidecarManager.shared.serverPort)/auth/set-cookie") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ["psid": psid, "psidts": psidts]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let success = json["success"] as? Bool, success {
                statusMessage = "凭据绑定成功！"
                _ = await SidecarManager.shared.checkHealth()
                try? await Task.sleep(nanoseconds: 800_000_000)
                dismiss()
            }
        } catch {
            statusMessage = "上传凭据失败: \(error.localizedDescription)"
        }
    }
}

// 内部封装的 NSViewRepresentable WebKit 视图
struct GeminiWebView: NSViewRepresentable {
    @Binding var isLoading: Bool
    var onCookiesDetected: (String, String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 720, height: 500), configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = context.coordinator
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

        if let url = URL(string: "https://gemini.google.com") {
            webView.load(URLRequest(url: url))
        }

        context.coordinator.startCookieTimer(webView: webView)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, onCookiesDetected: onCookiesDetected)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        var onCookiesDetected: (String, String) -> Void
        var timer: Timer?

        init(isLoading: Binding<Bool>, onCookiesDetected: @escaping (String, String) -> Void) {
            self._isLoading = isLoading
            self.onCookiesDetected = onCookiesDetected
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            DispatchQueue.main.async {
                self.isLoading = false
            }
        }

        func startCookieTimer(webView: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self, weak webView] _ in
                guard let self = self, let webView = webView else { return }
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    var psid: String?
                    var psidts: String?
                    for cookie in cookies {
                        if cookie.name == "__Secure-1PSID" {
                            psid = cookie.value
                        } else if cookie.name == "__Secure-1PSIDTS" {
                            psidts = cookie.value
                        }
                    }
                    if let p = psid, !p.isEmpty {
                        self.timer?.invalidate()
                        self.timer = nil
                        self.onCookiesDetected(p, psidts ?? "")
                    }
                }
            }
        }

        deinit {
            timer?.invalidate()
        }
    }
}
