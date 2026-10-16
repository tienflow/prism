import SwiftUI

public struct PromptInspectorView: View {
    @Binding public var prompt: String
    @Binding public var negativePrompt: String
    @Binding public var selectedAspect: AspectRatioOption
    @Binding public var selectedStyle: ArtStyleOption
    public var hasAuth: Bool
    public var onOpenAuth: () -> Void
    public var onOpenPreferences: () -> Void
    /// 当前选中记录正在生成 / 改图中（决定底部主按钮区显示「停止生成」还是其他动作）
    public var isActingOnSelection: Bool
    /// 是否选中了一条历史记录（选中时底部只保留「继续修改当前画面」，不显示「开始生图」）
    public var hasSelection: Bool = false
    /// 有其他记录正在生成 / 改图时的提示文案（非空则禁用开始生图与继续修改）
    public var busyElsewhereHint: String? = nil
    /// 点击提示行「查看」跳转到正在运行的那条记录
    public var onViewBusyBatch: (() -> Void)? = nil
    public var currentStage: GenerationStage
    public var currentMessage: String
    public var onGenerate: () -> Void
    public var onStopGeneration: () -> Void
    /// 是否可对当前选中画面继续改图（多轮会话）
    public var canContinueEditing: Bool
    /// 触发「继续修改」（多轮会话改图）
    public var onContinueEditing: (() -> Void)?

    @State private var isStylesExpanded: Bool = false
    @State private var previousPrompt: String? = nil
    @State private var isPolishing: Bool = false
    @State private var polishError: String? = nil

    // 负面提示词 AI 推荐
    @State private var isSuggestingNegative: Bool = false
    @State private var previousNegativePrompt: String? = nil
    @State private var negativeError: String? = nil

    // 参考图绑定（由父视图持有）
    @Binding public var referenceImagePath: String?
    // 对参考图执行 AI 描述（逻辑在父视图，与画布区按钮一致）
    public var onDescribeReference: ((String) -> Void)?

    /// 输入上下文令牌：父视图在「切换历史记录 / 新建画布」时刷新。
    /// 令牌变化即代表换了输入上下文，需清空撤回栈，避免「撤回」按钮跨记录残留。
    public var contextToken: UUID = UUID()

    // 参考图大图查看
    @State private var showRefViewer: Bool = false

    // 读取 AI 偏好设置
    @AppStorage("pref_use_custom_ai") private var useCustomAI: Bool = false
    @AppStorage("pref_custom_api_key") private var customApiKey: String = ""
    @AppStorage("pref_custom_base_url") private var customBaseUrl: String = ""
    @AppStorage("pref_custom_model") private var customModel: String = "gemini-1.5-flash"

    public init(
        prompt: Binding<String>,
        negativePrompt: Binding<String>,
        selectedAspect: Binding<AspectRatioOption>,
        selectedStyle: Binding<ArtStyleOption>,
        referenceImagePath: Binding<String?> = .constant(nil),
        hasAuth: Bool = false,
        onOpenAuth: @escaping () -> Void = {},
        onOpenPreferences: @escaping () -> Void = {},
        isActingOnSelection: Bool,
        hasSelection: Bool = false,
        currentStage: GenerationStage,
        currentMessage: String,
        onGenerate: @escaping () -> Void,
        onStopGeneration: @escaping () -> Void = {},
        canContinueEditing: Bool = false,
        onContinueEditing: (() -> Void)? = nil,
        onDescribeReference: ((String) -> Void)? = nil,
        contextToken: UUID = UUID(),
        busyElsewhereHint: String? = nil,
        onViewBusyBatch: (() -> Void)? = nil
    ) {
        self._prompt = prompt
        self._negativePrompt = negativePrompt
        self._selectedAspect = selectedAspect
        self._selectedStyle = selectedStyle
        self._referenceImagePath = referenceImagePath
        self.hasAuth = hasAuth
        self.onOpenAuth = onOpenAuth
        self.onOpenPreferences = onOpenPreferences
        self.isActingOnSelection = isActingOnSelection
        self.hasSelection = hasSelection
        self.busyElsewhereHint = busyElsewhereHint
        self.onViewBusyBatch = onViewBusyBatch
        self.currentStage = currentStage
        self.currentMessage = currentMessage
        self.onGenerate = onGenerate
        self.onStopGeneration = onStopGeneration
        self.canContinueEditing = canContinueEditing
        self.onContinueEditing = onContinueEditing
        self.onDescribeReference = onDescribeReference
        self.contextToken = contextToken
    }

