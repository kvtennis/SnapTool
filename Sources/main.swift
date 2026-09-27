import Cocoa
import Carbon.HIToolbox

// MARK: - 截图模式

enum CaptureMode: String {
    case region, regionCopy, fullscreen, window, regionDelayed

    var title: String {
        switch self {
        case .region:        return "区域截图并编辑"
        case .regionCopy:    return "区域截图直接复制"
        case .fullscreen:    return "全屏截图"
        case .window:        return "窗口截图"
        case .regionDelayed: return "延时区域截图"
        }
    }
}

// MARK: - 全局快捷键

final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var nextID: UInt32 = 1
    private var installed = false

    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        handlers[id] = handler
        var hkID = EventHotKeyID(signature: OSType(0x534E4150) /* SNAP */, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs.append(ref)
        } else {
            NSLog("SnapTool: 快捷键注册失败 code=\(keyCode) status=\(status)")
        }
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            HotKeyCenter.shared.fire(hkID.id)
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var lastMode: CaptureMode = .region
    private var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        registerHotKeys()
        checkPermission(ask: true)
    }

    // MARK: 状态栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnapTool")
            img?.isTemplate = true
            button.image = img
            button.toolTip = "SnapTool 截图小工具"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        // 权限状态置顶
        let granted = CGPreflightScreenCaptureAccess()
        let st = NSMenuItem(title: granted ? "✅ 屏幕录制权限：已授权" : "⚠️ 屏幕录制权限：未授权（截图会空白）",
                            action: granted ? nil : #selector(fixPermission), keyEquivalent: "")
        st.target = self
        if granted { st.isEnabled = false }
        menu.addItem(st)
        menu.addItem(.separator())

        addItem(menu, "区域截图（编辑）", #selector(capRegion), "a", [.control, .option])
        addItem(menu, "区域截图（直接复制）", #selector(capRegionCopy), "c", [.control, .option])
        menu.addItem(.separator())
        addItem(menu, "全屏截图", #selector(capFull), "f", [.control, .option])
        addItem(menu, "窗口截图", #selector(capWindow), "w", [.control, .option])
        addItem(menu, "延时 \(AppSettings.shared.delaySeconds == 0 ? 3 : AppSettings.shared.delaySeconds) 秒区域截图",
                #selector(capDelayed), "d", [.control, .option])
        addItem(menu, "重复上次模式（\(lastMode.title)）", #selector(capRepeat), "z", [.control, .option])
        menu.addItem(.separator())

        // 最近截图
        let recent = AppSettings.shared.recentFiles
        let recentItem = NSMenuItem(title: "最近截图", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if recent.isEmpty {
            let empty = NSMenuItem(title: "暂无", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        } else {
            for p in recent {
                let it = NSMenuItem(title: (p as NSString).lastPathComponent,
                                    action: #selector(openRecent(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = p
                sub.addItem(it)
            }
            sub.addItem(.separator())
            let clear = NSMenuItem(title: "清空记录", action: #selector(clearRecent), keyEquivalent: "")
            clear.target = self
            sub.addItem(clear)
        }
        recentItem.submenu = sub
        menu.addItem(recentItem)

        let openFolder = NSMenuItem(title: "打开截图文件夹", action: #selector(openFolder), keyEquivalent: "")
        openFolder.target = self
        menu.addItem(openFolder)

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let perm = NSMenuItem(title: "检查 / 修复屏幕录制授权", action: #selector(checkPermissionAction), keyEquivalent: "")
        perm.target = self
        menu.addItem(perm)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 SnapTool", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector,
                         _ key: String, _ mods: NSEvent.ModifierFlags) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.target = self
        menu.addItem(it)
        return it
    }

    // MARK: 快捷键

    private func registerHotKeys() {
        let ctrlOpt = UInt32(controlKey | optionKey)
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_A), modifiers: ctrlOpt) { [weak self] in self?.capture(.region) }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_C), modifiers: ctrlOpt) { [weak self] in self?.capture(.regionCopy) }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_F), modifiers: ctrlOpt) { [weak self] in self?.capture(.fullscreen) }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_W), modifiers: ctrlOpt) { [weak self] in self?.capture(.window) }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_D), modifiers: ctrlOpt) { [weak self] in self?.capture(.regionDelayed) }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_Z), modifiers: ctrlOpt) { [weak self] in
            guard let self else { return }
            self.capture(self.lastMode)
        }
    }

    // MARK: 菜单动作

    @objc private func capRegion()      { capture(.region) }
    @objc private func capRegionCopy()  { capture(.regionCopy) }
    @objc private func capFull()        { capture(.fullscreen) }
    @objc private func capWindow()      { capture(.window) }
    @objc private func capDelayed()     { capture(.regionDelayed) }
    @objc private func capRepeat()      { capture(lastMode) }

    @objc private func openSettings()   { SettingsWindowController.show() }
    @objc private func openFolder()     { NSWorkspace.shared.open(AppSettings.shared.saveDirectory) }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let p = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }

    @objc private func clearRecent() {
        AppSettings.shared.recentFiles = []
    }

    @objc private func checkPermissionAction() {
        if CGPreflightScreenCaptureAccess() {
            let a = NSAlert()
            a.messageText = "屏幕录制授权正常"
            a.informativeText = "SnapTool 已获得录制屏幕的权限，可以正常截图。"
            a.runModal()
        } else {
            fixPermission()
        }
    }

    @objc private func fixPermission() {
        _ = CGRequestScreenCaptureAccess()      // 若系统仍可弹原生授权窗，触发之
        if CGPreflightScreenCaptureAccess() { return }

        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "未获得「屏幕录制」权限，截图会是空白"
        a.informativeText = """
        macOS 要求截图类应用必须获得该权限，否则截到的只是透明/空白画面。

        1. 点击下面的「打开系统设置」
        2. 在「隐私与安全性 → 屏幕录制」里打开 SnapTool 开关
        3. 若列表中没有 SnapTool，点左下角 + 添加：
           /Users/fengyu/Applications/SnapTool.app
        4. 回到 SnapTool 点「已授权，重试」

        提示：勾选后若仍未生效，请退出 SnapTool 重新打开。
        """
        a.addButton(withTitle: "打开系统设置")
        a.addButton(withTitle: "已授权，重试")
        a.addButton(withTitle: "取消")
        let r = a.runModal()
        if r == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        } else if r == .alertSecondButtonReturn {
            if CGPreflightScreenCaptureAccess() {
                let ok = NSAlert()
                ok.messageText = "权限已生效"
                ok.informativeText = "现在可以正常截图了。"
                ok.runModal()
            } else {
                let no = NSAlert()
                no.alertStyle = .warning
                no.messageText = "系统仍未授权"
                no.informativeText = "请确认已在「隐私与安全性 → 屏幕录制」中勾选 SnapTool，然后退出并重新打开 SnapTool。"
                no.addButton(withTitle: "打开系统设置")
                no.addButton(withTitle: "知道了")
                if no.runModal() == .alertFirstButtonReturn { openScreenRecordingSettings() }
            }
        }
    }

    /// 返回 true 表示已授权，可继续截图
    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        fixPermission()
        return CGPreflightScreenCaptureAccess()
    }

    private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    private func checkPermission(ask: Bool) {
        guard !CGPreflightScreenCaptureAccess() else { return }
        if ask && !AppSettings.shared.didPromptPermission {
            AppSettings.shared.didPromptPermission = true
            _ = CGRequestScreenCaptureAccess()
            let a = NSAlert()
            a.messageText = "需要「屏幕录制」权限"
            a.informativeText = """
            SnapTool 需要该权限才能截取屏幕内容。
            请在「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 SnapTool，然后重新启动本应用。

            已为你打开设置页面。
            """
            a.addButton(withTitle: "打开系统设置")
            a.addButton(withTitle: "稍后")
            if a.runModal() == .alertFirstButtonReturn { openScreenRecordingSettings() }
        }
    }

    // MARK: 截图流程

    func capture(_ mode: CaptureMode) {
        if isCapturing { return }

        // 关键：未授权时直接拦截，避免产出透明空白图
        guard ensurePermission() else { return }

        lastMode = mode
        isCapturing = true

        let delay = (mode == .regionDelayed) ? max(1, AppSettings.shared.delaySeconds == 0 ? 3 : AppSettings.shared.delaySeconds) : 0
        let settings = AppSettings.shared

        DispatchQueue.global(qos: .userInitiated).async {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("snaptool_\(UUID().uuidString).png")
            try? FileManager.default.removeItem(at: tmp)

            var args: [String] = []
            switch mode {
            case .region, .regionCopy, .regionDelayed:
                args += ["-i"]
            case .window:
                args += ["-i", "-W"]
                if !settings.windowShadow { args += ["-o"] }
            case .fullscreen:
                break
            }
            args += ["-t", "png"]
            if !settings.playSound { args += ["-x"] }
            if settings.includeCursor { args += ["-C"] }
            if delay > 0, mode != .regionCopy { args += ["-T", String(delay)] }
            args.append(tmp.path)

            let status = self.runScreencapture(args)
            let ok = FileManager.default.fileExists(atPath: tmp.path)
            guard status == 0, ok, let img = Renderer.loadCGImage(tmp) else {
                try? FileManager.default.removeItem(at: tmp)
                DispatchQueue.main.async { self.isCapturing = false }
                return
            }
            try? FileManager.default.removeItem(at: tmp)

            DispatchQueue.main.async {
                self.isCapturing = false
                self.handleCaptured(img, mode: mode)
            }
        }
    }

    private func runScreencapture(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = args
        do { try p.run() } catch {
            NSLog("SnapTool: 无法启动 screencapture \(error)")
            return -1
        }
        p.waitUntilExit()
        return p.terminationStatus
    }

    private func handleCaptured(_ img: CGImage, mode: CaptureMode) {
        let settings = AppSettings.shared

        // 兜底 1：完全透明 = 权限问题
        if BlankCheck.isTransparent(img) {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "截到的是空白图"
            a.informativeText = "系统未真正放行「屏幕录制」权限，请到系统设置中勾选 SnapTool，然后退出并重新打开本应用。"
            a.addButton(withTitle: "打开系统设置")
            a.addButton(withTitle: "知道了")
            if a.runModal() == .alertFirstButtonReturn { openScreenRecordingSettings() }
            return
        }

        // 兜底 2：近似纯色（截到纯白/纯黑，通常是窗口未就绪或权限异常）
        if BlankCheck.looksBlank(img) {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "截图内容疑似空白"
            a.informativeText = "这张图几乎没有内容变化（纯色）。可能是选中的区域本身是空白的，也可能是屏幕录制权限异常。要如何继续？"
            a.addButton(withTitle: "仍然编辑这张图")
            a.addButton(withTitle: "丢弃并检查权限")
            a.addButton(withTitle: "丢弃")
            switch a.runModal() {
            case .alertFirstButtonReturn:
                break
            case .alertSecondButtonReturn:
                fixPermission()
                return
            default:
                return
            }
        }

        if mode == .regionCopy && !settings.openEditor {
            Renderer.copyToPasteboard(img)
            if let url = saveToDisk(img) {
                Toast.show(image: img, text: "已复制到剪贴板", path: url.path)
            } else {
                Toast.show(image: img, text: "已复制到剪贴板", path: nil)
            }
            return
        }

        if settings.openEditor {
            EditorCenter.open(img)
            return
        }

        var savedPath: String?
        if let url = saveToDisk(img) { savedPath = url.path }
        if settings.autoCopy { Renderer.copyToPasteboard(img) }
        Toast.show(image: img,
                   text: settings.autoCopy ? "已复制到剪贴板" : "截图完成",
                   path: savedPath)
    }

    @discardableResult
    private func saveToDisk(_ img: CGImage) -> URL? {
        let dir = AppSettings.shared.saveDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("SnapTool_\(Renderer.fileStamp()).png")
        guard Renderer.savePNG(img, to: url) else { return nil }
        AppSettings.shared.pushRecent(url)
        return url
    }
}

