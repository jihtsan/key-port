import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: swift render-production-review.swift <asset-directory>")
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let appIconURL = root.appendingPathComponent("keyport-app-icon-source.png")
let menuIconURL = root.appendingPathComponent("exports/keyport-menu-template@2x.png")

guard let appIcon = NSImage(contentsOf: appIconURL),
      let menuSource = NSImage(contentsOf: menuIconURL) else {
    fatalError("Missing production icon assets")
}

let canvasSize = NSSize(width: 1400, height: 900)
let image = NSImage(size: canvasSize)
image.lockFocus()

func fill(_ color: NSColor, _ rect: NSRect) {
    color.setFill()
    rect.fill()
}

func text(_ value: String, at point: NSPoint, font: NSFont, color: NSColor) {
    value.draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
}

func roundedRect(_ rect: NSRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func templateImage(color: NSColor) -> NSImage {
    let result = NSImage(size: menuSource.size)
    result.lockFocus()
    color.setFill()
    NSRect(origin: .zero, size: menuSource.size).fill()
    menuSource.draw(
        in: NSRect(origin: .zero, size: menuSource.size),
        from: .zero,
        operation: .destinationIn,
        fraction: 1
    )
    result.unlockFocus()
    return result
}

let background = NSColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1)
let ink = NSColor(srgbRed: 0.06, green: 0.075, blue: 0.09, alpha: 1)
let secondary = NSColor(srgbRed: 0.32, green: 0.35, blue: 0.39, alpha: 1)
fill(background, NSRect(origin: .zero, size: canvasSize))

text("KeyPort · 已选生产图标", at: NSPoint(x: 90, y: 808), font: .systemFont(ofSize: 38, weight: .semibold), color: ink)
text("App Icon + 18 pt macOS menu bar template image", at: NSPoint(x: 90, y: 758), font: .systemFont(ofSize: 20), color: secondary)

roundedRect(NSRect(x: 90, y: 120, width: 580, height: 580), radius: 8, color: .white)
appIcon.draw(in: NSRect(x: 145, y: 175, width: 470, height: 470))
text("App Icon", at: NSPoint(x: 90, y: 76), font: .systemFont(ofSize: 20, weight: .medium), color: ink)
text("1254 px source · packaged as KeyPort.icns", at: NSPoint(x: 205, y: 78), font: .systemFont(ofSize: 15), color: secondary)

text("菜单栏实际尺寸", at: NSPoint(x: 755, y: 666), font: .systemFont(ofSize: 22, weight: .semibold), color: ink)
let lightBar = NSRect(x: 755, y: 530, width: 555, height: 76)
let darkBar = NSRect(x: 755, y: 410, width: 555, height: 76)
roundedRect(lightBar, radius: 6, color: NSColor(srgbRed: 0.89, green: 0.9, blue: 0.915, alpha: 1))
roundedRect(darkBar, radius: 6, color: NSColor(srgbRed: 0.1, green: 0.11, blue: 0.125, alpha: 1))

let darkGlyph = templateImage(color: ink)
let lightGlyph = templateImage(color: .white)
darkGlyph.draw(in: NSRect(x: 1024, y: 559, width: 18, height: 18))
lightGlyph.draw(in: NSRect(x: 1024, y: 439, width: 18, height: 18))
text("浅色菜单栏", at: NSPoint(x: 780, y: 556), font: .systemFont(ofSize: 16), color: secondary)
text("深色菜单栏", at: NSPoint(x: 780, y: 436), font: .systemFont(ofSize: 16), color: NSColor.white.withAlphaComponent(0.72))

text("放大检查", at: NSPoint(x: 755, y: 340), font: .systemFont(ofSize: 22, weight: .semibold), color: ink)
roundedRect(NSRect(x: 755, y: 120, width: 260, height: 180), radius: 6, color: .white)
roundedRect(NSRect(x: 1050, y: 120, width: 260, height: 180), radius: 6, color: NSColor(srgbRed: 0.1, green: 0.11, blue: 0.125, alpha: 1))
darkGlyph.draw(in: NSRect(x: 805, y: 145, width: 160, height: 160))
lightGlyph.draw(in: NSRect(x: 1100, y: 145, width: 160, height: 160))

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to encode review image")
}
try png.write(to: root.appendingPathComponent("keyport-production-icon-review.png"))
