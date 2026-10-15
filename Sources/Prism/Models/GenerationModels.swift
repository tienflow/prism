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
        aiDescriptions: [String: String]? = nil
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
    }
}
