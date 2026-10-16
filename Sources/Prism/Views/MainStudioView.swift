import SwiftUI
import AppKit
import QuickLookUI
import os

public struct MainStudioView: View {
    @State private var sidecar = SidecarManager.shared

    // 界面折叠状态 (默认收起历史面板，营造通透画布)
    @State private var isSidebarVisible: Bool = false

    // 参数面板状态 (默认新画布，清空输入)
    @State private var prompt: String = ""
    @State private var negativePrompt: String = ""
    @State private var selectedAspect: AspectRatioOption = .landscape
    @State private var selectedStyle: ArtStyleOption = .none

    // 运行状态
    @State private var isGenerating: Bool = false
    @State private var currentStage: GenerationStage = .idle
    @State private var currentMessage: String = ""

    // 历史与画廊
    @State private var history: [GenerationBatch] = []
    @State private var selectedBatchId: UUID?
    @State private var selectedImageIndex: Int = 0

    // 凭据登录与偏好设置弹窗
    @State private var showAuthSheet: Bool = false
    @State private var showPreferencesSheet: Bool = false
    @State private var currentGenTask: Task<Void, Never>? = nil

    // 多模态 AI 状态
    @State private var referenceImagePath: String? = nil
    @State private var isDescribingImage: Bool = false
    @State private var imageDescription: String? = nil
    @State private var showDescriptionSheet: Bool = false

    // 元数据弹窗与键盘事件监听
    @State private var showMetadata: Bool = false
    @State private var keyMonitor: Any? = nil

    // 参数栏输入上下文令牌：切换历史记录 / 新建画布时刷新（用于清空撤回栈）
    @State private var inspectorContextToken: UUID = UUID()

    // 当前正在执行的生成 / 改图所属的记录 ID（让按钮区随选中记录独立呈现，而非全局状态）
    @State private var generatingBatchId: UUID? = nil

    // AI 配置（来自偏好设置）
    @AppStorage("pref_use_custom_ai") private var useCustomAI: Bool = false
    @AppStorage("pref_custom_api_key") private var customApiKey: String = ""
    @AppStorage("pref_custom_base_url") private var customBaseUrl: String = ""
    @AppStorage("pref_custom_model") private var customModel: String = "gemini-1.5-flash"

    public init() {}

