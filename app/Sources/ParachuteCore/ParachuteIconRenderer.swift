import AppKit
import CoreGraphics

/// Draws the parachute glyph programmatically. Output is a template image (black + alpha),
/// so the menu bar tints it for light/dark. Cut-outs (badge halo, "!") are baked in an
/// offscreen bitmap so they never punch through whatever the image is composited onto.
public enum ParachuteIconRenderer {
    public static let size = NSSize(width: 20, height: 18)

    /// Pure function: same arguments => same pixels.
    public static func frame(index: Int, count: Int, style: IconStyle) -> NSImage {
        let pose = Pose.make(index: index, count: count, style: style)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let dev = ctx.convertToDeviceSpace(CGSize(width: 1, height: 1))
            let scale = min(4, max(1, ceil(abs(dev.width))))
            guard let cg = render(pose: pose, scale: scale) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: rect)
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Rasterised frame (black + alpha) for contact sheets / GIFs.
    public static func cgImage(index: Int, count: Int, style: IconStyle, scale: CGFloat) -> CGImage? {
        render(pose: Pose.make(index: index, count: count, style: style), scale: scale)
    }

    // MARK: pose

    enum Badge { case none, error, partial }

    struct Pose {
        var inflate: CGFloat = 0     // -1...1
        var sway: CGFloat = 0        // radians
        var drift: CGFloat = 0       // pt downwards
        var collapse: CGFloat = 0    // 0...1
        var settle: CGFloat = 0      // payload bounce, pt
        var alpha: CGFloat = 1
        var badge: Badge = .none

        static func make(index: Int, count: Int, style: IconStyle) -> Pose {
            let n = max(1, count)
            let i = ((index % n) + n) % n
            var p = Pose()
            switch style {
            case .idle: break
            case .notSetUp: p.alpha = 0.4
            case .error: p.badge = .error
            case .partial: p.badge = .partial
            case .running:
                let t = CGFloat(i) / CGFloat(n)
                let phase = 2 * .pi * t
                p.sway = 8 * .pi / 180 * sin(phase)
                p.inflate = sin(phase * 2 + 0.6)
                p.drift = 1.6 * t                   // descends, then resets on loop
            case .reducedMotion:
                let t = CGFloat(i) / CGFloat(n)
                p.alpha = 0.45 + 0.55 * (0.5 + 0.5 * cos(2 * .pi * t))
            case .landing:
                let t = n > 1 ? CGFloat(min(index, n - 1)) / CGFloat(n - 1) : 1
                let c = min(1, t / 0.65)
                p.collapse = 1 - pow(1 - c, 3)
                p.sway = 8 * .pi / 180 * (1 - t) * cos(t * .pi * 2)
                p.drift = 1.6 * min(1, t * 1.5)
                p.settle = 0.9 * (1 - t) * abs(sin(t * .pi * 3))
                p.inflate = -0.5 * t
            }
            return p
        }
    }

    // MARK: drawing

    static func render(pose: Pose, scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = bitmap(w, h) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setShouldAntialias(true)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        draw(pose: pose, in: ctx)
        guard let raw = ctx.makeImage() else { return nil }
        guard pose.alpha < 0.999, let out = bitmap(w, h) else { return raw }
        out.setAlpha(pose.alpha)
        out.draw(raw, in: CGRect(x: 0, y: 0, width: w, height: h))
        return out.makeImage()
    }

