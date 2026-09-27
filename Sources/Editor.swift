import Cocoa

final class EditorWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let c = windowController as? EditorWindowController, c.handleKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class EditorWindowController: NSWindowController, CanvasDelegate, NSWindowDelegate {

    private let baseImage: CGImage
    private var canvas: CanvasView!
    private var toolButtons: [Tool: NSButton] = [:]
    private var colorButtons: [NSButton] = []
    private var undoBtn: NSButton!
    private var redoBtn: NSButton!
    private var sizeLabel: NSTextField!

    private let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),   // 红
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),   // 橙
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1),   // 黄
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),   // 绿
        NSColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1),   // 蓝
        NSColor(srgbRed: 0.55, green: 0.13, blue: 0.95, alpha: 1),   // 紫
        NSColor.white,
        NSColor(srgbRed: 0.05, green: 0.05, blue: 0.05, alpha: 1)    // 黑
    ]

    init(image: CGImage) {
        self.baseImage = image
        let imgW = CGFloat(image.width), imgH = CGFloat(image.height)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxW = screen.width * 0.72, maxH = screen.height * 0.78
        let fit = min(maxW / imgW, maxH / imgH, 1)
        let w = max(560, imgW * fit + 24)
        let h = max(360, imgH * fit + 110)

        let win = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered, defer: false)
        win.title = "SnapTool · 截图编辑"
        win.minSize = NSSize(width: 520, height: 340)
        win.isReleasedWhenClosed = false
        super.init(window: win)
        win.windowController = self
        win.delegate = self
        buildUI()
        win.center()
        win.level = .floating
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: UI

    private func buildUI() {
        guard let cv = window?.contentView else { return }
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 0
        root.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(root)

        // ── 顶部工具条
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        bar.translatesAutoresizingMaskIntoConstraints = false

        for t in Tool.allCases {
            let b = iconButton(t.symbol, tip: "\(t.title)  (\(t.key))", action: #selector(pickTool(_:)))
            b.tag = Tool.allCases.firstIndex(of: t)!
            if t == .move { b.state = .on }
            toolButtons[t] = b
            bar.addArrangedSubview(b)
        }
        bar.addArrangedSubview(separator())

        // 颜色
        for (i, c) in palette.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(pickColor(_:)))
            b.tag = i
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.wantsLayer = true
            b.layer?.cornerRadius = 8
            b.layer?.backgroundColor = c.cgColor
            b.layer?.borderWidth = 2
            b.layer?.borderColor = NSColor.clear.cgColor
            b.widthAnchor.constraint(equalToConstant: 20).isActive = true
            b.heightAnchor.constraint(equalToConstant: 20).isActive = true
            b.refusesFirstResponder = true
            b.toolTip = "颜色"
            colorButtons.append(b)
            bar.addArrangedSubview(b)
        }
        bar.addArrangedSubview(separator())

        // 线宽
        let widthPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (i, t) in ["细", "中", "粗", "特粗"].enumerated() {
            widthPopup.addItem(withTitle: t)
            widthPopup.lastItem?.tag = [3, 5, 9, 16][i]
        }
        widthPopup.selectItem(withTag: 5)
        widthPopup.target = self
        widthPopup.action = #selector(changeWidth(_:))
        widthPopup.refusesFirstResponder = true
        widthPopup.toolTip = "线条粗细"
        bar.addArrangedSubview(widthPopup)

        undoBtn = iconButton("arrow.uturn.backward", tip: "撤销 (⌘Z)", action: #selector(doUndo))
        redoBtn = iconButton("arrow.uturn.forward", tip: "重做 (⇧⌘Z)", action: #selector(doRedo))
        let clearBtn = iconButton("trash", tip: "清空标注", action: #selector(doClear))
        bar.addArrangedSubview(undoBtn)
        bar.addArrangedSubview(redoBtn)
        bar.addArrangedSubview(clearBtn)
        bar.addArrangedSubview(separator())

        bar.addArrangedSubview(iconButton("minus.magnifyingglass", tip: "缩小 (⌘−)", action: #selector(doZoomOut)))
        bar.addArrangedSubview(iconButton("plus.magnifyingglass", tip: "适应窗口 (⌘0)", action: #selector(doZoomReset)))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bar.addArrangedSubview(spacer)

        let saveBtn = NSButton(title: "保存", target: self, action: #selector(saveImage))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.refusesFirstResponder = true
        let cancelBtn = NSButton(title: "取消", target: self, action: #selector(closeEditor))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.refusesFirstResponder = true
        bar.addArrangedSubview(saveBtn)
        bar.addArrangedSubview(cancelBtn)

        // ── 画布
        canvas = CanvasView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.baseImage = baseImage
        canvas.mosaicImage = Renderer.mosaic(from: baseImage)
        canvas.delegate = self
        canvas.currentColor = palette[0]
        canvas.tool = .move
        updateColorSelection()

        // ── 底部状态
        sizeLabel = NSTextField(labelWithString: "\(baseImage.width) × \(baseImage.height) px")
        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        let hint = NSTextField(labelWithString: "拖动图片可直接拖到微信 / QQ / 文件夹    ⌘C 复制   ⌘S 保存   ⌘Z 撤销   Esc 关闭")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        let foot = NSStackView(views: [hint, NSView(), sizeLabel])
        foot.orientation = .horizontal
        foot.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 8, right: 12)
        foot.translatesAutoresizingMaskIntoConstraints = false
        foot.setHuggingPriority(.defaultLow, for: .horizontal)

        root.addArrangedSubview(bar)
        root.addArrangedSubview(canvas)
        root.addArrangedSubview(foot)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            root.topAnchor.constraint(equalTo: cv.topAnchor),
            root.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            foot.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            foot.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            canvas.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
        ])
        canvas.setContentHuggingPriority(.defaultLow, for: .vertical)
        canvas.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        updateButtons()
    }

    private func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 1).isActive = true
        v.heightAnchor.constraint(equalToConstant: 20).isActive = true
        return v
    }

    private func iconButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton(title: "", target: self, action: action)
        b.bezelStyle = .texturedRounded
        b.setButtonType(.pushOnPushOff)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.imagePosition = .imageOnly
        b.toolTip = tip
        b.refusesFirstResponder = true
        b.widthAnchor.constraint(equalToConstant: 34).isActive = true
        return b
    }

    // MARK: 动作

    @objc private func pickTool(_ sender: NSButton) {
        let t = Tool.allCases[sender.tag]
        canvas.tool = t
        for (tool, b) in toolButtons { b.state = (tool == t) ? .on : .off }
        canvas.tool = t
    }

    @objc private func pickColor(_ sender: NSButton) {
        canvas.currentColor = palette[sender.tag]
        updateColorSelection()
    }

    private func updateColorSelection() {
        for (i, b) in colorButtons.enumerated() {
            let sel = palette[i].isEqual(canvas.currentColor)
            b.layer?.borderColor = sel ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
            b.layer?.borderWidth = sel ? 3 : 0
        }
    }

    @objc private func changeWidth(_ s: NSPopUpButton) {
        canvas.currentLineWidth = CGFloat(s.selectedItem?.tag ?? 5)
    }

    @objc private func doUndo() { canvas.undo(); updateButtons() }
    @objc private func doRedo() { canvas.redo(); updateButtons() }
    @objc private func doClear() { canvas.clearAll(); updateButtons() }
    @objc private func doZoomIn() { canvas.zoomIn() }
    @objc private func doZoomOut() { canvas.zoomOut() }
    @objc private func doZoomReset() { canvas.zoomReset() }

    private func updateButtons() {
        undoBtn.isEnabled = canvas.canUndo
        redoBtn.isEnabled = canvas.canRedo
    }

    func handleKeyEquivalent(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command), let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
        switch ch {
        case "c": copyImage(); return true
        case "s": saveImage(); return true
        case "z": mods.contains(.shift) ? doRedo() : doUndo(); return true
        case "e": copyImage(); closeEditor(); return true
        case "w": closeEditor(); return true
        case "+", "=": doZoomIn(); return true
        case "-": doZoomOut(); return true
        case "0": doZoomReset(); return true
        default: return false
        }
    }

    @objc func copyImage() {
        guard let img = canvas.currentComposed() else { return }
        Renderer.copyToPasteboard(img)
    }

    @objc func saveImage() {
        guard let img = canvas.currentComposed() else { return }
        let dir = AppSettings.shared.saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("SnapTool_\(Renderer.fileStamp()).png")
        guard Renderer.savePNG(img, to: url) else { NSSound.beep(); return }
        AppSettings.shared.pushRecent(url)
        if AppSettings.shared.autoCopy { Renderer.copyToPasteboard(img) }
        Toast.show(image: img, text: "已保存  \(url.lastPathComponent)", path: url.path)
        closeEditor()
    }

    @objc func closeEditor() {
        window?.orderOut(nil)
        window?.close()
        if EditorCenter.editor === self { EditorCenter.editor = nil }
    }

    // MARK: CanvasDelegate

    func canvasDidChange(_ canvas: CanvasView) {
        updateButtons()
        sizeLabel.stringValue = "\(baseImage.width) × \(baseImage.height) px   标注 \(canvas.shapes.count) 个"
    }

    func canvasRequestClose(_ canvas: CanvasView) { closeEditor() }

    func canvasRequestCopy(_ canvas: CanvasView, dragOnly: Bool) { copyImage() }

    // MARK: NSWindowDelegate

    func windowWillClose(_ n: Notification) {
        if EditorCenter.editor === self { EditorCenter.editor = nil }
    }
}

