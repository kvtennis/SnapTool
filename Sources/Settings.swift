import Cocoa

final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    private enum K {
        static let dir = "saveDirectory"
        static let autoCopy = "autoCopy"
        static let openEditor = "openEditor"
        static let sound = "playSound"
        static let cursor = "includeCursor"
        static let shadow = "windowShadow"
        static let recent = "recentFiles"
        static let delay = "delaySeconds"
        static let registered = "didPromptPermission"
    }

    private init() {
        d.register(defaults: [
            K.autoCopy: true,
            K.openEditor: true,
            K.sound: false,
            K.cursor: false,
            K.shadow: false,
            K.delay: 0,
            K.registered: false
        ])
    }

    var saveDirectory: URL {
        get {
            if let p = d.string(forKey: K.dir), !p.isEmpty {
                return URL(fileURLWithPath: p)
            }
            let def = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures/SnapTool", isDirectory: true)
            try? FileManager.default.createDirectory(at: def, withIntermediateDirectories: true)
            return def
        }
        set { d.set(newValue.path, forKey: K.dir) }
    }

    var autoCopy: Bool {
        get { d.bool(forKey: K.autoCopy) }
        set { d.set(newValue, forKey: K.autoCopy) }
    }
    var openEditor: Bool {
        get { d.bool(forKey: K.openEditor) }
        set { d.set(newValue, forKey: K.openEditor) }
    }
    var playSound: Bool {
        get { d.bool(forKey: K.sound) }
        set { d.set(newValue, forKey: K.sound) }
    }
    var includeCursor: Bool {
        get { d.bool(forKey: K.cursor) }
        set { d.set(newValue, forKey: K.cursor) }
    }
    var windowShadow: Bool {
        get { d.bool(forKey: K.shadow) }
        set { d.set(newValue, forKey: K.shadow) }
    }
    var delaySeconds: Int {
        get { d.integer(forKey: K.delay) }
        set { d.set(newValue, forKey: K.delay) }
    }
    var didPromptPermission: Bool {
        get { d.bool(forKey: K.registered) }
        set { d.set(newValue, forKey: K.registered) }
    }

    var recentFiles: [String] {
        get { d.stringArray(forKey: K.recent) ?? [] }
        set { d.set(Array(newValue.prefix(10)), forKey: K.recent) }
    }

    func pushRecent(_ url: URL) {
        var list = recentFiles.filter { $0 != url.path }
        list.insert(url.path, at: 0)
        recentFiles = list
    }
}

// MARK: - 设置窗口

final class SettingsWindowController: NSWindowController {

    static var shared: SettingsWindowController?

    static func show() {
        if shared == nil { shared = SettingsWindowController() }
        shared?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var dirLabel: NSTextField!

    convenience init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "SnapTool 设置"
        w.center()
        w.isReleasedWhenClosed = false
        self.init(window: w)
        build()
    }

    private func build() {
        guard let cv = window?.contentView else { return }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(stack)

        let title = NSTextField(labelWithString: "截图设置")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(20, after: title)

        // 保存目录
        let dirRow = NSStackView()
        dirRow.orientation = .horizontal
        dirRow.spacing = 10
        dirLabel = NSTextField(labelWithString: AppSettings.shared.saveDirectory.path)
        dirLabel.lineBreakMode = .byTruncatingMiddle
        dirLabel.textColor = .secondaryLabelColor
        dirLabel.widthAnchor.constraint(equalToConstant: 230).isActive = true
        let chooseBtn = NSButton(title: "选择文件夹…", target: self, action: #selector(chooseDir))
        chooseBtn.bezelStyle = .rounded
        let openBtn = NSButton(title: "打开", target: self, action: #selector(openDir))
        openBtn.bezelStyle = .rounded
        dirRow.addArrangedSubview(NSTextField(labelWithString: "保存位置"))
        dirRow.addArrangedSubview(dirLabel)
        dirRow.addArrangedSubview(chooseBtn)
        dirRow.addArrangedSubview(openBtn)
        stack.addArrangedSubview(dirRow)

        stack.addArrangedSubview(makeCheck("截图后自动复制到剪贴板", #selector(toggleAutoCopy), AppSettings.shared.autoCopy))
        stack.addArrangedSubview(makeCheck("截图后打开标注编辑器", #selector(toggleOpenEditor), AppSettings.shared.openEditor))
        stack.addArrangedSubview(makeCheck("截图时播放提示音", #selector(toggleSound), AppSettings.shared.playSound))
        stack.addArrangedSubview(makeCheck("捕获鼠标指针", #selector(toggleCursor), AppSettings.shared.includeCursor))
        stack.addArrangedSubview(makeCheck("窗口截图保留阴影", #selector(toggleShadow), AppSettings.shared.windowShadow))

        // 延时
        let delayRow = NSStackView()
        delayRow.orientation = .horizontal
        delayRow.spacing = 10
        delayRow.addArrangedSubview(NSTextField(labelWithString: "区域截图延时"))
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for (i, t) in ["不延时", "3 秒", "5 秒", "10 秒"].enumerated() {
            popup.addItem(withTitle: t)
            popup.lastItem?.tag = [0, 3, 5, 10][i]
        }
        let cur = AppSettings.shared.delaySeconds
        popup.selectItem(withTag: cur)
        popup.target = self
        popup.action = #selector(changeDelay(_:))
        delayRow.addArrangedSubview(popup)
        stack.addArrangedSubview(delayRow)

        let tip = NSTextField(wrappingLabelWithString: """
        快捷键：
        ⌃⌥A 区域截图并编辑    ⌃⌥C 区域截图直接复制
        ⌃⌥F 全屏截图          ⌃⌥W 窗口截图
        ⌃⌥D 延时区域截图      ⌃⌥Z 反复上次模式

        编辑器内：拖动图片可直接拖到微信/QQ等应用；⌘C 复制、⌘S 保存、⌘Z 撤销、Esc 关闭。
        首次使用需在「系统设置 → 隐私与安全性 → 屏幕录制」中授权 SnapTool。
        """)
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .tertiaryLabelColor
        stack.addArrangedSubview(tip)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: cv.topAnchor, constant: 20)
        ])
    }

    private func makeCheck(_ title: String, _ action: Selector, _ on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.state = on ? .on : .off
        return b
    }

    private func refresh() {
        dirLabel.stringValue = AppSettings.shared.saveDirectory.path
    }

    @objc private func chooseDir() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.directoryURL = AppSettings.shared.saveDirectory
        if p.runModal() == .OK, let url = p.url {
            AppSettings.shared.saveDirectory = url
            refresh()
        }
    }

    @objc private func openDir() {
        NSWorkspace.shared.open(AppSettings.shared.saveDirectory)
    }

    @objc private func toggleAutoCopy(_ s: NSButton) { AppSettings.shared.autoCopy = s.state == .on }
    @objc private func toggleOpenEditor(_ s: NSButton) { AppSettings.shared.openEditor = s.state == .on }
    @objc private func toggleSound(_ s: NSButton) { AppSettings.shared.playSound = s.state == .on }
    @objc private func toggleCursor(_ s: NSButton) { AppSettings.shared.includeCursor = s.state == .on }
    @objc private func toggleShadow(_ s: NSButton) { AppSettings.shared.windowShadow = s.state == .on }
    @objc private func changeDelay(_ s: NSPopUpButton) {
        AppSettings.shared.delaySeconds = s.selectedItem?.tag ?? 0
    }
}
