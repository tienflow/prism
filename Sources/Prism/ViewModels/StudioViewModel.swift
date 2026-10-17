import SwiftUI
import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import os

/// 主画布的全部业务状态与编排：生成 / 改图任务（多任务并行）、历史 CRUD、
/// AI 图像描述、参考图同步、键盘快捷键。
///
/// 从 MainStudioView 抽出：View 只负责渲染与绑定，所有跨组件状态与异步逻辑集中在这里，
/// 也让菜单命令（SwiftUI Commands）、拖入/粘贴等入口能直接调用同一个动作。
@Observable
@MainActor
public final class StudioViewModel {
    public let sidecar = SidecarManager.shared

    // MARK: - 界面折叠
    public var isSidebarVisible: Bool = false

    // MARK: - 参数面板
    public var prompt: String = ""
    public var negativePrompt: String = ""
    public var selectedAspect: AspectRatioOption = .landscape
    public var selectedStyle: ArtStyleOption = .none

    // MARK: - 运行状态（多任务：每个记录独立一个生成任务，可并行）
    /// 画布/参数栏的进度一律从「当前选中记录」派生，避免多任务之间串台。
    public var generatingBatchIds: Set<UUID> = []
    public var genTasks: [UUID: Task<Void, Never>] = [:]
    /// 每个记录各自的运行令牌。停止该记录时换新令牌，作废它的在途 UI 回调——
    /// SSE 帧派发到主线程的 `Task { @MainActor in … }` 不受 Task 取消影响，
    /// 若不作废，停止后这些迟到帧会把批次 stage 写回「生成中」，界面看起来像没停下来。
    public var runTokens: [UUID: UUID] = [:]

    // MARK: - 历史与画廊
    public var history: [GenerationBatch] = []
    public var selectedBatchId: UUID?
    public var selectedImageIndex: Int = 0
    /// 历史侧栏搜索关键字（按提示词 / 修改指令过滤，空串 = 全部）
    public var historySearchText: String = ""

