import AVFoundation
import Speech

/// 语音输入：macOS 端上语音识别（强制 `requiresOnDeviceRecognition`，绝不回退云端）。
///
/// 权限：首次使用时系统弹窗请求「麦克风 + 语音识别」，均为用户显式操作触发。
/// 音频只在内存中流转到系统端上识别器，不落盘、不联网。
final class VoiceInputController {
    static let shared = VoiceInputController()

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private var tapInstalled = false

    private(set) var isListening = false

    /// 实时文本（partial）与最终文本。
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    /// 状态/错误提示（用于气泡）。
    var onStatus: ((String) -> Void)?

    private init() {}

    /// 端上识别可用性 + 授权状态（不触发弹窗）。
    static func availability(locale: String = "zh-CN") -> (onDevice: Bool, authorized: SFSpeechRecognizerAuthorizationStatus) {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
        return (recognizer?.supportsOnDeviceRecognition ?? false, SFSpeechRecognizer.authorizationStatus())
    }

    /// 开始听写：先请求权限，再启动端上识别。
    func start(locale: String = "zh-CN") {
        guard !isListening else { return }
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                DispatchQueue.main.async {
                    self?.onStatus?("语音识别未授权（系统设置 → 隐私与安全性 → 语音识别）")
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard granted else {
                    DispatchQueue.main.async { self?.onStatus?("麦克风未授权（系统设置 → 隐私与安全性 → 麦克风）") }
                    return
                }
                DispatchQueue.main.async { self?.begin(locale: locale) }
            }
        }
    }

    func stop() {
        guard isListening || task != nil || tapInstalled else { return }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine.stop()
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isListening = false
    }

    private func begin(locale: String) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recognizer.isAvailable else {
            onStatus?("当前系统语音识别不可用")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // 关键边界：不支持端上就直接拒绝，绝不回退到云端识别
            onStatus?("该语言不支持端上识别，已取消（不会回退云端）")
            return
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true      // 端上执行
        request.taskHint = .dictation
        if #available(macOS 13.0, *) {
            request.addsPunctuation = true
        }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async {
                    if result.isFinal {
                        self.onFinal?(text)
                        self.stop()
                    } else {
                        self.onPartial?(text)
                    }
                }
                return
            }
            if error != nil {
                DispatchQueue.main.async {
                    self.onStatus?("语音识别结束/出错")
                    self.stop()
                }
            }
        }

        do {
            engine.prepare()
            try engine.start()
            isListening = true
            onStatus?("聆听中…（Esc 取消）")
        } catch {
            stop()
            onStatus?("无法启动麦克风：\(error.localizedDescription)")
        }
    }
}
