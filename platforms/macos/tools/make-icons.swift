// InputFlow 图标生成器：`swift tools/make-icons.swift`
//
// 生成 assets/InputFlow.icns（输入光标 + 三条文字线）与
// assets/InputFlowInstaller.icns（下载箭头变体）。
// 配色来自 docs/design-tokens.json 的 accent（oklch 62% 0.14 250）换算 sRGB。
import AppKit

let accentTop = NSColor(srgbRed: 0x3E / 255, green: 0x90 / 255, blue: 0xDF / 255, alpha: 1)
let accentBottom = NSColor(srgbRed: 0x2F / 255, green: 0x36 / 255, blue: 0x71 / 255, alpha: 1)

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

func drawIcon(size s: CGFloat, installer: Bool) {
    let squircle = roundedRect(0, 0, s, s, s * 0.2237)
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: accentTop, ending: accentBottom)?.draw(in: squircle, angle: -62)

    // 顶部高光，营造玻璃感
    NSGraphicsContext.saveGraphicsState()
    let highlight = NSBezierPath(rect: NSRect(x: 0, y: s * 0.52, width: s, height: s * 0.48))
    highlight.addClip()
    NSGradient(
        starting: NSColor.white.withAlphaComponent(0.18),
        ending: NSColor.white.withAlphaComponent(0.0)
    )?.draw(in: highlight, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // 符号（仍在圆角矩形裁剪内）
    NSColor.white.setFill()
    if installer {
        // 下载箭头 + 托盘
        roundedRect(s * 0.47, s * 0.44, s * 0.06, s * 0.28, s * 0.03).fill()
        let head = NSBezierPath()
        head.move(to: NSPoint(x: s * 0.35, y: s * 0.48))
        head.line(to: NSPoint(x: s * 0.65, y: s * 0.48))
        head.line(to: NSPoint(x: s * 0.50, y: s * 0.30))
        head.close()
        head.fill()
        roundedRect(s * 0.28, s * 0.20, s * 0.44, s * 0.075, s * 0.0375).fill()
    } else {
        // 光标 + 三条文字线
        roundedRect(s * 0.245, s * 0.30, s * 0.055, s * 0.40, s * 0.0275).fill()
        let widths: [CGFloat] = [0.42, 0.30, 0.20]
        let ys: [CGFloat] = [0.615, 0.4575, 0.30]
        for (w, y) in zip(widths, ys) {
            roundedRect(s * 0.37, s * y, s * w, s * 0.085, s * 0.0425).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
}

func pngData(size: Int, installer: Bool) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    drawIcon(size: CGFloat(size), installer: installer)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("assets", isDirectory: true)
try? FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

let variants: [(name: String, installer: Bool)] = [
    ("InputFlow", false),
    ("InputFlowInstaller", true),
]
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(variant.name).iconset", isDirectory: true)
    try? FileManager.default.removeItem(at: iconset)
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for (name, size) in entries {
        let data = pngData(size: size, installer: variant.installer)
        try! data.write(to: iconset.appendingPathComponent("\(name).png"))
    }
    let out = assets.appendingPathComponent("\(variant.name).icns")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", "-o", out.path, iconset.path]
    try! process.run()
    process.waitUntilExit()
    print("已生成 \(out.path)")
}
