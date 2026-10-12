import UIKit

/// 全平台统一设计 Token（docs/design/UNIFIED-DESIGN.md 为单一事实源）。
enum LianaTheme {
    static let bg = UIColor(red: 0x1C/255, green: 0x1C/255, blue: 0x22/255, alpha: 1)
    static let key = UIColor(red: 0x2A/255, green: 0x2A/255, blue: 0x33/255, alpha: 1)
    static let keyPressed = UIColor(red: 0x33/255, green: 0x33/255, blue: 0x3E/255, alpha: 1)
    static let text = UIColor(red: 0xE8/255, green: 0xE8/255, blue: 0xEC/255, alpha: 1)
    static let secondary = UIColor(red: 0x9A/255, green: 0x9A/255, blue: 0xA5/255, alpha: 1)
    static let accent = UIColor(red: 0x33/255, green: 0x7B/255, blue: 0xFF/255, alpha: 1)
    static let fontCandidate: CGFloat = 17
    static let fontKey: CGFloat = 16
    static let padSplitMinWidth: CGFloat = 600
}

/// 松萝 iOS 键盘扩展。
///
/// 与 macOS 端同构：Swift 只做 UI 与协议翻译，引擎逻辑全部来自
/// 静态链接的 Rust 内核（libliana_ffi.a，经 bridge.h 直调 liana.h）。
/// 内存红线：扩展进程上限约 60MB，词典按需加载、候选即时释放。
///
/// 触控创新（统一设计语言 §3）：
/// - 全键触觉反馈（§3.1）
/// - 候选上滑直上屏（§3.2）
/// - 退格长按连删（§3.3）
/// - Pad 宽度 ≥ 600pt 自动分体键盘（§3.4）
final class KeyboardViewController: UIInputViewController {

    private var session: OpaquePointer?
    private var modeIdx = 0
    private var candidates: [String] = []
    private var rawInput = ""

    private var candidateStrip: UIStackView!
    private var modeButton: UIButton!
    private var tradButton: UIButton!
    private var backspaceButton: UIButton!
    private var repeatTimer: Timer?
    private let hapticLight = UIImpactFeedbackGenerator(style: .light)
    private let hapticStrong = UIImpactFeedbackGenerator(style: .medium)

    private static let modes = ["pinyin", "en"]

    // ---- 生命周期 ----

    override func viewDidLoad() {
        super.viewDidLoad()
        loadEngine()
        buildUI()
    }

    override func viewWillDisappear(_ animated: Bool) {
        saveUserWords()
        stopRepeat()
        super.viewWillDisappear(animated)
    }

    private func loadEngine() {
        let dictURL = Bundle.main.url(forResource: "base", withExtension: "ifd")
        if let path = dictURL?.path {
            session = liana_new_with_dict("pinyin", path)
        }
        if session == nil {
            session = liana_new("pinyin")
        }
        // 用户词：App Group 共享容器（无权限时退化为内存态学习）
        if let tsv = readUserWords() {
            liana_user_import(session, tsv)
        }
    }

    private func saveUserWords() {
        guard let session, let tsv = liana_user_export(session) else { return }
        let tsvString = String(cString: tsv)
        liana_free_string(tsv)
        writeUserWords(tsvString)
    }

    /// 键盘扩展没有自己的容器写权限（未开 Full Access 时），退化到内存缓存
    private func readUserWords() -> String? {
        guard let shared = UserDefaults(suiteName: "dev.liana.ime.ios") else { return nil }
        return shared.string(forKey: "user_dict_tsv")
    }

    private func writeUserWords(_ tsv: String) {
        UserDefaults(suiteName: "dev.liana.ime.ios")?.set(tsv, forKey: "user_dict_tsv")
    }

    // ---- UI（程序化构建，无 storyboard） ----

