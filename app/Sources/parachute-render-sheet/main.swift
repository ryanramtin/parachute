import AppKit
import ImageIO
import UniformTypeIdentifiers
import ParachuteCore

// Usage: swift run parachute-render-sheet [outDir=build]
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let S: CGFloat = 4                       // sheet scale
let iconW = ParachuteIconRenderer.size.width, iconH = ParachuteIconRenderer.size.height
let cellW = (iconW + 4) * S, cellH = (iconH + 4) * S
let labelH: CGFloat = 22

struct Row { let title: String; let items: [(IconStyle, Int, Int)] }   // style, index, count
func frames(_ s: IconStyle) -> [(IconStyle, Int, Int)] { (0..<s.frameCount).map { (s, $0, s.frameCount) } }
let rows: [Row] = [
    Row(title: "running (12 frames @10fps)", items: frames(.running)),
    Row(title: "landing (8 frames, 0.8s)", items: frames(.landing)),
    Row(title: "static: idle | error | partial | not set up", items: [.idle, .error, .partial, .notSetUp].map { ($0, 0, 1) }),
    Row(title: "reduce-motion pulse (10 frames, 1s)", items: frames(.reducedMotion)),
]
let columns = 12
let stripH = CGFloat(rows.count) * (cellH + labelH) + labelH + labelH + 60
let sheetW = CGFloat(columns) * cellW + 20
let sheetH = stripH * 2

func tinted(_ cg: CGImage, _ color: CGColor, in ctx: CGContext, rect: CGRect) {
    ctx.saveGState()
    ctx.clip(to: rect, mask: cg)
    ctx.setFillColor(color)
    ctx.fill(rect)
    ctx.restoreGState()
}

func drawText(_ s: String, at p: CGPoint, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: color]
    (s as NSString).draw(at: p, withAttributes: attrs)
}

func bitmap(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func png(_ cg: CGImage, to path: String) {
    let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
}

let sheet = bitmap(Int(sheetW), Int(sheetH))
let gc = NSGraphicsContext(cgContext: sheet, flipped: false)
NSGraphicsContext.current = gc

for (si, dark) in [false, true].enumerated() {
    let bg = dark ? CGColor(gray: 0.13, alpha: 1) : CGColor(gray: 0.93, alpha: 1)
    let fg = dark ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1)
    let textColor: NSColor = dark ? .white : .black
    let y0 = CGFloat(1 - si) * stripH
    sheet.setFillColor(bg)
    sheet.fill(CGRect(x: 0, y: y0, width: sheetW, height: stripH))
    var y = y0 + stripH
    drawText(dark ? "DARK menu bar" : "LIGHT menu bar", at: CGPoint(x: 10, y: y - labelH + 4), color: textColor)
    y -= labelH
    for row in rows {
        drawText(row.title, at: CGPoint(x: 10, y: y - 14), color: textColor.withAlphaComponent(0.7))
        y -= labelH
        y -= cellH
        for (n, item) in row.items.enumerated() {
            if let cg = ParachuteIconRenderer.cgImage(index: item.1, count: item.2, style: item.0, scale: S) {
                tinted(cg, fg, in: sheet, rect: CGRect(x: 10 + CGFloat(n) * cellW + 2 * S, y: y + 2 * S, width: iconW * S, height: iconH * S))
            }
        }
    }
    // actual-size (2x retina, i.e. 1 image px = 0.5pt) strip: 22pt-tall menu bar mock
    drawText("actual size @2x on a 22pt bar (running loop, then idle/error/partial)", at: CGPoint(x: 10, y: y - 14), color: textColor.withAlphaComponent(0.7))
    y -= labelH
    let barH: CGFloat = 22 * 2
    sheet.setFillColor(dark ? CGColor(gray: 0.2, alpha: 1) : CGColor(gray: 0.85, alpha: 1))
    sheet.fill(CGRect(x: 0, y: y - barH - 4, width: sheetW, height: barH))
    var x: CGFloat = 12
    let seq: [(IconStyle, Int, Int)] = frames(.running) + [(.idle, 0, 1), (.error, 0, 1), (.partial, 0, 1)]
    for item in seq {
        if let cg = ParachuteIconRenderer.cgImage(index: item.1, count: item.2, style: item.0, scale: 2) {
            tinted(cg, fg, in: sheet, rect: CGRect(x: x, y: y - barH - 4 + (barH - iconH * 2) / 2, width: iconW * 2, height: iconH * 2))
        }
        x += iconW * 2 + 8
    }
}
png(sheet.makeImage()!, to: outDir + "/frames.png")
print("wrote \(outDir)/frames.png")

// GIF: running x3 loops, landing, hold idle. Light and dark side by side at 6x.
let G: CGFloat = 6
let gw = Int((iconW + 6) * G), gh = Int((iconH + 6) * G)
func gifFrame(_ item: (IconStyle, Int, Int)) -> CGImage {
    let c = bitmap(gw * 2, gh)
    for (n, dark) in [false, true].enumerated() {
        c.setFillColor(dark ? CGColor(gray: 0.16, alpha: 1) : CGColor(gray: 0.92, alpha: 1))
        c.fill(CGRect(x: n * gw, y: 0, width: gw, height: gh))
        if let cg = ParachuteIconRenderer.cgImage(index: item.1, count: item.2, style: item.0, scale: G) {
            tinted(cg, dark ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1), in: c,
                   rect: CGRect(x: CGFloat(n * gw) + 3 * G, y: 3 * G, width: iconW * G, height: iconH * G))
        }
    }
    return c.makeImage()!
}
var seq: [((IconStyle, Int, Int), Double)] = []
for _ in 0..<3 { for f in frames(.running) { seq.append((f, 0.1)) } }
for f in frames(.landing) { seq.append((f, 0.1)) }
seq.append(((.idle, 0, 1), 1.0))
let gifPath = outDir + "/preview.gif"
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: gifPath) as CFURL, UTType.gif.identifier as CFString, seq.count, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]] as CFDictionary)
for (item, delay) in seq {
    CGImageDestinationAddImage(dest, gifFrame(item),
        [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFDelayTime as String: delay]] as CFDictionary)
}
print(CGImageDestinationFinalize(dest) ? "wrote \(gifPath)" : "GIF failed")
