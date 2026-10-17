import Foundation

@Observable
public final class SidecarManager: @unchecked Sendable {
    public static let shared = SidecarManager()

    public private(set) var isRunning: Bool = false
    public private(set) var hasAuth: Bool = false
    /// 是否已拿到一次**权威**的登录态结果（首轮 /health 成功返回即置位）。
    /// ⚠️ `hasAuth` 初值是 false，若 UI 直接据此渲染，App 刚启动、Sidecar 还在
    /// 拉起的 1–2 秒里会先闪一条「未连接 Google 账号」，随后又自动消失。
    /// 所有「未连接」提示都必须同时满足 `authChecked && !hasAuth`。
    public private(set) var authChecked: Bool = false
    public private(set) var serverPort: Int = 5188
    public private(set) var statusMessage: String = "未连接"
    /// 最近一次启动/自检失败的详细原因（供 UI 展示与问题排查），正常时为 nil
    public private(set) var startupError: String?

    private var process: Process?
    private var logHandle: FileHandle?

    /// Sidecar 必需的第三方依赖；启动前用解释器实跑 import 自检
    private static let requiredModules = "import gemini_webapi, cryptography, PIL"
    private static let logFileName = "sidecar.log"

    public init() {}

    // MARK: - 运行时解析

    /// 一个候选 Python 运行时：解释器路径 + 可选的外挂 site-packages（内嵌运行时用）。
    private struct PythonRuntime {
        let executable: String
        let sitePackages: String?
    }

    /// 定位 Sidecar 资源目录（Bundle 内 → 开发目录 → Bundle 同级 staging）。
    private static func resolveSidecarDir() -> URL? {
        let bundleScript = Bundle.main.resourceURL?.appendingPathComponent("Sidecar/server.py")
        let devScript = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sidecar/server.py")
        let siblingScript = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Sidecar/server.py")

        if let bPath = bundleScript, FileManager.default.fileExists(atPath: bPath.path) {
            return bPath.deletingLastPathComponent()
        }
        if FileManager.default.fileExists(atPath: devScript.path) {
            return devScript.deletingLastPathComponent()
        }
        if FileManager.default.fileExists(atPath: siblingScript.path) {
            return siblingScript.deletingLastPathComponent()
        }
        return nil
    }

