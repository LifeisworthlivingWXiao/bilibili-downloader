import AppKit

final class Downloader: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let engine = Process()
    var endpoint: URL!
    var token = ""
    var timer: Timer?
    var running = false
    var initialized = false

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 505),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    let link = NSTextField()
    let folder = NSTextField()
    let format = NSPopUpButton()
    let status = NSTextField(labelWithString: "正在启动下载引擎…")
    let logs = NSTextView()
    var startButton: NSButton!
    var cancelButton: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        do {
            try startEngine()
            try refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                do { try self.refresh() }
                catch {
                    self.status.stringValue = "无法连接下载引擎"
                    self.startButton.isEnabled = false
                    self.running = self.engine.isRunning && self.running
                }
            }
        } catch {
            status.stringValue = "下载引擎启动失败"
            showError(error.localizedDescription)
        }
    }

    func buildMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出 Bilibili 下载器", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        bar.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        bar.addItem(editItem)
        NSApp.mainMenu = bar
    }

    func buildWindow() {
        window.title = "Bilibili 下载器"
        window.delegate = self
        window.center()
        let view = window.contentView!
        func put(_ control: NSView, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) {
            control.frame = NSRect(x: x, y: y, width: width, height: height)
            view.addSubview(control)
        }
        func button(_ title: String, _ action: Selector, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat) -> NSButton {
            let control = NSButton(title: title, target: self, action: action)
            control.bezelStyle = .rounded
            put(control, x, y, width, 32)
            return control
        }
        let title = NSTextField(labelWithString: "Bilibili 下载器")
        title.font = .systemFont(ofSize: 31, weight: .bold)
        put(title, 24, 441, 630, 40)
        put(NSTextField(labelWithString: "视频地址 · B 站链接、分享文本或 BV/av 号"), 24, 404, 630, 22)
        link.placeholderString = "https://www.bilibili.com/video/BV…"
        put(link, 24, 369, 632, 27)
        put(NSTextField(labelWithString: "输出格式"), 24, 330, 82, 22)
        format.addItems(withTitles: ["MP4 视频", "MP3 音频", "M4A 音频"])
        put(format, 106, 326, 167, 29)
        put(NSTextField(labelWithString: "保存目录"), 24, 292, 82, 22)
        put(folder, 106, 291, 465, 26)
        _ = button("选择…", #selector(chooseFolder), 577, 286, 81)
        startButton = button("开始下载", #selector(start), 24, 238, 104)
        startButton.keyEquivalent = "\r"
        startButton.isEnabled = false
        cancelButton = button("取消任务", #selector(cancel), 133, 238, 104)
        cancelButton.isEnabled = false
        _ = button("打开保存目录", #selector(openFolder), 242, 238, 134)
        status.font = .systemFont(ofSize: 14, weight: .semibold)
        put(status, 24, 203, 632, 22)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        logs.isEditable = false
        logs.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        logs.textContainer?.widthTracksTextView = true
        scroll.documentView = logs
        put(scroll, 24, 23, 632, 171)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(link)
        NSApp.activate(ignoringOtherApps: true)
    }

    func startEngine() throws {
        let pipe = Pipe()
        engine.standardOutput = pipe
        engine.executableURL = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("BilibiliEngine")
        try engine.run()
        let reader = pipe.fileHandleForReading
        var data = Data()
        while data.count < 512 {
            let byte = reader.readData(ofLength: 1)
            if byte.isEmpty || byte.first == 10 { break }
            data.append(byte)
        }
        guard let address = String(data: data, encoding: .utf8),
              let url = URL(string: address),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let key = parts.queryItems?.first(where: { $0.name == "token" })?.value,
              let port = parts.port, parts.host == "127.0.0.1" else {
            throw failure("无法读取下载引擎地址")
        }
        endpoint = URL(string: "http://127.0.0.1:\(port)")!
        token = key
    }

    func failure(_ message: String) -> NSError {
        NSError(domain: "BilibiliDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func call(_ action: String, _ payload: [String: String]? = nil) throws -> Data {
        guard let endpoint = endpoint else { throw failure("下载引擎尚未连接") }
        var request = URLRequest(url: endpoint.appendingPathComponent("api").appendingPathComponent(action),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.setValue(token, forHTTPHeaderField: "X-Bili-Token")
        if let payload = payload {
            request.httpMethod = "POST"
            request.setValue(endpoint.absoluteString, forHTTPHeaderField: "Origin")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        }
        var response: URLResponse?
        let data = try NSURLConnection.sendSynchronousRequest(request, returning: &response)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw failure(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "下载引擎请求失败")
        }
        return data
    }

    struct State: Decodable {
        var status: String
        var folder: String
        var log: [String]?
        var file: String
    }

    func refresh() throws {
        let state = try JSONDecoder().decode(State.self, from: call("state"))
        if !initialized { folder.stringValue = state.folder; initialized = true }
        running = state.status == "运行中"
        status.stringValue = state.status
        startButton.isEnabled = !running
        cancelButton.isEnabled = running
        let message = ((state.log ?? []) + (state.file.isEmpty ? [] : [state.file])).joined(separator: "\n")
        if logs.string != message {
            logs.string = message
            logs.scrollRangeToVisible(NSRange(location: (message as NSString).length, length: 0))
        }
    }

    func perform(_ action: String, _ payload: [String: String] = [:]) {
        do { _ = try call(action, payload); try refresh() }
        catch { showError(error.localizedDescription) }
    }

    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window)
    }

    @objc func start() {
        perform("start", ["url": link.stringValue, "folder": folder.stringValue,
                          "format": ["mp4", "mp3", "m4a"][format.indexOfSelectedItem]])
    }

    @objc func cancel() { perform("cancel") }
    @objc func openFolder() { perform("open") }

    @objc func chooseFolder() {
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.canCreateDirectories = true
        picker.directoryURL = URL(fileURLWithPath: folder.stringValue)
        if picker.runModal() == .OK, let selected = picker.url {
            folder.stringValue = selected.path
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if running { showError("请先取消任务，或等待下载完成。") }
        return !running
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if running { showError("请先取消任务，或等待下载完成。"); return .terminateCancel }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if engine.isRunning { engine.terminate() }
    }
}

let app = NSApplication.shared
let delegate = Downloader()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