// MARK: - 编辑器中心

enum EditorCenter {
    static var editor: EditorWindowController?

    static func open(_ image: CGImage) {
        editor?.closeEditor()
        let c = EditorWindowController(image: image)
        editor = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - 轻量提示条

enum Toast {
    private static var panel: NSPanel?

    static func show(image: CGImage?, text: String, path: String?) {
        panel?.close()
        guard let screen = NSScreen.main else { return }
        let w: CGFloat = 330, h: CGFloat = 84
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false

        let box = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.94).cgColor
        box.layer?.cornerRadius = 14

        if let img = image {
            let iv = NSImageView(frame: NSRect(x: 10, y: 12, width: 60, height: 60))
            iv.image = NSImage(cgImage: img, size: NSSize(width: 60, height: 60))
            iv.imageScaling = .scaleProportionallyUpOrDown
            iv.wantsLayer = true
            iv.layer?.cornerRadius = 6
            iv.layer?.masksToBounds = true
            iv.layer?.borderWidth = 1
            iv.layer?.borderColor = NSColor.white.withAlphaComponent(0.25).cgColor
            box.addSubview(iv)
        }

        let t = NSTextField(labelWithString: text)
        t.frame = NSRect(x: 82, y: 44, width: w - 94, height: 24)
        t.textColor = .white
        t.font = .systemFont(ofSize: 12, weight: .semibold)
        t.lineBreakMode = .byTruncatingMiddle
        box.addSubview(t)

        if let path {
            let s = NSTextField(labelWithString: path)
            s.frame = NSRect(x: 82, y: 18, width: w - 94, height: 22)
            s.textColor = NSColor.white.withAlphaComponent(0.55)
            s.font = .systemFont(ofSize: 10)
            s.lineBreakMode = .byTruncatingMiddle
            box.addSubview(s)
        }

        p.contentView = box
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.maxX - w - 18, y: f.minY + 18))
        p.orderFrontRegardless()
        panel = p

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            guard panel === p else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.35
                p.animator().alphaValue = 0
            }, completionHandler: {
                p.close()
                if panel === p { panel = nil }
            })
        }
    }
}