    private var selectedBatch: GenerationBatch? {
        guard let id = selectedBatchId else { return nil }
        return history.first(where: { $0.id == id })
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // 1. 左侧历史面板 (支持折叠)
            if isSidebarVisible {
                historySidebarView
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // 2. 中间纯粹作品画廊展台
            StudioGalleryView(
                currentBatch: selectedBatch,
                selectedImageIndex: $selectedImageIndex,
                isGenerating: isGenerating,
                currentStage: currentStage,
                currentMessage: currentMessage,
                isSidebarHidden: !isSidebarVisible,
                showMetadata: $showMetadata,
                onToggleSidebar: {
                    withAnimation(.spring(duration: 0.3)) {
                        isSidebarVisible.toggle()
                    }
                },
                onNewCanvas: {
                    createNewCanvas()
                },
                onDeleteBatch: { id in
                    deleteBatch(id: id)
                },
                onStopGeneration: {
                    stopGeneration()
                },
                onDescribeImage: { path in
                    describeImage(path: path)
                }
            )
            .frame(maxHeight: .infinity)

            // 3. 右侧参数配置栏 (包含 AI 润色、参考图生图、停止生成与偏好设置)
            PromptInspectorView(
                prompt: $prompt,
                negativePrompt: $negativePrompt,
                selectedAspect: $selectedAspect,
                selectedStyle: $selectedStyle,
                referenceImagePath: $referenceImagePath,
                hasAuth: sidecar.hasAuth,
                onOpenAuth: {
                    showAuthSheet = true
                },
                onOpenPreferences: {
                    showPreferencesSheet = true
                },
                isActingOnSelection: isActingOnSelection,
                hasSelection: selectedBatch != nil,
                currentStage: currentStage,
                currentMessage: currentMessage,
                onGenerate: {
                    startGeneration()
                },
                onStopGeneration: {
                    stopGeneration()
                },
                canContinueEditing: canContinueEditing,
                onContinueEditing: {
                    continueEditing()
                },
                onDescribeReference: { path in
                    describeImage(path: path)
                },
                contextToken: inspectorContextToken,
                busyElsewhereHint: busyElsewhereHint,
                onViewBusyBatch: {
                    if let id = generatingBatchId, let b = history.first(where: { $0.id == id }) {
                        selectBatch(b)
                    }
                }
            )
            .frame(maxHeight: .infinity)
        }
        .padding([.horizontal, .bottom], 10)
        .padding(.top, 6) // 系统 safeArea 已自然避让红绿灯，极小间距实现极致紧凑
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        // App 标题：标题栏行（红绿灯那一行）水平居中
        .overlay(alignment: .top) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("Prism")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .padding(.top, -21) // 从安全区顶部上移至标题栏行，与红绿灯齐平
            .allowsHitTesting(false)
        }
        .sheet(isPresented: $showAuthSheet) {
            WebKitLoginView()
        }
        .sheet(isPresented: $showPreferencesSheet) {
            PreferencesView()
        }
        .sheet(isPresented: $showDescriptionSheet) {
            descriptionSheetView
        }
        .task {
            await sidecar.startIfNeeded()
            await loadExistingImages()
            installKeyMonitor()
        }
        // 切换批次/画布时：参考图跟随该批次（有参考图显示之，无则空），同时刷新上下文令牌清空撤回栈
        .onChange(of: selectedBatchId) { _, _ in
            referenceImagePath = selectedBatch?.referenceImagePath
            inspectorContextToken = UUID()
        }
        // 手动移除参考图（×）时：同步回当前批次并持久化
        .onChange(of: referenceImagePath) { _, newValue in
            syncReferenceImageToBatch(newValue)
        }
    }

    // MARK: - 参考图与批次同步
    private func syncReferenceImageToBatch(_ path: String?) {
        guard let id = selectedBatchId,
              let idx = history.firstIndex(where: { $0.id == id }),
              history[idx].referenceImagePath != path else { return }
        history[idx].referenceImagePath = path
        HistoryStore.shared.save(history)
    }

    // MARK: - AI 图像描述 Sheet（macOS 原生弹窗）
    private var descriptionSheetView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack(spacing: 8) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("AI 图像描述")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    showDescriptionSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider().opacity(0.15)

            // 内容区（支持 Markdown 内联渲染：粗体/斜体/代码）
            if isDescribingImage {
                ZStack {
                    VStack(spacing: 14) {
                        HaloSpinnerView(size: 40, lineWidth: 4)
                        Text("AI 正在描述图像...")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let desc = imageDescription {
                ScrollView {
                    markdownText(desc)
                        .font(.system(size: 13))
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            } else {
                // 防御分支：状态意外落入"无内容且未加载"时自动发起加载（走缓存逻辑，命中即秒开）
                VStack(spacing: 14) {
                    HaloSpinnerView(size: 40, lineWidth: 4)
                    Text("正在加载描述...")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    aiLog("sheet hit defensive branch, auto-recovering")
                    if let path = activeImagePathForAI {
                        describeImage(path: path, force: false)
                    }
                }
            }

            Divider().opacity(0.15)

            // 底部操作区
            HStack(spacing: 10) {
                if let promptText = extractedGenerationPrompt, !promptText.isEmpty {
                    Button {
                        copyGenerationPrompt(promptText)
                    } label: {
                        Label(promptCopied ? "已复制" : "复制提示词", systemImage: promptCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .controlSize(.regular)
                    .disabled(promptCopied)
                }

                Button {
                    if let path = activeImagePathForAI {
                        describeImage(path: path, force: true)
                    }
                } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .controlSize(.regular)
                .disabled(isDescribingImage)

                Spacer()

                Button {
                    showDescriptionSheet = false
                } label: {
                    Text("完成")
                        .font(.system(size: 12, weight: .medium))
                        .frame(minWidth: 52)
                }
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 480)
    }

    /// 从描述文本中解析【生图提示词】部分（markdown 渲染后的正文太长，单独提取方便复用）
    private var extractedGenerationPrompt: String? {
        guard let desc = imageDescription else { return nil }
        guard let range = desc.range(of: "【生图提示词】") else { return nil }
        let prompt = desc[range.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : String(prompt)
    }

    /// Markdown 内联渲染（粗体/斜体/行内代码），解析失败回退纯文本
    private func markdownText(_ raw: String) -> Text {
        if let attributed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnly
            )
        ) {
            return Text(attributed)
        }
        return Text(raw)
    }

    @State private var promptCopied: Bool = false

    private func copyGenerationPrompt(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        promptCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            promptCopied = false
        }
    }


    /// 供 AI 弹窗"重新生成"时定位当前展示的图片路径
    private var activeImagePathForAI: String? {
        guard let id = selectedBatchId else { return nil }
        guard let batch = history.first(where: { $0.id == id }), !batch.imagePaths.isEmpty else { return nil }
        return batch.imagePaths.indices.contains(selectedImageIndex)
            ? batch.imagePaths[selectedImageIndex]
            : batch.imagePaths.first
    }

    // MARK: - 左侧历史列表
    private var historySidebarView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("历史批次", systemImage: "clock.arrow.circlepath")
                    .font(.headline)

                if !history.isEmpty {
                    Text("\(history.count) 组")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // 新建画布按钮 (图标)
                Button {
                    createNewCanvas()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .padding(5)
                }
                .buttonStyle(.plain)
                .liquidGlassCard(cornerRadius: DesignMetrics.radiusS)
                .help("新建画布并重置提示词")

                // 折叠历史按钮作为一个 icon 放在历史区卡片
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        isSidebarVisible = false
                    }
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(5)
                }
                .buttonStyle(.plain)
                .liquidGlassCard(cornerRadius: DesignMetrics.radiusS)
                .help("折叠历史面板")
            }

            if history.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("暂无生成历史")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("在右侧输入描述并点击开始生图")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(history) { batch in
                            HistoryItemRow(
                                batch: batch,
                                isSelected: selectedBatch?.id == batch.id,
                                onSelect: {
                                    selectBatch(batch)
                                },
                                onDelete: {
                                    deleteBatch(id: batch.id)
                                },
                                onReuse: {
                                    selectBatch(batch)
                                }
                            )
                        }
                    }
                }
            }
        }
        .padding()
        .frame(width: 240)
        .frame(maxHeight: .infinity)
        .liquidGlassBackground(cornerRadius: DesignMetrics.radiusL)
    }

    /// 启动时预热缩略图缓存：批量加载磁盘缩略图（~20KB/张）到内存
    private func preloadThumbnails() async {
        let paths = history.flatMap { $0.imagePaths }
        guard !paths.isEmpty else { return }
        await ThumbnailGenerator.shared.preloadThumbnails(for: paths)
    }

    private func createNewCanvas() {
        // 如果正在生成，弹出确认对话框
        if isGenerating {
            let alert = NSAlert()
            alert.messageText = "正在生成图片"
            alert.informativeText = "当前有图片正在生成中，新建画布不会取消后台任务。是否继续？"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                return
            }
        }

        withAnimation(.spring(duration: 0.25)) {
            selectedBatchId = nil
            selectedImageIndex = 0
            prompt = ""
            negativePrompt = ""
            selectedStyle = .none
            inspectorContextToken = UUID()
        }
    }

    private func selectBatch(_ batch: GenerationBatch) {
        withAnimation(.spring(duration: 0.2)) {
            selectedBatchId = batch.id
            selectedImageIndex = 0
            self.prompt = batch.prompt
            self.negativePrompt = batch.negativePrompt
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

    private func deleteBatch(id: UUID) {
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
        let moveToTrash = (response == .alertFirstButtonReturn)

        HistoryStore.removeAssets(for: batch, moveImagesToTrash: moveToTrash)

        withAnimation(.spring(duration: 0.25)) {
            history.removeAll(where: { $0.id == id })
            HistoryStore.shared.save(history)
            if selectedBatchId == id {
                selectedBatchId = nil
                selectedImageIndex = 0
            }
        }
    }

    /// 当前选中的批次是否可继续改图（有图 + 有提示词输入）
    private var canContinueEditing: Bool {
        guard let batch = selectedBatch, !batch.imagePaths.isEmpty else { return false }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 选中记录自身正在生成 / 改图中（决定按钮区显示「停止生成」还是「开始生图」）
    private var isActingOnSelection: Bool {
        guard isGenerating, let id = generatingBatchId else { return false }
        return id == selectedBatchId
    }

    /// 任务正跑在「别的」记录上时的提示文案（非空则禁用开始生图 / 继续修改）
    private var busyElsewhereHint: String? {
        guard isGenerating, let id = generatingBatchId, id != selectedBatchId else { return nil }
        guard let batch = history.first(where: { $0.id == id }) else { return "另一条记录正在生成中" }
        let text = batch.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = text.count > 12 ? String(text.prefix(12)) + "…" : text
        return "「\(short)」正在生成中"
    }

    // MARK: - 多轮会话改图
    private func continueEditing() {
        guard !isGenerating else { return }   // 同一时刻只跑一个任务，避免按钮与状态错乱
        guard let batchId = selectedBatchId,
              let idx = history.firstIndex(where: { $0.id == batchId }),
              !history[idx].imagePaths.isEmpty else { return }

        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }

        let batch = history[idx]
        let sourcePath = batch.imagePaths.indices.contains(selectedImageIndex)
            ? batch.imagePaths[selectedImageIndex]
            : batch.imagePaths[0]

        isGenerating = true
        generatingBatchId = batchId
        currentStage = .connecting
        currentMessage = batch.sessionId == nil ? "正在建立改图会话..." : "正在修改..."

        currentGenTask = Task {
            do {
                try await GeminiSSEClient.shared.editImage(
                    sourceImagePath: sourcePath,
                    instruction: instruction,
                    sessionId: batch.sessionId ?? "",
                    aspectRatio: selectedAspect.rawValue,
                    styleContext: selectedStyle.rawValue,
                    negativePrompt: negativePrompt,
                    maxKb: 0,
                    port: sidecar.serverPort
                ) { chunk in
                    Task { @MainActor in
                        currentMessage = chunk.message
                        if let st = GenerationStage(rawValue: chunk.stage) {
                            currentStage = st
                        }
                        guard let i = history.firstIndex(where: { $0.id == batchId }) else { return }
                        if let st = GenerationStage(rawValue: chunk.stage) {
                            history[i].stage = st
                        }
                        history[i].statusMessage = chunk.message
                        if let sid = chunk.sessionId, !sid.isEmpty {
                            history[i].sessionId = sid
                        }
                        if let files = chunk.files, !files.isEmpty {
                            history[i].imagePaths.append(contentsOf: files)
                            // 记录本轮改图指令，供「稿次条」与「信息」弹窗回看
                            var turns = history[i].editTurns ?? []
                            let now = Date()
                            for f in files {
                                turns.append(EditTurn(
                                    instruction: instruction,
                                    imagePath: f,
                                    createdAt: now,
                                    aspectRatio: selectedAspect.rawValue,
                                    style: selectedStyle.rawValue,
                                    negativePrompt: negativePrompt
                                ))
                            }
                            history[i].editTurns = turns
                            history[i].stage = .completed
                            history[i].statusMessage = "修改完成"
                            selectedImageIndex = history[i].imagePaths.count - 1
                            HistoryStore.shared.append(history[i])
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        currentStage = .error
                        currentMessage = "改图请求异常: \(error.localizedDescription)"
                        if let i = history.firstIndex(where: { $0.id == batchId }) {
                            history[i].stage = .error
                            history[i].statusMessage = currentMessage
                        }
                    }
                }
            }
            await MainActor.run {
                isGenerating = false
                generatingBatchId = nil
                currentGenTask = nil
            }
        }
    }

    private func loadExistingImages() async {
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

        // 2. 无 history.json 时自动扫描本地目录兜底
        let picturesDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Prism")
        guard let files = try? FileManager.default.contentsOfDirectory(at: picturesDir, includingPropertiesForKeys: [.contentModificationDateKey], options: .skipsHiddenFiles) else { return }

        let pngFiles = files.filter { $0.pathExtension.lowercased() == "png" || $0.pathExtension.lowercased() == "jpg" }
            .sorted { (u1, u2) -> Bool in
                let d1 = (try? u1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                let d2 = (try? u2.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                return d1 > d2
            }

        guard !pngFiles.isEmpty else { return }
        var loaded: [GenerationBatch] = []
        for file in pngFiles {
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

    private func stopGeneration() {
        currentGenTask?.cancel()
        currentGenTask = nil
        Task {
            await GeminiSSEClient.shared.cancel(port: sidecar.serverPort)
        }
        withAnimation(.spring(duration: 0.25)) {
            isGenerating = false
            currentStage = .idle
            currentMessage = "已取消生成"
            // 中断批次状态回落（避免侧栏一直停在「生成中」）；尚无产图的批次直接清理
            if let id = generatingBatchId, let i = history.firstIndex(where: { $0.id == id }) {
                if history[i].imagePaths.isEmpty {
                    history.removeAll(where: { $0.id == id })
                    selectedBatchId = history.first?.id
                } else {
                    history[i].stage = .completed
                    history[i].statusMessage = "已取消生成"
                    HistoryStore.shared.append(history[i])
                }
            }
            generatingBatchId = nil
        }
    }

    private func startGeneration() {
        guard !isGenerating else { return }   // 同一时刻只跑一个任务，避免按钮与状态错乱
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        isGenerating = true
        currentStage = .connecting
        currentMessage = "正在建立 Google Gemini 会话..."

        let newBatchId = UUID()
        let newBatch = GenerationBatch(
            id: newBatchId,
            prompt: prompt,
            negativePrompt: negativePrompt,
            aspectRatio: selectedAspect.rawValue,
            style: selectedStyle.rawValue,
            stage: .connecting,
            statusMessage: "连接中",
            referenceImagePath: referenceImagePath
        )
        history.insert(newBatch, at: 0)
        selectedBatchId = newBatchId
        generatingBatchId = newBatchId
        selectedImageIndex = 0

        currentGenTask = Task {
            do {
                let hasReference = referenceImagePath != nil
                if hasReference, let refPath = referenceImagePath {
                    try await GeminiSSEClient.shared.generateWithImage(
                        imagePath: refPath,
                        prompt: prompt,
                        aspectRatio: selectedAspect.rawValue,
                        styleContext: selectedStyle.rawValue,
                        negativePrompt: negativePrompt,
                        maxKb: 0,
                        port: sidecar.serverPort
                    ) { chunk in
                        Task { @MainActor in
                            currentMessage = chunk.message
                            if let st = GenerationStage(rawValue: chunk.stage) {
                                currentStage = st
                            }
                            if let idx = history.firstIndex(where: { $0.id == newBatchId }) {
                                if let st = GenerationStage(rawValue: chunk.stage) {
                                    history[idx].stage = st
                                }
                                history[idx].statusMessage = chunk.message
                                if let files = chunk.files, !files.isEmpty {
                                    history[idx].imagePaths = files
                                    history[idx].stage = .completed
                                    history[idx].statusMessage = "生成完成"
                                    HistoryStore.shared.append(history[idx])
                                }
                            }
                        }
                    }
                } else {
                    try await GeminiSSEClient.shared.generate(
                        prompt: prompt,
                        aspectRatio: selectedAspect.rawValue,
                        negativePrompt: negativePrompt,
                        styleContext: selectedStyle.contextSuffix,
                        maxKb: 0,
                        port: sidecar.serverPort
                    ) { chunk in
                        Task { @MainActor in
                            currentMessage = chunk.message
                            if let st = GenerationStage(rawValue: chunk.stage) {
                                currentStage = st
                            }
                            if let idx = history.firstIndex(where: { $0.id == newBatchId }) {
                                if let st = GenerationStage(rawValue: chunk.stage) {
                                    history[idx].stage = st
                                }
                                history[idx].statusMessage = chunk.message
                                if let files = chunk.files, !files.isEmpty {
                                    history[idx].imagePaths = files
                                    history[idx].stage = .completed
                                    history[idx].statusMessage = "生成完成"
                                    HistoryStore.shared.append(history[idx])
                                }
                            }
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        currentStage = .error
                        currentMessage = "生图请求异常: \(error.localizedDescription)"
                        if let idx = history.firstIndex(where: { $0.id == newBatchId }) {
                            history[idx].stage = .error
                            history[idx].statusMessage = currentMessage
                        }
                    }
                }
            }
            await MainActor.run {
                isGenerating = false
                generatingBatchId = nil
                currentGenTask = nil
            }
        }
    }

    // MARK: - 键盘流（←/→ 切换图片 · 空格 Quick Look · I 元数据浮层）
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 正在文本输入（提示词/负面词等）时，除 ⌘ 组合键外一律放行，绝不劫持空格与方向键
            if let responder = NSApp.keyWindow?.firstResponder, responder is NSTextView {
                return event
            }
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                return event
            }

            switch event.keyCode {
            case 123: // ←
                stepImage(-1)
                return nil
            case 124: // →
                stepImage(+1)
                return nil
            case 49: // Space
                if let path = activeImagePathForAI {
                    ImageQuickLookController.shared.present(path: path)
                    return nil
                }
                return event
            default:
                break
            }

            if event.charactersIgnoringModifiers?.lowercased() == "i" {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showMetadata.toggle()
                }
                return nil
            }

            return event
        }
    }

    /// 在当前批次内切换图片（到边界即停）
    private func stepImage(_ delta: Int) {
        guard let batch = selectedBatch, batch.imagePaths.count > 1 else { return }
        let next = min(max(selectedImageIndex + delta, 0), batch.imagePaths.count - 1)
        guard next != selectedImageIndex else { return }
        withAnimation(.spring(duration: 0.2)) {
            selectedImageIndex = next
        }
    }

    // MARK: - AI 功能：图像描述（批次级缓存优先，独立文件兜底；仅弹窗内点"重新生成"才重新请求）
    /// 当前描述请求对应的图片路径，用于丢弃过期响应（防止旧请求覆盖新内容）
    @State private var pendingDescribePath: String? = nil

    private func describeImage(path: String, force: Bool = false) {
        aiLog("describeImage called: path=\(URL(fileURLWithPath: path).lastPathComponent) force=\(force)")
        let batchCached = selectedBatch?.aiDescriptions?[path]
        if !force, let cached = batchCached ?? AIAnalysisStore.cachedDescription(for: path) {
            aiLog("cache HIT (batch=\(batchCached != nil)) len=\(cached.count)")
            isDescribingImage = false
            imageDescription = cached
            showDescriptionSheet = true
            return
        }

        aiLog("cache MISS, requesting from AI...")
        pendingDescribePath = path
        isDescribingImage = true
        imageDescription = nil
        showDescriptionSheet = true

        Task {
            do {
                let desc = try await GeminiSSEClient.shared.describeImage(
                    imagePath: path,
                    style: selectedStyle.rawValue,
                    customApiKey: useCustomAI ? customApiKey : "",
                    customBaseUrl: useCustomAI ? customBaseUrl : "",
                    customModel: useCustomAI ? customModel : "",
                    port: sidecar.serverPort
                )
                await MainActor.run {
                    guard pendingDescribePath == path else {
                        aiLog("response STALE (requested \(URL(fileURLWithPath: path).lastPathComponent)), dropped")
                        return
                    }
                    aiLog("response OK len=\(desc.count)")
                    isDescribingImage = false
                    imageDescription = desc
                    saveDescriptionToStores(desc, for: path)
                }
            } catch {
                await MainActor.run {
                    guard pendingDescribePath == path else { return }
                    aiLog("response FAILED: \(error.localizedDescription)")
                    isDescribingImage = false
                    imageDescription = "描述失败: \(error.localizedDescription)"
                }
            }
        }
    }

    /// 统一日志出口（Console.app 按 subsystem 过滤）
    private func aiLog(_ message: String) {
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

// MARK: - 独立历史记录行组件 (支持优雅 Hover 浮现删除按键与生成中状态)
struct HistoryItemRow: View {
    let batch: GenerationBatch
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onReuse: () -> Void

    @State private var isHovered: Bool = false
    @State private var thumbnailImage: NSImage? = nil

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(spacing: 8) {
                if let firstPath = batch.imagePaths.first {
                    if let img = thumbnailImage {
                        Image(nsImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusS))
                    } else {
                        RoundedRectangle(cornerRadius: DesignMetrics.radiusS)
                            .fill(Color.secondary.opacity(0.1))
                            .frame(width: 44, height: 44)
                            .overlay(
                                ProgressView()
                                    .controlSize(.mini)
                            )
                            .task {
                                // 优先从内存/磁盘缓存读取（磁盘缓存仅 ~20KB，几乎瞬时）
                                // 无缓存时后台生成，不阻塞主线程
                                thumbnailImage = await ThumbnailGenerator.shared.loadThumbnail(for: firstPath)
                            }
                    }
                } else {
                    RoundedRectangle(cornerRadius: DesignMetrics.radiusS)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Group {
                                if batch.stage != .completed && batch.stage != .idle && batch.stage != .error {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "photo")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        )
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(batch.prompt)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack {
                        if batch.stage != .completed && batch.stage != .idle && batch.stage != .error {
                            Text(batch.statusMessage.isEmpty ? batch.stage.localizedText : batch.statusMessage)
                                .font(.system(size: 9))
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)
                        } else {
                            Text(batch.aspectRatio)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)

                            if batch.imagePaths.count > 1 {
                                Text("\(batch.imagePaths.count) 稿")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.accentColor.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                        Spacer()
                        Text(formattedDate(batch.createdAt))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }

                if isHovered {
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.red.opacity(0.9))
                            .padding(5)
                            .background(Color(NSColor.windowBackgroundColor).opacity(0.9))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("删除此记录")
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignMetrics.radiusM)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : (isHovered ? Color.secondary.opacity(0.08) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            Button("复用提示词") { onReuse() }
            if let p = batch.imagePaths.first {
                Button("在访达中显示") {
                    NSWorkspace.shared.selectFile(p, inFileViewerRootedAtPath: "")
                }
            }
            Divider()
            Button("删除此条记录", role: .destructive) { onDelete() }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let cal = Calendar.current
        let formatter = DateFormatter()
        if cal.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(date) {
            formatter.dateFormat = "昨天 HH:mm"
        } else {
            formatter.dateFormat = "MM-dd HH:mm"
        }
        return formatter.string(from: date)
    }
}

// MARK: - Quick Look 预览（空格键唤起系统原生预览面板）
final class ImageQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = ImageQuickLookController()
    private var currentURL: URL?

    func present(path: String) {
        currentURL = URL(fileURLWithPath: path)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        currentURL as NSURL?
    }
}

