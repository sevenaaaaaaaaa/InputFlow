import AppKit
import QuartzCore

/// 候选窗：无激活面板 + Liquid Glass 背景（macOS 26+），旧系统回退 NSVisualEffectView。
final class CandidateWindowController {
    static let pageSize = 9

    private let panel: NSPanel
    private let background: NSView
    private let row = NSStackView()
    private let pageLabel = NSTextField(labelWithString: "")
    private var onPick: ((Int) -> Void)?

    private(set) var page = 0

    init() {
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

        background = Self.makeGlassBackground()
        background.autoresizingMask = [.width, .height]
        panel.contentView = background

        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        row.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        row.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *), let glass = background as? NSGlassEffectView {
            glass.contentView = row
        } else {
            background.addSubview(row)
        }
    }

    private static func makeGlassBackground() -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 18
            glass.style = .regular
            glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.25)
            return glass
        }
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true
        return effect
    }

    var isVisible: Bool { panel.isVisible }

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
        for (offset, candidate) in slice.enumerated() {
            let cell = CandidateCell(index: offset + 1)
            cell.configure(candidate)
            cell.onClick = { [weak self] in
                self?.onPick?(start + offset)
            }
            row.addArrangedSubview(cell)
        }

        if pageCount > 1 {
            pageLabel.stringValue = "\(page + 1)/\(pageCount)"
            pageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            pageLabel.textColor = .tertiaryLabelColor
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
        label.textColor = .secondaryLabelColor
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

/// 单个候选格：序号 + 文本 +（可选）拼音注释。
private final class CandidateCell: NSView {
    static let maxTextWidth: CGFloat = 320

    var onClick: (() -> Void)?
    private let indexLabel = NSTextField(labelWithString: "")
    private let textLabel = NSTextField(labelWithString: "")
    private let commentLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var baseBackground: CGColor = NSColor.clear.cgColor

    init(index: Int) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10

        indexLabel.stringValue = "\(index)"
        indexLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        indexLabel.textColor = .tertiaryLabelColor
        textLabel.font = .systemFont(ofSize: 17, weight: .regular)
        textLabel.textColor = .labelColor
        textLabel.lineBreakMode = .byTruncatingMiddle
        commentLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        commentLabel.textColor = .secondaryLabelColor
        commentLabel.lineBreakMode = .byTruncatingTail

        for label in [indexLabel, textLabel, commentLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            indexLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            indexLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            textLabel.leadingAnchor.constraint(equalTo: indexLabel.trailingAnchor, constant: 6),
            textLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textLabel.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            commentLabel.leadingAnchor.constraint(equalTo: textLabel.leadingAnchor),
            commentLabel.trailingAnchor.constraint(equalTo: textLabel.trailingAnchor),
            commentLabel.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 1),
            commentLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(_ candidate: Candidate) {
        textLabel.stringValue = candidate.text
        textLabel.font = candidate.kind == "emoji"
            ? .systemFont(ofSize: 26)
            : .systemFont(ofSize: 17, weight: .regular)
        if let comment = candidate.comment, !comment.isEmpty {
            commentLabel.stringValue = comment
            commentLabel.isHidden = candidate.kind == "emoji"
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
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = baseBackground
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.24).cgColor
        onClick?()
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor
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
        return NSSize(width: 8 + indexLabel.intrinsicContentSize.width + 6 + textWidth + 10, height: height + 4)
    }
}
