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
    /// 选中记录的**画面描述**（历史上下文下描述框是「修改指令」位、可能为空；
    /// 配参与负面词看的是画面长什么样，不能用修改指令）。优先是该图的 AI 描述。
    public var selectedPromptText: String = ""
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
    /// 描述框里仍是上一轮已用过的文字（尚未修改）——用于解释主按钮为何置灰
    public var promptIsConsumedBaseline: Bool = false
    /// 触发「继续修改」（多轮会话改图）
    public var onContinueEditing: (() -> Void)?

    @State private var isStylesExpanded: Bool = false

    /// 画风网格的展示顺序（常用优先）；初始沿用枚举原顺序，视图出现后再按统计刷新
    @State private var rankedStyles: [ArtStyleOption] = ArtStyleOption.allCases

    /// 生成链路的四个阶段标签（与 `GenerationStage.progressStep` 一一对应）
    private static let generationStepLabels = ["连接", "提交", "渲染", "下载"]

    // AI 一条龙（润色 + 配参 + 负面词）：一次点击跑完三步，配一个统一撤回
    @State private var isOptimizing: Bool = false
    @State private var optimizeStage: String = ""
    @State private var optimizeSnapshot: OptimizeSnapshot? = nil
    @State private var optimizeResult: GeminiSSEClient.OptimizeResult? = nil
    @State private var optimizeError: String? = nil

    /// AI 优化改写前的四项前值（统一撤回用）
    private struct OptimizeSnapshot {
        var prompt: String
        var style: ArtStyleOption
        var aspect: AspectRatioOption
        var negativePrompt: String
    }

    // 负面提示词单项重推（负面词的独立入口；一条龙也会填它）
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
        selectedPromptText: String = "",
        currentStage: GenerationStage,
        currentMessage: String,
        onGenerate: @escaping () -> Void,
        onStopGeneration: @escaping () -> Void = {},
        canContinueEditing: Bool = false,
        promptIsConsumedBaseline: Bool = false,
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
        self.selectedPromptText = selectedPromptText
        self.busyElsewhereHint = busyElsewhereHint
        self.onViewBusyBatch = onViewBusyBatch
        self.currentStage = currentStage
        self.currentMessage = currentMessage
        self.onGenerate = onGenerate
        self.onStopGeneration = onStopGeneration
        self.canContinueEditing = canContinueEditing
        self.promptIsConsumedBaseline = promptIsConsumedBaseline
        self.onContinueEditing = onContinueEditing
        self.onDescribeReference = onDescribeReference
        self.contextToken = contextToken
    }

    /// 底部「继续修改当前画面」按钮的提示文案（禁用时说明原因）
    private var continueEditingHelp: String {
        // 多任务并行：别的记录在跑不再阻止本记录的改图
        if promptIsConsumedBaseline { return "描述框里还是上一轮用过的文字，改一下才能作为新的修改指令发送" }
        if !canContinueEditing { return "需要一条已有画面的记录，并在描述框里写修改要求（⌘⇧↩）" }
        return "在同一会话中继续修改选中的画面（⌘⇧↩），描述框里写修改要求"
    }

    /// 画风网格顺序：常用优先（「无预设」固定首位）。
    /// `rankedStyles` 只在切换输入上下文时重算 —— 点选当下不重排，避免刚点的按钮从眼皮底下跳走。
    private var displayedStyles: [ArtStyleOption] {
        if isStylesExpanded {
            return rankedStyles
        } else {
            var base = Array(rankedStyles.prefix(6))
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

                    // 1.5 未连接 Google 账号时的提示（此前 hasAuth / onOpenAuth 声明后从未使用）
                    if !hasAuth {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                            Text("未连接 Google 账号，暂时无法生图")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Button("去连接") {
                                onOpenAuth()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .liquidGlassCard(cornerRadius: DesignMetrics.radiusS)
                        .help("可同步 Chrome 凭据，或使用内嵌窗口登录 Google")
                    }

                    // 2. 中文主提示词 (Prompt) 区域：集成清空、撤回与 AI 润色
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            // 选中历史记录时，这个输入框是「修改指令」而非主体描述，
                            // 标题随上下文切换，避免把两种情况混淆
                            Text(hasSelection ? "修改指令（基于当前画面）" : "主体描述 (Prompt)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        ZStack(alignment: .topLeading) {
                            NativePlainTextEditor(text: $prompt)
                                .frame(minHeight: 80, maxHeight: 110)
                                .padding(4)

                            if prompt.isEmpty {
                                Text(hasSelection
                                     ? "输入修改要求，例：把天空换成黄昏、给人物加一顶草帽"
                                     : "描述你想画的画面，例：江南暮雨迷蒙的青石巷深处")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 9)
                                    .padding(.top, 5)
                                    .allowsHitTesting(false)
                            }
                        }

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

                            // 统一撤回：一次恢复描述 / 画风 / 比例 / 负面词
                            if optimizeSnapshot != nil {
                                Button {
                                    revertOptimize()
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
                                .help("恢复到 AI 优化前的描述、画风、比例与负面词")
                                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                            }

                            // AI 优化（一条龙）：润色描述 → 判定画风与比例 → 推荐负面提示词。
                            // 选中历史记录时描述框是「修改指令」，此时只润色指令、不动参数。
                            Button {
                                runAIOptimize()
                            } label: {
                                HStack(spacing: 4) {
                                    if isOptimizing {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else {
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 10, weight: .bold))
                                    }
                                    Text(isOptimizing
                                         ? (optimizeStage.isEmpty ? "优化中..." : optimizeStage)
                                         : (hasSelection ? "AI 润色" : "AI 优化"))
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.1))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isOptimizing || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help(aiOptimizeHelp)
                        }
                    }
                    .padding(8)
                    .liquidGlassCard(cornerRadius: DesignMetrics.radiusM)

                    // 2.2 AI 优化结果行（紧随触发按钮，常驻到撤回为止；把握一般时给次选可点）
                    if optimizeResult != nil || optimizeError != nil {
                        VStack(alignment: .leading, spacing: 5) {
                            if let r = optimizeResult, let stylePick = r.style {
                                HStack(spacing: 6) {
                                    Image(systemName: selectedStyle.icon)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.accentColor)
                                    Text("AI 优化：\(selectedStyle.rawValue) · \(selectedAspect.rawValue)")
                                        .font(.system(size: 10, weight: .medium))
                                        .lineLimit(1)

                                    Spacer(minLength: 4)

                                    if let ru = stylePick.runnerUp,
                                       ru != selectedStyle.rawValue,
                                       stylePick.runnerUpProbability >= 0.2,
                                       let alt = ArtStyleOption(rawValue: ru) {
                                        Button {
                                            withAnimation(.spring(duration: 0.2)) { selectedStyle = alt }
                                            StyleUsageStore.record(alt)
                                        } label: {
                                            Text("改画风 \(ru)")
                                                .font(.system(size: 10, weight: .medium))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 3)
                                                .background(Color.secondary.opacity(0.12))
                                                .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                        .help("AI 认为这个描述也有 \(Int(stylePick.runnerUpProbability * 100))% 的把握属于该画风")
                                    }
                                }

                                if r.negativePrompt != nil {
                                    Text("负面提示词已一并填入")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            ForEach(Array(optimizeNotices.enumerated()), id: \.offset) { _, notice in
                                Text(notice)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                                    .lineLimit(2)
                            }

                            if let err = optimizeError {
                                Text(err)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.orange)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .liquidGlassCard(cornerRadius: DesignMetrics.radiusS)
                    }
                    // 2.5 参考图上传区 (参考图生图)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("参考图 (可选)")
                                .font(.caption)
                            Spacer()
                            if referenceImagePath != nil {
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
                                    StyleUsageStore.record(style)
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
                            .disabled(isSuggestingNegative || negativeSourceDescription.isEmpty)
                            .help(negativeSourceDescription.isEmpty
                                  ? "先写下画面描述（或选中一条历史记录），AI 才能推荐负面词"
                                  : "根据画面描述生成针对性的负面提示词（不看修改指令）")
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
                        // 概览位：画布中央已经有大号状态与详细文案，这里只做「走到第几步」，
                        // 不再复读同一句话；也不再重复放停止按钮（画布中央与顶栏各有一个入口）。
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.mini)
                                Text(currentStage.localizedText)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                                    .lineLimit(1)
                            }

                            // 四段式阶段进度（无真实百分比可报，故按阶段推进）
                            HStack(spacing: 4) {
                                ForEach(1...4, id: \.self) { step in
                                    Capsule()
                                        .fill(step <= currentStage.progressStep
                                              ? Color.accentColor
                                              : Color.secondary.opacity(0.18))
                                        .frame(height: 3)
                                }
                            }

                            HStack(spacing: 4) {
                                ForEach(Array(Self.generationStepLabels.enumerated()), id: \.offset) { index, label in
                                    Text(label)
                                        .font(.system(size: 9))
                                        .foregroundStyle(index + 1 <= currentStage.progressStep
                                                         ? Color.secondary
                                                         : Color.secondary.opacity(0.45))
                                        .frame(maxWidth: .infinity)
                                }
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
                            // 后台任务跑在别的记录上时，这里也必须能停 ——
                            // 否则一旦切走，全界面就没有任何停止入口了
                            Button("停止") {
                                onStopGeneration()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.red.opacity(0.85))
                            .help("中断这条记录的后台渲染任务")
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
                    if promptIsConsumedBaseline {
                        HStack(spacing: 5) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                            Text("描述框里是上一轮用过的文字，改一下才能作为新的修改指令")
                                .font(.system(size: 10))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(.secondary)
                    }
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
                    .disabled(!canContinueEditing)   // 多任务并行：别的记录在跑不阻止本记录
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
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .help("⌘↩ 开始生图（可与其他任务并行）")
                }
            }
            .padding(12)
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .liquidGlassBackground(cornerRadius: DesignMetrics.radiusL)
        // 切换历史记录 / 新建画布时清空撤回栈，避免「撤回」按钮跨记录残留
        .onChange(of: contextToken) { _, _ in
            previousNegativePrompt = nil
            negativeError = nil
            // 换输入上下文（切历史记录 / 新建画布）时清掉 AI 优化结果与统一撤回点
            optimizeSnapshot = nil
            optimizeResult = nil
            optimizeError = nil
            optimizeStage = ""
            // 此时重算画风顺序：统计已生效，但不会打断正在进行的点选
            rankedStyles = StyleUsageStore.rankedStyles()
        }
        .task {
            rankedStyles = StyleUsageStore.rankedStyles()
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

    // MARK: - AI 一条龙：润色 + 配参 + 负面提示词

    /// 「AI 优化」按钮的提示文案（禁用时说明原因）
    private var aiOptimizeHelp: String {
        if isOptimizing { return "AI 正在处理，请稍候" }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "先写下画面描述，AI 再据此优化"
        }
        if hasSelection {
            return "只润色这段修改指令（保持指令形态），不动画风与比例"
        }
        return "一次完成三件事：丰富画面描述、判定画风与画幅比例、生成负面提示词（可一键撤回）"
    }

    /// 分步失败提示：任一步失败都不阻断其余步骤，逐条说明缺哪一步
    private var optimizeNotices: [String] {
        guard let r = optimizeResult else { return [] }
        var notices: [String] = []
        if let e = r.polishError { notices.append("描述未润色：\(e)") }
        if let e = r.paramsError { notices.append("画风与比例未判定：\(e)") }
        if let e = r.negativeError { notices.append("负面提示词未生成：\(e)") }
        return notices
    }

    /// 入口：新画布跑一条龙；历史上下文只润色「修改指令」
    /// （用户裁定：历史里不需要动参数，一条龙的配参/负面词留给新画布）
    private func runAIOptimize() {
        guard !isOptimizing else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if hasSelection {
            runPolishOnly(text)
        } else {
            runOptimizeAll(text)
        }
    }

    /// 一条龙：润色主体描述 → 配参 + 负面词（后两步由 Sidecar 并发执行）
    private func runOptimizeAll(_ text: String) {
        isOptimizing = true
        optimizeStage = ""
        optimizeError = nil

        let styleMap = Dictionary(uniqueKeysWithValues: ArtStyleOption.allCases.map {
            ($0.rawValue, $0.criteriaHint)
        })
        let aspectMap = Dictionary(uniqueKeysWithValues: AspectRatioOption.allCases.map {
            ($0.rawValue, $0.criteriaHint)
        })

        Task {
            do {
                let result = try await GeminiSSEClient.shared.optimizeAll(
                    description: text,
                    style: selectedStyle.rawValue,
                    styles: styleMap,
                    aspects: aspectMap,
                    customApiKey: useCustomAI ? customApiKey : "",
                    customBaseUrl: useCustomAI ? customBaseUrl : "",
                    customModel: useCustomAI ? customModel : "",
                    hasReferenceImage: referenceImagePath != nil,
                    port: SidecarManager.shared.serverPort,
                    onStage: { message in
                        Task { @MainActor in
                            optimizeStage = message
                        }
                    }
                )
                await MainActor.run {
                    applyOptimizeResult(result)
                }
            } catch {
                await MainActor.run {
                    isOptimizing = false
                    optimizeStage = ""
                    optimizeError = error.localizedDescription
                }
            }
        }
    }

    /// 历史上下文：只润色「修改指令」，不动参数。
    /// 必须走 instruction 模式——用 describe 会把指令扩写成一整幅无关的画。
    private func runPolishOnly(_ text: String) {
        isOptimizing = true
        optimizeStage = "润色中..."
        optimizeError = nil

        Task {
            do {
                let polished = try await GeminiSSEClient.shared.polish(
                    prompt: text,
                    style: selectedStyle.rawValue,
                    customApiKey: useCustomAI ? customApiKey : "",
                    customBaseUrl: useCustomAI ? customBaseUrl : "",
                    customModel: useCustomAI ? customModel : "",
                    mode: "instruction",
                    port: SidecarManager.shared.serverPort
                )
                await MainActor.run {
                    optimizeSnapshot = OptimizeSnapshot(
                        prompt: prompt,
                        style: selectedStyle,
                        aspect: selectedAspect,
                        negativePrompt: negativePrompt
                    )
                    withAnimation(.spring(duration: 0.25)) {
                        prompt = polished
                    }
                    optimizeResult = nil
                    isOptimizing = false
                    optimizeStage = ""
                }
            } catch {
                await MainActor.run {
                    isOptimizing = false
                    optimizeStage = ""
                    optimizeError = error.localizedDescription
                }
            }
        }
    }

    /// 应用一条龙结果，并记录统一撤回点
    private func applyOptimizeResult(_ r: GeminiSSEClient.OptimizeResult) {
        optimizeSnapshot = OptimizeSnapshot(
            prompt: prompt,
            style: selectedStyle,
            aspect: selectedAspect,
            negativePrompt: negativePrompt
        )

        withAnimation(.spring(duration: 0.25)) {
            prompt = r.polishedPrompt
        }
        if let pick = r.style, let matched = ArtStyleOption(rawValue: pick.choice) {
            selectedStyle = matched
            StyleUsageStore.record(matched)   // 采纳 AI 的选择也算一次使用
        }
        if let pick = r.aspectRatio, let matched = AspectRatioOption(rawValue: pick.choice) {
            selectedAspect = matched
        }
        if let negative = r.negativePrompt, !negative.isEmpty {
            negativePrompt = negative
        }

        optimizeResult = r
        isOptimizing = false
        optimizeStage = ""
    }

    /// 统一撤回：一次恢复描述 / 画风 / 比例 / 负面词
    private func revertOptimize() {
        guard let snapshot = optimizeSnapshot else { return }
        withAnimation(.spring(duration: 0.25)) {
            prompt = snapshot.prompt
            selectedStyle = snapshot.style
            selectedAspect = snapshot.aspect
            negativePrompt = snapshot.negativePrompt
        }
        optimizeSnapshot = nil
        optimizeResult = nil
        optimizeError = nil
    }

    // MARK: - 负面提示词 AI 推荐
    /// 负面词的生成依据 = **画面描述**，不是修改指令。
    /// 历史上下文下描述框是「修改指令」位、可能为空，此时应回退到选中记录的画面描述。
    private var negativeSourceDescription: String {
        let typed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasSelection else { return typed }
        let base = selectedPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? typed : base
    }

    private func suggestNegativePrompt() {
        let base = negativeSourceDescription
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
