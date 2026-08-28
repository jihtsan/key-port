import AppKit
import Foundation

struct Concept {
    let label: String
    let name: String
    let subtitle: String
    let file: String
    let recommended: Bool
}

let concepts = [
    Concept(label: "A", name: "Key Hub", subtitle: "密钥中心 · 推荐", file: "key-hub", recommended: true),
    Concept(label: "B", name: "Trust Link", subtitle: "可信链路", file: "trust-link", recommended: false),
    Concept(label: "C", name: "Key Route", subtitle: "密钥路由", file: "key-route", recommended: false),
]

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift render-review.swift <asset-directory>")
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let canvasSize = NSSize(width: 1800, height: 1180)
let image = NSImage(size: canvasSize)
image.lockFocus()

func fill(_ color: NSColor, _ rect: NSRect) {
    color.setFill()
    rect.fill()
}

func text(_ value: String, at point: NSPoint, font: NSFont, color: NSColor) {
    value.draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
}

func roundedRect(_ rect: NSRect, radius: CGFloat, fill color: NSColor, stroke: NSColor? = nil) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    color.setFill()
    path.fill()
    if let stroke {
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

func templateImage(_ url: URL, color: NSColor) -> NSImage {
    guard let source = NSImage(contentsOf: url) else { fatalError("Missing image: \(url.path)") }
    let result = NSImage(size: source.size)
    result.lockFocus()
    color.setFill()
    NSRect(origin: .zero, size: source.size).fill()
    source.draw(in: NSRect(origin: .zero, size: source.size), from: .zero, operation: .destinationIn, fraction: 1)
    result.unlockFocus()
    return result
}

func drawPixelExact(_ source: NSImage, in rect: NSRect) {
    NSGraphicsContext.current?.imageInterpolation = .none
    source.draw(in: rect, from: NSRect(origin: .zero, size: source.size), operation: .sourceOver, fraction: 1)
    NSGraphicsContext.current?.imageInterpolation = .high
}

let background = NSColor(srgbRed: 0.955, green: 0.96, blue: 0.97, alpha: 1)
let ink = NSColor(srgbRed: 0.08, green: 0.095, blue: 0.12, alpha: 1)
let secondary = NSColor(srgbRed: 0.34, green: 0.37, blue: 0.42, alpha: 1)
let accent = NSColor(srgbRed: 0.05, green: 0.38, blue: 0.72, alpha: 1)
fill(background, NSRect(origin: .zero, size: canvasSize))

text("KeyPort · macOS 菜单栏 Icon 候选", at: NSPoint(x: 100, y: 1080), font: .systemFont(ofSize: 38, weight: .semibold), color: ink)
text("18 pt template image · 单色 / 透明背景 · 浅色与深色菜单栏验证", at: NSPoint(x: 100, y: 1032), font: .systemFont(ofSize: 20), color: secondary)

let cardWidth: CGFloat = 500
let cardHeight: CGFloat = 820
let cardY: CGFloat = 155
let cardXs: [CGFloat] = [100, 650, 1200]

for (index, concept) in concepts.enumerated() {
    let x = cardXs[index]
    let card = NSRect(x: x, y: cardY, width: cardWidth, height: cardHeight)
    roundedRect(card, radius: 8, fill: .white, stroke: NSColor.black.withAlphaComponent(0.1))

    roundedRect(NSRect(x: x + 34, y: cardY + 744, width: 40, height: 40), radius: 6, fill: concept.recommended ? accent : ink)
    text(concept.label, at: NSPoint(x: x + 47, y: cardY + 752), font: .systemFont(ofSize: 20, weight: .bold), color: .white)
    text(concept.name, at: NSPoint(x: x + 90, y: cardY + 752), font: .systemFont(ofSize: 26, weight: .semibold), color: ink)
    text(concept.subtitle, at: NSPoint(x: x + 34, y: cardY + 704), font: .systemFont(ofSize: 17, weight: concept.recommended ? .semibold : .regular), color: concept.recommended ? accent : secondary)

    roundedRect(NSRect(x: x + 34, y: cardY + 404, width: 432, height: 270), radius: 6, fill: NSColor(srgbRed: 0.965, green: 0.97, blue: 0.98, alpha: 1))
    let large = templateImage(root.appendingPathComponent("exports/\(concept.file)@2x.png"), color: ink)
    large.draw(in: NSRect(x: x + 150, y: cardY + 423, width: 200, height: 200))
    text("放大稿 · 18 pt 构图", at: NSPoint(x: x + 167, y: cardY + 645), font: .systemFont(ofSize: 15), color: secondary)

    text("真实菜单栏预览", at: NSPoint(x: x + 34, y: cardY + 365), font: .systemFont(ofSize: 16, weight: .medium), color: ink)
    let lightBar = NSRect(x: x + 34, y: cardY + 288, width: 432, height: 56)
    let darkBar = NSRect(x: x + 34, y: cardY + 212, width: 432, height: 56)
    roundedRect(lightBar, radius: 5, fill: NSColor(srgbRed: 0.9, green: 0.91, blue: 0.925, alpha: 1), stroke: NSColor.black.withAlphaComponent(0.08))
    roundedRect(darkBar, radius: 5, fill: NSColor(srgbRed: 0.12, green: 0.13, blue: 0.15, alpha: 1))
    let darkIcon = templateImage(root.appendingPathComponent("exports/\(concept.file)@2x.png"), color: .white)
    large.draw(in: NSRect(x: x + 238, y: cardY + 307, width: 18, height: 18))
    darkIcon.draw(in: NSRect(x: x + 238, y: cardY + 231, width: 18, height: 18))
    text("浅色", at: NSPoint(x: x + 50, y: cardY + 306), font: .systemFont(ofSize: 14), color: secondary)
    text("深色", at: NSPoint(x: x + 50, y: cardY + 230), font: .systemFont(ofSize: 14), color: NSColor.white.withAlphaComponent(0.72))

    text("实际栅格", at: NSPoint(x: x + 34, y: cardY + 166), font: .systemFont(ofSize: 16, weight: .medium), color: ink)
    let oneX = templateImage(root.appendingPathComponent("exports/\(concept.file)@1x.png"), color: ink)
    let twoX = templateImage(root.appendingPathComponent("exports/\(concept.file)@2x.png"), color: ink)
    drawPixelExact(oneX, in: NSRect(x: x + 48, y: cardY + 91, width: 54, height: 54))
    drawPixelExact(twoX, in: NSRect(x: x + 188, y: cardY + 73, width: 108, height: 108))
    text("1x · 18 px", at: NSPoint(x: x + 40, y: cardY + 52), font: .monospacedSystemFont(ofSize: 14, weight: .regular), color: secondary)
    text("2x · 36 px", at: NSPoint(x: x + 196, y: cardY + 52), font: .monospacedSystemFont(ofSize: 14, weight: .regular), color: secondary)
}

text("推荐 A：钥匙圆环作为中心节点，同时表达 SSH 密钥、可信设备互联与“密钥中心”定位。", at: NSPoint(x: 100, y: 88), font: .systemFont(ofSize: 21, weight: .medium), color: ink)
text("注：1x / 2x 区域为等倍像素放大，仅用于检查小尺寸轮廓；生产资源保持 18 px 与 36 px。", at: NSPoint(x: 100, y: 48), font: .systemFont(ofSize: 15), color: secondary)

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode review sheet")
}
try png.write(to: root.appendingPathComponent("keyport-menubar-icon-review.png"))
