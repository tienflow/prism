import SwiftUI
import AppKit
import QuickLookUI
import UniformTypeIdentifiers
import os

public struct MainStudioView: View {
    @State private var vm = StudioViewModel()

    public init() {}

    public var body: some View {
        @Bindable var vm = vm
        HStack(alignment: .top, spacing: 10) {
            // 1. 左侧历史面板 (支持折叠)
            if vm.isSidebarVisible {
                historySidebarView
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            // 2. 中间纯粹作品画廊展台
            StudioGalleryView(
                currentBatch: vm.selectedBatch,
                selectedImageIndex: $vm.selectedImageIndex,
                // 画布只反映「当前展示的记录」是否在生成（多任务下不看全局）
                isGenerating: vm.isActingOnSelection,
                currentStage: vm.currentStage,
                currentMessage: vm.currentMessage,
                isSidebarHidden: !vm.isSidebarVisible,
                showMetadata: $vm.showMetadata,
                onToggleSidebar: {
                    vm.toggleSidebar()
                },
                onNewCanvas: {
                    vm.createNewCanvas()
                },
                onDeleteBatch: { _ in
                    // 画布工具栏与当前稿绑定：删的是当前选中的那张稿（单稿记录则删整条）
                    vm.deleteCurrentShot()
                },
                onStopGeneration: {
                    vm.stopGeneration()
                },
                onDescribeImage: { path in
                    // 工具栏「AI 描述」= 描述**画布主图**（各入口各司其职：
                    // 参考图由描述框上方参考图区的 icon 负责，不在此混用）
                    vm.describeImage(path: path)
                },
                onRetry: { batchId in
                    vm.retry(batchId: batchId)
                }
            )
            .frame(maxHeight: .infinity)

            // 3. 右侧参数配置栏 (包含 AI 润色、参考图生图、停止生成与偏好设置)
            PromptInspectorView(
                prompt: $vm.prompt,
                negativePrompt: $vm.negativePrompt,
                selectedAspect: $vm.selectedAspect,
                selectedStyle: $vm.selectedStyle,
                referenceImagePath: $vm.referenceImagePath,
                hasAuth: vm.sidecar.hasAuth,
                authChecked: vm.sidecar.authChecked,
                onOpenAuth: {
                    vm.showAuthSheet = true
                },
                onOpenPreferences: {
                    vm.showPreferencesSheet = true
                },
                isActingOnSelection: vm.isActingOnSelection,
                hasSelection: vm.selectedBatch != nil,
                selectedPromptText: vm.selectedPictureDescription,
                currentStage: vm.currentStage,
                currentMessage: vm.currentMessage,
                onGenerate: {
                    vm.startGeneration()
                },
                onStopGeneration: {
                    vm.stopGeneration()
                },
                canContinueEditing: vm.canContinueEditing,
                promptIsConsumedBaseline: vm.promptIsConsumedBaseline,
                onContinueEditing: {
                    vm.continueEditing()
                },
                onDescribeReference: { path in
                    vm.describeImage(path: path)
                },
                contextToken: vm.inspectorContextToken,
                busyElsewhereHint: vm.busyElsewhereHint,
                onViewBusyBatch: {
                    vm.viewFirstBusyBatch()
                }
            )
            .frame(maxHeight: .infinity)
        }
        .padding([.horizontal, .bottom], 10)
        .padding(.top, 6) // 系统 safeArea 已自然避让红绿灯，极小间距实现极致紧凑
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
        // 拖图片到窗口任意位置 → 设为参考图（Finder 文件 / 其他 App 图像数据均可）
        .onDrop(
            of: [UTType.fileURL, UTType.image, UTType.png, UTType.jpeg],
            delegate: ReferenceImageDropDelegate { providers in
                vm.importReferenceImage(from: providers)
            }
        )
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
        .sheet(isPresented: $vm.showAuthSheet) {
            WebKitLoginView()
        }
        .sheet(isPresented: $vm.showPreferencesSheet) {
            PreferencesView()
        }
        .sheet(isPresented: $vm.showDescriptionSheet) {
            descriptionSheetView
        }
        .task {
            await vm.sidecar.startIfNeeded()
            await vm.loadExistingImages()
            vm.installKeyMonitor()
        }
        // 菜单命令（SwiftUI Commands）经 FocusedValues 拿到当前 VM 的动作
        .focusedSceneValue(\.prismMenuActions, vm.menuActions)
        // 切换批次/画布时：参考图跟随该批次（有参考图显示之，无则空），同时刷新上下文令牌清空撤回栈
        .onChange(of: vm.selectedBatchId) { _, _ in
            vm.referenceImagePath = vm.selectedBatch?.referenceImagePath
            vm.inspectorContextToken = UUID()
        }
        // 手动移除参考图（×）时：同步回当前批次并持久化
        .onChange(of: vm.referenceImagePath) { _, newValue in
            vm.syncReferenceImageToBatch(newValue)
        }
    }

    // MARK: - AI 图像描述 Sheet（macOS 原生弹窗）
    private var descriptionSheetView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack(spacing: 8) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(vm.describeTargetTitle)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    vm.showDescriptionSheet = false
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
            if vm.isDescribingImage {
                // 流式：已经有增量就直接渲染，边到边看；还没出字才显示大号 spinner
                if let streaming = vm.imageDescription, !streaming.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            descriptionBody(streaming)

                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("AI 正在描述图像...")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                } else {
                    ZStack {
                        VStack(spacing: 14) {
                            HaloSpinnerView(size: 40, lineWidth: 4)
                            Text("AI 正在描述图像...")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let desc = vm.imageDescription {
                ScrollView {
                    descriptionBody(desc)
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
                    vm.aiLog("sheet hit defensive branch, auto-recovering")
                    if let path = vm.pendingDescribePath ?? vm.activeImagePathForAI {
                        vm.describeImage(path: path, force: false)
                    }
                }
            }

            Divider().opacity(0.15)

            // 底部操作区
            HStack(spacing: 10) {
                if !vm.isDescribingImage,
                   let promptText = vm.extractedGenerationPrompt, !promptText.isEmpty {
                    Button {
                        vm.copyGenerationPrompt(promptText)
                    } label: {
                        Label(vm.promptCopied ? "已复制" : "复制提示词",
                              systemImage: vm.promptCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .controlSize(.regular)
                    .disabled(vm.promptCopied)
                }

                Button {
                    // 以「本次描述的对象」重跑——跟随参考图分流，不会退回主图
                    if let path = vm.pendingDescribePath ?? vm.activeImagePathForAI {
                        vm.describeImage(path: path, force: true)
                    }
                } label: {
                    Label("重新生成", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
                .controlSize(.regular)
                .disabled(vm.isDescribingImage)

                Spacer()

                Button {
                    vm.showDescriptionSheet = false
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

    /// 描述正文分段渲染：段落间只留 `spacing`，比保留 Markdown 空行（≈ 一整行高度）紧凑得多。
    /// 段落内部仍走 `markdownText`（内联语法照常解析），单换行由 lineSpacing 承担。
    private func descriptionBody(_ raw: String) -> some View {
        let blocks = raw
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                markdownText(block)
                    .font(.system(size: 13))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - 左侧历史列表
    private var historySidebarView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label("历史批次", systemImage: "clock.arrow.circlepath")
                    .font(.headline)

                if !vm.history.isEmpty {
                    Text(vm.historySearchText.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "\(vm.history.count) 组"
                         : "\(vm.filteredHistory.count)/\(vm.history.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // 新建画布按钮 (图标)
                Button {
                    vm.createNewCanvas()
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
                        vm.isSidebarVisible = false
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

            if vm.history.isEmpty {
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
                // 历史搜索框（按提示词 / 负面词 / 修改指令过滤）
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    TextField("搜索提示词 / 修改指令", text: $vm.historySearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                    if !vm.historySearchText.isEmpty {
                        Button {
                            vm.historySearchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .liquidGlassCard(cornerRadius: DesignMetrics.radiusS)

                if vm.filteredHistory.isEmpty {
                    VStack(spacing: 6) {
                        Spacer()
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                        Text("没有匹配的历史")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(vm.filteredHistory) { batch in
                                HistoryItemRow(
                                    batch: batch,
                                    isSelected: vm.selectedBatch?.id == batch.id,
                                    onSelect: {
                                        vm.selectBatch(batch)
                                    },
                                    onDelete: {
                                        vm.deleteBatch(id: batch.id)
                                    },
                                    onReuse: {
                                        vm.selectBatch(batch)
                                    }
                                )
                            }
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
                        Text(Self.formattedDate(batch.createdAt))
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

    /// 静态共享：历史列表每行重绘一次就新建 DateFormatter 是可观测的滚动开销，
    /// 日期格式只有三种，全局缓存一个 formatter 按需切换 dateFormat。
    private static let dateFormatter = DateFormatter()

    private static func formattedDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            dateFormatter.dateFormat = "HH:mm"
        } else if cal.isDateInYesterday(date) {
            dateFormatter.dateFormat = "昨天 HH:mm"
        } else {
            dateFormatter.dateFormat = "MM-dd HH:mm"
        }
        return dateFormatter.string(from: date)
    }
}

// MARK: - 参考图拖入代理
/// 接收外部拖入的图片（Finder 文件 / 其他 App 图像），交给 VM 设为参考图。
struct ReferenceImageDropDelegate: DropDelegate {
    let onDrop: ([NSItemProvider]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL, .image, .png, .jpeg])
    }

    func performDrop(info: DropInfo) -> Bool {
        let providers = info.itemProviders(
            for: [.fileURL, .image, .png, .jpeg, .webP, .tiff, .bmp]
        )
        guard !providers.isEmpty else { return false }
        onDrop(providers)
        return true
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
