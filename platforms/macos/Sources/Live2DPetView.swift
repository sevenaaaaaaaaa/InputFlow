import AppKit
import WebKit

/// 桌宠 Live2D 视图：透明 WKWebView + pixi.js/pixi-live2d-display。
/// 方案 A（Bring-Your-Own）：Cubism Core 与模型由用户自备，见 ADR-0009。
final class Live2DPetView: PetWebView {
    init(frame: NSRect, modelPath: String, framing: String = "full", zoom: Double = 1.0, scale: Double = 1.0) {
        let root = PetRuntimeStore.ensureLive2D()
        let page = root.appendingPathComponent("pet-live2d.html")
        let url = URL(string: "\(page.absoluteString)?model=\(modelPath)&framing=\(framing)&zoom=\(zoom)&scale=\(scale)") ?? page
        super.init(frame: frame, pageURL: url, readRoot: root)
    }

    required init?(coder: NSCoder) { nil }
}
