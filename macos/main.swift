// Materialize.app - a native macOS shell around the local Materialize UI.
//
// The app owns a private copy of the CLI, the Python server and the web UI
// inside its bundle, so it runs with nothing installed on the machine beyond
// a system Python. On launch it picks a free loopback port, starts the server
// as a child process, waits for it to answer, and shows the page in a
// WKWebView. A web view does not pick files or save downloads on its own, so
// both are wired to real AppKit panels here.

import AppKit
import Darwin
import UniformTypeIdentifiers
@preconcurrency import WebKit

// MARK: - Bundle layout

enum Res {
    static let ui = Bundle.main.resourceURL!.appendingPathComponent("ui")
    static let serve = ui.appendingPathComponent("serve.py")
    static let cli = Bundle.main.resourceURL!
        .appendingPathComponent("bin").appendingPathComponent("materialize")
    static let log = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs").appendingPathComponent("Materialize.log")
}

// MARK: - Finding a port and a Python

/// True when nothing is listening on 127.0.0.1:port.
func portIsFree(_ port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return rc == 0
}

func pickPort() -> UInt16? {
    // Start where the command-line server does, then step past any copy of it
    // the user already has running.
    for port in UInt16(8765)...UInt16(8795) where portIsFree(port) { return port }
    return nil
}

/// First Python that actually runs. `/usr/bin/python3` is a stub that fails
/// when the Command Line Tools are missing, so candidates are executed, not
/// just stat'd. A Finder launch has almost no PATH, hence the absolute list.
func findPython() -> String? {
    let candidates = ["/usr/bin/python3", "/opt/homebrew/bin/python3",
                      "/usr/local/bin/python3"]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: path)
        probe.arguments = ["-c", "import http.server"]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        if (try? probe.run()) != nil {
            probe.waitUntilExit()
            if probe.terminationStatus == 0 { return path }
        }
    }
    return nil
}

// MARK: - The server child process

final class Server {
    let port: UInt16
    private let process = Process()

    var url: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    init(port: UInt16, python: String) throws {
        self.port = port
        try? FileManager.default.createDirectory(
            at: Res.log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: Res.log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: Res.log)
        handle.truncateFile(atOffset: 0)

        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [Res.serve.path, "--port", String(port), "--no-open",
                             "--binary", Res.cli.path]
        process.standardOutput = handle
        process.standardError = handle
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    /// Waits for the server to answer, so the page is never loaded too early.
    func waitUntilReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let status = url.appendingPathComponent("api/status")
        while Date() < deadline {
            if !process.isRunning { return false }
            var request = URLRequest(url: status)
            request.timeoutInterval = 1.5
            let semaphore = DispatchSemaphore(value: 0)
            var ok = false
            URLSession.shared.dataTask(with: request) { _, response, _ in
                ok = (response as? HTTPURLResponse)?.statusCode == 200
                semaphore.signal()
            }.resume()
            _ = semaphore.wait(timeout: .now() + 2.0)
            if ok { return true }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }

    /// SIGINT rather than SIGTERM: the server cleans up its scratch directory
    /// on KeyboardInterrupt, and a plain terminate would leave it behind.
    func stop() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGINT)
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate() }
    }
}

// MARK: - Loading overlay

