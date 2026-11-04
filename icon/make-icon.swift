// 用法：swift icon/make-icon.swift icon/Comma.iconset → 再 iconutil 轉 .icns
// 圖示：暖白圓角方塊 + 正體中文置中逗點「，」（以字形實際外框置中，不靠字型的標點位置）
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS 圖示格線：1024 畫布內 824 方塊，圓角約 185
    let box = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shadow = NSShadow()
    shadow.shadowColor = .black.withAlphaComponent(0.25)
    shadow.shadowBlurRadius = 20 * s
    shadow.shadowOffset = NSSize(width: 0, height: -8 * s)
    shadow.set()
    NSColor(red: 1, green: 0.988, blue: 0.941, alpha: 1).setFill()  // #FFFCF0
    NSBezierPath(roundedRect: box, xRadius: 185 * s, yRadius: 185 * s).fill()
    NSShadow().set()

    let font = NSFont(name: "PingFangTC-Semibold", size: 1150 * s)!
    var glyph = CGGlyph(0)
    var ch: UniChar = 0xFF0C  // ，
    CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
    let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
    // 字形外框中心對到方塊中心
    let origin = CGPoint(x: box.midX - bounds.midX, y: box.midY - bounds.midY)
    let path = CTFontCreatePathForGlyph(font, glyph, nil)!
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: origin.x, y: origin.y)
    ctx.addPath(path)
    ctx.setFillColor(NSColor(red: 0.063, green: 0.059, blue: 0.059, alpha: 1).cgColor)  // #100F0F
    ctx.fillPath()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
