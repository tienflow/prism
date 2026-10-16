import Foundation

// MARK: - 宽高比例枚举
public enum AspectRatioOption: String, CaseIterable, Identifiable, Sendable {
    case square = "1:1"
    case landscape = "16:9"
    case portrait = "9:16"
    case standardLandscape = "4:3"
    case standardPortrait = "3:4"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .square: return "1:1 正方"
        case .landscape: return "16:9 宽屏"
        case .portrait: return "9:16 竖屏"
        case .standardLandscape: return "4:3 横版"
        case .standardPortrait: return "3:4 竖版"
        }
    }

    public var systemIcon: String {
        switch self {
        case .square: return "square"
        case .landscape: return "rectangle.ratio.16.to.9"
        case .portrait: return "rectangle.portrait"
        case .standardLandscape: return "rectangle.ratio.4.to.3"
        case .standardPortrait: return "rectangle.portrait"
        }
    }

    /// 供 TypeSafe Jev 判定层使用的选项描述。
    /// Jev 不认识「包豪斯极简」这类专名，必须给出可独立理解的判据；
    /// 单一数据源在 Swift 侧，随请求下发给 Sidecar，避免与 Python 副本漂移。
    public var criteriaHint: String {
        switch self {
        case .square: return "方形构图，适合头像、单品、图标"
        case .landscape: return "横构图，适合风景、全景场景、桌面壁纸"
        case .portrait: return "竖构图，适合手机壁纸、全身人像、竖屏短视频"
        case .standardLandscape: return "标准横构图，适合静物、日常场景"
        case .standardPortrait: return "竖构图，适合半身人像、海报、书籍封面"
        }
    }
}

// MARK: - 艺术风格上下文枚举 (不侵入主提示词，作为独立画风上下文)
public enum ArtStyleOption: String, CaseIterable, Identifiable, Sendable {
    case none = "无预设"
    case cyberpunk = "赛博朋克"
    case anime = "吉卜力动漫"
    case claymation = "3D 潮玩手办"
    case cinematic = "电影胶片肖像"
    case photorealistic = "超清写实摄影"
    case conceptArt = "游戏概念插画"
    case bauhaus = "包豪斯极简"
    case inkWash = "东方空灵水墨"
    case pixelArt = "复古像素艺术"
    case darkFantasy = "暗黑哥特奇幻"
    case watercolor = "柔和水彩手绘"
    case oilPainting = "经典油画大师"
    case paperCut = "3D 立体剪纸"
    case flatVector = "扁平矢量插画"
    case surrealism = "超现实主义"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .none: return "slash.circle"
        case .cyberpunk: return "sparkles"
        case .anime: return "paintpalette"
        case .claymation: return "cube.fill"
        case .cinematic: return "camera.aperture"
        case .photorealistic: return "camera.macro"
        case .conceptArt: return "wand.and.stars"
        case .bauhaus: return "square.2.layers.3d"
        case .inkWash: return "mountain.2"
        case .pixelArt: return "square.grid.3x3.square"
        case .darkFantasy: return "moon.stars"
        case .watercolor: return "drop.fill"
        case .oilPainting: return "paintbrush.pointed.fill"
        case .paperCut: return "scissors"
        case .flatVector: return "square.grid.2x2"
        case .surrealism: return "eye.circle"
        }
    }

    public var contextSuffix: String {
        switch self {
        case .none:
            return ""
        case .cyberpunk:
            return "8k photorealistic, futuristic cyberpunk city, volumetric neon rim lighting, cinematic rain reflections"
        case .anime:
            return "Studio Ghibli aesthetic, anime scenery, lush landscape, soft hand-painted watercolor, nostalgic, peaceful"
        case .claymation:
            return "Cute claymation 3d toy figurine, soft studio lighting, macro depth of field, octane render 3d"
        case .cinematic:
            return "Cinematic 85mm portrait photography, chiaroscuro rim lighting, shallow depth of field, 35mm film grain, masterpiece"
        case .photorealistic:
            return "Photorealistic 8k, shot on Hasselblad, studio lighting, natural skin and textures, ultra-detailed, sharp focus"
        case .conceptArt:
            return "Epic digital concept art, Artstation trending, dramatic scale, atmospheric volumetric lighting, rich details"
        case .bauhaus:
            return "Minimalist industrial design, Bauhaus geometry, frosted matte acrylic, soft architectural shadows, clean aesthetic"
        case .inkWash:
            return "Traditional Chinese ink wash painting, ethereal misty mountains, gold dust accents, poetic negative space"
        case .pixelArt:
            return "16-bit retro pixel art aesthetic, vibrant color palette, nostalgic game style, clean pixel dithering"
        case .darkFantasy:
            return "Dark fantasy gothic aesthetic, dramatic shadows, mysterious fog, moonlit ambiance, intricate textures"
        case .watercolor:
            return "Delicate watercolor illustration, gentle paper texture, soft blended pastel colors, artistic elegance"
        case .oilPainting:
            return "Classical oil painting masterpiece, rich impasto texture, visible expressive brushstrokes, museum quality, dramatic lighting"
        case .paperCut:
            return "Intricate 3D layered papercut art, delicate shadow play, tactile craft textures, paper sculpture depth"
        case .flatVector:
            return "Modern vector illustration, vibrant clean color palette, stylish minimalist geometric shapes, trendy editorial art"
        case .surrealism:
            return "Surrealist dreamscape art, metaphysical atmosphere, floating impossible elements, poetic visual metaphor"
        }
    }

    /// 供 TypeSafe Jev 判定层使用的选项描述（中文；Jev 不认识「东方空灵水墨」这类专名，
    /// 判据必须自解释）。此表是单一数据源，随请求下发给 Sidecar。
    public var criteriaHint: String {
        switch self {
        case .none: return "不指定画风，交由生图模型自然发挥"
        case .cyberpunk: return "霓虹高对比、未来都市、机械义体、冷色调电子光"
        case .anime: return "日式手绘动画、柔和自然光、宫崎骏风格"
        case .claymation: return "盲盒手办质感、圆润塑料光泽、C4D 渲染"
        case .cinematic: return "电影级打光、浅景深、胶片颗粒、人像特写"
        case .photorealistic: return "真实照片质感、高分辨率、自然光影"
        case .conceptArt: return "概念设定图、厚涂笔触、戏剧性构图"
        case .bauhaus: return "几何构成、原色块、无装饰的现代主义平面设计"
        case .inkWash: return "中国水墨、大量留白、宣纸肌理、淡墨晕染"
        case .pixelArt: return "8/16 位像素点阵、低分辨率复古游戏画面"
        case .darkFantasy: return "阴郁暗调、哥特建筑、奇幻生物、宗教感"
        case .watercolor: return "水彩晕染、透明叠色、纸纹、轻盈"
        case .oilPainting: return "古典油画厚涂、伦勃朗光、画布肌理"
        case .paperCut: return "多层纸雕、真实纸张厚度、剪影层次"
        case .flatVector: return "矢量色块、扁平化、粗描边或无描边"
        case .surrealism: return "梦境逻辑、物体错置、达利式荒诞"
        }
    }
}

