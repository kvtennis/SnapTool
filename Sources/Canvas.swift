import Cocoa

protocol CanvasDelegate: AnyObject {
    func canvasDidChange(_ canvas: CanvasView)
    func canvasRequestClose(_ canvas: CanvasView)
    func canvasRequestCopy(_ canvas: CanvasView, dragOnly: Bool)
}

final class CanvasView: NSView, NSDraggingSource {

    weak var delegate: CanvasDelegate?

    var baseImage: CGImage? { didSet { needsDisplay = true } }
    var mosaicImage: CGImage?

    var shapes: [Shape] = []            { didSet { needsDisplay = true } }
    private var redoStack: [Shape] = []

    var tool: Tool = .move              { didSet { cancelTextEditing(); needsDisplay = true } }
    var currentColor: NSColor = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    var currentLineWidth: CGFloat = 5
    var filled = false
    var numberSeq = 1

    var zoom: CGFloat = 1
    private var pan: CGPoint = .zero

    private var draft: Shape?
    private var activeTextField: NSTextField?
    private var pendingTextPoint: CGPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: 坐标换算

    private var imgSize: CGSize {
        guard let img = baseImage else { return CGSize(width: 1, height: 1) }
        return CGSize(width: img.width, height: img.height)
    }

    private var fitScale: CGFloat {
        guard baseImage != nil else { return 1 }
        let s = min(bounds.width / imgSize.width, bounds.height / imgSize.height)
        return s > 0 ? s : 1
    }

    private var scale: CGFloat { fitScale * zoom }

