import AppKit

// Generates the vMixrInterface app icon (dark background, white "vM", cyan waveform bars).
// Usage: swift tools/generate_app_icon.swift <output.png>

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: swift generate_app_icon.swift <output.png>\n".data(using: .utf8)!)
    exit(1)
}
let outPath = args[1]

let size: CGFloat = 1024
let cornerRadius: CGFloat = 184
let backgroundTop = NSColor(red: 0x23 / 255.0, green: 0x2C / 255.0, blue: 0x42 / 255.0, alpha: 1)
let backgroundBottom = NSColor(red: 0x14 / 255.0, green: 0x19 / 255.0, blue: 0x2A / 255.0, alpha: 1)
let accent = NSColor(red: 0x33 / 255.0, green: 0xD6 / 255.0, blue: 0xE8 / 255.0, alpha: 1)
let textFontSize: CGFloat = 400
let textCenterY: CGFloat = 560
let barWidth: CGFloat = 26
let barGap: CGFloat = 18
let barCenterY: CGFloat = 290
let barHeights: [CGFloat] = [36, 60, 90, 120, 142, 152, 142, 120, 90, 60, 36]

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(size),
                                 pixelsHigh: Int(size),
                                 bitsPerSample: 8,
                                 samplesPerPixel: 4,
                                 hasAlpha: true,
                                 isPlanar: false,
                                 colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0,
                                 bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: rep) else {
    FileHandle.standardError.write("failed to create bitmap context\n".data(using: .utf8)!)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let bodyPath = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size),
                            xRadius: cornerRadius,
                            yRadius: cornerRadius)
bodyPath.addClip()

guard let gradient = NSGradient(colors: [backgroundTop, backgroundBottom]) else {
    fatalError("failed to create gradient")
}
gradient.draw(in: bodyPath, angle: 270)

let font = NSFont.systemFont(ofSize: textFontSize, weight: .heavy)
let text = NSAttributedString(string: "vM",
                              attributes: [.font: font, .foregroundColor: NSColor.white])
let textSize = text.boundingRect(with: NSSize(width: size, height: textFontSize * 1.5),
                                 options: [.usesLineFragmentOrigin])
let textOrigin = NSPoint(x: (size - textSize.width) / 2,
                         y: textCenterY - textSize.height / 2)
text.draw(at: textOrigin)

let totalBarWidth = CGFloat(barHeights.count) * barWidth
    + CGFloat(barHeights.count - 1) * barGap
var barX = (size - totalBarWidth) / 2
for height in barHeights {
    let barRect = NSRect(x: barX,
                         y: barCenterY - height / 2,
                         width: barWidth,
                         height: height)
    let glowRect = barRect.insetBy(dx: -7, dy: -7)
    accent.withAlphaComponent(0.25).set()
    NSBezierPath(roundedRect: glowRect, xRadius: glowRect.width / 2, yRadius: glowRect.height / 2).fill()
    accent.set()
    NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
    barX += barWidth + barGap
}

NSGraphicsContext.restoreGraphicsState()

guard let pngData = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode png\n".data(using: .utf8)!)
    exit(1)
}
do {
    try pngData.write(to: URL(fileURLWithPath: outPath))
    print("wrote \(outPath) (\(size)x\(size))")
} catch {
    FileHandle.standardError.write("failed to write png: \(error)\n".data(using: .utf8)!)
    exit(1)
}
