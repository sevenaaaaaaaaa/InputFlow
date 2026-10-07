// 松萝 / Liana 图标生成器：`swift tools/make-icons.swift`
//
// 品牌符号：一片叶子，叶脉化作「文字行」——输入即生长。
//   assets/Liana.icns          输入法图标
//   assets/LianaInstaller.icns 安装器图标（叶片 + 下沉安装箭头）
// 配色来自 docs/design-tokens.json 的 accent（oklch 62% 0.14 250）换算 sRGB。
import AppKit

let accentTop = NSColor(srgbRed: 0x3E / 255, green: 0x90 / 255, blue: 0xDF / 255, alpha: 1)
let accentBottom = NSColor(srgbRed: 0x2A / 255, green: 0x33 / 255, blue: 0x6E / 255, alpha: 1)

func roundedRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

// 竖直叶片：上下两个尖，两侧对称鼓出
func leafPath(_ s: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: 0.50 * s, y: 0.15 * s))
    p.curve(
        to: NSPoint(x: 0.50 * s, y: 0.85 * s),
        controlPoint1: NSPoint(x: 0.17 * s, y: 0.38 * s),
        controlPoint2: NSPoint(x: 0.17 * s, y: 0.62 * s)
    )
    p.curve(
        to: NSPoint(x: 0.50 * s, y: 0.15 * s),
        controlPoint1: NSPoint(x: 0.83 * s, y: 0.62 * s),
        controlPoint2: NSPoint(x: 0.83 * s, y: 0.38 * s)
    )
    p.close()
    return p
}

func capsule(_ s: CGFloat, cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat) -> NSBezierPath {
    roundedRect((cx - w / 2) * s, (cy - h / 2) * s, w * s, h * s, h * s / 2)
}

func drawIcon(size s: CGFloat, installer: Bool) {
    // 背景：圆角方块 + 品牌渐变 + 顶部玻璃高光
    let squircle = roundedRect(0, 0, s, s, s * 0.2237)
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: accentTop, ending: accentBottom)?.draw(in: squircle, angle: -62)
    let highlight = NSBezierPath(rect: NSRect(x: 0, y: s * 0.5, width: s, height: s * 0.5))
    NSGraphicsContext.saveGraphicsState()
    highlight.addClip()
    NSGradient(
        starting: NSColor.white.withAlphaComponent(0.18),
        ending: NSColor.white.withAlphaComponent(0.0)
    )?.draw(in: highlight, angle: -90)
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()

    // 符号：白色叶片；叶脉用 even-odd 挖空，透出底色
    let mark = leafPath(s)
    if installer {
        // 下沉安装箭头（居中，稳妥落在叶片内）
        mark.append(capsule(s, cx: 0.50, cy: 0.60, w: 0.085, h: 0.18))
        let head = NSBezierPath()
        head.move(to: NSPoint(x: 0.375 * s, y: 0.555 * s))
        head.line(to: NSPoint(x: 0.625 * s, y: 0.555 * s))
        head.line(to: NSPoint(x: 0.50 * s, y: 0.40 * s))
        head.close()
        mark.append(head)
    } else {
        // 三条「文字行」叶脉
        mark.append(capsule(s, cx: 0.50, cy: 0.615, w: 0.26, h: 0.07))
        mark.append(capsule(s, cx: 0.50, cy: 0.485, w: 0.32, h: 0.07))
        mark.append(capsule(s, cx: 0.50, cy: 0.355, w: 0.22, h: 0.07))
    }
    mark.windingRule = .evenOdd
    NSColor.white.setFill()
    mark.fill()
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
    ("Liana", false),
    ("LianaInstaller", true),
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

    // 开发预览：多尺寸 PNG 便于检查
    for size in [512, 64, 32, 16] {
        let preview = URL(fileURLWithPath: "/tmp/\(variant.name)-preview-\(size).png")
        try! pngData(size: size, installer: variant.installer).write(to: preview)
    }
}