    private var imageOrigin: CGPoint {
        CGPoint(x: (bounds.width - imgSize.width * scale) / 2 + pan.x,
                y: (bounds.height - imgSize.height * scale) / 2 + pan.y)
    }

    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - imageOrigin.x) / scale, y: (p.y - imageOrigin.y) / scale)
    }

    private func clampPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), imgSize.width), y: min(max(p.y, 0), imgSize.height))
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
        bounds.fill()

        guard let base = baseImage else { return }
        let o = imageOrigin, sc = scale
        let rect = CGRect(x: o.x, y: o.y, width: imgSize.width * sc, height: imgSize.height * sc)

        // 阴影 + 白底
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 2), blur: 12,
                      color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(rect)
        ctx.restoreGState()

        // 棋盘格：透明像素一眼可见（避免「空白图」难以察觉）
        drawCheckerboard(ctx, in: rect)

        ctx.saveGState()
        ctx.translateBy(x: o.x, y: o.y)
        ctx.scaleBy(x: sc, y: sc)

        // 底图（y 向下坐标系需内翻转）
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: imgSize.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(base, in: CGRect(origin: .zero, size: imgSize))
        ctx.restoreGState()

        // 标注
        for s in shapes {
            ShapeDraw.draw(s, ctx: ctx, mosaic: mosaicImage, imageSize: imgSize)
        }
        if let d = draft {
            ctx.saveGState()
            ctx.setAlpha(0.85)
            ShapeDraw.draw(d, ctx: ctx, mosaic: mosaicImage, imageSize: imgSize)
            ctx.restoreGState()
        }
        ctx.restoreGState()

        // 外框
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(rect.insetBy(dx: -0.5, dy: -0.5))
    }

    private func drawCheckerboard(_ ctx: CGContext, in rect: CGRect) {
        ctx.saveGState()
        ctx.clip(to: rect)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(rect)
        ctx.setFillColor(NSColor(calibratedWhite: 0.87, alpha: 1).cgColor)
        let s: CGFloat = 10
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : s)
            while x < rect.maxX {
                ctx.fill(CGRect(x: x, y: y, width: s, height: s))
                x += s * 2
            }
            y += s
            row += 1
        }
        ctx.restoreGState()
    }

    // MARK: 鼠标

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if activeTextField != nil { commitTextEditing() }
        let vp = convert(e.locationInWindow, from: nil)
        let ip = toImage(vp)

        switch tool {
        case .move:
            dragOrigin = vp
        case .rect, .ellipse, .arrow, .line, .pen, .mosaic:
            var s = Shape(kind: kind(for: tool), points: [ip, ip])
            s.color = currentColor
            s.lineWidth = currentLineWidth
            s.filled = filled
            draft = s
            if tool == .pen { draft?.points = [ip] }
            needsDisplay = true
        case .text:
            beginTextEditing(at: clampPoint(ip))
        case .number:
            var s = Shape(kind: .number, points: [clampPoint(ip)])
            s.color = currentColor
            s.lineWidth = currentLineWidth
            s.text = "\(numberSeq)"
            numberSeq += 1
            commit(s)
        }
    }

    private var dragOrigin: CGPoint?

    override func mouseDragged(with e: NSEvent) {
        let vp = convert(e.locationInWindow, from: nil)
        let ip = toImage(vp)

        if tool == .move {
            guard let start = dragOrigin else { return }
            if abs(vp.x - start.x) + abs(vp.y - start.y) > 5 {
                dragOrigin = nil
                startDragOut()
            }
            return
        }
        guard var d = draft else { return }
        if d.kind == .pen {
            d.points.append(ip)
        } else {
            d.points[1] = ip
        }
        draft = d
        needsDisplay = true
    }

    override func mouseUp(with e: NSEvent) {
        dragOrigin = nil
        guard var d = draft else { return }
        draft = nil
        if d.kind != .mosaic {
            d.points = d.points.map(clampPoint)
        }
        if d.kind == .rect || d.kind == .ellipse || d.kind == .mosaic {
            let r = ShapeDraw.rectFrom(d.points[0], d.points[1])
            guard r.width > 3, r.height > 3 else { needsDisplay = true; return }
        } else if d.kind == .pen {
            guard d.points.count > 1 else { needsDisplay = true; return }
        }
        commit(d)
    }

    private func kind(for t: Tool) -> ShapeKind {
        switch t {
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .line: return .line
        case .pen: return .pen
        case .mosaic: return .mosaic
        default: return .rect
        }
    }

    func commit(_ s: Shape) {
        shapes.append(s)
        redoStack.removeAll()
        delegate?.canvasDidChange(self)
    }

    func undo() {
        guard let last = shapes.popLast() else { return }
        redoStack.append(last)
        if last.kind == .number { numberSeq = max(1, numberSeq - 1) }
        delegate?.canvasDidChange(self)
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        shapes.append(s)
        if s.kind == .number { numberSeq += 1 }
        delegate?.canvasDidChange(self)
    }

    func clearAll() {
        shapes.removeAll(); redoStack.removeAll(); numberSeq = 1
        delegate?.canvasDidChange(self)
    }

    var canUndo: Bool { !shapes.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    // MARK: 文字输入

    private func beginTextEditing(at ip: CGPoint) {
        let fontSize = currentLineWidth * 4.5 * scale
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 180, height: fontSize * 1.6))
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        tf.textColor = currentColor
        tf.placeholderString = "输入文字…"
        tf.delegate = self
        tf.target = self
        tf.action = #selector(commitTextEditing)
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true

        let vp = CGPoint(x: imageOrigin.x + ip.x * scale, y: imageOrigin.y + ip.y * scale)
        tf.frame.origin = CGPoint(x: vp.x, y: vp.y - fontSize * 0.15)

        pendingTextPoint = ip
        activeTextField = tf
        addSubview(tf)
        window?.makeFirstResponder(tf)
    }

    @objc func commitTextEditing() {
        guard let tf = activeTextField, let ip = pendingTextPoint else { return }
        let value = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        tf.removeFromSuperview()
        activeTextField = nil
        pendingTextPoint = nil
        window?.makeFirstResponder(self)
        guard !value.isEmpty else { needsDisplay = true; return }
        var s = Shape(kind: .text, points: [ip], text: value)
        s.color = currentColor
        s.lineWidth = currentLineWidth
        commit(s)
    }

    private func cancelTextEditing() {
        activeTextField?.removeFromSuperview()
        activeTextField = nil
        pendingTextPoint = nil
    }

    // MARK: 拖拽出图

    private func startDragOut() {
        guard let composed = currentComposed(),
              let url = Renderer.gifOrPngTempFile(composed),
              let ev = NSApp.currentEvent else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let frame = bounds.insetBy(dx: bounds.width * 0.25, dy: bounds.height * 0.25)
        item.setDraggingFrame(frame, contents: NSImage(cgImage: composed,
                                                       size: NSSize(width: composed.width, height: composed.height)))
        beginDraggingSession(with: [item], event: ev, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func currentComposed() -> CGImage? {
        guard let base = baseImage else { return nil }
        return Renderer.compose(base: base, mosaic: mosaicImage, shapes: shapes)
    }

    // MARK: 缩放 / 滚动

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.command) {
            let factor = 1 + e.scrollingDeltaY * 0.01
            zoom = min(max(zoom * factor, 0.15), 12)
            needsDisplay = true
        } else {
            pan.x += e.scrollingDeltaX
            pan.y += e.scrollingDeltaY
            needsDisplay = true
        }
    }

    override func magnify(with e: NSEvent) {
        zoom = min(max(zoom * (1 + e.magnification), 0.15), 12)
        needsDisplay = true
    }

    func zoomIn()  { zoom = min(zoom * 1.25, 12); needsDisplay = true }
    func zoomOut() { zoom = max(zoom / 1.25, 0.15); needsDisplay = true }
    func zoomReset() { zoom = 1; pan = .zero; needsDisplay = true }

    override func layout() {
        super.layout()
        if let tf = activeTextField, let ip = pendingTextPoint {
            let fontSize = currentLineWidth * 4.5 * scale
            tf.font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
            let vp = CGPoint(x: imageOrigin.x + ip.x * scale, y: imageOrigin.y + ip.y * scale)
            tf.frame = NSRect(x: vp.x, y: vp.y - fontSize * 0.15,
                              width: max(120, tf.frame.width), height: fontSize * 1.6)
        }
    }

    // MARK: 键盘

    override func keyDown(with e: NSEvent) {
        guard let chars = e.charactersIgnoringModifiers else { return super.keyDown(with: e) }
        switch chars.lowercased() {
        case "v": tool = .move
        case "r": tool = .rect
        case "e": tool = .ellipse
        case "a": tool = .arrow
        case "l": tool = .line
        case "p": tool = .pen
        case "t": tool = .text
        case "m": tool = .mosaic
        case "n": tool = .number
        case "\u{1b}": delegate?.canvasRequestClose(self)   // esc
        case "\u{7f}", "\u{8}": undo()                     // delete
        default: super.keyDown(with: e)
        }
    }
}

extension CanvasView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        let movement = (obj.userInfo?["NSTextMovement"] as? Int) ?? 0
        if movement == NSCancelTextMovement {
            cancelTextEditing()
            window?.makeFirstResponder(self)
        } else {
            commitTextEditing()
        }
    }
}
