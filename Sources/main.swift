// PaperBrowser — a minimal, secure WebKit browser for macOS. Single file, no dependencies.
import Cocoa
import WebKit

let homeURL = URL(string: "https://duckduckgo.com")!
let allowedSchemes: Set<String> = ["https", "http", "about", "blob", "data"]

/// Turns address-bar text into a URL: plain words become a search, bare hosts get https.
func resolve(_ input: String) -> URL? {
    let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return nil }
    if let u = URL(string: s), let sc = u.scheme?.lowercased(), allowedSchemes.contains(sc), u.host != nil || sc == "about" {
        return u
    }
    if !s.contains(" "), s.contains("."), let u = URL(string: "https://" + s), u.host != nil { return u }
    var c = URLComponents(string: "https://duckduckgo.com/")!
    c.queryItems = [URLQueryItem(name: "q", value: s)]
    return c.url
}

final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate,
                                     WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let webView: WKWebView
    let address = NSTextField()
    let progress = NSProgressIndicator()
    let lock = NSImageView()
    private var observers: [NSKeyValueObservation] = []
    let isPrivate: Bool

    init(configuration: WKWebViewConfiguration? = nil, isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        let cfg = configuration ?? BrowserWindowController.makeConfiguration(isPrivate: isPrivate)
        webView = WKWebView(frame: .zero, configuration: cfg)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = isPrivate ? "private" : "normal"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.setFrameAutosaveName("PaperBrowser")
        super.init(window: window)
        window.delegate = self
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    static func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        c.preferences.isFraudulentWebsiteWarningEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.upgradeKnownHostsToHTTPS = true
        c.defaultWebpagePreferences.preferredContentMode = .desktop
        c.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        return c
    }

    private func buildUI() {
        let w = webView
        w.navigationDelegate = self
        w.uiDelegate = self
        w.allowsBackForwardNavigationGestures = true
        w.allowsMagnification = true
        w.isInspectable = false

        let back = button("chevron.left", #selector(goBack)), fwd = button("chevron.right", #selector(goForward))
        let reload = button("arrow.clockwise", #selector(reloadPage))
        address.placeholderString = isPrivate ? "Private — search or enter address" : "Search or enter address"
        address.delegate = self
        address.lineBreakMode = .byTruncatingTail
        address.cell?.isScrollable = true
        address.target = self; address.action = #selector(go)
        lock.imageScaling = .scaleProportionallyDown
        progress.style = .bar; progress.isIndeterminate = false; progress.minValue = 0; progress.maxValue = 1
        progress.controlSize = .small; progress.isHidden = true

        let bar = NSStackView(views: [back, fwd, reload, lock, address])
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 78, bottom: 0, right: 10)
        lock.widthAnchor.constraint(equalToConstant: 14).isActive = true

        let root = NSView()
        for v in [bar, progress, w] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 4),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 30),
            progress.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 2),
            progress.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
            w.topAnchor.constraint(equalTo: progress.bottomAnchor),
            w.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            w.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            w.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window?.contentView = root

        observers = [
            w.observe(\.estimatedProgress) { [weak self] v, _ in
                self?.progress.doubleValue = v.estimatedProgress
                self?.progress.isHidden = v.estimatedProgress >= 1
            },
            w.observe(\.title) { [weak self] v, _ in
                let t = v.title?.isEmpty == false ? v.title! : "New Tab"
                self?.window?.title = (self?.isPrivate == true ? "🔒 " : "") + t
            },
            w.observe(\.url) { [weak self] v, _ in self?.syncAddress() },
            w.observe(\.hasOnlySecureContent) { [weak self] _, _ in self?.syncAddress() },
            w.observe(\.canGoBack) { _, _ in back.isEnabled = w.canGoBack },
            w.observe(\.canGoForward) { _, _ in fwd.isEnabled = w.canGoForward },
        ]
        back.isEnabled = false; fwd.isEnabled = false
    }

    private func button(_ symbol: String, _ sel: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!, target: self, action: sel)
        b.bezelStyle = .texturedRounded; b.isBordered = false
        return b
    }

    private func syncAddress() {
        if window?.firstResponder != address.currentEditor() { address.stringValue = webView.url?.absoluteString ?? "" }
        let secure = webView.url?.scheme == "https" && webView.hasOnlySecureContent
        lock.image = webView.url == nil ? nil : NSImage(systemSymbolName: secure ? "lock.fill" : "exclamationmark.triangle.fill", accessibilityDescription: nil)
        lock.contentTintColor = secure ? .secondaryLabelColor : .systemOrange
        lock.toolTip = secure ? "Secure connection" : "Not secure"
    }

    func load(_ url: URL) { webView.load(URLRequest(url: url)) }
    @objc func go() { if let u = resolve(address.stringValue) { load(u); window?.makeFirstResponder(webView) } }
    @objc func goBack() { webView.goBack() }
    @objc func goForward() { webView.goForward() }
    @objc func reloadPage() { webView.reload() }
    @objc func reloadIgnoringCache(_ s: Any?) { webView.reloadFromOrigin() }
    @objc func focusAddress(_ s: Any?) { window?.makeFirstResponder(address) }
    @objc func zoomIn(_ s: Any?) { webView.pageZoom = min(webView.pageZoom + 0.1, 3) }
    @objc func zoomOut(_ s: Any?) { webView.pageZoom = max(webView.pageZoom - 0.1, 0.3) }
    @objc func zoomReset(_ s: Any?) { webView.pageZoom = 1 }
    @objc func stopLoading(_ s: Any?) { webView.stopLoading() }
    @objc override func newWindowForTab(_ sender: Any?) { AppDelegate.shared.newTab(nil) }

    @objc func findInPage(_ s: Any?) {
        let a = NSAlert(); a.messageText = "Find in Page"; a.addButton(withTitle: "Find"); a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); a.accessoryView = f
        a.window.initialFirstResponder = f
        a.beginSheetModal(for: window!) { [weak self] r in
            guard r == .alertFirstButtonReturn, !f.stringValue.isEmpty else { return }
            let c = WKFindConfiguration(); c.wraps = true
            self?.webView.find(f.stringValue, configuration: c) { res in if !res.matchFound { NSSound.beep() } }
        }
    }

    // MARK: Navigation policy (security)
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return decisionHandler(.cancel, preferences) }
        if action.shouldPerformDownload { return decisionHandler(.download, preferences) }
        if allowedSchemes.contains(scheme) {
            // Upgrade top-level plain-HTTP navigations to HTTPS (HTTPS-first); falls back on failure.
            if scheme == "http", action.targetFrame?.isMainFrame == true, !httpAllowed.contains(url.host ?? ""),
               var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                c.scheme = "https"; if c.port == 80 { c.port = nil }
                if let u = c.url { decisionHandler(.cancel, preferences); pendingUpgrade = url.host; w.load(URLRequest(url: u)); return }
            }
            return decisionHandler(.allow, preferences)
        }
        // Other schemes (mailto:, apps…) only after explicit user confirmation.
        decisionHandler(.cancel, preferences)
        guard action.navigationType == .linkActivated, let win = window else { return }
        let a = NSAlert(); a.messageText = "Open external link?"; a.informativeText = url.absoluteString
        a.addButton(withTitle: "Open"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: win) { if $0 == .alertFirstButtonReturn { NSWorkspace.shared.open(url) } }
    }

    private var httpAllowed: Set<String> = []
    private var pendingUpgrade: String?

    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError error: Error) {
        let e = error as NSError
        if e.code == NSURLErrorCancelled || e.code == 102 /* frame load interrupted (download) */ { return }
        if let host = pendingUpgrade, let failing = e.userInfo[NSURLErrorFailingURLErrorKey] as? URL, failing.host == host, let win = window {
            pendingUpgrade = nil
            let a = NSAlert(); a.messageText = "\(host) does not support HTTPS"
            a.informativeText = "Continue over an insecure connection? Data you send could be read by others."
            a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Continue (Not Secure)")
            a.beginSheetModal(for: win) { [weak self] r in
                guard r == .alertSecondButtonReturn, var c = URLComponents(url: failing, resolvingAgainstBaseURL: false) else { return }
                self?.httpAllowed.insert(host); c.scheme = "http"; if let u = c.url { self?.load(u) }
            }
            return
        }
        let html = "<meta charset=utf-8><body style='font:15px -apple-system;padding:60px;color:#555'><h2>Can’t open this page</h2><p>\(e.localizedDescription.replacingOccurrences(of: "<", with: "&lt;"))</p>"
        w.loadHTMLString(html, baseURL: nil)
    }
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) { pendingUpgrade = nil }

    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(r.canShowMIMEType ? .allow : .download)
    }
    func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome d: WKDownload) { d.delegate = self }
    func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { w.reload() }

    // MARK: Downloads — saved to ~/Downloads, never auto-opened
    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename name: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let safe = (name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "_")
        var dest = dir.appendingPathComponent(safe.isEmpty ? "download" : safe), i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
            dest = dir.appendingPathComponent("\(base) (\(i))" + (ext.isEmpty ? "" : ".\(ext)")); i += 1
        }
        completionHandler(dest)
    }
    func downloadDidFinish(_ d: WKDownload) { NSSound(named: "Glass")?.play() }

    // MARK: UI delegate — popups, dialogs, file upload, permissions
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let c = BrowserWindowController(configuration: cfg, isPrivate: isPrivate)
        AppDelegate.shared.add(c, tabbedTo: window)
        return c.webView
    }
    func webViewDidClose(_ w: WKWebView) { window?.close() }
    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = f.securityOrigin.host; a.informativeText = m
        a.beginSheetModal(for: window!) { _ in completionHandler() }
    }
    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = f.securityOrigin.host; a.informativeText = m
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window!) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText: String?, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = f.securityOrigin.host; a.informativeText = p
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        let t = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); t.stringValue = defaultText ?? ""; a.accessoryView = t
        a.beginSheetModal(for: window!) { completionHandler($0 == .alertFirstButtonReturn ? t.stringValue : nil) }
    }
    func webView(_ w: WKWebView, runOpenPanelWith p: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let o = NSOpenPanel(); o.allowsMultipleSelection = p.allowsMultipleSelection; o.canChooseDirectories = p.allowsDirectories
        o.beginSheetModal(for: window!) { completionHandler($0 == .OK ? o.urls : nil) }
    }
    func webView(_ w: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame f: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let a = NSAlert(); a.messageText = "Allow \(origin.host) to use your \(type == .camera ? "camera" : type == .microphone ? "microphone" : "camera and microphone")?"
        a.addButton(withTitle: "Don’t Allow"); a.addButton(withTitle: "Allow")
        a.beginSheetModal(for: window!) { decisionHandler($0 == .alertSecondButtonReturn ? .grant : .deny) }
    }

    func controlTextDidEndEditing(_ n: Notification) { syncAddress() }
    func windowWillClose(_ n: Notification) {
        webView.stopLoading(); observers.removeAll()
        AppDelegate.shared.windows.removeAll { $0 === self }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let shared = AppDelegate()
    var windows: [BrowserWindowController] = []
    var current: BrowserWindowController? { NSApp.keyWindow?.windowController as? BrowserWindowController }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        newWindow(nil)
        NSApp.activate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func application(_ app: NSApplication, open urls: [URL]) {
        for u in urls where allowedSchemes.contains(u.scheme?.lowercased() ?? "") { let c = newWindow(nil, load: false); c.load(u) }
    }

    func add(_ c: BrowserWindowController, tabbedTo host: NSWindow?) {
        windows.append(c)
        if let host, let w = c.window { host.addTabbedWindow(w, ordered: .above) }
        c.window?.makeKeyAndOrderFront(nil)
    }
    @discardableResult @objc func newWindow(_ s: Any?, load: Bool = true) -> BrowserWindowController {
        let c = BrowserWindowController(); add(c, tabbedTo: nil); c.window?.center()
        if load { c.load(homeURL) }; c.focusAddress(nil); return c
    }
    @objc func newPrivateWindow(_ s: Any?) {
        let c = BrowserWindowController(isPrivate: true); add(c, tabbedTo: nil); c.focusAddress(nil)
    }
    @objc func newTab(_ s: Any?) {
        guard let cur = current else { newWindow(nil); return }
        let c = BrowserWindowController(isPrivate: cur.isPrivate); add(c, tabbedTo: cur.window)
        if !cur.isPrivate { c.load(homeURL) }; c.focusAddress(nil)
    }
    @objc func clearData(_ s: Any?) {
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    private func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) { let m = NSMenu(title: title); items.forEach(m.addItem); let i = NSMenuItem(); i.submenu = m; main.addItem(i) }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; i.target = target; return i
        }
        menu("PaperBrowser", [
            item("Clear Browsing Data", #selector(clearData), "", target: self), .separator(),
            item("Hide PaperBrowser", #selector(NSApplication.hide), "h"),
            item("Quit PaperBrowser", #selector(NSApplication.terminate), "q"),
        ])
        menu("File", [
            item("New Tab", #selector(newTab), "t", target: self),
            item("New Window", #selector(newWindow(_:load:)), "n", target: self),
            item("New Private Window", #selector(newPrivateWindow), "n", [.command, .shift], target: self),
            item("Open Location…", #selector(BrowserWindowController.focusAddress), "l"), .separator(),
            item("Close Tab", #selector(NSWindow.performClose), "w"),
            item("Print…", #selector(NSView.printView), "p"),
        ])
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            item("Cut", #selector(NSText.cut), "x"), item("Copy", #selector(NSText.copy), "c"),
            item("Paste", #selector(NSText.paste), "v"), item("Select All", #selector(NSText.selectAll), "a"), .separator(),
            item("Find…", #selector(BrowserWindowController.findInPage), "f"),
        ])
        menu("View", [
            item("Reload", #selector(BrowserWindowController.reloadPage), "r"),
            item("Reload Ignoring Cache", #selector(BrowserWindowController.reloadIgnoringCache), "r", [.command, .shift]),
            item("Stop", #selector(BrowserWindowController.stopLoading), "."), .separator(),
            item("Zoom In", #selector(BrowserWindowController.zoomIn), "+"),
            item("Zoom Out", #selector(BrowserWindowController.zoomOut), "-"),
            item("Actual Size", #selector(BrowserWindowController.zoomReset), "0"), .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen), "f", [.command, .control]),
        ])
        menu("History", [
            item("Back", #selector(BrowserWindowController.goBack), "["),
            item("Forward", #selector(BrowserWindowController.goForward), "]"),
        ])
        let win = NSMenu(title: "Window")
        [item("Minimize", #selector(NSWindow.performMiniaturize), "m"),
         item("Show Next Tab", #selector(NSWindow.selectNextTab), "}", [.command, .shift]),
         item("Show Previous Tab", #selector(NSWindow.selectPreviousTab), "{", [.command, .shift])].forEach(win.addItem)
        let wi = NSMenuItem(); wi.submenu = win; main.addItem(wi)
        NSApp.mainMenu = main; NSApp.windowsMenu = win
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = AppDelegate.shared
app.run()