    private func buildUI() {
        view.backgroundColor = LianaTheme.bg

        let root = UIStackView()
        root.axis = .vertical
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // 候选栏（横向滚动）
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 40).isActive = true
        candidateStrip = UIStackView()
        candidateStrip.axis = .horizontal
        candidateStrip.spacing = 6
        candidateStrip.layoutMargins = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        candidateStrip.isLayoutMarginsRelativeArrangement = true
        scroll.addSubview(candidateStrip)
        NSLayoutConstraint.activate([
            candidateStrip.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            candidateStrip.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            candidateStrip.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            candidateStrip.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            candidateStrip.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        root.addArrangedSubview(scroll)

        buildLetterRows(into: root)

        // 功能行（Pad 上保持通栏，双手公共区）
        let fn = UIStackView()
        fn.axis = .horizontal
        fn.spacing = 5
        modeButton = keyButton("中") { self.onModeToggle() }
        fn.addArrangedSubview(modeButton)
        tradButton = keyButton("简") { self.onTraditionalToggle() }
        fn.addArrangedSubview(tradButton)
        fn.addArrangedSubview(keyButton(",") { self.insertText(",") })
        let space = keyButton("空格") { self.onSpace() }
        space.widthAnchor.constraint(equalTo: fn.widthAnchor, multiplier: 0.42).isActive = true
        fn.addArrangedSubview(space)
        fn.addArrangedSubview(keyButton(".") { self.insertText(".") })
        fn.addArrangedSubview(keyButton("⏎") { self.onEnter() })
        fn.heightAnchor.constraint(equalToConstant: 46).isActive = true
        root.addArrangedSubview(fn)

        refreshCandidates()
    }

    /** 字母区：手机通栏；Pad（宽度 ≥ 600pt）自动左右分体，向拇指收拢。 */
    private func buildLetterRows(into root: UIStackView) {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        guard isPadWidth() else {
            for (i, keys) in rows.enumerated() {
                let row = UIStackView()
                row.axis = .horizontal
                row.distribution = .fillEqually
                row.spacing = 5
                for ch in keys {
                    row.addArrangedSubview(keyButton(String(ch)) { self.onLetter(ch) })
                }
                if i == 2 {
                    backspaceButton = keyButton("⌫") { self.onBackspace() }
                    attachBackspaceGestures()
                    row.addArrangedSubview(backspaceButton)
                }
                row.heightAnchor.constraint(equalToConstant: 44).isActive = true
                root.addArrangedSubview(row)
            }
            return
        }

        // Pad 分体：每行从中间拆开，两半各自贴边，中缝留空
        let halves = UIStackView()
        halves.axis = .horizontal
        halves.distribution = .fillEqually
        halves.spacing = 24
        let left = UIStackView(); left.axis = .vertical; left.spacing = 5
        let right = UIStackView(); right.axis = .vertical; right.spacing = 5
        for (i, keys) in rows.enumerated() {
            let mid = (keys.count + 1) / 2
            let rowL = UIStackView(); rowL.axis = .horizontal; rowL.distribution = .fillEqually; rowL.spacing = 5
            let rowR = UIStackView(); rowR.axis = .horizontal; rowR.distribution = .fillEqually; rowR.spacing = 5
            for ch in keys.prefix(mid) {
                rowL.addArrangedSubview(keyButton(String(ch)) { self.onLetter(ch) })
            }
            for ch in keys.dropFirst(mid) {
                rowR.addArrangedSubview(keyButton(String(ch)) { self.onLetter(ch) })
            }
            if i == 2 {
                backspaceButton = keyButton("⌫") { self.onBackspace() }
                attachBackspaceGestures()
                rowR.addArrangedSubview(backspaceButton)
            }
            rowL.heightAnchor.constraint(equalToConstant: 44).isActive = true
            rowR.heightAnchor.constraint(equalToConstant: 44).isActive = true
            left.addArrangedSubview(rowL)
            right.addArrangedSubview(rowR)
        }
        halves.addArrangedSubview(left)
        halves.addArrangedSubview(right)
        root.addArrangedSubview(halves)
    }

    private func isPadWidth() -> Bool {
        view.bounds.width >= LianaTheme.padSplitMinWidth
    }

    // ---- 视图工厂 ----

    private func keyButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(LianaTheme.text, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: LianaTheme.fontKey, weight: .semibold)
        b.backgroundColor = LianaTheme.key
        b.layer.cornerRadius = 8
        b.addAction(UIAction { _ in
            self.hapticLight.impactOccurred()
            action()
        }, for: .touchUpInside)
        return b
    }

    // ---- 退格长按连删（§3.3） ----