    /// 底部「继续修改当前画面」按钮的提示文案（禁用时说明原因）
    private var continueEditingHelp: String {
        if busyElsewhereHint != nil { return "另一条记录正在生成，请先等待或点「查看」前往" }
        if !canContinueEditing { return "需要一条已有画面的记录，并在描述框里写修改要求（⌘⇧↩）" }
        return "在同一会话中继续修改选中的画面（⌘⇧↩），描述框里写修改要求"
    }

    private var displayedStyles: [ArtStyleOption] {
        if isStylesExpanded {
            return ArtStyleOption.allCases
        } else {
            var base = Array(ArtStyleOption.allCases.prefix(6))
            if !base.contains(selectedStyle) && selectedStyle != .none {
                base.append(selectedStyle)
            }
            return base
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 参数可滚动配置区
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    // 1. 标题与偏好设置齿轮 (已移除多余的凭据图标)
                    HStack(spacing: 8) {
                        Label("创作参数", systemImage: "slider.horizontal.3")
                            .font(.headline)
                        Spacer()

                        // 偏好设置齿轮
                        Button {
                            onOpenPreferences()
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(5)
                        }
                        .buttonStyle(.plain)
                        .liquidGlassCard(cornerRadius: DesignMetrics.radiusS)
                        .help("偏好设置 (AI 配置与账号绑定)")
                    }

                    // 2. 中文主提示词 (Prompt) 区域：集成清空、撤回与 AI 润色
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("主体描述 (Prompt)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        NativePlainTextEditor(text: $prompt)
                            .frame(minHeight: 80, maxHeight: 110)
                            .padding(4)

                        // 底部工具条：清空、撤回、AI 润色
                        HStack(spacing: 8) {
                            if !prompt.isEmpty {
                                Button {
                                    prompt = ""
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "trash")
                                            .font(.system(size: 10))
                                        Text("清空")
                                            .font(.system(size: 10))
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                }
                                .buttonStyle(.plain)
                                .help("一键清空当前主体描述")
                                .transition(.opacity)
                            }

                            Spacer()

                            // 撤回上次 AI 润色
                            if let prev = previousPrompt {
                                Button {
                                    withAnimation(.spring(duration: 0.25)) {
                                        prompt = prev
                                        previousPrompt = nil
                                    }
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.uturn.backward")
                                            .font(.system(size: 10))
                                        Text("撤回")
                                            .font(.system(size: 10))
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("撤回上次 AI 润色内容")
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                            }

                            // AI 润色按钮
                            Button {
                                performAIPolish()
                            } label: {
                                HStack(spacing: 4) {
                                    if isPolishing {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    Text(isPolishing ? "润色中..." : "AI 润色")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isPolishing || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help("使用 AI 将描述丰富扩写为大师级细节画面")
                        }
                    }
                    .padding(8)
                    .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)

                    // 2.5 参考图上传区 (参考图生图)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("参考图 (可选)")
                                .font(.caption)
                            Spacer()
                            if let refPath = referenceImagePath {
                                Button {
                                    referenceImagePath = nil
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("移除参考图")
                            }
                        }

                        if let refPath = referenceImagePath {
                            // 已选择参考图，显示预览（右侧常驻：查看 / AI 描述）
                            HStack(spacing: 8) {
                                if let img = NSImage(contentsOfFile: refPath) {
                                    Image(nsImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 48, height: 48)
                                        .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusS))
                                        .onTapGesture {
                                            showRefViewer = true
                                        }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(URL(fileURLWithPath: refPath).lastPathComponent)
                                        .font(.system(size: 10))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text("将以此图为参考生图")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()

                                // 右侧操作区：查看 / AI 描述
                                HStack(spacing: 6) {
                                    Button {
                                        showRefViewer = true
                                    } label: {
                                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 22, height: 22)
                                            .background(Color.secondary.opacity(0.1))
                                            .clipShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("放大查看")

                                    Button {
                                        onDescribeReference?(refPath)
                                    } label: {
                                        Image(systemName: "text.book.closed")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 22, height: 22)
                                            .background(Color.secondary.opacity(0.1))
                                            .clipShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("AI 描述此图")
                                }
                            }
                            .padding(6)
                            .liquidGlassCard(cornerRadius: DesignMetrics.radiusS)
                            .sheet(isPresented: $showRefViewer) {
                                referenceViewerSheet(path: refPath)
                            }
                        } else {
                            // 未选择参考图，显示上传按钮
                            Button {
                                pickReferenceImage()
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "photo.badge.plus")
                                        .font(.system(size: 11))
                                    Text("选择参考图")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(Color.secondary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: DesignMetrics.radiusS))
                                .overlay(
                                    RoundedRectangle(cornerRadius: DesignMetrics.radiusS)
                                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                                        .foregroundStyle(Color.secondary.opacity(0.3))
                                )
                            }
                            .buttonStyle(.plain)
                            .help("上传参考图后，AI 会基于此图的构图和风格进行生图")
                        }
                    }

