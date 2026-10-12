import UIKit
import os

/// 松萝 iOS 键盘扩展。
///
/// 与 macOS 端同构：Swift 只做 UI 与协议翻译，引擎逻辑全部来自
/// 静态链接的 Rust 内核（libliana_ffi.a，经 bridge.h 直调 liana.h）。
/// 内存红线：扩展进程上限约 60MB，词典按需加载、候选即时释放。
final class KeyboardViewController: UIInputViewController {

    private var session: OpaquePointer?
    private var modeIdx = 0
    private var candidates: [String] = []
    private var rawInput = ""

    private var candidateStrip: UIStackView!
    private var modeButton: UIButton!
    private var tradButton: UIButton!

    private static let modes = ["pinyin", "en"]

    // ---- 生命周期 ----

    override func viewDidLoad() {
        super.viewDidLoad()
        loadEngine()
        buildUI()
    }

    override func viewWillDisappear(_ animated: Bool) {
        saveUserWords()
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
        view.backgroundColor = UIColor(white: 0.11, alpha: 1)

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

        // QWERTY 三行
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        for (i, keys) in rows.enumerated() {
            let row = UIStackView()
            row.axis = .horizontal
            row.distribution = .fillEqually
            row.spacing = 5
            for ch in keys {
                row.addArrangedSubview(keyButton(String(ch)) { self.onLetter(ch) })
            }
            if i == 2 {
                row.addArrangedSubview(keyButton("⌫") { self.onBackspace() })
            }
            row.heightAnchor.constraint(equalToConstant: 44).isActive = true
            root.addArrangedSubview(row)
        }

        // 功能行
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

    private func keyButton(_ title: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.backgroundColor = UIColor(white: 0.18, alpha: 1)
        b.layer.cornerRadius = 8
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
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
    }

    private func commitRaw() {
        guard let session, let p = liana_commit_raw(session) else { return }
        let text = String(cString: p)
        liana_free_string(p)
        insertText(text)
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
        composing.textColor = UIColor(white: 0.62, alpha: 1)
        candidateStrip.addArrangedSubview(composing)

        let arr = obj["candidates"] as? [[String: Any]] ?? []
        candidates = arr.prefix(9).compactMap { $0["text"] as? String }
        for (i, text) in candidates.enumerated() {
            let b = keyButton(text) { self.selectCandidate(i) }
            b.backgroundColor = UIColor(white: 0.24, alpha: 1)
            b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
            b.titleLabel?.font = .systemFont(ofSize: 17, weight: .bold)
            candidateStrip.addArrangedSubview(b)
        }
    }
}