// MARK: - 任务阶段
public enum GenerationStage: String, Codable, Sendable {
    case idle
    case connecting
    case sessionReady = "session_ready"
    case submitting
    case generating
    case downloading
    case completed
    case error

    public var localizedText: String {
        switch self {
        case .idle: return "就绪"
        case .connecting: return "连接中..."
        case .sessionReady: return "会话就绪"
        case .submitting: return "已提交提示词"
        case .generating: return "Imagen 3 原生渲染中"
        case .downloading: return "正在下载 CDN 超清原图"
        case .completed: return "生成完成"
        case .error: return "发生错误"
        }
    }

    /// 生成链路的四个阶段序号（用于参数栏的细粒度进度条）：
    /// 1 连接 → 2 提交 → 3 渲染 → 4 下载。就绪 / 出错记为 0。
    public var progressStep: Int {
        switch self {
        case .idle, .error: return 0
        case .connecting, .sessionReady: return 1
        case .submitting: return 2
        case .generating: return 3
        case .downloading, .completed: return 4
        }
    }
}

// MARK: - 单轮改图记录（继续修改：指令 → 产出图）
public struct EditTurn: Identifiable, Codable, Sendable, Hashable {
    public let id: UUID
    /// 本轮发给模型的修改指令
    public let instruction: String
    /// 本轮产出的图片路径
    public let imagePath: String
    /// 产出时间
    public let createdAt: Date
    /// 本轮使用的画幅比例（旧数据为 nil，展示时回退到记录级）
    public var aspectRatio: String?
    /// 本轮使用的画风
    public var style: String?
    /// 本轮使用的负面提示词
    public var negativePrompt: String?
    /// 所属改图轮次（0 基）。单次改图可能返回多张候选，它们共享同一轮次编号；
    /// 旧数据为 nil，展示时回退为数组下标（旧数据每轮仅一张，下标即轮次）。
    public var roundIndex: Int?

