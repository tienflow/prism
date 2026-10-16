import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct StudioGalleryView: View {
    public var currentBatch: GenerationBatch?
    @Binding public var selectedImageIndex: Int
    public var isGenerating: Bool
    public var currentStage: GenerationStage
    public var currentMessage: String
    public var isSidebarHidden: Bool
    /// 元数据浮层显隐（由父视图持有，便于键盘流统一控制）
    @Binding public var showMetadata: Bool
    public var onToggleSidebar: (() -> Void)?
    public var onNewCanvas: () -> Void
    public var onDeleteBatch: ((UUID) -> Void)?
    public var onStopGeneration: (() -> Void)?
    public var onDescribeImage: ((String) -> Void)?

    @State private var scale: CGFloat = 1.0
    @State private var lastScaleValue: CGFloat = 1.0
    @State private var dragOffset: CGSize = .zero
    @State private var showCopiedAlert: Bool = false
    @State private var compressAlertMessage: String? = nil
    @State private var isCompressing: Bool = false
    @State private var imageRefreshID: UUID = UUID()
    @State private var showCompressPopover: Bool = false
    /// 稿次行「该稿信息」弹窗（提示词 / 本轮指令 / 生成参数，均可复制）
    @State private var showTurnParams: Bool = false
    /// 已复制字段的反馈标记（1.5s 后自动清除）
    @State private var copiedField: String? = nil
    /// 稿次条缩略图（显式持有，替代早先只写不读的刷新令牌 hack）
    @State private var pagerThumbs: [String: NSImage] = [:]

    public init(
        currentBatch: GenerationBatch?,
        selectedImageIndex: Binding<Int>,
        isGenerating: Bool = false,
        currentStage: GenerationStage = .idle,
        currentMessage: String = "",
        isSidebarHidden: Bool = false,
        showMetadata: Binding<Bool> = .constant(false),
        onToggleSidebar: (() -> Void)? = nil,
        onNewCanvas: @escaping () -> Void = {},
        onDeleteBatch: ((UUID) -> Void)? = nil,
        onStopGeneration: (() -> Void)? = nil,
        onDescribeImage: ((String) -> Void)? = nil
    ) {
        self.currentBatch = currentBatch
        self._selectedImageIndex = selectedImageIndex
        self.isGenerating = isGenerating
        self.currentStage = currentStage
        self.currentMessage = currentMessage
        self.isSidebarHidden = isSidebarHidden
        self._showMetadata = showMetadata
        self.onToggleSidebar = onToggleSidebar
        self.onNewCanvas = onNewCanvas
        self.onDeleteBatch = onDeleteBatch
        self.onStopGeneration = onStopGeneration
        self.onDescribeImage = onDescribeImage
    }

    private var activeImagePath: String? {
        guard let batch = currentBatch, !batch.imagePaths.isEmpty else { return nil }
        return batch.imagePaths.indices.contains(selectedImageIndex)
            ? batch.imagePaths[selectedImageIndex]
            : batch.imagePaths.first
    }

    public var body: some View {
        ZStack {
            if let batch = currentBatch {
                if !batch.imagePaths.isEmpty {
                    // 1. 选中批次已有画作：优先展示该历史作品（绝不被后台生图状态强行遮蔽）
                    galleryView(batch: batch)
                } else if batch.stage != .completed && batch.stage != .idle {
                    // 2. 选中的正好是生成中批次：展示其生成进度
                    generatingIndicatorView(
                        stage: batch.stage,
                        message: batch.statusMessage.isEmpty ? currentMessage : batch.statusMessage
                    )
                } else {
                    // 3. 空白或待机
                    standbyCanvasView
                }
            } else if isGenerating {
                // 4. 未选中特定批次但全局正在生图
                generatingIndicatorView(stage: currentStage, message: currentMessage)
            } else {
                // 5. 待机状态：艺术空画布
                standbyCanvasView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlassBackground(cornerRadius: DesignMetrics.radiusL)
        // 顶部统一条：左侧折叠按钮 + 尺寸信息 + 后台生图状态，右侧新建画布
        .overlay(alignment: .top) {
            HStack(spacing: 8) {
                if isSidebarHidden {
                    Button {
                        withAnimation(.spring(duration: 0.3)) {
                            onToggleSidebar?()
                        }
                    } label: {
                        Image(systemName: "sidebar.leading")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .liquidGlassCard(cornerRadius: DesignMetrics.radiusS)
                    .help("展开历史面板")
                }

                // 尺寸规格药丸 (与折叠按钮在同一个 HStack 内，杜绝重叠)
                if let path = activeImagePath, let info = getImageInfo(path: path) {
                    Text(info)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.8))
                        .clipShape(Capsule())
                }

                // 如果正在后台生图，而用户正切在历史批次上看老作品：
                // 这里既报进度、也是**后台任务的停止入口**（此时参数栏与画布中央都没有停止按钮）
                if isGenerating && (currentBatch?.imagePaths.isEmpty == false) {
                    Button {
                        onStopGeneration?()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.red.opacity(0.85))
                            Text(currentMessage.isEmpty ? "新图渲染中..." : currentMessage)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Capsule())
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.85))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("点击停止这条后台渲染")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                Spacer()

                // 新建画布按钮
                Button {
                    withAnimation(.spring(duration: 0.3)) {
                        onNewCanvas()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 11, weight: .semibold))
                        Text("新建画布")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)
            }
            .padding(10)
        }
    }

    // MARK: - 1. 待机状态：艺术呼吸画布
    private var standbyCanvasView: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.accentColor.opacity(0.18), Color.clear],
                            center: .center,
                            startRadius: 10,
                            endRadius: 100
                        )
                    )
                    .frame(width: 200, height: 200)

                Image(systemName: "photo.artframe")
                    .font(.system(size: 60, weight: .ultraLight))
                    .foregroundStyle(Color.secondary.opacity(0.6))
            }

            VStack(spacing: 8) {
                Text("创作画布已就绪")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("在右侧输入中文描述、选择心仪画风与比例后，点击「开始生图」\n生成的高清原图将自动呈现在此画布中并安全持久化")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }
        }
        .padding(40)
    }

    // MARK: - 2. 生成中呼吸状态
    private func generatingIndicatorView(stage: GenerationStage, message: String) -> some View {
        VStack(spacing: 28) {
            ZStack {
                // 旋转光环动画
                TimelineView(.animation) { timeline in
                    let elapsed = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: 3.0)
                    Circle()
                        .fill(
                            AngularGradient(
                                colors: [.blue, .purple, .pink, .blue],
                                center: .center
                            )
                        )
                        .frame(width: 150, height: 150)
                        .blur(radius: 30)
                        .opacity(0.6)
                        .rotationEffect(.degrees(elapsed / 3.0 * 360))
                }

                HaloSpinnerView(size: 56)
            }

            VStack(spacing: 10) {
                Text(stage.localizedText)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .id(stage)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))

                Text(message.isEmpty ? "Google Imagen 3 正在构建细节与光影..." : message)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .id(message)
                    .transition(.opacity)
            }
            .padding(.horizontal, 32)

            if let onStop = onStopGeneration {
                Button {
                    onStop()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 13, weight: .semibold))
                        Text("停止生成")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(Color.red.opacity(0.85))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .liquidGlassCard(cornerRadius: DesignMetrics.radiusS)
                .padding(.top, 6)
            }
        }
        .padding(56)
        .frame(minWidth: 480, minHeight: 440)
        .liquidGlassCard(cornerRadius: DesignMetrics.radiusL)
        .animation(.spring(duration: 0.4), value: stage)
    }

    // MARK: - 3. 作品画廊全屏检视
    @ViewBuilder
    private func galleryView(batch: GenerationBatch) -> some View {
        VStack(spacing: 10) {
            ZStack {
                if let activePath = activeImagePath {
                    GeometryReader { geo in
                        if let nsImage = ImageCache.shared.image(for: activePath) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFit()
                                .id(activePath)
                                .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusM))
                                .shadow(color: Color.black.opacity(0.12), radius: 16, x: 0, y: 8)
                                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                                .scaleEffect(scale)
                                .offset(dragOffset)
                                .gesture(
                                    MagnificationGesture()
                                        .onChanged { value in
                                            let delta = value / lastScaleValue
                                            lastScaleValue = value
                                            scale = min(max(scale * delta, 0.5), 5.0)
                                        }
                                        .onEnded { _ in
                                            lastScaleValue = 1.0
                                            if scale < 1.0 {
                                                withAnimation(.spring(duration: 0.3)) {
                                                    scale = 1.0
                                                    dragOffset = .zero
                                                }
                                            }
                                        }
                                )
                                .simultaneousGesture(
                                    DragGesture()
                                        .onChanged { value in
                                            if scale > 1.0 {
                                                dragOffset = value.translation
                                            }
                                        }
                                        .onEnded { _ in
                                            if scale <= 1.0 {
                                                withAnimation(.spring(duration: 0.3)) {
                                                    dragOffset = .zero
                                                }
                                            }
                                        }
                                )
                                .onTapGesture(count: 2) {
                                    withAnimation(.spring(duration: 0.3)) {
                                        if scale > 1.0 {
                                            scale = 1.0
                                            dragOffset = .zero
                                        } else {
                                            scale = 2.0
                                        }
                                    }
                                }
                                .transition(.asymmetric(
                                    insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)
                                ))
                        } else {
                            VStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.orange)
                                Text("图片读取失败")
                                    .font(.headline)
                                Text(activePath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                    .padding(.top, 40)
                    .padding(.bottom, 56) // 预留底部浮动工具栏呼吸空间
                    .padding(.horizontal, 16)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 32))
                            .foregroundStyle(.orange)
                        Text("图片读取失败")
                            .font(.headline)
                        Text(activeImagePath ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }

                // 稿次左右切换（鼠标直接切稿，不依赖键盘焦点；仅多稿时出现）
                if batch.imagePaths.count > 1, activeImagePath != nil {
                    HStack {
                        pagerButton(icon: "chevron.left", help: "上一稿（←）", enabled: selectedImageIndex > 0) {
                            goToTurn(selectedImageIndex - 1)
                        }
                        Spacer()
                        pagerButton(icon: "chevron.right", help: "下一稿（→）", enabled: selectedImageIndex < batch.imagePaths.count - 1) {
                            goToTurn(selectedImageIndex + 1)
                        }
                    }
                    .padding(.horizontal, 14)
                }

                // 底部悬浮轻量化工具栏 (胶囊与内部按钮 100% 统一圆角)
                VStack {
                    Spacer()

                    HStack(spacing: 4) {
                        // 1. 信息（看懂组：画面元数据弹窗，贴近工具栏展开）
                        ToolbarCapsuleButton(
                            icon: showMetadata ? "info.circle.fill" : "info.circle",
                            title: "信息",
                            tint: showMetadata ? Color.accentColor : Color.primary
                        ) {
                            showMetadata.toggle()
                        }
                        .help("查看画面元数据（快捷键 I）")
                        .popover(isPresented: $showMetadata, arrowEdge: .top) {
                            metadataPopover(batch: batch)
                        }

                        // 2. AI 描述（看懂组：AI 解读**画布主图**；参考图另有独立入口，不混用）
                        if let describe = onDescribeImage, let p = activeImagePath {
                            ToolbarCapsuleButton(
                                icon: "text.book.closed",
                                title: "AI 描述",
                                tint: Color.primary
                            ) {
                                describe(p)
                            }
                            .help("AI 自动描述这张图片的内容与风格")
                        }

                        // 组间分隔：看懂 → 拿走
                        Divider().frame(height: 14).opacity(0.3)

                        // 3. 复制原图到剪贴板（拿走组）
                        ToolbarCapsuleButton(
                            icon: showCopiedAlert ? "checkmark" : "doc.on.doc",
                            title: showCopiedAlert ? "已复制！" : "复制原图",
                            tint: showCopiedAlert ? Color.green : Color.primary
                        ) {
                            if let p = activeImagePath {
                                copyImageToClipboard(path: p)
                            }
                        }
                        .help("拷贝图片至剪贴板")

                        // 4. 另存为... (NSSavePanel)（拿走组）
                        ToolbarCapsuleButton(
                            icon: "square.and.arrow.down",
                            title: "另存为...",
                            tint: Color.primary
                        ) {
                            if let p = activeImagePath {
                                exportImage(path: p)
                            }
                        }
                        .help("导出画作到本地")

                        // 5. 压缩并导出（拿走组）
                        ToolbarCapsuleButton(
                            icon: compressAlertMessage != nil ? "checkmark" : "arrow.down.right.and.arrow.up.left",
                            title: compressAlertMessage ?? "压缩",
                            tint: compressAlertMessage != nil ? Color.green : Color.primary
                        ) {
                            showCompressPopover = true
                        }
                        .help("弹出压缩设置，选择目标大小并保存到本地")
                        .popover(isPresented: $showCompressPopover, arrowEdge: .top) {
                            if let p = activeImagePath {
                                CompressExportPopoverView(
                                    sourcePath: p,
                                    onDismiss: { showCompressPopover = false },
                                    onExportCompleted: { msg in
                                        withAnimation {
                                            compressAlertMessage = msg
                                        }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                            withAnimation {
                                                compressAlertMessage = nil
                                            }
                                        }
                                    }
                                )
                            }
                        }

                        // 6. 访达显示（拿走组）
                        ToolbarCapsuleButton(
                            icon: "folder",
                            title: "访达定位",
                            tint: Color.primary
                        ) {
                            if let p = activeImagePath {
                                NSWorkspace.shared.selectFile(p, inFileViewerRootedAtPath: "")
                            }
                        }
                        .help("在 macOS 访达中查看原图")

                        // 7. 删除当前稿（危险操作，单独分隔；单稿记录=删整条）
                        if let del = onDeleteBatch {
                            Divider().frame(height: 14).opacity(0.3)
                            ToolbarCapsuleButton(
                                icon: "trash",
                                title: nil,
                                tint: Color.red.opacity(0.85)
                            ) {
                                del(batch.id)
                            }
                            .help(batch.imagePaths.count > 1
                                  ? "删除当前稿件（其余稿保留）"
                                  : "删除此组记录（含本地图片文件）")
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.88))
                    .clipShape(Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 4)
                    .padding(.bottom, 12)
                }
            }

            // 稿次条：原图 / 改 1 / 改 2 …（横向滚动 + 编号角标 + 当前稿次指令）
            if batch.imagePaths.count > 1 {
                VStack(alignment: .leading, spacing: 7) {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(Array(batch.imagePaths.enumerated()), id: \.offset) { idx, path in
                                    pagerThumb(batch: batch, idx: idx, path: path)
                                        .id(idx)
                                }
                            }
                            .padding(2)
                        }
                        .onChange(of: selectedImageIndex) { _, newValue in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(newValue, anchor: .center)
                            }
                        }
                    }

                    // 常驻：当前稿件的来源（原图 → 原始提示词；改 n → 该轮修改指令）
                    // 参数（比例 / 画风 / 负面词）收进行尾的 ⓘ 弹窗，不再占用本行宽度
                    if let info = currentTurnInfo(batch: batch) {
                        HStack(spacing: 6) {
                            Text(info.label)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(info.isOriginal ? Color.secondary : Color.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(
                                    Capsule().fill(info.isOriginal ? Color.secondary.opacity(0.15) : Color.accentColor)
                                )
                            Text(info.text)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .textSelection(.enabled)

                            Spacer(minLength: 8)

                            // 该稿参数（比例 / 画风 / 负面词）收进 ⓘ 弹窗：
                            // 本行只留「稿次 + 指令」，窄窗口下指令不再被胶囊挤没
                            Button {
                                showTurnParams.toggle()
                            } label: {
                                Image(systemName: showTurnParams ? "info.circle.fill" : "info.circle")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(showTurnParams ? Color.accentColor : Color.secondary)
                                    .padding(3)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("查看该稿的提示词 / 修改指令与生成参数（可复制）")
                            .popover(isPresented: $showTurnParams, arrowEdge: .top) {
                                turnParamsPopover(batch: batch)
                            }
                        }
                        .help(info.tooltip)
                    }
                }
                .padding(6)
                .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)
            }
        }
        .padding(10)
    }

    // MARK: - 稿次切换（画布按钮 / 稿次条共用）
    /// 切换到指定稿次（越界忽略）
    private func goToTurn(_ index: Int) {
        guard let count = currentBatch?.imagePaths.count, index >= 0, index < count else { return }
        withAnimation(.spring(duration: 0.2)) { selectedImageIndex = index }
    }

    /// 画布两侧的圆形切稿按钮
    @ViewBuilder
    private func pagerButton(icon: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.6))
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(Color(NSColor.windowBackgroundColor).opacity(0.88))
                )
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    /// 稿次条缩略图（编号角标 + 选中描边 + 悬停显示该轮指令）
    @ViewBuilder
    private func pagerThumb(batch: GenerationBatch, idx: Int, path: String) -> some View {
        let isSelected = selectedImageIndex == idx
        Button {
            goToTurn(idx)
        } label: {
            Group {
                if let thumb = pagerThumbs[path] ?? ThumbnailGenerator.shared.thumbnailFromCache(for: path) {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFill()
                } else {
                    RoundedRectangle(cornerRadius: DesignMetrics.radiusS)
                        .fill(Color.secondary.opacity(0.1))
                        .overlay(ProgressView().controlSize(.mini))
                        .task(id: path) {
                            // 异步生成/读取缩略图后写回本视图状态，触发该分支重新求值
                            if let img = await ThumbnailGenerator.shared.loadThumbnail(for: path) {
                                pagerThumbs[path] = img
                            }
                        }
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusS))
            .overlay(alignment: .topLeading) {
                Text(batch.turnLabel(at: idx))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(isSelected ? Color.accentColor : Color(NSColor.windowBackgroundColor).opacity(0.86))
                    )
                    .padding(2)
            }
            .overlay(
                RoundedRectangle(cornerRadius: DesignMetrics.radiusS)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .help(batch.turnInstruction(at: idx).map { "\(batch.turnLabel(at: idx)) · \($0)" } ?? batch.turnLabel(at: idx))
    }

    /// 当前稿件的说明（原图 → 原始提示词；改 n → 该轮修改指令）
    private func currentTurnInfo(batch: GenerationBatch) -> (label: String, text: String, isOriginal: Bool, tooltip: String)? {
        guard batch.imagePaths.indices.contains(selectedImageIndex) else { return nil }
        let label = batch.turnLabel(at: selectedImageIndex)
        if let instruction = batch.turnInstruction(at: selectedImageIndex), !instruction.isEmpty {
            return (label, "指令：" + instruction, false, "\(label) · 第 \(selectedImageIndex) 轮修改指令：\(instruction)")
        }
        let prompt = batch.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        return (label, prompt, true, "原图 · 原始提示词：\(prompt)")
    }

    /// 该稿信息弹窗（提示词 / 本轮指令 / 比例 / 画风 / 负面词，均可复制）
    /// ——从稿次行 ⓘ 展开，样式对齐压缩/信息弹窗
    @ViewBuilder
    private func turnParamsPopover(batch: GenerationBatch) -> some View {
        let snap = batch.turnSnapshot(at: selectedImageIndex)
        let styleName = (snap.style?.isEmpty == false) ? (snap.style ?? "无预设") : "无预设"
        let turnLabel = batch.turnLabel(at: selectedImageIndex)
        let instruction = batch.turnInstruction(at: selectedImageIndex)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("\(turnLabel) · 图像信息")
                    .font(.system(size: 13, weight: .bold))
                Spacer(minLength: 8)
                Button {
                    showTurnParams = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider().opacity(0.5)

            // 本轮修改指令（仅改稿有）
            if let instruction, !instruction.isEmpty {
                copyFieldBlock(label: "本轮修改指令", value: instruction, tag: "instruction", lineLimit: 5)
            }

            // 原始提示词：任何时候都能取回（描述框在历史上下文中已改为「修改指令」输入位）
            copyFieldBlock(
                label: instruction?.isEmpty == false ? "原始提示词" : "提示词",
                value: batch.prompt.isEmpty ? "—" : batch.prompt,
                tag: "prompt",
                dimmed: batch.prompt.isEmpty,
                lineLimit: 6
            )

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 8) {
                metadataLine(label: "画幅比例", value: snap.aspectRatio)
                metadataLine(label: "画风", value: styleName)
                metadataLine(label: "生成时间", value: Self.metadataDateFormatter.string(from: batch.createdAt))
            }

            copyFieldBlock(
                label: "负面提示词",
                value: snap.negativePrompt.isEmpty ? "未设置" : snap.negativePrompt,
                tag: "negative",
                dimmed: snap.negativePrompt.isEmpty,
                lineLimit: 3
            )
        }
        .padding(14)
        .frame(width: 300)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusM))
    }

    /// 可复制的文本框（caption 标签 + 右上角复制按钮 + 可选中内容）
    @ViewBuilder
    private func copyFieldBlock(
        label: String,
        value: String,
        tag: String,
        dimmed: Bool = false,
        lineLimit: Int = 4
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !dimmed {
                    Button {
                        copyToPasteboard(value, tag: tag)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: copiedField == tag ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 9, weight: .semibold))
                            Text(copiedField == tag ? "已复制" : "复制")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(copiedField == tag ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("复制到剪贴板")
                }
            }
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                .lineLimit(lineLimit)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusS))
        }
    }

    /// 复制纯文本到剪贴板并给出短暂反馈
    private func copyToPasteboard(_ text: String, tag: String) {
        guard !text.isEmpty, text != "—" else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        withAnimation { copiedField = tag }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copiedField = nil }
        }
    }

    /// 轮次参数摘要（比例 · 画风 · 负面词）
    private func turnMetaText(_ snap: (aspectRatio: String, style: String?, negativePrompt: String)) -> String {
        var parts: [String] = [snap.aspectRatio]
        parts.append((snap.style?.isEmpty == false) ? (snap.style ?? "无预设") : "无预设")
        if !snap.negativePrompt.isEmpty {
            parts.append("负面：" + snap.negativePrompt)
        }
        return parts.joined(separator: " · ")
    }

    /// 归并后的改图轮次（同一次改图返回的多张候选合并为一项）
    private struct TurnRound: Identifiable {
        let id: Int                 // 轮次编号（0 基）
        let instruction: String
        let paths: [String]
        let aspectRatio: String
        let style: String?
        let negativePrompt: String
    }

    /// 把逐图 EditTurn 归并为轮次：以 roundIndex 为准（旧数据回退为数组下标），
    /// 参数取该轮首个候选的记录值，缺省回退到记录级参数。
    private func turnRounds(of batch: GenerationBatch) -> [TurnRound] {
        guard let turns = batch.editTurns, !turns.isEmpty else { return [] }

        var order: [Int] = []
        var instructionOf: [Int: String] = [:]
        var pathsOf: [Int: [String]] = [:]
        var aspectOf: [Int: String] = [:]
        var styleOf: [Int: String?] = [:]
        var negativeOf: [Int: String] = [:]

        for (offset, turn) in turns.enumerated() {
            let r = batch.turnRoundIndex(atTurnOffset: offset)
            if pathsOf[r] == nil {
                order.append(r)
                instructionOf[r] = turn.instruction
                pathsOf[r] = [turn.imagePath]
                aspectOf[r] = turn.aspectRatio ?? batch.aspectRatio
                styleOf[r] = turn.style
                negativeOf[r] = turn.negativePrompt ?? batch.negativePrompt
            } else {
                pathsOf[r]?.append(turn.imagePath)
            }
        }

        return order.compactMap { r in
            guard let paths = pathsOf[r] else { return nil }
            return TurnRound(
                id: r,
                instruction: instructionOf[r] ?? "",
                paths: paths,
                aspectRatio: aspectOf[r] ?? batch.aspectRatio,
                style: styleOf[r] ?? batch.style,
                negativePrompt: negativeOf[r] ?? batch.negativePrompt
            )
        }
    }

    // MARK: - 画面元数据弹窗（贴近工具栏展开，样式对齐压缩弹窗）
    @ViewBuilder
    private func metadataPopover(batch: GenerationBatch) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标题栏
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("画面元数据")
                        .font(.system(size: 13, weight: .bold))
                }
                Spacer()
                Button {
                    showMetadata = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider().opacity(0.5)

            // 文本信息
            VStack(alignment: .leading, spacing: 10) {
                metadataBlock(
                    label: "提示词",
                    value: batch.prompt.isEmpty ? "—" : batch.prompt,
                    copyTag: "meta_prompt"
                )
                metadataBlock(
                    label: "负面词",
                    value: batch.negativePrompt.isEmpty ? "未设置" : batch.negativePrompt,
                    dimmed: batch.negativePrompt.isEmpty,
                    copyTag: "meta_negative"
                )
            }

            Divider().opacity(0.5)

            // 生成参数
            VStack(alignment: .leading, spacing: 8) {
                metadataLine(label: "比例", value: batch.aspectRatio)
                metadataLine(label: "画风", value: batch.style ?? "无预设")

                if let info = activeImagePath.flatMap({ getImageInfo(path: $0) }) {
                    metadataLine(label: "画幅", value: info)
                }

                metadataLine(label: "生成时间", value: Self.metadataDateFormatter.string(from: batch.createdAt))
            }

            if let turns = batch.editTurns, !turns.isEmpty {
                Divider().opacity(0.5)

                // 改图轮次（按轮次归并：一次改图返回多张候选时合并为一项）
                let rounds = turnRounds(of: batch)
                VStack(alignment: .leading, spacing: 8) {
                    Text("改图轮次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(rounds) { round in
                        let isCurrent = round.paths.contains(activeImagePath ?? "")
                        HStack(alignment: .top, spacing: 6) {
                            Text("改 \(round.id + 1)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Text(round.instruction)
                                        .font(.system(size: 11))
                                        .foregroundStyle(isCurrent ? Color.primary : Color.secondary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                    if round.paths.count > 1 {
                                        Text("\(round.paths.count) 张候选")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(Color.secondary)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                                    }
                                    Spacer(minLength: 0)
                                }
                                Text(turnMetaText((aspectRatio: round.aspectRatio, style: round.style, negativePrompt: round.negativePrompt)))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: DesignMetrics.radiusS)
                                .fill(isCurrent ? Color.accentColor.opacity(0.10) : Color.clear)
                        )
                    }
                }
            }

            Divider().opacity(0.5)

            // 多轮会话状态
            metadataBlock(
                label: "改图会话",
                value: sessionText(for: batch),
                mono: hasSession(batch),
                lineLimit: hasSession(batch) ? 1 : 2,
                dimmed: !hasSession(batch)
            )
        }
        .padding(16)
        .frame(width: 320)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusM))
    }

    @ViewBuilder
    private func metadataBlock(label: String, value: String, mono: Bool = false, lineLimit: Int = 4, dimmed: Bool = false, copyTag: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if let copyTag, !dimmed {
                    Button {
                        copyToPasteboard(value, tag: copyTag)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: copiedField == copyTag ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 9, weight: .semibold))
                            Text(copiedField == copyTag ? "已复制" : "复制")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(copiedField == copyTag ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("复制到剪贴板")
                }
            }
            Text(value)
                .font(.system(size: 11, design: mono ? .monospaced : .default))
                .foregroundStyle(dimmed ? Color.secondary : Color.primary)
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusS))
        }
    }

    @ViewBuilder
    private func metadataLine(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())
        }
    }

    private func hasSession(_ batch: GenerationBatch) -> Bool {
        guard let sid = batch.sessionId else { return false }
        return !sid.isEmpty
    }

    private func sessionText(for batch: GenerationBatch) -> String {
        if let sid = batch.sessionId, !sid.isEmpty {
            return "\(sid) · 可继续修改"
        }
        return "未建立 · 可点「继续修改当前画面」新建"
    }

    private static let metadataDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()

    private func getImageInfo(path: String) -> String? {
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        let size = img.representations.first.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? img.size
        let w = Int(size.width)
        let h = Int(size.height)

        let fileSize: String
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let bytes = attrs[.size] as? Int64 {
            let mb = Double(bytes) / (1024.0 * 1024.0)
            fileSize = String(format: "%.1f MB", mb)
        } else {
            fileSize = ""
        }
        return "\(w) × \(h)  \(fileSize)"
    }

    private func copyImageToClipboard(path: String) {
        guard let image = NSImage(contentsOfFile: path) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        withAnimation {
            showCopiedAlert = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation {
                showCopiedAlert = false
            }
        }
    }

    private func exportImage(path: String) {
        guard let sourceURL = URL(string: "file://" + path) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sourceURL.lastPathComponent
        panel.begin { response in
            if response == .OK, let destURL = panel.url {
                try? FileManager.default.copyItem(at: sourceURL, to: destURL)
            }
        }
    }
}