    private func attachBackspaceGestures() {
        guard let backspaceButton else { return }
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(onBackspaceLongPress(_:)))
        longPress.minimumPressDuration = 0.3
        backspaceButton.addGestureRecognizer(longPress)
    }

    @objc private func onBackspaceLongPress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            hapticStrong.impactOccurred()
            startRepeat()
        case .ended, .cancelled:
            stopRepeat()
        default: break
        }
    }

    private func startRepeat() {
        guard repeatTimer == nil else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.065, repeats: true) { [weak self] _ in
            guard let self, let session = self.session else { return }
            if !self.rawInput.isEmpty {
                liana_backspace(session)
                self.refreshCandidates()
            } else {
                self.textDocumentProxy.deleteBackward()
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    // ---- 按键行为（与 macOS/Android 端约定一致） ----

    private func onLetter(_ ch: Character) {
        guard let session else { return }
        if currentMode() == "en" {
            insertText(String(ch))
            return
        }
        if liana_feed(session, String(ch)) == 1 {
            refreshCandidates()
        }
    }

    private func onBackspace() {
        guard let session else { return }
        if !rawInput.isEmpty {
            liana_backspace(session)
            refreshCandidates()
        } else {
            textDocumentProxy.deleteBackward()
        }
    }

    private func onSpace() {
        if !candidates.isEmpty {
            selectCandidate(0)
        } else {
            insertText(" ")
        }
    }

    private func onEnter() {
        if !rawInput.isEmpty {
            commitRaw()
        } else {
            textDocumentProxy.insertText("\n")
        }
    }

    private func onModeToggle() {
        modeIdx = (modeIdx + 1) % Self.modes.count
        applyMode()
    }

    private func onTraditionalToggle() {
        guard let session else { return }
        let on = liana_traditional(session) == 0
        liana_set_traditional(session, on ? 1 : 0)
        tradButton.setTitle(on ? "繁" : "简", for: .normal)
        refreshCandidates()
    }

    private func applyMode() {
        guard let session else { return }
        let mode = Self.modes[modeIdx]
        liana_set_mode(session, mode)
        liana_clear(session)
        modeButton.setTitle(mode == "pinyin" ? "中" : "EN", for: .normal)
        refreshCandidates()
    }

    private func currentMode() -> String { Self.modes[modeIdx] }

    private func selectCandidate(_ index: Int) {
        guard let session, let p = liana_select(session, UInt32(index)) else { return }
        let text = String(cString: p)
        liana_free_string(p)
        insertText(text)
        // 上屏加强触觉：形成"上屏了"的身体确认（§3.1）
        hapticStrong.impactOccurred()
    }

    private func commitRaw() {
        guard let session, let p = liana_commit_raw(session) else { return }
        let text = String(cString: p)
        liana_free_string(p)
        insertText(text)
        hapticStrong.impactOccurred()
    }

    private func insertText(_ text: String) {
        textDocumentProxy.insertText(text)
    }

    // ---- 候选刷新 ----

    private func refreshCandidates() {
        guard let session else { return }
        candidateStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        candidates = []
        rawInput = ""

        guard let p = liana_composition_json(session) else { return }
        let jsonString = String(cString: p)
        liana_free_string(p)

        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["raw"] as? String, !raw.isEmpty else { return }
        rawInput = raw
        let preedit = obj["preedit"] as? String ?? ""

        let composing = UILabel()
        composing.text = preedit.isEmpty ? raw : "\(raw) › \(preedit)"
        composing.font = .systemFont(ofSize: 13)
        composing.textColor = LianaTheme.secondary
        candidateStrip.addArrangedSubview(composing)

        let arr = obj["candidates"] as? [[String: Any]] ?? []
        candidates = arr.prefix(9).compactMap { $0["text"] as? String }
        for (i, text) in candidates.enumerated() {
            candidateStrip.addArrangedSubview(candidateButton(text, index: i))
        }
    }

    /** 候选条目：点击选中；上滑 ≥ 24pt 直接着该候选上屏（§3.2）。 */
    private func candidateButton(_ text: String, index: Int) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(text, for: .normal)
        b.setTitleColor(LianaTheme.text, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: LianaTheme.fontCandidate, weight: .bold)
        b.backgroundColor = LianaTheme.keyPressed
        b.layer.cornerRadius = 6
        b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        b.addAction(UIAction { _ in self.selectCandidate(index) }, for: .touchUpInside)
        let swipeUp = UISwipeGestureRecognizer(target: self, action: #selector(onCandidateSwipeUp(_:)))
        swipeUp.direction = .up
        b.addGestureRecognizer(swipeUp)
        return b
    }

    @objc private func onCandidateSwipeUp(_ g: UISwipeGestureRecognizer) {
        guard let b = g.view as? UIButton,
              let idx = candidateStrip.arrangedSubviews.firstIndex(of: b),
              idx > 0, idx - 1 < candidates.count else { return }
        // arrangedSubviews[0] 是组合提示，候选从 1 开始
        hapticStrong.impactOccurred()
        selectCandidate(idx - 1)
    }
}