    public init(
        id: UUID = UUID(),
        instruction: String,
        imagePath: String,
        createdAt: Date = Date(),
        aspectRatio: String? = nil,
        style: String? = nil,
        negativePrompt: String? = nil,
        roundIndex: Int? = nil
    ) {
        self.id = id
        self.instruction = instruction
        self.imagePath = imagePath
        self.createdAt = createdAt
        self.aspectRatio = aspectRatio
        self.style = style
        self.negativePrompt = negativePrompt
        self.roundIndex = roundIndex
    }
}

// MARK: - 单次生成任务历史记录
public struct GenerationBatch: Identifiable, Codable, Sendable {
    public let id: UUID
    public let prompt: String
    public let negativePrompt: String
    public let aspectRatio: String
    public let style: String?
    public var stage: GenerationStage
    public var statusMessage: String
    public var imagePaths: [String]
    public let createdAt: Date
    /// 本批次生成时使用的参考图（nil 表示无参考图）
    public var referenceImagePath: String?
    /// 本批次内各图片的 AI 描述缓存（图片路径 → 描述文本），随 history.json 持久化
    public var aiDescriptions: [String: String]?
    /// 多轮改图会话 ID（存在即表示该批次可继续以对话方式修改）
    public var sessionId: String?
    /// 逐轮改图记录（指令 + 产出图），随 history.json 持久化；用于展示「原图 / 改 1 / 改 2 …」稿次
    public var editTurns: [EditTurn]?

    public init(
        id: UUID = UUID(),
        prompt: String,
        negativePrompt: String = "",
        aspectRatio: String = "1:1",
        style: String? = nil,
        stage: GenerationStage = .idle,
        statusMessage: String = "",
        imagePaths: [String] = [],
        createdAt: Date = Date(),
        referenceImagePath: String? = nil,
        aiDescriptions: [String: String]? = nil,
        sessionId: String? = nil,
        editTurns: [EditTurn]? = nil
    ) {
        self.id = id
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.aspectRatio = aspectRatio
        self.style = style
        self.stage = stage
        self.statusMessage = statusMessage
        self.imagePaths = imagePaths
        self.createdAt = createdAt
        self.referenceImagePath = referenceImagePath
        self.aiDescriptions = aiDescriptions
        self.sessionId = sessionId
        self.editTurns = editTurns
    }

    /// 第 pos 条 EditTurn 所属的轮次编号（0 基）。同轮多候选共享同一编号；
    /// 旧数据 roundIndex 为 nil，回退为数组下标。
    public func turnRoundIndex(atTurnOffset pos: Int) -> Int {
        guard let turns = editTurns, turns.indices.contains(pos) else { return pos }
        return turns[pos].roundIndex ?? pos
    }

    /// 该批次内第 index 张图所属的轮次编号（0 基）；原图或无记录时返回 nil
    public func turnRound(at index: Int) -> Int? {
        guard imagePaths.indices.contains(index),
              let pos = editTurns?.firstIndex(where: { $0.imagePath == imagePaths[index] }) else { return nil }
        return turnRoundIndex(atTurnOffset: pos)
    }

    /// 该批次内第 index 张图的稿次标签（原图 / 改 1 / 改 2 …）
    /// 同一次改图返回的多张候选共享同一个「改 n」，不会被切成多个轮次。
    public func turnLabel(at index: Int) -> String {
        guard imagePaths.indices.contains(index) else { return "—" }
        if let round = turnRound(at: index) {
            return "改 \(round + 1)"
        }
        return "原图"
    }

    /// 该批次内第 index 张图对应的改图指令（原图或无记录时返回 nil）
    public func turnInstruction(at index: Int) -> String? {
        guard imagePaths.indices.contains(index) else { return nil }
        return editTurns?.first(where: { $0.imagePath == imagePaths[index] })?.instruction
    }

    /// 该批次内第 index 张图的参数快照（比例 / 画风 / 负面词）
    /// 改稿取该轮记录值；原图或旧数据（字段为 nil）回退到记录级参数
    public func turnSnapshot(at index: Int) -> (aspectRatio: String, style: String?, negativePrompt: String) {
        guard imagePaths.indices.contains(index) else { return (aspectRatio, style, negativePrompt) }
        if let turn = editTurns?.first(where: { $0.imagePath == imagePaths[index] }) {
            return (turn.aspectRatio ?? aspectRatio, turn.style ?? style, turn.negativePrompt ?? negativePrompt)
        }
        return (aspectRatio, style, negativePrompt)
    }
}
