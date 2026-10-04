import AppKit
import Vision

/// 营养库发生变化（喂入 / 忘记 / 清空）：输入控制器收到后整体重导入。
extension Notification.Name {
    static let nutritionChanged = Notification.Name("LianaNutritionChanged")
    /// 知你学习开关在权限中心被切换：输入控制器收到后重同步决策上下文。
    static let evolutionToggled = Notification.Name("LianaEvolutionToggled")
}

/// 喂食窗（ADR-0008 E2）：截图/文档/粘贴文本 → 端上提炼 → 营养库。
/// OCR 用 Apple Vision（零网络）；术语提炼是内核里的纯统计；
/// 营养词获得词典级加分与按键召回，忘记即全部效果消失。
final class FeedWindowController: NSWindowController {
    static let shared = FeedWindowController()

    /// 营养库管理走自己的会话：知你账本是进程单例，营养库随 TSV 全量对齐。
    private let engine = LianaEngine(mode: "pinyin")
    private let store = EncryptedStore.shared

    private let textView = NSTextView()
    private let sourceLabel = NSTextField(labelWithString: "还没喂入内容——选文件、贴截图或直接粘贴文本")
    private let extractButton = NSButton(title: "提炼术语", target: nil, action: nil)
    private let aiToggle = NSButton(checkboxWithTitle: "AI 增强提炼（本机 Gemma，零网络）", target: nil, action: nil)
    private let feedButton = NSButton(title: "喂入选中术语", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let termsStack = NSStackView()
    private let libraryStack = NSStackView()
    private var pendingSourceBase = ""
    private var aiTopic = ""
    private var pendingSource = ""
    private var aiRunning = false
    private var terms: [CandidateTerm] = []

    /// 待喂入的术语：统计提炼与 Gemma 提炼共用一条勾选流。
    struct CandidateTerm {
        var term: String
        var count: Int
        var checked: Bool
        var isAI: Bool
    }

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "松萝 · 喂它一段"
        window.isReleasedWhenClosed = false
        window.center()
        window.minSize = NSSize(width: 480, height: 520)
        self.init(window: window)
        buildUI()
    }

