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
    @State private var thumbnailRefreshID: UUID = UUID()

    public init(
        currentBatch: GenerationBatch?,
        selectedImageIndex: Binding<Int>,
        isGenerating: Bool = false,
        currentStage: GenerationStage = .idle,
        currentMessage: String = "",
        isSidebarHidden: Bool = false,
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

                // 如果正在后台生图，而用户正切在历史批次上看老作品，显示轻巧的后台渲染进度胶囊
                if isGenerating && (currentBatch?.imagePaths.isEmpty == false) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(currentMessage.isEmpty ? "新图渲染中..." : currentMessage)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(NSColor.windowBackgroundColor).opacity(0.85))
                    .clipShape(Capsule())
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

                // 底部悬浮轻量化工具栏 (胶囊与内部按钮 100% 统一圆角)
                VStack {
                    Spacer()

                    HStack(spacing: 4) {
                        // 1. 复制原图到剪贴板
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

                        Divider().frame(height: 14).opacity(0.3)

                        // 2. 另存为... (NSSavePanel)
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

                        Divider().frame(height: 14).opacity(0.3)

                        // 3. 压缩并导出 (小弹窗选择目标大小并保存到本地)
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

                        Divider().frame(height: 14).opacity(0.3)

                        // 4. 访达显示
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

                        // 4.5 AI 功能区
                        if let describe = onDescribeImage, let p = activeImagePath {
                            Divider().frame(height: 14).opacity(0.3)
                            ToolbarCapsuleButton(
                                icon: "text.book.closed",
                                title: "AI 描述",
                                tint: Color.primary
                            ) {
                                describe(p)
                            }
                            .help("AI 自动描述这张图片的内容与风格")
                        }

                        // 5. 删除当前批次
                        if let del = onDeleteBatch {
                            Divider().frame(height: 14).opacity(0.3)
                            ToolbarCapsuleButton(
                                icon: "trash",
                                title: nil,
                                tint: Color.red.opacity(0.85)
                            ) {
                                del(batch.id)
                            }
                            .help("删除此组生成记录")
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

            // 多候选图横向缩略选择栏 (如果有 ≥ 2 张)
            if batch.imagePaths.count > 1 {
                HStack(spacing: 10) {
                    ForEach(Array(batch.imagePaths.enumerated()), id: \.offset) { idx, path in
                        Button {
                            withAnimation(.spring(duration: 0.2)) {
                                selectedImageIndex = idx
                            }
                        } label: {
                            if let thumb = ThumbnailGenerator.shared.thumbnailFromCache(for: path) {
                                Image(nsImage: thumb)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 54, height: 54)
                                    .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusS))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: DesignMetrics.radiusS)
                                            .strokeBorder(selectedImageIndex == idx ? Color.accentColor : Color.clear, lineWidth: 2)
                                    )
                            } else {
                                RoundedRectangle(cornerRadius: DesignMetrics.radiusS)
                                    .fill(Color.secondary.opacity(0.1))
                                    .frame(width: 54, height: 54)
                                    .overlay(
                                        ProgressView().controlSize(.mini)
                                    )
                                    .task {
                                        _ = await ThumbnailGenerator.shared.loadThumbnail(for: path)
                                        withAnimation { thumbnailRefreshID = UUID() }
                                    }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)
            }
        }
        .padding(10)
    }

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


