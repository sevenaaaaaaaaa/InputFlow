import AppKit
import QuartzCore

/// 候选窗：无激活面板 + Liquid Glass 背景（macOS 26+），旧系统回退 NSVisualEffectView。
/// 支持皮肤包（ThemeStore）：颜色/圆角/字号来自激活皮肤，缺省回落系统语义色。
final class CandidateWindowController {
    static let pageSize = 9

    private let panel: NSPanel
    private var background: NSView
    private let row = NSStackView()
    private let pageLabel = NSTextField(labelWithString: "")
    private var onPick: ((Int) -> Void)?
    private var theme: CandidateTheme
    private var themeObserver: NSObjectProtocol?

    private(set) var page = 0

    init() {
        let initialTheme = ThemeStore.activeTheme()
        theme = initialTheme
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 40),
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
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = false

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        row.autoresizingMask = [.width, .height]

        background = Self.makeBackground(initialTheme.current)
        applyBackground()
        panel.contentView = background

        themeObserver = NotificationCenter.default.addObserver(
            forName: ThemeStore.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadTheme()
        }
    }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    /// 切换皮肤时重建背景并让后续渲染走新主题。
    func reloadTheme() {
        theme = ThemeStore.activeTheme()
        background = Self.makeBackground(theme.current)
        applyBackground()
        panel.contentView = background
    }

    private func applyBackground() {
        background.autoresizingMask = [.width, .height]
        let side = theme.current
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.contentView = row
            if let surface = side.surface {
                glass.tintColor = surface
            }
        } else {
            background.addSubview(row)
            if let surface = side.surface {
                background.wantsLayer = true
                background.layer?.backgroundColor = surface.cgColor
            }
        }
    }

    private static func makeBackground(_ side: CandidateTheme.Side) -> NSView {
        let radius = side.radius ?? 18
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = radius
            glass.style = .regular
            glass.tintColor = side.surface ?? NSColor.windowBackgroundColor.withAlphaComponent(0.25)
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = radius
        effect.layer?.masksToBounds = true
        return effect
    }

    var isVisible: Bool { panel.isVisible }

    /// 开发用：把当前候选窗渲染成 PNG（离屏，不依赖屏幕录制权限）。
    func snapshot(to path: String) {
        panel.layoutIfNeeded()
        guard let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    /// 更新内容并定位在光标下方；没有候选时自动隐藏。
    func present(candidates: [Candidate], page newPage: Int, near lineRect: NSRect?, onPick: @escaping (Int) -> Void) {
        self.onPick = onPick
        let total = candidates.count
        guard total > 0 else {
            hide()
            return
        }
        let pageCount = max(1, Int(ceil(Double(total) / Double(Self.pageSize))))
        page = min(max(0, newPage), pageCount - 1)
        let start = page * Self.pageSize
        let slice = Array(candidates[start..<min(start + Self.pageSize, total)])

        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let side = theme.current
        for (offset, candidate) in slice.enumerated() {
            let cell = CandidateCell(index: offset + 1, side: side)
            cell.configure(candidate)
            cell.onClick = { [weak self] in
                self?.onPick?(start + offset)
            }
            row.addArrangedSubview(cell)
        }

        if pageCount > 1 {
            pageLabel.stringValue = "\(page + 1)/\(pageCount)"
            pageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            pageLabel.textColor = side.comment ?? .tertiaryLabelColor
            row.addArrangedSubview(pageLabel)
        }

        let size = row.fittingSize
        let maxWidth = (NSScreen.main?.visibleFrame.width ?? 1440) - 48
        panel.setContentSize(NSSize(width: min(max(80, size.width), maxWidth), height: max(36, size.height)))
        let wasVisible = panel.isVisible
        if let lineRect {
            position(near: lineRect)
        }
        if !wasVisible {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        if panel.isVisible {
            panel.alphaValue = 0
            panel.orderOut(nil)
        }
    }

    /// 提示条（网址模式等）：复用候选窗的玻璃外观。
    func presentHint(_ text: String, near lineRect: NSRect?) {
        row.arrangedSubviews.forEach {
            row.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = theme.current.comment ?? .secondaryLabelColor
        row.addArrangedSubview(label)
        let size = row.fittingSize
        panel.setContentSize(NSSize(width: max(120, size.width), height: max(32, size.height)))
        let wasVisible = panel.isVisible
        if let lineRect {
            position(near: lineRect)
        }
        if !wasVisible {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        if !wasVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
    }

    private func position(near lineRect: NSRect) {
        let size = panel.frame.size
        let gap: CGFloat = 4
        var origin = NSPoint(x: lineRect.minX, y: lineRect.minY - size.height - gap)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: lineRect.minX, y: lineRect.minY)) }) ?? NSScreen.main {
            let visible = screen.visibleFrame
            if origin.y < visible.minY + gap {
                origin.y = lineRect.maxY + gap
            }
            origin.x = min(max(origin.x, visible.minX + gap), visible.maxX - size.width - gap)
        }
        panel.setFrameOrigin(origin)
    }
}