final class LoadingView: NSView {
    private let label = NSTextField(labelWithString: "Starting Materialize…")
    private let spinner = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.055, green: 0.063, blue: 0.075, alpha: 1).cgColor

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimation(nil)
        addSubview(spinner)

        label.font = .systemFont(ofSize: 13)
        label.textColor = NSColor(red: 0.58, green: 0.63, blue: 0.70, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -16),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 14),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setMessage(_ text: String) { label.stringValue = text }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate,
                         WKUIDelegate, WKDownloadDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var overlay: LoadingView!
    private var server: Server?
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildWindow()
        startServer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) { server?.stop() }

    // MARK: window

    private func buildWindow() {
        let frame = NSRect(x: 0, y: 0, width: 1180, height: 820)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Materialize"
        window.minSize = NSSize(width: 820, height: 560)
        window.setFrameAutosaveName("MaterializeMainWindow")
        window.center()
        window.backgroundColor = NSColor(red: 0.055, green: 0.063, blue: 0.075, alpha: 1)

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Right-click > Inspect Element, which is how you debug the page itself.
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        webView = WKWebView(frame: frame, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.allowsMagnification = true
        if #available(macOS 12.0, *) {
            webView.underPageBackgroundColor = NSColor(red: 0.055, green: 0.063,
                                                       blue: 0.075, alpha: 1)
        }

        overlay = LoadingView(frame: frame)
        overlay.autoresizingMask = [.width, .height]

        let content = NSView(frame: frame)
        content.addSubview(webView)
        content.addSubview(overlay)
        window.contentView = content

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: server lifecycle

    private func startServer() {
        guard FileManager.default.isExecutableFile(atPath: Res.cli.path) else {
            fail("The bundled materialize binary is missing.",
                 "Rebuild the app with macos/build-app.sh.")
            return
        }
        guard let python = findPython() else {
            fail("No usable Python 3 found.",
                 "Materialize needs python3. Install Apple's Command Line Tools "
                 + "with 'xcode-select --install', then open the app again.")
            return
        }
        guard let port = pickPort() else {
            fail("No free port available.",
                 "Ports 8765-8795 are all in use. Quit whatever is using them "
                 + "and open the app again.")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let server = try Server(port: port, python: python)
                let ready = server.waitUntilReady(timeout: 25)
                DispatchQueue.main.async {
                    self.server = server
                    if ready {
                        self.overlay.setMessage("Loading…")
                        self.webView.load(URLRequest(url: server.url))
                    } else {
                        self.fail("The Materialize server did not start.",
                                  self.logTail())
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.fail("Could not start the Materialize server.",
                              error.localizedDescription)
                }
            }
        }
    }

    private func logTail() -> String {
        guard let text = try? String(contentsOf: Res.log, encoding: .utf8) else {
            return "No log output was produced."
        }
        let lines = text.split(separator: "\n").suffix(12)
        return lines.isEmpty ? "No log output was produced." : lines.joined(separator: "\n")
    }

    private func fail(_ message: String, _ detail: String) {
        overlay.setMessage(message)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Show Log")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Res.log])
        }
        NSApp.terminate(nil)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        overlay.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        overlay.isHidden = false
        overlay.setMessage("Could not load the page: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The renderer can be jettisoned under memory pressure; just come back.
        if let url = server?.url { webView.load(URLRequest(url: url)) }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // Anything that is not our own server (documentation links and such)
        // belongs in the user's real browser, not in this window.
        if let url = navigationAction.request.url,
           navigationAction.navigationType == .linkActivated,
           url.host != "127.0.0.1" {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Zips cannot be displayed, so they become downloads instead of a
        // silently cancelled navigation.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: WKUIDelegate

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.message = "Choose a diffuse texture"
        panel.prompt = "Open"
        panel.allowedContentTypes = ["png", "jpg", "jpeg", "tga", "exr"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Materialize"
        alert.informativeText = message
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    // MARK: WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory,
                                                 in: .userDomainMask)[0]
        var target = downloads.appendingPathComponent(suggestedFilename)
        // Never overwrite an earlier export.
        let ext = target.pathExtension
        let stem = target.deletingPathExtension().lastPathComponent
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = downloads.appendingPathComponent("\(stem) \(n)")
                .appendingPathExtension(ext)
            n += 1
        }
        downloadDestinations[ObjectIdentifier(download)] = target
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let url = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error,
                  resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        let alert = NSAlert()
        alert.messageText = "Download failed"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: menu

    @objc private func reloadPage() { webView.reload() }
    @objc private func openTexture() {
        // Drives the page's own hidden file input, so one code path handles
        // the picked file whether it came from the menu or the drop zone.
        webView.evaluateJavaScript("document.getElementById('file').click()")
    }
    @objc private func zoomIn() { webView.pageZoom = min(webView.pageZoom + 0.1, 3.0) }
    @objc private func zoomOut() { webView.pageZoom = max(webView.pageZoom - 0.1, 0.5) }
    @objc private func zoomActual() { webView.pageZoom = 1.0 }
    @objc private func showLog() { NSWorkspace.shared.activateFileViewerSelecting([Res.log]) }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Materialize",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Show Server Log", action: #selector(showLog), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Materialize", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Materialize", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open Texture…", action: #selector(openTexture), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(zoomActual), keyEquivalent: "0")
        viewMenu.addItem(withTitle: "Zoom In", action: #selector(zoomIn), keyEquivalent: "+")
        viewMenu.addItem(withTitle: "Zoom Out", action: #selector(zoomOut), keyEquivalent: "-")
        viewMenu.addItem(.separator())
        let fullScreen = NSMenuItem(title: "Enter Full Screen",
                                    action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreen)
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
