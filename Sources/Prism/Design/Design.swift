import SwiftUI
import AppKit

// MARK: - 1. 统一设计度量 (Design Metrics)
public enum DesignMetrics {
    // 圆角标尺
    public static let radiusS: CGFloat = 6    // 按钮、Tag、选项 Pills
    public static let radiusM: CGFloat = 10   // 输入框卡片、参数 Card
    public static let radiusL: CGFloat = 16   // 浮岛主面板、画廊画布、检视栏

    // 交互态 Alpha 规范
    public static let hoverAlpha: Double = 0.08
    public static let selectedAlpha: Double = 0.16
}

// MARK: - 2. macOS 26 玻璃样式映射
public enum LiquidGlassStyle: Sendable {
    case regular
    case clear

    @available(macOS 26.0, *)
    var systemStyle: NSGlassEffectView.Style {
        switch self {
        case .regular: return .regular
        case .clear: return .clear
        }
    }
}

// MARK: - 3. macOS 26 原生玻璃背景 (带向下优雅降级)
public struct GlassEffectBackground: NSViewRepresentable {
    public var style: LiquidGlassStyle
    public var cornerRadius: CGFloat
    public var tintColor: NSColor?
    public var enableScrim: Bool

    public init(
        style: LiquidGlassStyle = .regular,
        cornerRadius: CGFloat = DesignMetrics.radiusL,
        tintColor: NSColor? = nil,
        enableScrim: Bool = true
    ) {
        self.style = style
        self.cornerRadius = cornerRadius
        self.tintColor = tintColor
        self.enableScrim = enableScrim
    }

    public func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = style.systemStyle
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
            if enableScrim, glass.responds(to: NSSelectorFromString("set_scrimState:")) {
                glass.setValue(1, forKey: "_scrimState")
            }
            return glass
        } else {
            // 向下兼容低版本 macOS
            let view = NSVisualEffectView()
            view.material = (style == .clear) ? .contentBackground : .popover
            view.blendingMode = .behindWindow
            view.state = .active
            view.wantsLayer = true
            if cornerRadius > 0 {
                view.layer?.cornerRadius = cornerRadius
                view.layer?.masksToBounds = true
            }
            return view
        }
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26.0, *), let glass = nsView as? NSGlassEffectView {
            glass.style = style.systemStyle
            glass.cornerRadius = cornerRadius
            glass.tintColor = tintColor
            if enableScrim, glass.responds(to: NSSelectorFromString("set_scrimState:")) {
                glass.setValue(1, forKey: "_scrimState")
            }
        } else if let view = nsView as? NSVisualEffectView {
            if cornerRadius > 0 {
                view.layer?.cornerRadius = cornerRadius
                view.layer?.masksToBounds = true
            } else {
                view.layer?.cornerRadius = 0
                view.layer?.masksToBounds = false
            }
        }
    }
}

// MARK: - 4. 光学融合容器 (NSGlassEffectContainerView)
public struct GlassEffectContainer<Content: View>: NSViewRepresentable {
    public var spacing: CGFloat
    public var content: () -> Content

    public init(spacing: CGFloat = 0, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    public func makeNSView(context: Context) -> NSView {
        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView()
            container.spacing = spacing
            container.contentView = NSHostingView(rootView: content())
            return container
        } else {
            return NSHostingView(rootView: content())
        }
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        if #available(macOS 26.0, *), let container = nsView as? NSGlassEffectContainerView {
            container.spacing = spacing
            if let hosting = container.contentView as? NSHostingView<Content> {
                hosting.rootView = content()
            }
        } else if let hosting = nsView as? NSHostingView<Content> {
            hosting.rootView = content()
        }
    }
}

// MARK: - 5. SwiftUI 修饰符 (双层衬底防灰与卡片防耀斑规范)
public struct LiquidGlassBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    public var cornerRadius: CGFloat = DesignMetrics.radiusL
    public var style: LiquidGlassStyle = .regular
    public var tintColor: NSColor? = nil

    public func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    // 1. 底层：垫在玻璃背后的系统材质衬底（浅色模式采用明快柔和的近白暖灰 #F6F6F8，深色模式采用深邃系统底色）
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(
                            colorScheme == .dark
                                ? Color(NSColor.windowBackgroundColor).opacity(0.90)
                                : Color(red: 0.965, green: 0.965, blue: 0.972).opacity(0.95)
                        )
                    // 2. 表层：原生 macOS 26 NSGlassEffectView
                    GlassEffectBackground(
                        style: style,
                        cornerRadius: cornerRadius,
                        tintColor: tintColor,
                        enableScrim: colorScheme == .dark
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

public struct LiquidGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    public var cornerRadius: CGFloat = DesignMetrics.radiusM

    public func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.secondary.opacity(colorScheme == .dark ? 0.12 : 0.045))
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(
                        Color(NSColor.separatorColor).opacity(colorScheme == .dark ? 0.35 : 0.18),
                        lineWidth: 0.5
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

public extension View {
    func liquidGlassBackground(
        cornerRadius: CGFloat = DesignMetrics.radiusL,
        style: LiquidGlassStyle = .regular,
        tintColor: NSColor? = nil
    ) -> some View {
        modifier(LiquidGlassBackgroundModifier(cornerRadius: cornerRadius, style: style, tintColor: tintColor))
    }

    func liquidGlassCard(cornerRadius: CGFloat = DesignMetrics.radiusM) -> some View {
        modifier(LiquidGlassCardModifier(cornerRadius: cornerRadius))
    }
}