    private static func bitmap(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func draw(pose: Pose, in ctx: CGContext) {
        let cx: CGFloat = 10
        let baseH: CGFloat = 5.8, baseW: CGFloat = 7.4, lineLen: CGFloat = 6.0
        let payloadW: CGFloat = 3.0, payloadH: CGFloat = 3.2
        let scallops = 4
        let k = pose.collapse

        let canopyH = baseH * (1 + 0.12 * pose.inflate) * (1 - 0.78 * k)
        let canopyW = baseW * (1 - 0.05 * pose.inflate) * (1 + 0.14 * k)
        let L = lineLen * (1 - 0.5 * k)
        let payloadY = 5.2 - pose.drift          // top of payload
        let yb = payloadY + L + pose.settle      // canopy baseline (settle = little bounce)
        let apex = yb + canopyH

        ctx.saveGState()
        // Pendulum: rotate about the apex, so the payload swings the most.
        ctx.translateBy(x: cx, y: apex)
        ctx.rotate(by: pose.sway)
        ctx.translateBy(x: -cx, y: -apex)

        // suspension lines
        ctx.setLineWidth(0.7)
        ctx.setLineCap(.round)
        for i in 0...scallops {
            let fx = CGFloat(i) / CGFloat(scallops)
            let x = cx - canopyW + 2 * canopyW * fx
            let tx = cx + (fx - 0.5) * (payloadW - 0.8)
            let p0 = CGPoint(x: x, y: yb), p1 = CGPoint(x: tx, y: payloadY)
            ctx.move(to: p0)
            if k > 0.01 {
                let side: CGFloat = (i % 2 == 0 ? 1 : -1)
                let mid = CGPoint(x: (p0.x + p1.x) / 2 + side * 2.4 * k, y: (p0.y + p1.y) / 2 - 0.3 * k)
                ctx.addQuadCurve(to: p1, control: mid)
            } else {
                ctx.addLine(to: p1)
            }
        }
        ctx.strokePath()

        // payload (tiny person: head + body reads as a rounded block at this size)
        let body = CGRect(x: cx - payloadW / 2, y: payloadY - payloadH, width: payloadW, height: payloadH)
        ctx.addPath(CGPath(roundedRect: body, cornerWidth: 1.1, cornerHeight: 1.1, transform: nil))
        ctx.fillPath()

        // canopy
        let kk: CGFloat = 0.5523
        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx - canopyW, y: yb))
        path.addCurve(to: CGPoint(x: cx, y: yb + canopyH),
                      control1: CGPoint(x: cx - canopyW, y: yb + kk * canopyH),
                      control2: CGPoint(x: cx - kk * canopyW, y: yb + canopyH))
        path.addCurve(to: CGPoint(x: cx + canopyW, y: yb),
                      control1: CGPoint(x: cx + kk * canopyW, y: yb + canopyH),
                      control2: CGPoint(x: cx + canopyW, y: yb + kk * canopyH))
        // scalloped hem: arcs bulge up into the canopy, points hang down
        let scallopDepth = 2.2 * (1 - 0.6 * k)
        for i in stride(from: scallops - 1, through: 0, by: -1) {
            let x0 = cx - canopyW + 2 * canopyW * CGFloat(i) / CGFloat(scallops)
            let x1 = cx - canopyW + 2 * canopyW * CGFloat(i + 1) / CGFloat(scallops)
            path.addQuadCurve(to: CGPoint(x: x0, y: yb),
                              control: CGPoint(x: (x0 + x1) / 2, y: yb + scallopDepth))
        }
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()

        // panel seams cut out of the canopy (subtle, helps read as a chute at 4x+)
        if k < 0.4 {
            ctx.setBlendMode(.clear)
            ctx.setLineWidth(0.45)
            for fx in [CGFloat(0.25), 0.75] {
                let x = cx - canopyW + 2 * canopyW * fx
                let top = CGPoint(x: cx + (x - cx) * 0.35, y: yb + canopyH * 0.93 * (1 - 0.0))
                ctx.move(to: CGPoint(x: x, y: yb + scallopDepth * 0.9))
                ctx.addLine(to: top)
            }
            ctx.strokePath()
            ctx.setBlendMode(.normal)
        }
        ctx.restoreGState()

        drawBadge(pose.badge, in: ctx)
    }

    private static func drawBadge(_ badge: Badge, in ctx: CGContext) {
        guard badge != .none else { return }
        let c = CGPoint(x: 15.9, y: 4.2)
        // halo cut-out
        ctx.setBlendMode(.clear)
        ctx.fillEllipse(in: CGRect(x: c.x - 4.3, y: c.y - 4.3, width: 8.6, height: 8.6))
        ctx.setBlendMode(.normal)
        let r: CGFloat = badge == .partial ? 3.3 : 2.5
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        if badge == .partial {
            // "!" cut out of the dot
            ctx.setBlendMode(.clear)
            ctx.fill(CGRect(x: c.x - 0.45, y: c.y - 0.5, width: 0.9, height: 2.3))
            ctx.fillEllipse(in: CGRect(x: c.x - 0.55, y: c.y - 2.1, width: 1.1, height: 1.1))
            ctx.setBlendMode(.normal)
        }
    }
}