// MARK: - 自检（渲染方向 / 标注正确性）

enum SelfTest {
    static func run(outputPath: String) -> Int32 {
        let W = 900, H = 620
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }

        // 背景：带文字标记的渐变，便于检查方向
        let colors = [NSColor(srgbRed: 0.99, green: 0.90, blue: 0.93, alpha: 1).cgColor,
                      NSColor(srgbRed: 0.80, green: 0.94, blue: 0.99, alpha: 1).cgColor] as CFArray
        if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: W, y: H), options: [])
        }
        // 预翻转 CTM，配合 flipped:true 的 NSGraphicsContext，文字才不会上下颠倒
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let title = NSAttributedString(string: "TOP-LEFT (0,0) → BOTTOM-RIGHT", attributes: [
            .font: NSFont.systemFont(ofSize: 26, weight: .bold), .foregroundColor: NSColor.black])
        title.draw(at: CGPoint(x: 24, y: 22))
        let foot = NSAttributedString(string: "底部文案应在此处 — BOTTOM", attributes: [
            .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)])
        foot.draw(at: CGPoint(x: 24, y: CGFloat(H) - 46))
        // 四个角标记
        for (i, p) in [CGPoint(x: 12, y: 12), CGPoint(x: CGFloat(W) - 40, y: 12),
                       CGPoint(x: 12, y: CGFloat(H) - 40), CGPoint(x: CGFloat(W) - 40, y: CGFloat(H) - 40)].enumerated() {
            NSAttributedString(string: "\(i + 1)", attributes: [
                .font: NSFont.systemFont(ofSize: 22, weight: .heavy),
                .foregroundColor: NSColor.systemBlue]).draw(at: p)
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()

        guard let base = ctx.makeImage() else { return 1 }
        let mosaic = Renderer.mosaic(from: base)

        var shapes: [Shape] = []
        var r = Shape(kind: .rect, points: [CGPoint(x: 120, y: 120), CGPoint(x: 380, y: 260)])
        r.color = .systemRed; r.lineWidth = 5
        shapes.append(r)

        var e = Shape(kind: .ellipse, points: [CGPoint(x: 450, y: 120), CGPoint(x: 700, y: 300)])
        e.color = .systemGreen; e.lineWidth = 6
        shapes.append(e)

        var a = Shape(kind: .arrow, points: [CGPoint(x: 120, y: 400), CGPoint(x: 420, y: 330)])
        a.color = .systemBlue; a.lineWidth = 5
        shapes.append(a)

        var p = Shape(kind: .pen, points: [])
        p.color = .systemPurple; p.lineWidth = 6
        p.points = stride(from: 0, through: 40, by: 1).map { i in
            let x = 120.0 + Double(i) * 6
            return CGPoint(x: x, y: 500 + sin(Double(i) / 4) * 18)
        }
        shapes.append(p)

        var t = Shape(kind: .text, points: [CGPoint(x: 460, y: 380)], text: "文字标注 Text ABC")
        t.color = .systemRed; t.lineWidth = 6
        shapes.append(t)

        var n = Shape(kind: .number, points: [CGPoint(x: 460, y: 460)], text: "1")
        n.color = .systemRed; n.lineWidth = 6
        shapes.append(n)
        var n2 = Shape(kind: .number, points: [CGPoint(x: 530, y: 460)], text: "2")
        n2.color = .systemBlue; n2.lineWidth = 6
        shapes.append(n2)

        var m = Shape(kind: .mosaic, points: [CGPoint(x: 640, y: 400), CGPoint(x: 840, y: 560)])
        m.color = .black; m.lineWidth = 4
        shapes.append(m)

        guard let out = Renderer.compose(base: base, mosaic: mosaic, shapes: shapes) else { return 1 }
        let url = URL(fileURLWithPath: outputPath)
        guard Renderer.savePNG(out, to: url) else { return 1 }

        // ── 空白检测自检
        func makeTestImage(_ fill: NSColor?) -> CGImage? {
            guard let c = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            if let f = fill {
                c.setFillColor(f.cgColor)
                c.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            }
            return c.makeImage()
        }
        let transparent = makeTestImage(nil)
        let white = makeTestImage(.white)
        var pass = true
        if let t = transparent, !(BlankCheck.isTransparent(t) && BlankCheck.looksBlank(t)) {
            print("FAIL: 全透明图未被识别"); pass = false
        }
        if let w = white, !BlankCheck.looksBlank(w) {
            print("FAIL: 纯白图未被识别"); pass = false
        }
        if BlankCheck.looksBlank(out) || BlankCheck.isTransparent(out) {
            print("FAIL: 正常图被误判为空白"); pass = false
        }
        print("blank-check: \(pass ? "PASS" : "FAIL")  (透明白=\(BlankCheck.isTransparent(transparent!)), 纯白空白=\(BlankCheck.looksBlank(white!)), 正常图空白=\(BlankCheck.looksBlank(out)))")

        print("selftest \(pass ? "ok" : "FAILED") -> \(outputPath)  \(out.width)x\(out.height)")
        return pass ? 0 : 1
    }
}

// MARK: - 入口

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--selftest") {
    let out = (i + 1 < args.count) ? args[i + 1] : "/tmp/snaptool_selftest.png"
    exit(SelfTest.run(outputPath: out))
}
if let i = args.firstIndex(of: "--editor"), i + 1 < args.count {
    if let img = Renderer.loadCGImage(URL(fileURLWithPath: args[i + 1])) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            EditorCenter.open(img)
        }
    }
    // 调试模式：不用 accessory，方便截屏验证
    NSApplication.shared.setActivationPolicy(.regular)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
