import Cocoa
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - 工具枚举

enum Tool: String, CaseIterable {
    case move, rect, ellipse, arrow, line, pen, text, mosaic, number

    var symbol: String {
        switch self {
        case .move:    return "hand.raised"
        case .rect:    return "rectangle"
        case .ellipse: return "circle"
        case .arrow:   return "arrow.up.right"
        case .line:    return "line.diagonal"
        case .pen:     return "pencil.tip"
        case .text:    return "textformat"
        case .mosaic:  return "squareshape.split.2x2"
        case .number:  return "1.circle"
        }
    }

    var title: String {
        switch self {
        case .move:    return "拖动 / 移动"
        case .rect:    return "矩形"
        case .ellipse: return "椭圆"
        case .arrow:   return "箭头"
        case .line:    return "直线"
        case .pen:     return "画笔"
        case .text:    return "文字"
        case .mosaic:  return "马赛克"
        case .number:  return "序号"
        }
    }

    var key: String {
        switch self {
        case .move: return "V"; case .rect: return "R"; case .ellipse: return "E"
        case .arrow: return "A"; case .line: return "L"; case .pen: return "P"
        case .text: return "T"; case .mosaic: return "M"; case .number: return "N"
        }
    }
}

enum ShapeKind { case rect, ellipse, arrow, line, pen, text, mosaic, number }

struct Shape {
    var kind: ShapeKind
    var points: [CGPoint]          // 图像像素坐标，原点左上（y 向下）
    var text: String = ""
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 5
    var filled: Bool = false
}

// MARK: - 绘图

enum ShapeDraw {

    static func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// 在 y 轴向下的坐标系中绘制图形。
    /// - Parameter flippedText: 当前 NSGraphicsContext.isFlipped 是否为 true（文字方向依赖它）
    static func draw(_ s: Shape, ctx: CGContext, mosaic: CGImage?, imageSize: CGSize) {
        let color = s.color.usingColorSpace(.sRGB) ?? s.color
        ctx.setStrokeColor(color.cgColor)
        ctx.setFillColor(color.cgColor)
        ctx.setLineWidth(s.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch s.kind {
        case .rect:
            let r = rectFrom(s.points[0], s.points[1])
            if s.filled { ctx.fill(r) }
            ctx.stroke(r)

        case .ellipse:
            let r = rectFrom(s.points[0], s.points[1])
            let path = CGPath(ellipseIn: r, transform: nil)
            ctx.addPath(path)
            if s.filled { ctx.fillPath() }
            ctx.addPath(path)
            ctx.strokePath()

        case .line:
            ctx.move(to: s.points[0]); ctx.addLine(to: s.points[1]); ctx.strokePath()

        case .arrow:
            drawArrow(ctx, from: s.points[0], to: s.points[1], width: s.lineWidth)

        case .pen:
            guard s.points.count > 1 else { break }
            ctx.move(to: s.points[0])
            for p in s.points.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()

        case .mosaic:
            guard let mosaic else { break }
            let r = rectFrom(s.points[0], s.points[1]).intersection(CGRect(origin: .zero, size: imageSize))
            guard r.width > 1, r.height > 1 else { break }
            ctx.saveGState()
            ctx.clip(to: r)
            ctx.interpolationQuality = .none
            ctx.translateBy(x: r.minX, y: r.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(mosaic, in: CGRect(origin: .zero, size: imageSize))
            ctx.restoreGState()

        case .text:
            let font = NSFont.systemFont(ofSize: s.lineWidth * 4.5, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let str = NSAttributedString(string: s.text, attributes: attrs)
            str.draw(at: s.points[0])   // flipped 上下文：点为左上角

        case .number:
            let size = max(s.lineWidth * 4.5, 24)
            let r = size * 0.85
            let c = s.points[0]
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            let font = NSFont.systemFont(ofSize: size * 1.35, weight: .bold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
            let str = NSAttributedString(string: s.text, attributes: attrs)
            let ts = str.size()
            str.draw(at: CGPoint(x: c.x - ts.width / 2, y: c.y - ts.height / 2))
        }
    }

    static func drawArrow(_ ctx: CGContext, from a: CGPoint, to b: CGPoint, width: CGFloat) {
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()

        let angle = atan2(b.y - a.y, b.x - a.x)
        let head = max(12, width * 4.5)
        let spread = CGFloat.pi / 7

        let p1 = CGPoint(x: b.x - head * cos(angle - spread), y: b.y - head * sin(angle - spread))
        let p2 = CGPoint(x: b.x - head * cos(angle + spread), y: b.y - head * sin(angle + spread))

        ctx.move(to: b); ctx.addLine(to: p1); ctx.addLine(to: p2); ctx.closePath()
        ctx.fillPath()
    }
}

// MARK: - 渲染器

enum Renderer {

    /// 生成整图马赛克底图（缩小后再放大得到方块效果）
    static func mosaic(from cg: CGImage, block: CGFloat = 16) -> CGImage? {
        let w = max(1, Int((CGFloat(cg.width) / block).rounded()))
        let h = max(1, Int((CGFloat(cg.height) / block).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// 把底图与标注合成为最终位图
    static func compose(base: CGImage, mosaic: CGImage?, shapes: [Shape]) -> CGImage? {
        let w = base.width, h = base.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))

        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)          // 转为 y 向下坐标系

        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        for s in shapes {
            ShapeDraw.draw(s, ctx: ctx, mosaic: mosaic, imageSize: CGSize(width: w, height: h))
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        return ctx.makeImage()
    }

    // MARK: 输出

    static func pngData(_ img: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: img)
        return rep.representation(using: .png, properties: [:])
    }

    static func savePNG(_ img: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

    static func copyToPasteboard(_ img: CGImage) {
        let rep = NSBitmapImageRep(cgImage: img)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.declareTypes([.png, .tiff], owner: nil)
        if let d = rep.representation(using: .png, properties: [:]) { pb.setData(d, forType: .png) }
        if let t = rep.representation(using: .tiff, properties: [:]) { pb.setData(t, forType: .tiff) }
    }

    static func gifOrPngTempFile(_ img: CGImage) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapTool-\(Int(Date().timeIntervalSince1970)).png")
        return savePNG(img, to: url) ? url : nil
    }

    static func fileStamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH.mm.ss"
        return f.string(from: Date())
    }

    static func loadCGImage(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

// MARK: - 空白图检测（用于识别「未授权导致截到全透明/纯色图」）

enum BlankCheck {

    /// 全透明 或 近似纯色的图，视为无效截图
    static func looksBlank(_ img: CGImage) -> Bool {
        let w = 32, h = 32
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return false }

        var maxAlpha: UInt8 = 0
        var minLum = 255 * 3, maxLum = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            maxAlpha = max(maxAlpha, buf[i + 3])
            let lum = Int(buf[i]) + Int(buf[i + 1]) + Int(buf[i + 2])
            minLum = min(minLum, lum)
            maxLum = max(maxLum, lum)
        }
        if maxAlpha < 10 { return true }              // 完全透明
        if maxLum - minLum < 12 { return true }       // 近似纯色
        return false
    }

    static func isTransparent(_ img: CGImage) -> Bool {
        let w = 16, h = 16
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return false }
        for i in stride(from: 3, to: buf.count, by: 4) where buf[i] > 10 { return false }
        return true
    }
}
