import AppKit
import QuartzCore

/// 桌宠 v1：玻璃态小猫，随输入状态切换表情，可拖动、可开关。
///
/// 候选条吸附到桌宠（双形态）留到 M2；当前桌宠与候选窗并存：
/// 候选窗跟随光标，桌宠只表达状态（发呆 / 思考 / 开心）。
final class PetWindowController {
    enum State {
        case idle
        case composing
        case commit
    }

    static let shared = PetWindowController()
    private static let enabledKey = "InputFlowPetEnabled"
    private static let originKey = "InputFlowPetOrigin"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: enabledKey)
        if on {
            shared.show()
        } else {
            shared.hide()
        }
    }

    static func restoreIfEnabled() {
        guard isEnabled else { return }
        shared.show()
    }

    private var panel: NSPanel?
    private let face = NSTextField(labelWithString: "🐱")
    private var resetWorkItem: DispatchWorkItem?

    private init() {}

    func show() {
        if panel == nil {
            panel = makePanel()
            restoreOrigin()
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func react(_ state: State) {
        guard let panel, panel.isVisible else { return }
        resetWorkItem?.cancel()
        switch state {
        case .idle:
            face.stringValue = "🐱"
        case .composing:
            face.stringValue = "🙀"
        case .commit:
            face.stringValue = "😻"
            bounce()
            let item = DispatchWorkItem { [weak self] in self?.face.stringValue = "🐱" }
            resetWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
        }
    }

    private func makePanel() -> NSPanel {
        let size: CGFloat = 84
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 24
        background.layer?.masksToBounds = true

        face.font = .systemFont(ofSize: 42)
        face.alignment = .center
        face.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(face)
        NSLayoutConstraint.activate([
            face.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            face.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
        panel.contentView = background

        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { _ in
            PetWindowController.shared.saveOrigin()
        }
        return panel
    }

    private func bounce() {
        face.wantsLayer = true
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, 1.28, 0.94, 1.0]
        animation.duration = 0.34
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        face.layer?.add(animation, forKey: "bounce")
    }

    // MARK: - 位置记忆

    private func restoreOrigin() {
        guard let panel else { return }
        if let saved = UserDefaults.standard.array(forKey: Self.originKey) as? [Double], saved.count == 2 {
            panel.setFrameOrigin(NSPoint(x: saved[0], y: saved[1]))
            return
        }
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - panel.frame.width - 28,
                y: visible.minY + 28
            ))
        }
    }

    private func saveOrigin() {
        guard let origin = panel?.frame.origin else { return }
        UserDefaults.standard.set([Double(origin.x), Double(origin.y)], forKey: Self.originKey)
    }
}