// MARK: - 悬浮胶囊工具栏轻量级药丸按钮
struct ToolbarCapsuleButton: View {
    let icon: String
    let title: String?
    let tint: Color
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                if let t = title {
                    Text(t)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, title != nil ? 10 : 8)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isHovered ? Color.primary.opacity(0.08) : Color.clear)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - 压缩并保存画作轻量弹窗
struct CompressExportPopoverView: View {
    let sourcePath: String
    let onDismiss: () -> Void
    let onExportCompleted: (String) -> Void

    @State private var targetKB: Int = 1024
    @State private var isProcessing: Bool = false
    @State private var errorMessage: String? = nil

    private var originalSizeText: String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: sourcePath),
              let bytes = attrs[.size] as? Int64 else { return "未知" }
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb >= 1.0 {
            return String(format: "%.2f MB", mb)
        } else {
            return String(format: "%d KB", Int(Double(bytes) / 1024.0))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 标题栏
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text("压缩并保存画作")
                        .font(.system(size: 13, weight: .bold))
                }
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // 当前文件信息
            HStack {
                Text("原图体积")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(originalSizeText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }

            Divider().opacity(0.5)

            // 目标大小选择
            VStack(alignment: .leading, spacing: 8) {
                Text("目标压缩大小")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    presetButton(title: "500 KB", kb: 500)
                    presetButton(title: "1 MB (公众号)", kb: 1024)
                    presetButton(title: "2 MB", kb: 2048)
                }

                // 自定义调节
                HStack(spacing: 8) {
                    Text("微调:")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(targetKB) },
                            set: { targetKB = Int($0) }
                        ),
                        in: 200...4000,
                        step: 50
                    )
                    Text("\(targetKB) KB")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 60, alignment: .trailing)
                }
                .padding(.top, 4)
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            Divider().opacity(0.5)

            // 操作按键
            HStack(spacing: 10) {
                Button("取消") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .liquidGlassCard(cornerRadius: DesignMetrics.radiusS)

                Spacer()

                Button {
                    startCompressionAndSave()
                } label: {
                    HStack(spacing: 4) {
                        if isProcessing {
                            ProgressView().controlSize(.mini)
                            Text("处理中...")
                        } else {
                            Image(systemName: "square.and.arrow.down")
                            Text("保存到本地...")
                        }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isProcessing)
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusM))
    }

    private func presetButton(title: String, kb: Int) -> some View {
        Button {
            targetKB = kb
        } label: {
            Text(title)
                .font(.system(size: 10, weight: targetKB == kb ? .semibold : .regular))
                .foregroundStyle(targetKB == kb ? Color.accentColor : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(targetKB == kb ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(targetKB == kb ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func startCompressionAndSave() {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.canCreateDirectories = true

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(baseName)_\(targetKB)kb.jpg"

        panel.begin { response in
            if response == .OK, let destURL = panel.url {
                isProcessing = true
                errorMessage = nil

                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let finalKB = try performCompression(from: sourcePath, to: destURL, targetKB: self.targetKB)
                        DispatchQueue.main.async {
                            self.isProcessing = false
                            self.onDismiss()
                            self.onExportCompleted("已保存 (\(finalKB) KB)")
                            NSWorkspace.shared.selectFile(destURL.path, inFileViewerRootedAtPath: "")
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.isProcessing = false
                            self.errorMessage = "压缩导出失败: \(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }

    private func performCompression(from src: String, to dest: URL, targetKB: Int) throws -> Int {
        guard let image = NSImage(contentsOfFile: src),
              let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData) else {
            throw NSError(domain: "Compress", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法解析图片数据"])
        }

        var quality: Float = 0.90
        var bestData: Data? = nil

        // 1. JPEG 质量阶梯
        while quality >= 0.2 {
            if let data = rep.representation(using: .jpeg, properties: [.compressionFactor: NSNumber(value: quality)]) {
                bestData = data
                if Double(data.count) / 1024.0 <= Double(targetKB) {
                    break
                }
            }
            quality -= 0.08
        }

        // 2. 尺寸阶梯缩放
        if let data = bestData, Double(data.count) / 1024.0 > Double(targetKB) {
            var scale: CGFloat = 0.85
            while scale >= 0.25 {
                let targetW = max(80, Int(CGFloat(rep.pixelsWide) * scale))
                let targetH = max(80, Int(CGFloat(rep.pixelsHigh) * scale))
                if let resizedRep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: targetW,
                    pixelsHigh: targetH,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .calibratedRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                ) {
                    NSGraphicsContext.saveGraphicsState()
                    let context = NSGraphicsContext(bitmapImageRep: resizedRep)
                    NSGraphicsContext.current = context
                    image.draw(in: NSRect(x: 0, y: 0, width: targetW, height: targetH))
                    NSGraphicsContext.restoreGraphicsState()

                    if let scaledData = resizedRep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) {
                        bestData = scaledData
                        if Double(scaledData.count) / 1024.0 <= Double(targetKB) {
                            break
                        }
                    }
                }
                scale -= 0.15
            }
        }

        guard let finalData = bestData else {
            throw NSError(domain: "Compress", code: 2, userInfo: [NSLocalizedDescriptionKey: "未能生成压缩数据"])
        }

        try finalData.write(to: dest)
        return Int(Double(finalData.count) / 1024.0)
    }
}

// MARK: - 高清矢量加载指示器（TimelineView 逐帧重绘，无隐式动画、任意尺寸锐利）
struct HaloSpinnerView: View {
    var size: CGFloat = 56
    var lineWidth: CGFloat = 5
    /// 一圈时长（秒）
    var period: Double = 0.9

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: period)
            Circle()
                .trim(from: 0.0, to: 0.72)
                .stroke(
                    AngularGradient(
                        colors: [Color.accentColor.opacity(0.15), Color.accentColor, Color.purple, Color.accentColor.opacity(0.15)],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .frame(width: size, height: size)
                .rotationEffect(.degrees(elapsed / period * 360))
        }
    }
}