    /// 搜索过滤后的历史列表（匹配提示词、负面词、修改指令；空关键字返回全部）
    public var filteredHistory: [GenerationBatch] {
        let keyword = historySearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return history }
        return history.filter { batch in
            if batch.prompt.localizedCaseInsensitiveContains(keyword) { return true }
            if batch.negativePrompt.localizedCaseInsensitiveContains(keyword) { return true }
            if let turns = batch.editTurns,
               turns.contains(where: { $0.instruction.localizedCaseInsensitiveContains(keyword) }) {
                return true
            }
            return false
        }
    }

    // MARK: - 弹窗
    public var showAuthSheet: Bool = false
    public var showPreferencesSheet: Bool = false
    public var showMetadata: Bool = false

    // MARK: - 多模态 AI 状态
    public var referenceImagePath: String? = nil
    public var isDescribingImage: Bool = false
    public var imageDescription: String? = nil
    public var showDescriptionSheet: Bool = false
    public var pendingDescribePath: String? = nil
    /// 描述请求的作废令牌：同一条记录的「重新生成」会换新令牌，
    /// 让上一轮在途的流式增量回调失效（否则两轮文字会交错拼在一起）。
    private var describeRunToken = UUID()
    public var promptCopied: Bool = false

    // MARK: - 输入上下文
    /// 参数栏输入上下文令牌：切换历史记录 / 新建画布时刷新（用于清空撤回栈）
    public var inspectorContextToken: UUID = UUID()

    /// 描述框里「已被消费过」的文本基线（提交生图 / 改图时记录）。
    /// 「继续修改当前画面」要求描述框内容与该基线不同——避免把刚用过、
    /// 或进入历史时预填的提示词原样当作修改指令再提交一次（白跑一轮）。
    public var promptBaseline: String = ""

    // MARK: - 键盘事件监听
    private var keyMonitor: Any? = nil

    // MARK: - 菜单命令桥接（SwiftUI Commands 通过 FocusedValues 调用）
    public let menuActions = PrismMenuActions()

    public init() {
        menuActions.startGeneration = { [weak self] in self?.startGeneration() }
        menuActions.focusPrompt = { [weak self] in self?.focusPromptEditor() }
        menuActions.toggleMetadata = { [weak self] in self?.toggleMetadata() }
        menuActions.toggleSidebar = { [weak self] in self?.toggleSidebar() }
        menuActions.quickLook = { [weak self] in
            guard let self, let path = self.activeImagePathForAI else { return }
            ImageQuickLookController.shared.present(path: path)
        }
    }

    /// ⌘L：把键盘焦点交给描述框（界面中唯一可编辑的 NSTextView，负面词是 NSTextField）
    public func focusPromptEditor() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        guard let content = window.contentView,
              let textView = Self.firstEditableTextView(in: content) else { return }
        window.makeFirstResponder(textView)
    }

    private static func firstEditableTextView(in view: NSView) -> NSTextView? {
        for sub in view.subviews {
            if let textView = sub as? NSTextView, textView.isEditable {
                return textView
            }
            if let hit = firstEditableTextView(in: sub) {
                return hit
            }
        }
        return nil
    }

    // MARK: - AI 配置（偏好设置，UserDefaults 单一数据源）
    private var defaults: UserDefaults { .standard }
    public var useCustomAI: Bool { defaults.bool(forKey: "pref_use_custom_ai") }
    public var customApiKey: String { defaults.string(forKey: "pref_custom_api_key") ?? "" }
    public var customBaseUrl: String { defaults.string(forKey: "pref_custom_base_url") ?? "" }
    public var customModel: String { defaults.string(forKey: "pref_custom_model") ?? "gemini-3.5-flash-lite" }
    public var customVisionModel: String { defaults.string(forKey: "pref_custom_vision_model") ?? "" }

    // MARK: - 派生状态
    public var selectedBatch: GenerationBatch? {
        guard let id = selectedBatchId else { return nil }
        return history.first(where: { $0.id == id })
    }

    /// 当前稿件的**画面描述**（AI 优化的配参/负面词依据、负面词「AI 推荐」的依据）。
    /// 优先取该图的 AI 描述——它最准，尤其图生图时 `batch.prompt` 只是修改指令
    /// （如「把丁香换成玫瑰」），拿它当画面描述会跑偏；没有 AI 描述则回退记录级提示词。
    public var selectedPictureDescription: String {
        guard let b = selectedBatch else {
            return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let paths = b.imagePaths
        if paths.indices.contains(selectedImageIndex),
           let desc = b.aiDescriptions?[paths[selectedImageIndex]]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !desc.isEmpty {
            return desc
        }
        return b.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 有任意记录正在生成 / 改图中（多任务并行）
    public var isGenerating: Bool { !generatingBatchIds.isEmpty }

    /// 画布与参数栏的进度一律取自**当前选中记录**，多任务下不串台
    public var currentStage: GenerationStage { selectedBatch?.stage ?? .idle }
    public var currentMessage: String { selectedBatch?.statusMessage ?? "" }

    /// 选中记录自身正在生成 / 改图中（决定按钮区显示「停止生成」还是「开始生图」）
    public var isActingOnSelection: Bool {
        guard let id = selectedBatchId else { return false }
        return generatingBatchIds.contains(id)
    }

    /// 有其他记录在跑时的提示文案（**信息性**，不再禁用——并行是允许的）
    public var busyElsewhereHint: String? {
        let others = generatingBatchIds.filter { $0 != selectedBatchId }
        guard !others.isEmpty else { return nil }
        let names = others.compactMap { id -> String? in
            guard let batch = history.first(where: { $0.id == id }) else { return nil }
            let text = batch.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.count > 12 ? String(text.prefix(12)) + "…" : text
        }
        if names.isEmpty { return "另有 \(others.count) 个任务正在生成中" }
        if others.count == 1, let first = names.first { return "「\(first)」正在生成中" }
        return "另有 \(others.count) 个任务正在生成中（含「\(names.first ?? "")」）"
    }

    /// 当前选中的批次是否可继续改图（有图 + 描述框里是**新的**修改指令）
    public var canContinueEditing: Bool {
        guard let batch = selectedBatch, !batch.imagePaths.isEmpty else { return false }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        // 内容与「已消费基线」相同（刚生图/改图用过的那段文字）→ 不算新指令，不激活按钮
        return text != promptBaseline.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 描述框里仍是上一轮用过、尚未修改的文字（用于向用户解释按钮为何置灰）
    public var promptIsConsumedBaseline: Bool {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text == promptBaseline.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 供 AI 弹窗"重新生成"时定位当前展示的图片路径
    public var activeImagePathForAI: String? {
        guard let id = selectedBatchId else { return nil }
        guard let batch = history.first(where: { $0.id == id }), !batch.imagePaths.isEmpty else { return nil }
        return batch.imagePaths.indices.contains(selectedImageIndex)
            ? batch.imagePaths[selectedImageIndex]
            : batch.imagePaths.first
    }

    // MARK: - 参考图与批次同步
    public func syncReferenceImageToBatch(_ path: String?) {
        guard let id = selectedBatchId,
              let idx = history.firstIndex(where: { $0.id == id }),
              history[idx].referenceImagePath != path else { return }
        history[idx].referenceImagePath = path
        HistoryStore.shared.save(history)
    }

    // MARK: - 画布与批次选择
    public func createNewCanvas() {
        // 支持多任务并行：新建画布不会取消后台正在跑的生成任务，无需确认
        withAnimation(.spring(duration: 0.25)) {
            selectedBatchId = nil
            selectedImageIndex = 0
            prompt = ""
            promptBaseline = ""
            negativePrompt = ""
            selectedStyle = .none
            referenceImagePath = nil
            inspectorContextToken = UUID()
        }
    }

    public func selectBatch(_ batch: GenerationBatch) {
        withAnimation(.spring(duration: 0.2)) {
            selectedBatchId = batch.id
            // 🔴 打开历史记录默认停在该记录的**最新稿**，而不是第 0 张（原图）。
            // 复用远端改图会话的判定是「当前稿 == 最新稿」（见 continueEditing），
            // 若这里固定回到原图，凡是改过图的记录（张数 ≥ 2）每次都会被判为
            // 「不在最新稿」→ 必然主动重新播种新会话，Gemini 侧就会多出一条会话。
            // 实测：服务端续接路径本身正确（cid 不变），问题只在稿位。
            selectedImageIndex = max(0, batch.imagePaths.count - 1)
            // ⚠️ 描述框在历史上下文中是「修改指令」的输入位，绝不能预填原始提示词：
            // 否则主按钮（继续修改当前画面）会立刻可点，误回车即把原提示词当作修改指令
            // 再跑一次生图（白等 20–50 秒）。原始提示词可在稿次行与「信息」弹窗查看。
            self.prompt = ""
            self.promptBaseline = ""
            self.negativePrompt = batch.negativePrompt
            self.referenceImagePath = batch.referenceImagePath
            inspectorContextToken = UUID()
            if let matched = AspectRatioOption.allCases.first(where: { $0.rawValue == batch.aspectRatio }) {
                self.selectedAspect = matched
            }
            if let s = batch.style, let matchedStyle = ArtStyleOption.allCases.first(where: { $0.rawValue == s }) {
                self.selectedStyle = matchedStyle
            } else {
                self.selectedStyle = .none
            }
        }
    }

    /// 切到第一个正在跑但不是当前选中的批次（参数栏「查看忙碌任务」入口）
    public func viewFirstBusyBatch() {
        if let id = generatingBatchIds.first(where: { $0 != selectedBatchId }),
           let b = history.first(where: { $0.id == id }) {
            selectBatch(b)
        }
    }

    // MARK: - 删除
    public func deleteBatch(id: UUID) {
        guard let batch = history.first(where: { $0.id == id }) else { return }

        // 删除会触及磁盘文件，先二次确认（默认移入废纸篓，可恢复）
        let alert = NSAlert()
        alert.messageText = "删除这组生成记录？"
        alert.informativeText = "「\(batch.prompt.prefix(40))\(batch.prompt.count > 40 ? "…" : "")」\n共 \(batch.imagePaths.count) 张图片，同时会清理伴生元数据、缩略图与 AI 描述缓存。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "保留图片，仅移除记录")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        deleteBatchInternal(id: id, moveImagesToTrash: response == .alertFirstButtonReturn)
    }

    private func deleteBatchInternal(id: UUID, moveImagesToTrash: Bool) {
        guard let batch = history.first(where: { $0.id == id }) else { return }
        HistoryStore.removeAssets(for: batch, moveImagesToTrash: moveImagesToTrash)

        withAnimation(.spring(duration: 0.25)) {
            history.removeAll(where: { $0.id == id })
            HistoryStore.shared.save(history)
            if selectedBatchId == id {
                selectedBatchId = nil
                selectedImageIndex = 0
            }
        }
    }

    /// 删除**当前稿**（画布底部工具栏与当前稿绑定）。
    /// 多稿记录：只删当前稿，其余保留；单稿记录：等同删除整条记录。
    public func deleteCurrentShot() {
        guard let batch = selectedBatch,
              batch.imagePaths.indices.contains(selectedImageIndex) else { return }
        let idx = selectedImageIndex
        let label = batch.turnLabel(at: idx)

        // 单稿：删稿 = 删整条记录（沿用原确认与文案）
        if batch.imagePaths.count == 1 {
            let alert = NSAlert()
            alert.messageText = "删除这组生成记录？"
            alert.informativeText = "「\(batch.prompt.prefix(40))\(batch.prompt.count > 40 ? "…" : "")」\n这组只有当前这 1 张图，将整条移除，并清理伴生元数据、缩略图与 AI 描述缓存。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "移到废纸篓")
            alert.addButton(withTitle: "保留图片，仅移除记录")
            alert.addButton(withTitle: "取消")
            let r = alert.runModal()
            guard r == .alertFirstButtonReturn || r == .alertSecondButtonReturn else { return }
            deleteBatchInternal(id: batch.id, moveImagesToTrash: r == .alertFirstButtonReturn)
            return
        }

        let alert = NSAlert()
        alert.messageText = "删除当前稿件（\(label)）？"
        alert.informativeText = "仅删除这一稿，其余 \(batch.imagePaths.count - 1) 稿保留；将同时清理该稿的伴生元数据、缩略图与 AI 描述缓存。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "保留图片，仅移除该稿")
        alert.addButton(withTitle: "取消")
        let r = alert.runModal()
        guard r == .alertFirstButtonReturn || r == .alertSecondButtonReturn else { return }
        removeShot(batchId: batch.id, index: idx, moveImagesToTrash: r == .alertFirstButtonReturn)
    }

    /// 从多稿记录中移除一张稿（图文件 + 轮次记录 + AI 描述缓存）。
    /// 稿次编号按 imagePath 匹配 turn，删中间稿/原图后其余编号不受影响。
    private func removeShot(batchId: UUID, index: Int, moveImagesToTrash: Bool) {
        guard let batch = history.first(where: { $0.id == batchId }),
              batch.imagePaths.indices.contains(index) else { return }
        let path = batch.imagePaths[index]

        HistoryStore.removeAssets(forPaths: [path], moveImagesToTrash: moveImagesToTrash)

        withAnimation(.spring(duration: 0.25)) {
            guard let i = history.firstIndex(where: { $0.id == batchId }) else { return }
            history[i].imagePaths.remove(at: index)
            // 该稿的轮次记录与描述缓存一并移除
            history[i].editTurns?.removeAll(where: { $0.imagePath == path })
            history[i].aiDescriptions?[path] = nil
            // 远端改图会话的上下文包含被删画面：主动失效，下次改图自动以当前画面重新播种
            history[i].sessionId = nil
            selectedImageIndex = min(index, max(0, history[i].imagePaths.count - 1))
            HistoryStore.shared.save(history)
        }
    }

    // MARK: - 启动加载
    public func loadExistingImages() async {
        // 后台清一次过期缩略图缓存（>30 天，含旧版文件名缓存孤儿），不阻塞加载
        DispatchQueue.global(qos: .utility).async {
            ThumbnailGenerator.shared.cleanExpiredThumbnails()
        }
        // 1. 优先读取持久化 history.json（异步加载）
        let loadedFromStore = await HistoryStore.shared.loadAsync()
        if !loadedFromStore.isEmpty {
            self.history = loadedFromStore
            // 默认展示新画布 (创作画布已就绪)，用户点击左侧历史才切换到既往作品
            self.selectedBatchId = nil
            // 预热缩略图缓存（后台批量加载磁盘缩略图到内存）
            await preloadThumbnails()
            return
        }

        // 2. 无 history.json 时自动扫描本地目录兜底（含 YYYY-MM 子目录，递归枚举）
        let picturesDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Prism")
        let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: picturesDir,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else { return }

        let imageURLs = enumerator.compactMap { $0 as? URL }.filter { url in
            // references/ 存放粘贴的参考图（pasted_*.png），不是历史作品
            if url.path.contains("/references/") { return false }
            let ext = url.pathExtension.lowercased()
            return ext == "png" || ext == "jpg" || ext == "jpeg"
        }.sorted { (u1, u2) -> Bool in
            let d1 = (try? u1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            let d2 = (try? u2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
            return d1 > d2
        }

        guard !imageURLs.isEmpty else { return }
        var loaded: [GenerationBatch] = []
        for file in imageURLs {
            var promptText = "历史作品"
            var aspectText = "原画"
            var styleText: String? = nil
            var negPrompt = ""

            // 尝试读取同名 .json 元数据文件
            let metaURL = file.deletingPathExtension().appendingPathExtension("json")
            if let metaData = try? Data(contentsOf: metaURL),
               let json = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any] {
                if let p = json["prompt"] as? String, !p.isEmpty { promptText = p }
                if let a = json["aspect_ratio"] as? String, !a.isEmpty { aspectText = a }
                if let s = json["style"] as? String, !s.isEmpty { styleText = s }
                if let np = json["negative_prompt"] as? String { negPrompt = np }
            }

            let fileModDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            let b = GenerationBatch(
                prompt: promptText,
                negativePrompt: negPrompt,
                aspectRatio: aspectText,
                style: styleText,
                stage: .completed,
                statusMessage: "已就绪",
                imagePaths: [file.path],
                createdAt: fileModDate
            )
            loaded.append(b)
        }
        self.history = loaded
        // 默认展示新画布，用户随时可从历史面板切入
        self.selectedBatchId = nil
        HistoryStore.shared.save(loaded)
    }

    /// 启动时预热缩略图缓存：批量加载磁盘缩略图（~20KB/张）到内存
    private func preloadThumbnails() async {
        let paths = history.flatMap { $0.imagePaths }
        guard !paths.isEmpty else { return }
        await ThumbnailGenerator.shared.preloadThumbnails(for: paths)
    }

    // MARK: - 停止
    /// 停止指定记录的生成任务（缺省 = 当前选中记录）。
    /// 多任务并行下只停这一个，不影响其他正在跑的记录。
    public func stopGeneration(_ batchId: UUID? = nil) {
        guard let id = batchId ?? selectedBatchId, generatingBatchIds.contains(id) else { return }
        // 留痕便于诊断「点了没反应」类反馈
        aiLog("stopGeneration 触发: batch=\(String(id.uuidString.prefix(8))) "
              + "其余仍在跑=\(generatingBatchIds.count - 1) "
              + "selBatch=\(selectedBatchId?.uuidString.prefix(8) ?? "nil")")
        // 先作废该记录的运行令牌：此后的在途 SSE 回调一律丢弃，
        // 避免它们把批次 stage 写回「生成中」而让界面看起来停不下来。
        runTokens[id] = UUID()
        genTasks[id]?.cancel()
        genTasks[id] = nil
        let port = sidecar.serverPort
        Task {
            let delivered = await GeminiSSEClient.shared.cancel(
                port: port,
                taskId: id.uuidString
            )
            if !delivered {
                await MainActor.run {
                    if let i = self.history.firstIndex(where: { $0.id == id }) {
                        self.history[i].statusMessage = "已停止本地等待，但停止请求未送达后台（Sidecar 可能已退出）"
                    }
                }
            }
        }
        withAnimation(.spring(duration: 0.25)) {
            generatingBatchIds.remove(id)
            // 中断批次状态回落（避免侧栏一直停在「生成中」）；尚无产图的批次直接清理
            if let i = history.firstIndex(where: { $0.id == id }) {
                if history[i].imagePaths.isEmpty {
                    history.removeAll(where: { $0.id == id })
                    // 停止后回「创作画布」而不是跳到某条历史记录；
                    // 描述框保留用户刚写的文字，改一改就能直接再次生成。
                    selectedBatchId = nil
                } else {
                    history[i].stage = .completed
                    history[i].statusMessage = "已取消生成"
                    HistoryStore.shared.append(history[i])
                }
            }
        }
    }

    // MARK: - 文生图 / 图生图
    public func startGeneration() {
        let promptText = prompt
        let negative = negativePrompt
        let aspect = selectedAspect.rawValue
        let styleSuffix = selectedStyle.contextSuffix
        let styleRaw = selectedStyle.rawValue
        let refPath = referenceImagePath

        guard !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // 无并发上限：每次新建一条记录并各自起任务（同记录不重复跑由 generatingBatchIds 保证）

        let newBatchId = UUID()
        let newBatch = GenerationBatch(
            id: newBatchId,
            prompt: promptText,
            negativePrompt: negative,
            aspectRatio: aspect,
            style: styleRaw,
            stage: .connecting,
            statusMessage: "正在建立 Google Gemini 会话...",
            referenceImagePath: refPath
        )
        history.insert(newBatch, at: 0)
        selectedBatchId = newBatchId
        generatingBatchIds.insert(newBatchId)
        selectedImageIndex = 0
        promptBaseline = promptText   // 本次输入已被消费，改一个字才能再次提交

        launchGeneration(
            batchId: newBatchId, promptText: promptText, negative: negative,
            aspect: aspect, styleSuffix: styleSuffix, refPath: refPath
        )
    }

    /// 文生图 / 图生图的统一任务编排（新建与失败重试共用；批次记录已存在）。
    private func launchGeneration(
        batchId: UUID,
        promptText: String,
        negative: String,
        aspect: String,
        styleSuffix: String,
        refPath: String?
    ) {
        let runToken = UUID()
        runTokens[batchId] = runToken
        let port = sidecar.serverPort
        genTasks[batchId] = Task { [weak self] in
            do {
                if let refPath {
                    try await GeminiSSEClient.shared.generateWithImage(
                        imagePath: refPath,
                        prompt: promptText,
                        aspectRatio: aspect,
                        // 与文生图 / 改图统一：下发完整风格描述（contextSuffix）
                        styleContext: styleSuffix,
                        negativePrompt: negative,
                        maxKb: 0,
                        taskId: batchId.uuidString,
                        port: port
                    ) { [weak self] chunk in
                        Task { @MainActor in
                            self?.applyGenerationChunk(chunk, batchId: batchId, runToken: runToken, replaceFiles: true)
                        }
                    }
                } else {
                    try await GeminiSSEClient.shared.generate(
                        prompt: promptText,
                        aspectRatio: aspect,
                        negativePrompt: negative,
                        styleContext: styleSuffix,
                        maxKb: 0,
                        taskId: batchId.uuidString,
                        port: port
                    ) { [weak self] chunk in
                        Task { @MainActor in
                            self?.applyGenerationChunk(chunk, batchId: batchId, runToken: runToken, replaceFiles: true)
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { [weak self] in
                        self?.markBatchError(batchId: batchId, message: "生图请求异常: \(error.localizedDescription)")
                    }
                }
            }
            await MainActor.run { [weak self] in
                self?.generatingBatchIds.remove(batchId)
                self?.genTasks[batchId] = nil
                self?.runTokens[batchId] = nil
            }
        }
    }

    /// 失败重试：
    /// - 无图批次（文生图 / 图生图失败）→ 用批次原参数重新发起，沿用原批次记录；
    /// - 有图批次（改图失败）→ 切回该批次，用最后一轮修改指令重新走「继续修改」。
    public func retry(batchId: UUID) {
        guard !generatingBatchIds.contains(batchId),
              let idx = history.firstIndex(where: { $0.id == batchId }) else { return }
        let batch = history[idx]

        if batch.imagePaths.isEmpty {
            history[idx].stage = .connecting
            history[idx].statusMessage = "正在重新建立 Google Gemini 会话..."
            selectedBatchId = batchId
            selectedImageIndex = 0
            generatingBatchIds.insert(batchId)
            let styleOption = batch.style.flatMap { ArtStyleOption(rawValue: $0) } ?? .none
            launchGeneration(
                batchId: batchId,
                promptText: batch.prompt,
                negative: batch.negativePrompt,
                aspect: batch.aspectRatio,
                styleSuffix: styleOption.contextSuffix,
                refPath: batch.referenceImagePath
            )
        } else {
            // 改图失败：恢复当时的参数与指令，复用 continueEditing 的全部会话规则
            withAnimation(.spring(duration: 0.2)) {
                selectedBatchId = batchId
                selectedImageIndex = batch.imagePaths.count - 1
                prompt = batch.editTurns?.last?.instruction ?? batch.prompt
                promptBaseline = ""   // 解除「已消费」锁定，让主按钮重新可点
                negativePrompt = batch.negativePrompt
                if let a = AspectRatioOption(rawValue: batch.aspectRatio) { selectedAspect = a }
                if let s = batch.style { selectedStyle = ArtStyleOption(rawValue: s) ?? .none }
                referenceImagePath = batch.referenceImagePath
            }
            continueEditing()
        }
    }

    /// 统一应用 SSE 进度帧到指定批次（runToken 不匹配的迟到帧直接丢弃）。
    private func applyGenerationChunk(_ chunk: SSEChunk, batchId: UUID, runToken: UUID, replaceFiles: Bool) {
        guard runToken == runTokens[batchId] else { return }
        guard let idx = history.firstIndex(where: { $0.id == batchId }) else { return }
        if let st = GenerationStage(rawValue: chunk.stage) {
            history[idx].stage = st
        }
        history[idx].statusMessage = chunk.message
        if let files = chunk.files, !files.isEmpty {
            if replaceFiles {
                history[idx].imagePaths = files
            } else {
                history[idx].imagePaths.append(contentsOf: files)
            }
            history[idx].stage = .completed
            history[idx].statusMessage = "生成完成"
            HistoryStore.shared.append(history[idx])
        }
    }

    private func markBatchError(batchId: UUID, message: String) {
        if let i = history.firstIndex(where: { $0.id == batchId }) {
            history[i].stage = .error
            history[i].statusMessage = message
        }
    }

    // MARK: - 多轮会话改图
    public func continueEditing() {
        guard let batchId = selectedBatchId,
              !generatingBatchIds.contains(batchId),   // 同一记录不重复跑；**其他记录可并行**
              let idx = history.firstIndex(where: { $0.id == batchId }),
              !history[idx].imagePaths.isEmpty else { return }

        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        promptBaseline = prompt   // 本次指令已被消费

        let batch = history[idx]
        let sourcePath = batch.imagePaths.indices.contains(selectedImageIndex)
            ? batch.imagePaths[selectedImageIndex]
            : batch.imagePaths[0]

        // 会话复用规则：仅当所选稿＝最后一次产出的那张时才复用远端会话
        // （复用时模型保留上一轮画面上下文，source_image_path 不会被使用）。
        // 若用户切到较早的稿再改，则以该稿重新播种新会话——否则引擎的 resumed 分支
        // 会忽略 source_image_path，实际仍基于「最后一稿」修改，与界面所见不符。
        let isOnLatestTurn = (selectedImageIndex == batch.imagePaths.count - 1)
        let reuseSessionId = isOnLatestTurn ? (batch.sessionId ?? "") : ""

        let aspect = selectedAspect.rawValue
        let styleSuffix = selectedStyle.contextSuffix
        let styleRaw = selectedStyle.rawValue
        let negative = negativePrompt

        generatingBatchIds.insert(batchId)
        history[idx].stage = .connecting
        history[idx].statusMessage = reuseSessionId.isEmpty ? "正在建立改图会话..." : "正在修改..."

        let runToken = UUID()
        runTokens[batchId] = runToken
        let port = sidecar.serverPort
        genTasks[batchId] = Task { [weak self] in
            do {
                try await GeminiSSEClient.shared.editImage(
                    sourceImagePath: sourcePath,
                    instruction: instruction,
                    sessionId: reuseSessionId,
                    aspectRatio: aspect,
                    // 画风上下文与文生图保持一致：下发完整风格描述（contextSuffix）。
                    styleContext: styleSuffix,
                    negativePrompt: negative,
                    maxKb: 0,
                    taskId: batchId.uuidString,
                    port: port
                ) { [weak self] chunk in
                    Task { @MainActor in
                        guard let self, runToken == self.runTokens[batchId] else { return }
                        guard let i = self.history.firstIndex(where: { $0.id == batchId }) else { return }
                        if let st = GenerationStage(rawValue: chunk.stage) {
                            self.history[i].stage = st
                        }
                        self.history[i].statusMessage = chunk.message
                        if let sid = chunk.sessionId, !sid.isEmpty {
                            self.history[i].sessionId = sid
                        }
                        if let files = chunk.files, !files.isEmpty {
                            self.history[i].imagePaths.append(contentsOf: files)
                            // 记录本轮改图指令，供「稿次条」与「信息」弹窗回看。
                            // 一次改图可能返回多张候选，它们属于同一轮次（共享 roundIndex），
                            // 否则会被误标成「改 1 / 改 2 / 改 3…」。
                            var turns = self.history[i].editTurns ?? []
                            let nextRound = turns.enumerated()
                                .map { (offset, turn) in turn.roundIndex ?? offset }
                                .max()
                                .map { $0 + 1 } ?? 0
                            let now = Date()
                            for f in files {
                                turns.append(EditTurn(
                                    instruction: instruction,
                                    imagePath: f,
                                    createdAt: now,
                                    aspectRatio: aspect,
                                    style: styleRaw,
                                    negativePrompt: negative,
                                    roundIndex: nextRound
                                ))
                            }
                            self.history[i].editTurns = turns
                            self.history[i].stage = .completed
                            self.history[i].statusMessage = "修改完成"
                            // selectedImageIndex 是画布全局态：只有用户还停在这条记录上才跳到最新稿。
                            if self.selectedBatchId == batchId {
                                self.selectedImageIndex = self.history[i].imagePaths.count - 1
                            }
                            HistoryStore.shared.append(self.history[i])
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run { [weak self] in
                        self?.markBatchError(batchId: batchId, message: "改图请求异常: \(error.localizedDescription)")
                    }
                }
            }
            await MainActor.run { [weak self] in
                self?.generatingBatchIds.remove(batchId)
                self?.genTasks[batchId] = nil
                self?.runTokens[batchId] = nil
            }
        }
    }

    // MARK: - 键盘
    public func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // 正在文本输入（提示词/负面词等）时，除 ⌘ 组合键外一律放行，绝不劫持空格与方向键。
            // NSTextView（TextView 编辑器）与 NSTextField（单行输入框）都要排除。
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            // 非文本编辑态：⌘V 且剪贴板含图片时，作为参考图导入（拦截默认粘贴）
            if event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.control),
               event.charactersIgnoringModifiers?.lowercased() == "v",
               ReferenceImageImporter.pasteboardContainsImage {
                self.pasteReferenceImageFromClipboard()
                return nil
            }
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                return event
            }

            switch event.keyCode {
            case 123: // ←
                self.stepImage(-1)
                return nil
            case 124: // →
                self.stepImage(+1)
                return nil
            case 49: // Space
                if let path = self.activeImagePathForAI {
                    ImageQuickLookController.shared.present(path: path)
                    return nil
                }
                return event
            default:
                break
            }

            if event.charactersIgnoringModifiers?.lowercased() == "i" {
                withAnimation(.easeInOut(duration: 0.15)) {
                    self.showMetadata.toggle()
                }
                return nil
            }

            return event
        }
    }

    /// 在当前批次内切换图片（到边界即停）
    public func stepImage(_ delta: Int) {
        guard let batch = selectedBatch, batch.imagePaths.count > 1 else { return }
        let next = min(max(selectedImageIndex + delta, 0), batch.imagePaths.count - 1)
        guard next != selectedImageIndex else { return }
        withAnimation(.spring(duration: 0.2)) {
            selectedImageIndex = next
        }
    }

    public func toggleMetadata() {
        withAnimation(.easeInOut(duration: 0.15)) {
            showMetadata.toggle()
        }
    }

    public func toggleSidebar() {
        withAnimation(.spring(duration: 0.3)) {
            isSidebarVisible.toggle()
        }
    }

    // MARK: - 参考图：拖入 / 粘贴导入

    /// 拖入导入：从 NSItemProvider 数组解析图片，成功设为参考图（取第一张）。
    /// 支持 Finder 文件 URL（png/jpg/jpeg/heic/tiff/bmp/gif/webp）与其他 App 直接拖入的图像数据。
    public func importReferenceImage(from providers: [NSItemProvider]) {
        let provider = providers.first {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            || $0.canLoadObject(ofClass: NSImage.self)
        }
        guard let provider else { return }
        Task {
            let path = await ReferenceImageImporter.importFrom(provider)
            if let path {
                await MainActor.run {
                    referenceImagePath = path
                }
            }
        }
    }

    /// ⌘V 粘贴：剪贴板有图片文件或图像数据时设为参考图（文本编辑态由调用方先排除）。
    public func pasteReferenceImageFromClipboard() {
        let pb = NSPasteboard.general

        // 1. 优先文件 URL（Finder 复制的图片）
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first(where: { ReferenceImageImporter.isSupportedImage($0) }) {
            referenceImagePath = url.path
            return
        }

        // 2. 裸图像数据（截图、浏览器复制图片等）
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first,
           let path = ReferenceImageImporter.savePastedImage(image) {
            referenceImagePath = path
        }
    }

    // MARK: - AI 图像描述
    public func describeImage(path: String, force: Bool = false) {
        aiLog("describeImage called: path=\(URL(fileURLWithPath: path).lastPathComponent) force=\(force)")
        // 记录「本次描述对象」：缓存命中也要更新——弹窗内的「重新生成」/防御分支
        // 都以它为准，否则重新生成会用主图路径覆盖掉刚描述的参考图
        pendingDescribePath = path
        let batchCached = selectedBatch?.aiDescriptions?[path]
        if !force, let cached = batchCached ?? AIAnalysisStore.cachedDescription(for: path) {
            aiLog("cache HIT (batch=\(batchCached != nil)) len=\(cached.count)")
            isDescribingImage = false
            imageDescription = cached
            showDescriptionSheet = true
            return
        }

        aiLog("cache MISS, requesting from AI...")
        let runToken = UUID()
        describeRunToken = runToken
        isDescribingImage = true
        imageDescription = ""   // 空串 = 流已开始但还没有内容；nil 会让 UI 误判为「未开始」
        showDescriptionSheet = true

        let styleRaw = selectedStyle.rawValue
        let apiKey = useCustomAI ? customApiKey : ""
        let baseURL = useCustomAI ? customBaseUrl : ""
        let visionModel = useCustomAI ? customVisionModel : ""
        let port = sidecar.serverPort

        Task { [weak self] in
            do {
                // 流式：每来一块就把增量追加进弹窗，模型出第一个字就能看见
                let desc = try await GeminiSSEClient.shared.describeImageStream(
                    imagePath: path,
                    style: styleRaw,
                    customApiKey: apiKey,
                    customBaseUrl: baseURL,
                    customVisionModel: visionModel,
                    port: port
                ) { [weak self] delta in
                    Task { @MainActor in
                        guard let self,
                              self.describeRunToken == runToken,
                              self.pendingDescribePath == path else { return }
                        self.imageDescription = (self.imageDescription ?? "") + delta
                    }
                }
                await MainActor.run {
                    guard let self, self.describeRunToken == runToken,
                          self.pendingDescribePath == path else {
                        self?.aiLog("response STALE (requested \(URL(fileURLWithPath: path).lastPathComponent)), dropped")
                        return
                    }
                    self.aiLog("response OK len=\(desc.count)")
                    self.isDescribingImage = false
                    self.imageDescription = desc
                    self.saveDescriptionToStores(desc, for: path)
                }
            } catch {
                await MainActor.run {
                    guard let self, self.describeRunToken == runToken,
                          self.pendingDescribePath == path else { return }
                    self.aiLog("response FAILED: \(error.localizedDescription)")
                    self.isDescribingImage = false
                    self.imageDescription = "描述失败: \(error.localizedDescription)"
                }
            }
        }
    }

    /// 描述弹窗标题：显示当前描述对象，消除「描述的是哪张图」的歧义
    public var describeTargetTitle: String {
        guard let p = pendingDescribePath else { return "AI 图像描述" }
        return p == referenceImagePath ? "AI 图像描述 · 参考图" : "AI 图像描述 · 当前画面"
    }

    /// 从描述文本中解析【生图提示词】部分（markdown 渲染后的正文太长，单独提取方便复用）
    public var extractedGenerationPrompt: String? {
        guard let desc = imageDescription else { return nil }
        guard let range = desc.range(of: "【生图提示词】") else { return nil }
        let promptText = desc[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return promptText.isEmpty ? nil : String(promptText)
    }

    public func copyGenerationPrompt(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        promptCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.promptCopied = false
        }
    }

    /// 统一日志出口（Console.app 按 subsystem 过滤）
    public func aiLog(_ message: String) {
        #if DEBUG
        print("[AI-DESC] \(message)")
        #endif
        Logger(subsystem: "com.tienyeung.prism", category: "ai-desc").info("\(message, privacy: .public)")
    }

    /// 描述双写：随批次持久化（重启必恢复）+ 独立文件（跨批次共享同一文件路径时兜底）
    private func saveDescriptionToStores(_ desc: String, for path: String) {
        AIAnalysisStore.saveDescription(desc, for: path)

        guard let id = selectedBatchId,
              let idx = history.firstIndex(where: { $0.id == id }) else { return }
        if history[idx].aiDescriptions == nil {
            history[idx].aiDescriptions = [:]
        }
        history[idx].aiDescriptions?[path] = desc
        HistoryStore.shared.save(history)
    }
}

// MARK: - 参考图导入（拖入 / 粘贴）
/// 从 NSItemProvider 或剪贴板解析图片：
/// - Finder 文件 URL：直接引用原路径（不复制，参考图本就不随产物移动）；
/// - 其他 App 拖入 / 粘贴的裸图像：转 PNG 落盘到 `~/Pictures/Prism/references/`。
enum ReferenceImageImporter {
    /// 允许作为参考图的扩展名（与参考图选择面板口径一致）
    static let supportedExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "tif", "tiff", "bmp", "gif", "webp"
    ]

    static func isSupportedImage(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// 剪贴板当前是否含图片（文件 URL 或图像数据）
    static var pasteboardContainsImage: Bool {
        let pb = NSPasteboard.general
        if pb.canReadItem(withDataConformingToTypes: [UTType.fileURL.identifier]),
           let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           urls.contains(where: isSupportedImage) {
            return true
        }
        return pb.canReadItem(withDataConformingToTypes: [UTType.image.identifier, UTType.png.identifier])
    }

    /// 从拖入的 NSItemProvider 解析本地图片路径（全异步，不阻塞主线程）
    static func importFrom(_ provider: NSItemProvider) async -> String? {
        // 1. 文件 URL（Finder 拖入）
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await loadFileURL(provider), isSupportedImage(url) {
                return url.path
            }
        }

        // 2. 裸图像数据（其他 App 直接拖图片）
        if provider.canLoadObject(ofClass: NSImage.self),
           let image = await loadImage(provider) {
            return savePastedImage(image)
        }
        return nil
    }

    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                cont.resume(returning: object as? URL)
            }
        }
    }

    private static func loadImage(_ provider: NSItemProvider) async -> NSImage? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: NSImage.self) { object, _ in
                cont.resume(returning: object as? NSImage)
            }
        }
    }

    /// 把裸图像数据写为 PNG，返回落盘路径
    @discardableResult
    static func savePastedImage(_ image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/Prism/references")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let url = dir.appendingPathComponent("pasted_\(Int(Date().timeIntervalSince1970))_\(Int.random(in: 0...9999)).png")
        do {
            try png.write(to: url)
            return url.path
        } catch {
            return nil
        }
    }
}

// MARK: - 菜单命令桥接
/// 菜单（SwiftUI Commands）与 ViewModel 之间的动作包。
/// Commands 拿不到 View 里的 @State 对象，通过 FocusedValues 注入。
@MainActor
@Observable
public final class PrismMenuActions {
    public init() {}
    public var startGeneration: () -> Void = {}
    public var focusPrompt: () -> Void = {}
    public var toggleMetadata: () -> Void = {}
    public var toggleSidebar: () -> Void = {}
    public var quickLook: () -> Void = {}
}

// 注：不用 @Entry 宏——本机 CLT 工具链缺 SwiftUIMacros 插件（AGENTS.md 已记录的 SDK 约束），
// 回退到显式 FocusedValueKey 写法，行为等价。
public extension FocusedValues {
    struct PrismMenuActionsKey: FocusedValueKey {
        public typealias Value = PrismMenuActions
    }

    var prismMenuActions: PrismMenuActions? {
        get { self[PrismMenuActionsKey.self] }
        set { self[PrismMenuActionsKey.self] = newValue }
    }
}