/// 单个候选格：序号 + 文本 +（可选）拼音注释。颜色/字号来自主题侧。
private final class CandidateCell: NSView {
    static let maxTextWidth: CGFloat = 320

    var onClick: (() -> Void)?
    private let indexLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let commentLabel = NSTextField(labelWithString: "")
    private let column = NSStackView()
    private var trackingArea: NSTrackingArea?
    private var baseBackground: CGColor = NSColor.clear.cgColor
    private let hoverAccent: NSColor
    private let baseFontSize: CGFloat

    init(index: Int, side: CandidateTheme.Side) {
        hoverAccent = side.accent ?? .controlAccentColor
        baseFontSize = side.fontSize ?? 17
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = (side.radius ?? 18) * 0.55

        indexLabel.stringValue = "\(index)"
        indexLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        indexLabel.textColor = side.comment ?? .tertiaryLabelColor
        indexLabel.alignment = .right

        textLabel.font = .systemFont(ofSize: baseFontSize, weight: .regular)
        textLabel.textColor = side.text ?? .labelColor
        textLabel.lineBreakMode = .byTruncatingMiddle
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        commentLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        commentLabel.textColor = side.comment ?? .secondaryLabelColor
        commentLabel.lineBreakMode = .byTruncatingTail
        commentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // 文本 + 注释用纵向 stack：注释隐藏时自动收起，避免留空错位
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        column.addArrangedSubview(textLabel)
        column.addArrangedSubview(commentLabel)

        indexLabel.translatesAutoresizingMaskIntoConstraints = false
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(indexLabel)
        addSubview(column)
        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            indexLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 10),
            indexLabel.firstBaselineAnchor.constraint(equalTo: textLabel.firstBaselineAnchor),
            column.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 6),
            column.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ candidate: Candidate) {
        textLabel.stringValue = candidate.text
        textLabel.font = candidate.kind == "emoji"
            ? .systemFont(ofSize: baseFontSize + 9)
            : .systemFont(ofSize: baseFontSize, weight: .regular)
        if let comment = candidate.comment, !comment.isEmpty, candidate.kind != "emoji" {
            commentLabel.stringValue = comment
            commentLabel.isHidden = false
        } else {
            commentLabel.stringValue = ""
            commentLabel.isHidden = true
        }
        baseBackground = candidate.kind == "literal"
            ? NSColor.quaternaryLabelColor.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
        layer?.backgroundColor = baseBackground
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = hoverAccent.withAlphaComponent(0.14).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = baseBackground
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = hoverAccent.withAlphaComponent(0.24).cgColor
        onClick?()
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = hoverAccent.withAlphaComponent(0.14).cgColor
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        let textWidth = min(
            max(
                textLabel.intrinsicContentSize.width,
                commentLabel.isHidden ? 0 : commentLabel.intrinsicContentSize.width
            ),
            Self.maxTextWidth
        )
        let height = textLabel.intrinsicContentSize.height
            + (commentLabel.isHidden ? 0 : commentLabel.intrinsicContentSize.height + 1)
        return NSSize(width: 8 + max(10, indexLabel.intrinsicContentSize.width) + 6 + textWidth + 10, height: height + 5)
    }
}