                    // 3. 画风选择 (默认展示 6 个精选画风，其他平滑折叠)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("画风")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if selectedStyle != .none {
                                Text(selectedStyle.rawValue)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                            ForEach(displayedStyles) { style in
                                Button {
                                    selectedStyle = style
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: style.icon)
                                            .font(.system(size: 11))
                                        Text(style.rawValue)
                                            .font(.system(size: 11, weight: selectedStyle == style ? .semibold : .regular))
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                                    .background(
                                        RoundedRectangle(cornerRadius: DesignMetrics.radiusS)
                                            .fill(selectedStyle == style ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: DesignMetrics.radiusS)
                                            .strokeBorder(
                                                selectedStyle == style ? Color.accentColor : Color.secondary.opacity(0.18),
                                                lineWidth: selectedStyle == style ? 1.0 : 0.5
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // 折叠/展开控制按钮
                        Button {
                            withAnimation(.spring(duration: 0.25)) {
                                isStylesExpanded.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(isStylesExpanded ? "收起画风" : "展开更多画风 (\(ArtStyleOption.allCases.count - 6) 种)...")
                                    .font(.system(size: 10, weight: .medium))
                                Image(systemName: isStylesExpanded ? "chevron.up" : "chevron.down")
                                    .font(.system(size: 9))
                            }
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)

                    // 4. 图片比例 (Aspect Ratio)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("画幅比例 (Aspect Ratio)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            ForEach(AspectRatioOption.allCases) { option in
                                Button {
                                    selectedAspect = option
                                } label: {
                                    VStack(spacing: 4) {
                                        Image(systemName: option.systemIcon)
                                            .font(.system(size: 12))
                                        Text(option.rawValue)
                                            .font(.system(size: 10, weight: selectedAspect == option ? .semibold : .medium))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                    .background(
                                        RoundedRectangle(cornerRadius: DesignMetrics.radiusS)
                                            .fill(selectedAspect == option ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.04))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: DesignMetrics.radiusS)
                                            .strokeBorder(
                                                selectedAspect == option ? Color.accentColor : Color.secondary.opacity(0.18),
                                                lineWidth: selectedAspect == option ? 1.2 : 0.5
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(10)
                    .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)

                    // 5. 负面提示词 (可选，支持 AI 智能推荐)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text("负面提示词 (可选)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()

                            if previousNegativePrompt != nil {
                                Button {
                                    negativePrompt = previousNegativePrompt ?? ""
                                    previousNegativePrompt = nil
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.uturn.backward")
                                            .font(.system(size: 10))
                                        Text("撤回")
                                            .font(.system(size: 10))
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .help("撤回 AI 推荐的负面提示词")
                            }

                            Button {
                                suggestNegativePrompt()
                            } label: {
                                HStack(spacing: 4) {
                                    if isSuggestingNegative {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "wand.and.sparkles")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    Text(isSuggestingNegative ? "推荐中..." : "AI 推荐")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isSuggestingNegative || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help("根据主体描述自动生成针对性的负面提示词")
                        }

                        TextField("例如：模糊、畸形、低分辨率、水印...", text: $negativePrompt)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .padding(8)

                        if let err = negativeError {
                            Text(err)
                                .font(.system(size: 10))
                                .foregroundStyle(.red)
                                .lineLimit(2)
                        }
                    }
                    .padding(8)
                    .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)



                    // 7. 进度 / 后台任务提示区（只反映选中记录；任务在别的记录上跑则提示并可跳转）
                    if isActingOnSelection {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(currentStage.localizedText)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            if !currentMessage.isEmpty {
                                Text(currentMessage)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)
                    } else if let hint = busyElsewhereHint {
                        HStack(spacing: 8) {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text(hint)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 0)
                            Button("查看") {
                                onViewBusyBatch?()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .help("跳转到正在生成的那条记录")
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)
                    }
                }
                .padding(12)
            }

            Divider().opacity(0.2)

            // 8. 常驻底部主操作区（开始生图 / 继续修改，间距按 macOS 控件规范 8pt）
            //    状态跟随「选中记录」：只有正在生成的那条记录才显示「停止生成」
            VStack(spacing: 8) {
                if isActingOnSelection {
                    Button {
                        onStopGeneration()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.circle.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text("停止生成")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: DesignMetrics.radiusM)
                                .fill(Color.red.opacity(0.85))
                        )
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .help("中断当前生成任务并恢复待机状态")
                } else if hasSelection {
                    // 历史记录上下文：只保留「继续修改当前画面」这一个动作
                    Button {
                        onContinueEditing?()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "wand.and.rays")
                            Text("继续修改当前画面")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: DesignMetrics.radiusM)
                                .fill(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.3) : Color.accentColor)
                        )
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canContinueEditing || busyElsewhereHint != nil)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .help(continueEditingHelp)
                } else {
                    Button {
                        onGenerate()
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("开始生图")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: DesignMetrics.radiusM)
                                .fill(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.3) : Color.accentColor)
                        )
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busyElsewhereHint != nil)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help(busyElsewhereHint == nil ? "⌘↩ 开始生图" : "另一条记录正在生成，请先等待或点「查看」前往")
                }
            }
            .padding(12)
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .liquidGlassBackground(cornerRadius: DesignMetrics.radiusL)
        // 切换历史记录 / 新建画布时清空撤回栈，避免「撤回」按钮跨记录残留
        .onChange(of: contextToken) { _, _ in
            previousPrompt = nil
            previousNegativePrompt = nil
            polishError = nil
            negativeError = nil
        }
    }

    // MARK: - 参考图放大查看 Sheet
    private func referenceViewerSheet(path: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button {
                    showRefViewer = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().opacity(0.15)

            if let img = NSImage(contentsOfFile: path) {
                GeometryReader { geo in
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .padding(12)
            } else {
                VStack {
                    Image(systemName: "photo")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("图片读取失败")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 640, height: 560)
    }

    // MARK: - 选择参考图
    private func pickReferenceImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .bmp, .gif]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择一张参考图"
        panel.prompt = "选择"

        if panel.runModal() == .OK, let url = panel.url {
            referenceImagePath = url.path
        }
    }

    // MARK: - 负面提示词 AI 推荐
    private func suggestNegativePrompt() {
        let base = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !isSuggestingNegative else { return }

        negativeError = nil
        isSuggestingNegative = true
        let originalNegative = negativePrompt

        Task {
            do {
                let suggestion = try await GeminiSSEClient.shared.suggestNegativePrompt(
                    prompt: base,
                    style: selectedStyle.rawValue,
                    customApiKey: useCustomAI ? customApiKey : "",
                    customBaseUrl: useCustomAI ? customBaseUrl : "",
                    customModel: useCustomAI ? customModel : "",
                    port: SidecarManager.shared.serverPort
                )
                await MainActor.run {
                    previousNegativePrompt = originalNegative
                    negativePrompt = suggestion
                    isSuggestingNegative = false
                }
            } catch {
                await MainActor.run {
                    isSuggestingNegative = false
                    negativeError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - 执行 AI 润色
    private func performAIPolish() {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isPolishing = true
        let original = prompt

        Task {
            do {
                let res = try await GeminiSSEClient.shared.polish(
                    prompt: original,
                    style: selectedStyle.rawValue,
                    customApiKey: useCustomAI ? customApiKey : "",
                    customBaseUrl: useCustomAI ? customBaseUrl : "",
                    customModel: useCustomAI ? customModel : "",
                    port: SidecarManager.shared.serverPort
                )
                await MainActor.run {
                    withAnimation(.spring(duration: 0.25)) {
                        self.previousPrompt = original
                        self.prompt = res
                    }
                    isPolishing = false
                }
            } catch {
                await MainActor.run {
                    isPolishing = false
                    self.polishError = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 原生无滚动条纯净文本输入框 (彻底消灭 macOS 顽固的白色滚动条)
struct NativePlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor.labelColor
        textView.isRichText = false
        textView.allowsUndo = true
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        if let textView = scrollView.documentView as? NSTextView {
            if textView.string != text {
                textView.string = text
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativePlainTextEditor
        init(_ parent: NativePlainTextEditor) {
            self.parent = parent
        }
        func textDidChange(_ notification: Notification) {
            if let textView = notification.object as? NSTextView {
                self.parent.text = textView.string
            }
        }
    }
}
