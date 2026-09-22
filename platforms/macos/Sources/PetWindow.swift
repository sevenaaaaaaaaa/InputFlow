import AppKit
import QuartzCore

/// 桌宠 v2：内置玻璃小猫 + 社区形象包（声明式数据包，零代码执行）。
///
/// 形象包 pet.json 形如：
/// {"size":96,
///  "states":{"idle":"idle.png","composing":"typing.png","commit":"happy.png"},
///  "follow_cursor":true,"typing_bounce":true,"commit_particles":"spark"}
///
/// 特效：打字跟随（组字时每次按键轻微弹动）、上屏礼花、鼠标追踪
/// （身体朝光标方向轻微倾斜——用 NSEvent.mouseLocation 轮询，不需要任何系统权限）。
final class PetWindowController {
    enum State: String {
        case idle
        case composing
        case commit
    }

    static let shared = PetWindowController()
    private static let enabledKey = "InputFlowPetEnabled"
    private static let originKey = "InputFlowPetOrigin"
    private static let packKey = "InputFlowPetPackId"
    private static let emojiKey = "InputFlowPetEmoji"

    /// 内置 emoji 形象（未选形象包时使用）。默认猫。
    static var builtinEmoji: String {
        get { UserDefaults.standard.string(forKey: emojiKey) ?? "🐱" }
        set {
            UserDefaults.standard.set(newValue, forKey: emojiKey)
            // emoji 形象与形象包互斥：清掉形象包
            UserDefaults.standard.set("", forKey: packKey)
            shared.rebuild()
            if isEnabled {
                shared.show()
            }
        }
    }

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// 激活的形象包 id；"" = 内置小猫。
    static var activePackId: String {
        get { UserDefaults.standard.string(forKey: packKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: packKey)
            shared.rebuild()
            if isEnabled {
                shared.show()
            }
        }
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

    /// 扫描社区形象包。
    static func availablePets() -> [PluginCatalog.Pack] {
        PluginStore.packs(kind: "pet", in: PluginStore.scan())
    }

    private var panel: NSPanel?
    private let face = NSTextField(labelWithString: "🐱")
    private var imageView: NSImageView?
    private var particleEmitter: CAEmitterLayer?
    private var resetWorkItem: DispatchWorkItem?
    private var modeButton: PetQuickButton?
    private var statsButton: PetQuickButton?
    /// 鼠标追踪：30fps 轮询（无权限需求），只在包声明 follow_cursor 时启动。
    private var mouseTimer: Timer?

    private struct PetPack {
        var size: CGFloat = 84
        var fps: Double = 6
        /// 分状态帧率：idle 慢（省电）、typing 快（跟手）。缺省从 fps 推导。
        var idleFps: Double = 3
        var typingFps: Double = 9
        /// 帧动画：idle 闲时小动作 / typing 敲击乐器 / commit 上屏开心。单图包退化为单帧。
        var idle: [NSImage] = []
        var typing: [NSImage] = []
        var commit: [NSImage] = []
        var followCursor = false
        var typingBounce = true
        var commitParticles = true

        static func load(dir: URL) -> PetPack? {
            guard
                let data = try? Data(contentsOf: dir.appendingPathComponent("pet.json")),
                let json = try? JSONDecoder().decode(PetFile.self, from: data)
            else { return nil }
            func images(_ names: [String]?) -> [NSImage] {
                (names ?? []).compactMap { name in
                    name.isEmpty ? nil : NSImage(contentsOf: dir.appendingPathComponent(name))
                }
            }
            func image(_ name: String?) -> NSImage? {
                guard let name, !name.isEmpty else { return nil }
                return NSImage(contentsOf: dir.appendingPathComponent(name))
            }
            var pack = PetPack()
            if let size = json.size, size >= 48, size <= 256 { pack.size = CGFloat(size) }
            if let fps = json.fps, fps >= 1, fps <= 30 { pack.fps = fps }
            pack.idleFps = max(2, pack.fps / 2)
            pack.typingFps = max(pack.fps, 9)
            if let v = json.fps_idle, v >= 1, v <= 30 { pack.idleFps = v }
            if let v = json.fps_typing, v >= 1, v <= 30 { pack.typingFps = v }
            // 帧数组优先；缺省回落到单图 states
            pack.idle = images(json.frames?.idle)
            pack.typing = images(json.frames?.typing)
            pack.commit = images(json.frames?.commit)
            if let singleIdle = image(json.states?.idle) {
                if pack.idle.isEmpty { pack.idle = [singleIdle] }
                if pack.typing.isEmpty { pack.typing = [image(json.states?.composing) ?? singleIdle] }
                if pack.commit.isEmpty { pack.commit = [image(json.states?.commit) ?? singleIdle] }
            }
            pack.followCursor = json.follow_cursor ?? false
            pack.typingBounce = json.typing_bounce ?? true
            pack.commitParticles = json.commit_particles ?? true
            // 至少要有一张 idle 图，否则包视为不可用
            return pack.idle.isEmpty ? nil : pack
        }

        struct PetFile: Codable {
            var size: Double?
            var fps: Double?
            var fps_idle: Double?
            var fps_typing: Double?
            var states: StateFiles?
            var frames: FrameFiles?
            var follow_cursor: Bool?
            var typing_bounce: Bool?
            var commit_particles: Bool?

            struct StateFiles: Codable {
                var idle: String?
                var composing: String?
                var commit: String?
            }

            struct FrameFiles: Codable {
                var idle: [String]?
                var typing: [String]?
                var commit: [String]?
            }
        }
    }

    private var pack: PetPack?

    private init() {}

    private func loadPack() {
        let id = Self.activePackId
        guard !id.isEmpty else {
            pack = nil
            return
        }
        pack = PetPack.load(dir: PluginStore.pluginsDir.appendingPathComponent(id, isDirectory: true))
    }

    /// 形象包切换 / 数据目录变化时重建窗口内容。
    func rebuild() {
        stopMouseTracking()
        stopAnimTimer()
        panel?.orderOut(nil)
        self.panel = nil
        imageView = nil
        particleEmitter = nil
        loadPack()
        if Self.isEnabled {
            show()
        }
    }

    func show() {
        if panel == nil {
            loadPack()
            panel = makePanel()
            restoreOrigin()
        }
        panel?.orderFrontRegardless()
        startMouseTrackingIfNeeded()
        startAnimTimerIfNeeded()
        react(.idle)
    }

    func hide() {
        stopMouseTracking()
        stopAnimTimer()
        panel?.orderOut(nil)
    }

    /// 开发用：把当前桌宠渲染为 PNG（离屏快照，便于检查形象与排版）。
    func snapshot(to path: String) {
        guard let view = panel?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - 帧动画状态机

    private var currentState: State = .idle
    private var frameIndex = 0
    private var animTimer: Timer?

    private func startAnimTimerIfNeeded() {
        guard animTimer == nil else { return }
        restartAnimTimer()
    }

    /// 按当前状态用对应帧率重启计时器：idle 慢速省电，typing 提速跟手。
    private func restartAnimTimer() {
        animTimer?.invalidate()
        animTimer = nil
        guard pack != nil else { return }
        let fps: Double
        switch currentState {
        case .idle: fps = pack?.idleFps ?? 3
        case .composing, .commit: fps = pack?.typingFps ?? 9
        }
        let timer = Timer(timeInterval: 1.0 / max(1, fps), repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        animTimer = timer
    }

    private func stopAnimTimer() {
        animTimer?.invalidate()
        animTimer = nil
    }

    private func tick() {
        guard let pack, let imageView, panel?.isVisible == true else { return }
        switch currentState {
        case .idle:
            frameIndex = (frameIndex + 1) % max(1, pack.idle.count)
            imageView.image = pack.idle[frameIndex]
        case .composing:
            frameIndex = (frameIndex + 1) % max(1, pack.typing.count)
            imageView.image = pack.typing[frameIndex]
        case .commit:
            // commit 帧只播一遍，播完回到 idle 小动作
            if frameIndex < max(1, pack.commit.count) - 1 {
                frameIndex += 1
            } else {
                currentState = .idle
                frameIndex = 0
                imageView.image = pack.idle.first
                return
            }
            imageView.image = pack.commit[frameIndex]
        }
    }

    func react(_ state: State) {
        guard let panel, panel.isVisible else { return }
        resetWorkItem?.cancel()
        // 形象包：切状态、帧归零、按状态换帧率
        if let pack, let imageView {
            currentState = state
            frameIndex = 0
            restartAnimTimer()
            switch state {
            case .idle: imageView.image = pack.idle.first
            case .composing: imageView.image = pack.typing.first
            case .commit:
                imageView.image = pack.commit.first
                if pack.commitParticles {
                    emitSparks()
                }
            }
            return
        }
        // 内置表情（emoji 形象）：干净、可放大，作为默认推荐
        switch state {
        case .idle:
            face.stringValue = Self.builtinEmoji
        case .composing:
            face.stringValue = Self.builtinEmoji
            pulse(scale: 1.08, duration: 0.16)
        case .commit:
            face.stringValue = Self.builtinEmoji
            pulse(scale: 1.22, duration: 0.34)
            emitSparks()
            let item = DispatchWorkItem { [weak self] in self?.react(.idle) }
            resetWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
        }
    }

    private func makePanel() -> NSPanel {
        let size = pack?.size ?? 84
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
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // 角色直接悬浮在桌面上：无托盘、无材质背景，只有角色本体
        let background = PetBackgroundView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        background.onClick = { [weak self] in self?.tapBody() }
        background.onHover = { [weak self] hovering in
            self?.hoverBody(hovering)
        }
        background.onRightClick = { [weak self] event in
            self?.presentPetMenu(event)
        }

        if let pack, let idle = pack.idle.first {
            let view = NSImageView(frame: background.bounds)
            view.image = idle
            view.imageScaling = .scaleProportionallyUpOrDown
            view.autoresizingMask = [.width, .height]
            background.addSubview(view)
            imageView = view
        } else {
            face.stringValue = Self.builtinEmoji
            face.font = .systemFont(ofSize: size * 0.62)
            face.alignment = .center
            face.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(face)
            NSLayoutConstraint.activate([
                face.centerXAnchor.constraint(equalTo: background.centerXAnchor),
                face.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            ])
        }

        // 悬停时才出现的小圆钮，吸附在角色下沿
        let modeBtn = PetQuickButton(title: "中")
        modeBtn.toolTip = "切换中 / 英（左 Shift 同效）"
        modeBtn.handler = {
            NotificationCenter.default.post(name: .petToggleLanguage, object: nil)
        }
        let statsBtn = PetQuickButton(title: "📊")
        statsBtn.toolTip = "昨日输入总结"
        statsBtn.handler = {
            NotificationCenter.default.post(name: .petShowStats, object: nil)
        }
        let dock = NSStackView(views: [modeBtn, statsBtn])
        dock.orientation = .horizontal
        dock.spacing = 6
        dock.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(dock)
        NSLayoutConstraint.activate([
            dock.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            dock.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -1),
            modeBtn.widthAnchor.constraint(equalToConstant: 22),
            modeBtn.heightAnchor.constraint(equalToConstant: 22),
            statsBtn.widthAnchor.constraint(equalToConstant: 22),
            statsBtn.heightAnchor.constraint(equalToConstant: 22),
        ])
        modeBtn.isHidden = true
        statsBtn.isHidden = true
        modeButton = modeBtn
        statsButton = statsBtn

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

    // MARK: - 互动（悬停 / 点按 / 右键）

    /// 左键点按身体 = 中英切换（与左 Shift 同效）。
    private func tapBody() {
        pulse(scale: 1.12, duration: 0.2)
        NotificationCenter.default.post(name: .petToggleLanguage, object: nil)
    }

    /// 悬停 = 被摸头：轻晃 + 显示吸附按钮 + 提示气泡（不刷屏，5 秒内只提示一次）。
    private func hoverBody(_ hovering: Bool) {
        modeButton?.isHidden = !hovering
        statsButton?.isHidden = !hovering
        guard hovering else { return }
        pulse(scale: 1.06, duration: 0.16)
        let now = Date().timeIntervalSince1970
        guard now - lastHintAt > 5 else { return }
        lastHintAt = now
        showToast("点按：中/英 · 右键：标点与统计", duration: 3.5)
    }

    private var lastHintAt: TimeInterval = 0

    /// 右键菜单：模式、标点、统计、隐私。
    private func presentPetMenu(_ event: NSEvent?) {
        let menu = NSMenu()
        let lang = NSMenuItem(title: "切换 中/英", action: #selector(petMenuToggleLanguage(_:)), keyEquivalent: "")
        lang.target = self
        menu.addItem(lang)
        let punct = NSMenuItem(
            title: "强制半角标点",
            action: #selector(petMenuTogglePunctuation(_:)),
            keyEquivalent: ""
        )
        punct.target = self
        punct.state = UserDefaults.standard.bool(forKey: "InputFlowForceHalfPunctuation") ? .on : .off
        menu.addItem(punct)
        menu.addItem(.separator())
        let stats = NSMenuItem(title: "昨日输入总结", action: #selector(petMenuShowStats(_:)), keyEquivalent: "")
        stats.target = self
        menu.addItem(stats)
        let perms = NSMenuItem(title: "权限与隐私…", action: #selector(petMenuPermissions(_:)), keyEquivalent: "")
        perms.target = self
        menu.addItem(perms)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func petMenuToggleLanguage(_ sender: Any) {
        NotificationCenter.default.post(name: .petToggleLanguage, object: nil)
    }

    @objc private func petMenuTogglePunctuation(_ sender: Any) {
        NotificationCenter.default.post(name: .petTogglePunctuation, object: nil)
    }

    @objc private func petMenuShowStats(_ sender: Any) {
        NotificationCenter.default.post(name: .petShowStats, object: nil)
    }

    @objc private func petMenuPermissions(_ sender: Any) {
        PermissionCenterWindowController.shared.show()
    }

    // MARK: - 气泡提示

    private var toastPanel: NSPanel?
    private var toastLabel = NSTextField(wrappingLabelWithString: "")
    private var toastWorkItem: DispatchWorkItem?

    /// 桌宠头顶气泡：任务完成提醒 / 模式反馈 / 统计卡片都走这里。
    /// 只展示本机任务与本地统计，绝不承载任何商务、付款类内容。
    func showToast(_ text: String, duration: TimeInterval = 5) {
        guard panel != nil else { return }  // 桌宠模式关闭时不弹气泡
        let panel = ensureToastPanel()
        toastLabel.stringValue = text
        toastLabel.preferredMaxLayoutWidth = 200
        let size = toastLabel.intrinsicContentSize
        let width = min(230, max(120, size.width + 24))
        let height = max(34, size.height + 18)
        panel.setContentSize(NSSize(width: width, height: height))
        positionToast()
        toastWorkItem?.cancel()
        panel.orderFrontRegardless()
        let item = DispatchWorkItem { [weak panel] in
            panel?.orderOut(nil)
        }
        toastWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
    }

    func hideToast() {
        toastWorkItem?.cancel()
        toastPanel?.orderOut(nil)
    }

    private func ensureToastPanel() -> NSPanel {
        if let toastPanel { return toastPanel }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let box = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        box.material = .hudWindow
        box.blendingMode = .behindWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.masksToBounds = true
        toastLabel.font = .systemFont(ofSize: 11.5)
        toastLabel.textColor = .labelColor
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(toastLabel)
        NSLayoutConstraint.activate([
            toastLabel.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            toastLabel.centerYAnchor.constraint(equalTo: box.centerYAnchor),
        ])
        panel.contentView = box
        toastPanel = panel
        return panel
    }

    private func positionToast() {
        guard let toast = toastPanel, let pet = panel else { return }
        let x = pet.frame.midX - toast.frame.width / 2
        let y = pet.frame.maxY + 6
        toast.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// 快启动台的模式徽标：中文模式显示「中」，英文显示「EN」。
    func setModeLabel(chinese: Bool) {
        modeButton?.title = chinese ? "中" : "EN"
    }

    /// 展示昨日（或今日）总结卡片。
    func showStatsCard(yesterday: Bool) {
        let day = yesterday ? PetStats.shared.yesterday : PetStats.shared.today
        let title = yesterday ? "昨日输入总结" : "今日输入小结"
        if let text = PetStats.summaryText(for: day, title: title) {
            showToast(text, duration: 12)
        }
    }

    // MARK: - 动效

    private func pulse(scale: CGFloat, duration: CGFloat) {
        let host = imageView ?? face
        host.wantsLayer = true
        guard let layer = host.layer else { return }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, scale, 1.0 - (scale - 1.0) * 0.25, 1.0]
        animation.duration = CFTimeInterval(duration)
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "pulse")
    }

    /// 上屏礼花：在桌宠脚下撒一小把 accent 色光点。
    private func emitSparks() {
        guard let panel, let background = panel.contentView else { return }
        particleEmitter?.removeFromSuperlayer()
        let emitter = CAEmitterLayer()
        emitter.emitterPosition = CGPoint(x: background.bounds.midX, y: background.bounds.height * 0.3)
        emitter.emitterSize = CGSize(width: background.bounds.width * 0.6, height: 4)
        emitter.emitterShape = .rectangle
        let cell = CAEmitterCell()
        cell.birthRate = 46
        cell.lifetime = 0.55
        cell.velocity = 68
        cell.velocityRange = 34
        cell.emissionRange = .pi * 0.85
        cell.emissionLongitude = .pi / 2
        cell.scale = 0.05
        cell.scaleRange = 0.04
        cell.spin = 4
        cell.color = NSColor.controlAccentColor.cgColor
        cell.contents = nil
        // 没有贴图时画一个小圆点
        let dot = NSImage(size: NSSize(width: 8, height: 8))
        dot.lockFocus()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 6, height: 6)).fill()
        dot.unlockFocus()
        cell.contents = dot.tiffRepresentation.map { NSImage(data: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) } ?? nil
        emitter.emitterCells = [cell]
        background.layer?.addSublayer(emitter)
        particleEmitter = emitter
        // 0.4 秒后停止发射并清理
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak emitter] in
            emitter?.birthRate = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self, weak emitter] in
            emitter?.removeFromSuperlayer()
            if self?.particleEmitter === emitter {
                self?.particleEmitter = nil
            }
        }
    }

    // MARK: - 鼠标追踪（NSEvent.mouseLocation 轮询，不需要辅助功能权限）

    private func startMouseTrackingIfNeeded() {
        guard pack?.followCursor == true, mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.trackCursor()
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        if let imageView {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            imageView.layer?.setAffineTransform(.identity)
            imageView.layer?.position = CGPoint(
                x: imageView.bounds.midX,
                y: imageView.bounds.midY
            )
            CATransaction.commit()
        }
    }

    private func trackCursor() {
        guard let panel, let imageView, panel.isVisible else { return }
        let mouse = NSEvent.mouseLocation
        let center = CGPoint(
            x: panel.frame.midX,
            y: panel.frame.minY + panel.frame.height / 2
        )
        let dx = mouse.x - center.x
        let dy = mouse.y - center.y
        let distance = max(1, sqrt(dx * dx + dy * dy))
        // 朝光标方向最多倾斜 6°、漂移 5px，像在「看」鼠标
        let angle = max(-6, min(6, dx / distance * 6)) * .pi / 180
        let position = CGPoint(
            x: imageView.bounds.midX + dx / distance * 5,
            y: imageView.bounds.midY + dy / distance * 5
        )
        imageView.wantsLayer = true
        imageView.layer?.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        imageView.layer?.position = position
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

// MARK: - 互动视图件

/// 桌宠身体：区分「点按」与「拖动」，支持悬停与右键。
/// 透明无背景，角色直接悬浮在桌面上。
private final class PetBackgroundView: NSView {
    var onClick: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var downLocation: NSPoint = .zero

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        downLocation = NSEvent.mouseLocation
    }

    override func mouseUp(with event: NSEvent) {
        // 拖动距离小于阈值才算点按，拖动留给窗口移动
        let moved = hypot(
            NSEvent.mouseLocation.x - downLocation.x,
            NSEvent.mouseLocation.y - downLocation.y
        )
        if moved < 4 {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }
}

/// 悬停浮出的小圆钮：半透明深色底 + 白字，吸附在角色下沿。
private final class PetQuickButton: NSButton {
    var handler: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        contentTintColor = .white
        font = .systemFont(ofSize: 11, weight: .semibold)
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func fire() {
        handler?()
    }
}

extension Notification.Name {
    static let petToggleLanguage = Notification.Name("InputFlowPetToggleLanguage")
    static let petTogglePunctuation = Notification.Name("InputFlowPetTogglePunctuation")
    static let petShowStats = Notification.Name("InputFlowPetShowStats")
}
