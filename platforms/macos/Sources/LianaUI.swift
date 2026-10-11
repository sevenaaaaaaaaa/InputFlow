import AppKit
import SwiftUI

// MARK: - 松萝设计语言（ADR-0003：苹果平台用原生 Liquid Glass，旧系统回退材质）
//
// 所有新界面（设置中心 / 功能面板 / 提示气泡）都从这里取材质与按钮样式，
// 保证 macOS 26 上统一是系统 Liquid Glass，macOS 13–15 上是同源的毛玻璃。

enum LianaDesign {
    static let radiusLarge: CGFloat = 26
    static let radiusMedium: CGFloat = 18
    static let radiusSmall: CGFloat = 12

    /// 品牌色（design-tokens: --accent oklch(62% 0.14 250) 的 sRGB 近似）。
    static let brand = Color(red: 0.25, green: 0.52, blue: 0.93)
    /// 松萝绿：品牌辅色，用于「学习 / 生长」类功能。
    static let pine = Color(red: 0.20, green: 0.68, blue: 0.52)
}

@available(macOS 26.0, *)
private func lianaGlassValue(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint {
        glass = glass.tint(tint)
    }
    if interactive {
        glass = glass.interactive()
    }
    return glass
}

extension View {
    /// 玻璃底：macOS 26 用系统 Liquid Glass；旧系统用超薄材质 + 高光描边近似。
    @ViewBuilder
    func lianaGlass(
        cornerRadius: CGFloat = LianaDesign.radiusMedium,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                lianaGlassValue(tint: tint, interactive: interactive),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .background(
                    (tint ?? Color.clear).opacity(0.18),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.8)
                )
        }
    }

    /// 主按钮：macOS 26 为 glassProminent，旧系统为 borderedProminent。
    @ViewBuilder
    func lianaProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    /// 次按钮：macOS 26 为 glass，旧系统为 bordered。
    @ViewBuilder
    func lianaGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

/// 圆角渐变图标底座（设置中心侧栏 / 功能面板磁贴共用），系统设置同款视觉语言。
struct LianaIconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.95), color.opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Image(systemName: symbol)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(Color.white)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - AppKit 玻璃容器

/// 非激活面板里的 SwiftUI 宿主：第一下点击就生效（不先被「激活窗口」吞掉）。
final class LianaFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 可成为 key 的无边框面板（无边框 NSPanel 默认不能成为 key，文本框收不到输入）。
final class LianaKeyablePanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

enum LianaGlassContainer {
    /// 把内容包进玻璃：macOS 26 用 NSGlassEffectView，旧系统用 HUD 毛玻璃。
    static func wrap(_ content: NSView, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            content.autoresizingMask = [.width, .height]
            glass.contentView = content
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        return effect
    }

    /// 浮层玻璃面板：不激活本进程（焦点留在用户正在打字的应用里）。
    static func makePanel(size: NSSize, cornerRadius: CGFloat, content: NSView) -> LianaKeyablePanel {
        let panel = LianaKeyablePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let container = wrap(content, cornerRadius: cornerRadius)
        container.frame = NSRect(origin: .zero, size: size)
        container.autoresizingMask = [.width, .height]
        panel.contentView = container
        return panel
    }

    /// 屏幕定位：优先贴在光标下方，放不下就放上方；没有光标位置时居中偏上。
    static func position(_ panel: NSPanel, near caret: NSRect?) {
        let size = panel.frame.size
        let screen = caret.flatMap { rect in
            NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        var origin: NSPoint
        if let caret, caret.origin.x.isFinite, caret.origin.y.isFinite, caret != .zero {
            origin = NSPoint(x: caret.minX - 24, y: caret.minY - size.height - 10)
            if origin.y < visible.minY {
                origin.y = caret.maxY + 10
            }
        } else {
            origin = NSPoint(
                x: visible.midX - size.width / 2,
                y: visible.minY + visible.height * 0.62 - size.height / 2
            )
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }
}

// MARK: - 玻璃提示气泡（不依赖桌宠）

/// 屏幕顶部居中的玻璃气泡。桌宠关闭时，语音/同传/截图学习的反馈也必须看得到。
final class GlassToast {
    static let shared = GlassToast()

    private var panel: LianaKeyablePanel?
    private var host: NSHostingView<GlassToastView>?
    private var hideWork: DispatchWorkItem?
    /// 每次 show 递增：淡出动画的回调只收起「自己那一代」的气泡。
    private var generation = 0

    func show(_ text: String, symbol: String = "sparkles", duration: TimeInterval = 3.5) {
        generation += 1
        let view = GlassToastView(text: text, symbol: symbol)
        let size = Self.measure(text)
        if let panel, let host {
            host.rootView = view
            panel.setContentSize(size)
        } else {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: size)
            let panel = LianaGlassContainer.makePanel(size: size, cornerRadius: size.height / 2, content: host)
            panel.ignoresMouseEvents = true
            panel.level = .statusBar
            self.panel = panel
            self.host = host
        }
        guard let panel else { return }
        if #available(macOS 26.0, *), let glass = panel.contentView as? NSGlassEffectView {
            glass.cornerRadius = size.height / 2
        } else {
            panel.contentView?.layer?.cornerRadius = size.height / 2
        }
        if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 14))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 1
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    func hide() {
        guard let panel else { return }
        let current = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == current else { return }
            panel.orderOut(nil)
        })
    }

    private static func measure(_ text: String) -> NSSize {
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let maxWidth: CGFloat = 420
        let rect = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth, height: 400),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let width = min(maxWidth, ceil(rect.width)) + 64
        let height = max(40, ceil(rect.height) + 22)
        return NSSize(width: max(160, width), height: height)
    }
}

struct GlassToastView: View {
    let text: String
    let symbol: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LianaDesign.brand)
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(4)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
