import Foundation

@Observable
public final class SidecarManager: @unchecked Sendable {
    public static let shared = SidecarManager()

    public private(set) var isRunning: Bool = false
    public private(set) var hasAuth: Bool = false
    public private(set) var serverPort: Int = 5188
    public private(set) var statusMessage: String = "未连接"

    private var process: Process?

    public init() {}

    public func startIfNeeded() async {
        // 1. 先检查是否已有运行中的 Sidecar
        if await checkHealth() {
            isRunning = true
            statusMessage = "服务正常"
            return
        }

        // 优先检查 App Bundle 内部的 Sidecar 资源，其次检查当前开发目录，
        // 最后回退到与 App Bundle 同级的 Sidecar（开发态 staging 产物；
        // 不再硬编码任何本机绝对路径）。
        let bundleScript = Bundle.main.resourceURL?.appendingPathComponent("Sidecar/server.py")
        let devScript = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sidecar/server.py")
        let siblingScript = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Sidecar/server.py")

        let scriptPath: String
        if let bPath = bundleScript?.path, FileManager.default.fileExists(atPath: bPath) {
            scriptPath = bPath
        } else if FileManager.default.fileExists(atPath: devScript.path) {
            scriptPath = devScript.path
        } else {
            scriptPath = siblingScript.path
        }

        statusMessage = "正在拉起 Sidecar 进程..."
        let interpreter = Self.resolvePythonInterpreter()
        let proc = Process()
        if interpreter == "/usr/bin/env" {
            // 兜底：交给 env 在 PATH 中查找 python3
            proc.executableURL = URL(fileURLWithPath: interpreter)
            proc.arguments = ["python3", "-B", scriptPath]
        } else {
            proc.executableURL = URL(fileURLWithPath: interpreter)
            // -B：禁止写出字节码。安装态下 Python 会在 Contents/Resources/Sidecar/
            // 生成 __pycache__，破坏代码签名封印（触发 TCC/钥匙串反复授权）。
            // 比 server.py 里的 sys.dont_write_bytecode 更稳——不依赖 import 顺序。
            proc.arguments = ["-B", scriptPath]
        }

        var env = ProcessInfo.processInfo.environment
        env["PRISM_PORT"] = "\(serverPort)"
        proc.environment = env

        do {
            try proc.run()
            self.process = proc

            // 轮询等待健康就绪 (最多等待 5 秒)
            for _ in 0..<10 {
                try await Task.sleep(nanoseconds: 500_000_000)
                if await checkHealth() {
                    isRunning = true
                    statusMessage = "服务已就绪"
                    return
                }
            }
            statusMessage = "启动超时，请检查环境"
        } catch {
            statusMessage = "启动失败: \(error.localizedDescription)"
        }
    }

    public func stop() {
        process?.terminate()
        process = nil
        isRunning = false
    }

    /// 解析可用的 Python 解释器：优先 App 内置 venv，其次常见安装位，
    /// 最后交给 `/usr/bin/env`（由调用方补 `python3` 参数）。不硬编码本机路径。
    private static func resolvePythonInterpreter() -> String {
        var candidates: [String] = []
        if let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Sidecar/venv/bin/python3").path {
            candidates.append(bundled)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/python3",   // Apple Silicon Homebrew
            "/usr/local/bin/python3",      // Intel Homebrew / 官方安装包
            "/usr/bin/python3"             // 系统自带
        ])
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/env"
    }

    public func checkHealth() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(serverPort)/health") else { return false }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let httpResp = resp as? HTTPURLResponse, httpResp.statusCode == 200 else { return false }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.hasAuth = (json["has_auth"] as? Bool) ?? false
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
                }
                return (ok, msg)
            }
            return (httpResp.statusCode == 200, "同步状态: \(httpResp.statusCode)")
        } catch {
            return (false, "同步失败: \(error.localizedDescription)")
        }
    }
}