    /// 候选解释器顺序：App 内嵌的 python-build-standalone（随包分发、依赖齐全），
    /// 其次开发机常见安装位，最后系统自带。
    private static func candidateRuntimes(sidecarDir: URL) -> [PythonRuntime] {
        var runtimes: [PythonRuntime] = []
        let bundledPython = sidecarDir.appendingPathComponent("python/bin/python3")
        if FileManager.default.isExecutableFile(atPath: bundledPython.path) {
            runtimes.append(PythonRuntime(
                executable: bundledPython.path,
                sitePackages: sidecarDir.appendingPathComponent("site-packages").path
            ))
        }
        for systemPython in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: systemPython) {
                runtimes.append(PythonRuntime(executable: systemPython, sitePackages: nil))
            }
        }
        return runtimes
    }

    /// 用解释器实跑一次 import 自检（带超时），判断该运行时是否真的能起 Sidecar。
    /// 解释器存在 ≠ 依赖齐全，缺包时必须给出明确报错而不是让子进程静默崩溃。
    private func runtimeUsable(_ runtime: PythonRuntime) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: runtime.executable)
        proc.arguments = ["-B", "-c", Self.requiredModules]
        proc.environment = runtimeEnvironment(runtime, extra: [:])

        let semaphore = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in semaphore.signal() }

        do {
            try proc.run()
        } catch {
            return false
        }
        // 最坏情况：某个解释器启动时卡在环境初始化（损坏的 Homebrew 链接等），
        // 8 秒不返回即判失败，避免整个 App 启动被无限拖住。
        if semaphore.wait(timeout: .now() + 8) == .timedOut {
            proc.terminate()
            return false
        }
        return proc.terminationStatus == 0
    }

    private func runtimeEnvironment(_ runtime: PythonRuntime, extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let sitePackages = runtime.sitePackages {
            // 内嵌 site-packages 置顶；若用户环境已有 PYTHONPATH 则追加在其后，不吞掉既有路径。
            let existing = env["PYTHONPATH"] ?? ""
            env["PYTHONPATH"] = existing.isEmpty ? sitePackages : "\(sitePackages):\(existing)"
        }
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        for (k, v) in extra { env[k] = v }
        return env
    }

    // MARK: - 启动

    public func startIfNeeded() async {
        // 1. 先检查是否已有运行中的 Sidecar
        if await checkHealth() {
            isRunning = true
            statusMessage = "服务正常"
            startupError = nil
            return
        }

        guard let sidecarDir = Self.resolveSidecarDir() else {
            statusMessage = "Sidecar 资源缺失"
            startupError = "未在 App 包内或开发目录找到 Sidecar/server.py，请重新安装 Prism。"
            return
        }
        let scriptPath = sidecarDir.appendingPathComponent("server.py").path

        // 2. 逐个候选解释器做依赖自检，取第一个可用的
        let runtimes = Self.candidateRuntimes(sidecarDir: sidecarDir)
        var selected: PythonRuntime?
        for runtime in runtimes where runtimeUsable(runtime) {
            selected = runtime
            break
        }

        guard let runtime = selected else {
            statusMessage = "Python 运行时不可用"
            if runtimes.isEmpty {
                startupError = "未找到任何 Python 3 解释器，且安装包内未包含内嵌运行时。请使用最新 DMG 重新安装 Prism。"
            } else {
                let tried = runtimes.map(\.executable).joined(separator: "\n  · ")
                startupError = """
                已找到 Python 解释器，但 Sidecar 依赖自检失败（需要 gemini-webapi / cryptography / pillow）。
                已尝试：
                  · \(tried)
                开发态可执行：python3 -m pip install -r Sidecar/requirements.txt
                分发态请使用含内嵌 Python 的最新 DMG 重新安装。日志：\(Self.logFileURL().path)
                """
            }
            return
        }

        statusMessage = "正在拉起 Sidecar 进程..."
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: runtime.executable)
        // -B：禁止写出字节码。安装态下 Python 会在 Contents/Resources/Sidecar/
        // 生成 __pycache__，破坏代码签名封印（触发 TCC/钥匙串反复授权）。
        proc.arguments = ["-B", scriptPath]
        proc.environment = runtimeEnvironment(runtime, extra: ["PRISM_PORT": "\(serverPort)"])

        // 3. stdout/stderr 落盘到用户目录，启动失败时有据可查（不写 Bundle，避免破坏签名）
        do {
            let logURL = Self.logFileURL()
            try? FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data("\n===== Prism Sidecar 启动 \(Date()) =====\n".utf8))
            proc.standardOutput = handle
            proc.standardError = handle
            logHandle = handle
        } catch {
            // 日志打不开不阻断启动，只是丢失诊断信息
        }

        do {
            try proc.run()
            self.process = proc

            // 轮询等待健康就绪（内嵌 Python 首次 import 较慢，最多等 15 秒）
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 500_000_000)
                if await checkHealth() {
                    isRunning = true
                    statusMessage = "服务已就绪"
                    startupError = nil
                    return
                }
                if proc.isRunning == false {
                    statusMessage = "Sidecar 进程意外退出"
                    startupError = "Sidecar 启动后立即退出，请查看日志：\(Self.logFileURL().path)"
                    return
                }
            }
            statusMessage = "启动超时，请检查环境"
            startupError = "Sidecar 在 15 秒内未通过健康检查，请查看日志：\(Self.logFileURL().path)"
        } catch {
            statusMessage = "启动失败: \(error.localizedDescription)"
            startupError = "拉起 Sidecar 进程失败：\(error.localizedDescription)"
        }
    }

    public func stop() {
        process?.terminate()
        process = nil
        try? logHandle?.close()
        logHandle = nil
        isRunning = false
    }

    static func logFileURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Prism/\(logFileName)")
    }

    public func checkHealth() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/health") else { return false }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 else { return false }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.hasAuth = (json["has_auth"] as? Bool) ?? false
                self.authChecked = true
                return true
            }
            return false
        } catch {
            return false
        }
    }

    public func syncChromeCookies() async -> (success: Bool, message: String) {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/auth/sync-chrome") else {
            return (false, "无效的 URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse else { return (false, "网络响应无效") }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let ok = (json["success"] as? Bool) ?? false
                let msg = (json["message"] as? String) ?? "未知响应"
                if ok {
                    self.hasAuth = true
                    self.authChecked = true
                }
                return (ok, msg)
            }
            return (httpResp.statusCode == 200, "同步状态: \(httpResp.statusCode)")
        } catch {
            return (false, "同步失败: \(error.localizedDescription)")
        }
    }
}
