import AppKit
import WebKit

/// 桌宠 VRM 视图：透明 WKWebView + three.js/three-vrm（注视/眨眼/物理/状态机）。
final class VRMPetView: PetWebView {
    init(frame: NSRect, modelPath: String, framing: String = "full", zoom: Double = 1.0) {
        let root = PetRuntimeStore.ensure()
        let page = root.appendingPathComponent("pet.html")
        let url = URL(string: "\(page.absoluteString)?model=\(modelPath)&framing=\(framing)&zoom=\(zoom)") ?? page
        super.init(frame: frame, pageURL: url, readRoot: root)
    }

    required init?(coder: NSCoder) { nil }
}