    func show() {
        refreshLibrary()
        refreshAIAvailability()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 界面

    private func buildUI() {
        guard let window else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        root.translatesAutoresizingMaskIntoConstraints = false

        let intro = NSTextField(wrappingLabelWithString: """
            把项目文档、聊天记录或截图喂给输入法：反复出现的词会被提炼成「营养词」，\
            打拼音时优先给出，专有名词一教就会。全部在本机完成，OCR 零网络。
            """)
        intro.preferredMaxLayoutWidth = 520
        intro.font = .systemFont(ofSize: 11)
        intro.textColor = .secondaryLabelColor
        root.addArrangedSubview(intro)

        let fileRow = NSStackView(views: [
            button("选择图片/截图…", #selector(pickImage(_:))),
            button("选择文本文档…", #selector(pickTextFile(_:))),
            button("识别剪切板截图", #selector(ocrClipboard(_:))),
        ])
        fileRow.orientation = .horizontal
        fileRow.spacing = 10
        root.addArrangedSubview(fileRow)

        // 文本区：展示提取结果，也可直接粘贴
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isEditable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 12)
        textView.string = ""
        textView.delegate = self
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 524).isActive = true
        root.addArrangedSubview(scroll)

        sourceLabel.font = .systemFont(ofSize: 10)
        sourceLabel.textColor = .tertiaryLabelColor
        root.addArrangedSubview(sourceLabel)

        extractButton.bezelStyle = .rounded
        extractButton.controlSize = .small
        extractButton.target = self
        extractButton.action = #selector(extractTerms(_:))
        root.addArrangedSubview(extractButton)

        refreshAIAvailability()
        aiToggle.target = self
        aiToggle.action = #selector(toggleAI(_:))
        let aiHint = NSTextField(labelWithString: "需 llama.cpp（brew install llama.cpp）+「AI 增强」里的 Gemma 模型")
        aiHint.font = .systemFont(ofSize: 10)
        aiHint.textColor = .tertiaryLabelColor
        let aiRow = NSStackView(views: [aiToggle, aiHint])
        aiRow.orientation = .horizontal
        aiRow.spacing = 8
        root.addArrangedSubview(aiRow)

        termsStack.orientation = .vertical
        termsStack.alignment = .leading
        termsStack.spacing = 2
        root.addArrangedSubview(termsScroll())

        feedButton.bezelStyle = .rounded
        feedButton.controlSize = .small
        feedButton.isEnabled = false
        feedButton.target = self
        feedButton.action = #selector(feedSelected(_:))
        root.addArrangedSubview(feedButton)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(statusLabel)

        root.addArrangedSubview(separator())
        let libHead = NSTextField(labelWithString: "营养库（吃什么、记住什么、忘掉什么，全由你）")
        libHead.font = .systemFont(ofSize: 12, weight: .semibold)
        root.addArrangedSubview(libHead)

        libraryStack.orientation = .vertical
        libraryStack.alignment = .leading
        libraryStack.spacing = 2
        root.addArrangedSubview(libraryScroll())

        let clear = NSButton(title: "清空营养库", target: self, action: #selector(clearLibrary(_:)))
        clear.bezelStyle = .rounded
        clear.controlSize = .small
        root.addArrangedSubview(clear)

        window.contentView = root
        let content = window.contentView!
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .small
        return b
    }

    private func termsScroll() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        termsStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scroll.documentView = termsStack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 524).isActive = true
        return scroll
    }

    private func libraryScroll() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.documentView = libraryStack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 140).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 524).isActive = true
        return scroll
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 524).isActive = true
        return box
    }

    // MARK: - 取材：文件 / 剪切板 / 粘贴

    /// UTF-8 优先，退回 GB18030（政务/老文档常见）。
    private static func decodeText(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                UInt32(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        return String(data: data, encoding: gb)
    }

    @objc private func pickImage(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择包含要学习的文字的图片/截图"
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recognizeImage(at: url, sourceName: url.lastPathComponent)
    }

    @objc private func pickTextFile(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择文本文档（txt/md/csv 等）"
        panel.allowedContentTypes = [.text, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // 上限 2MB：喂食是提炼术语，不是全文索引
        guard let data = try? Data(contentsOf: url), data.count <= 2_000_000,
              let text = Self.decodeText(data)
        else {
            setStatus("读不出文本（太大或不是 UTF-8/GB 编码）", error: true)
            return
        }
        setPending(text, source: url.lastPathComponent)
    }

    @objc private func ocrClipboard(_ sender: NSButton) {
        guard let image = NSPasteboard.general.data(forType: .tiff).flatMap(NSImage.init(data:))
            ?? NSPasteboard.general.data(forType: .png).flatMap(NSImage.init(data:))
        else {
            setStatus("剪切板里没有图片——用 ⇧⌘4 截图时按住 Ctrl 存到剪切板", error: true)
            return
        }
        var rect = CGRect.zero
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            setStatus("图片读不出来", error: true)
            return
        }
        runVision(cgImage: cg, sourceName: "剪切板截图")
    }

    private func recognizeImage(at url: URL, sourceName: String) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            setStatus("图片读不出来", error: true)
            return
        }
        runVision(cgImage: cg, sourceName: sourceName)
    }

    /// Apple Vision 端上 OCR：准确档，简中 + 英文。零网络。
    private func runVision(cgImage: CGImage, sourceName: String) {
        setStatus("正在识别…", error: false)
        let request = VNRecognizeTextRequest { [weak self] req, _ in
            let lines = (req.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string } ?? []
            DispatchQueue.main.async {
                guard let self else { return }
                if lines.isEmpty {
                    self.setStatus("没认出文字", error: true)
                } else {
                    self.setPending(lines.joined(separator: "\n"), source: sourceName)
                }
            }
        }
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                DispatchQueue.main.async {
                    self.setStatus("识别失败：\(error.localizedDescription)", error: true)
                }
            }
        }
    }

    // MARK: - 提炼与喂入

    @objc private func extractTerms(_ sender: NSButton) {
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            setStatus("先给点内容：选文件、贴截图或粘贴文本", error: true)
            return
        }
        if pendingSource.isEmpty { pendingSource = "粘贴文本" }
        pendingSourceBase = pendingSource
        aiTopic = ""
        let found = LianaEngine.feedExtract(text)
        terms = found.map { CandidateTerm(term: $0.term, count: $0.count, checked: true, isAI: false) }
        rebuildTermsStack()
        feedButton.isEnabled = !terms.isEmpty
        setStatus(
            terms.isEmpty
                ? "没有反复出现的词——喂一段更长的、重复度更高的内容试试"
                : "提炼出 \(terms.count) 个术语，勾掉不想学的，然后喂入",
            error: terms.isEmpty
        )
        // AI 增强（E4）：统计打底之后，让本机 Gemma 补一遍专有名词并概括主题
        if aiToggle.state == .on, aiAvailable() {
            runAIExtraction(text)
        }
    }

    @objc private func feedSelected(_ sender: NSButton) {
        let selected = terms.filter(\.checked)
        guard !selected.isEmpty else { return }
        var fed = 0
        for item in selected {
            if engine.nutritionAdd(term: item.term, source: pendingSource, strength: UInt32(item.count)) {
                fed += 1
            }
        }
        store.mergeNutrition(tsv: engine.nutritionExport())
        NotificationCenter.default.post(name: .nutritionChanged, object: nil)
        refreshLibrary()
        setStatus("已喂入 \(fed) 个术语——现在就能打出来，越用越懂你", error: false)
        PetWindowController.shared.showToast("已喂入 \(fed) 个营养词（\(pendingSource)）", duration: 4)
        terms = []
        rebuildTermsStack()
        feedButton.isEnabled = false
    }

    /// 有内容待提炼：放进文本区并记出处。
    private func setPending(_ text: String, source: String) {
        pendingSource = source
        pendingSourceBase = source
        aiTopic = ""
        textView.string = text
        sourceLabel.stringValue = "来源：\(source)（\(text.count) 字）"
        setStatus("", error: false)
        extractTerms(extractButton)
    }

    private func setStatus(_ text: String, error: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }

    private func rebuildTermsStack() {
        while termsStack.arrangedSubviews.count > 0 {
            let v = termsStack.arrangedSubviews.last!
            termsStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for (index, item) in terms.enumerated() {
            let badge = item.isAI ? "（AI）" : "（×\(item.count)）"
            let box = NSButton(checkboxWithTitle: item.term + badge, target: self, action: #selector(toggleTerm(_:)))
            box.font = .systemFont(ofSize: 12)
            box.state = item.checked ? .on : .off
            box.tag = index
            termsStack.addArrangedSubview(box)
        }
    }

    @objc private func toggleTerm(_ sender: NSButton) {
        guard terms.indices.contains(sender.tag) else { return }
        terms[sender.tag].checked = sender.state == .on
        feedButton.isEnabled = terms.contains(where: \.checked)
    }

    // MARK: - AI 增强提炼（E4：本机 Gemma，零云）

    private static let aiEnabledKey = "LianaFeedAIEnhanced"

    private func aiAvailable() -> Bool {
        TranslateClient.findRuntime() != nil && TranslateClient.translateModelPath() != nil
    }

    /// 开关可用性随运行时/模型状态刷新；首次可用时默认打开。
    private func refreshAIAvailability() {
        let available = aiAvailable()
        aiToggle.isEnabled = available
        if UserDefaults.standard.object(forKey: Self.aiEnabledKey) == nil {
            aiToggle.state = available ? .on : .off
        } else {
            aiToggle.state = UserDefaults.standard.bool(forKey: Self.aiEnabledKey) ? .on : .off
        }
    }

    @objc private func toggleAI(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Self.aiEnabledKey)
        // 开着的时候立即补跑一遍（文本已有统计提炼结果）
        if sender.state == .on, aiAvailable(),
           !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runAIExtraction(textView.string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Gemma 两步：先补专有名词（统计 n-gram 漏掉的低频词/专名），
    /// 再概括主题（进营养词出处，权限中心一眼看清这批词是干什么的）。
    private func runAIExtraction(_ text: String) {
        guard !aiRunning else { return }
        aiRunning = true
        setStatus("AI 提炼中（本机 Gemma，零网络）…", error: false)
        // 小模型上下文有限：只喂开头一段
        let clipped = String(text.prefix(1200))
        TranslateClient.shared.chat(
            system: "You extract proper nouns from Chinese text. Output ONLY the terms, one per line. No numbering, no explanations.",
            user: "从下面的文字里找专有名词（人名、地名、机构、项目、产品、术语），2到6个字，一行一个，最多20个：\n\n\(clipped)",
            maxTokens: 300
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let output):
                self.appendAITerms(Self.parseTerms(output))
                TranslateClient.shared.chat(
                    system: "Answer with the topic only. No explanations, no punctuation.",
                    user: "用不超过12个字概括这段文字的主题：\n\n\(clipped)",
                    maxTokens: 40
                ) { [weak self] topicResult in
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.aiRunning = false
                        if case .success(let topic) = topicResult {
                            self.applyTopic(topic)
                        }
                        let ai = self.terms.filter(\.isAI).count
                        self.setStatus(
                            "提炼完成：统计 \(self.terms.count - ai) 个 + AI 补充 \(ai) 个，勾掉不想学的然后喂入",
                            error: false
                        )
                    }
                }
            case .failure(let error):
                self.aiRunning = false
                self.setStatus("AI 提炼失败：\(error.localizedDescription)（统计提炼照常可用）", error: true)
            }
        }
    }

    /// 解析 Gemma 输出：一行一词，剥常见列表符号；只留 2–6 字含汉字的词，去重封顶 20。
    static func parseTerms(_ output: String) -> [String] {
        var seen = Set<String>()
        var found: [String] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            var term = String(raw)
            while let first = term.first, "-•*·> \t0123456789.、）)".contains(first) {
                term.removeFirst()
            }
            term = term.trimmingCharacters(in: .whitespaces)
            guard term.count >= 2, term.count <= 6,
                  term.contains(where: Self.isCJKIdeograph),
                  seen.insert(term).inserted
            else { continue }
            found.append(term)
            if found.count >= 20 { break }
        }
        return found
    }

    /// 与内核同一套汉字范围。
    static func isCJKIdeograph(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        return (0x3400...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
    }

    /// AI 补充的词并进勾选流：与统计结果去重，默认勾上，用户逐条把关。
    private func appendAITerms(_ found: [String]) {
        guard !found.isEmpty else { return }
        let existing = Set(terms.map(\.term))
        for term in found where !existing.contains(term) {
            terms.append(CandidateTerm(term: term, count: 1, checked: true, isAI: true))
        }
        DispatchQueue.main.async { [weak self] in
            self?.rebuildTermsStack()
            self?.feedButton.isEnabled = self?.terms.contains(where: \.checked) ?? false
        }
    }

    /// 主题进出处元数据：权限中心里一眼看清这批营养词是干什么的。
    private func applyTopic(_ topic: String) {
        let cleaned = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        aiTopic = String(cleaned.prefix(16))
        pendingSource = pendingSourceBase + " · 主题：\(aiTopic)"
        sourceLabel.stringValue = "来源：\(pendingSource)（\(textView.string.count) 字）"
    }

    // MARK: - 营养库管理

    private func refreshLibrary() {
        while libraryStack.arrangedSubviews.count > 0 {
            let v = libraryStack.arrangedSubviews.last!
            libraryStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let items = engine.nutritionList()
        if items.isEmpty {
            let empty = NSTextField(labelWithString: "（还是空的——喂它一段试试）")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            libraryStack.addArrangedSubview(empty)
            return
        }
        for item in items.prefix(100) {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            let label = NSTextField(
                labelWithString: "\(item.term)  ×\(item.strength)  ·  \(item.source)"
            )
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(label)
            let forget = NSButton(title: "忘记", target: self, action: #selector(forgetRow(_:)))
            forget.bezelStyle = .rounded
            forget.controlSize = .mini
            forget.identifier = NSUserInterfaceItemIdentifier(item.term)
            row.addArrangedSubview(forget)
            libraryStack.addArrangedSubview(row)
        }
        if items.count > 100 {
            let more = NSTextField(labelWithString: "…还有 \(items.count - 100) 个")
            more.font = .systemFont(ofSize: 10)
            more.textColor = .tertiaryLabelColor
            libraryStack.addArrangedSubview(more)
        }
    }

    @objc private func forgetRow(_ sender: NSButton) {
        guard let term = sender.identifier?.rawValue else { return }
        _ = engine.nutritionForget(term)
        store.mergeNutrition(tsv: engine.nutritionExport())
        NotificationCenter.default.post(name: .nutritionChanged, object: nil)
        refreshLibrary()
        setStatus("已忘记「\(term)」", error: false)
    }

    @objc private func clearLibrary(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = "清空营养库？"
        alert.informativeText = "所有营养词的加分与按键召回立即消失，忘了就是真忘了。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        engine.nutritionForgetAll()
        store.setNutrition("")
        NotificationCenter.default.post(name: .nutritionChanged, object: nil)
        refreshLibrary()
        setStatus("营养库已清空", error: false)
    }
}

extension FeedWindowController: NSTextViewDelegate {
    /// 用户手改文本：出处按粘贴处理。
    func textDidChange(_ notification: Notification) {
        pendingSource = textView.string.isEmpty ? "" : "粘贴文本"
        pendingSourceBase = pendingSource
        aiTopic = ""
        sourceLabel.stringValue = pendingSource.isEmpty
            ? "还没喂入内容——选文件、贴截图或直接粘贴文本"
            : "来源：粘贴文本（\(textView.string.count) 字）"
    }
}
