// PaperBrowser — 髪くらい軽い神ブラウザー。
// A minimal, secure WebKit browser for macOS. Single file, no dependencies.
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

// MARK: - Theme: washi paper + a single vermilion hairline

enum Theme {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { a in
            let v = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        }
    }
    static let paper = dyn(0xF4EFE6, 0x1B1A18)      // chrome background
    static let sheet = dyn(0xFFFDF8, 0x2A2825)      // selected tab / address field
    static let ink = dyn(0x2B2722, 0xECE6DA)        // primary text
    static let faint = dyn(0x8A8276, 0x8E877B)      // secondary text
    static let hair = dyn(0xE2DACB, 0x34312C)       // hairline separators
    static let shu = dyn(0xD9442F, 0xF0604A)        // 朱 accent: progress, focus
    static let hover = dyn(0xEAE3D6, 0x24221F)
}

class FlatView: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 0 { didSet { needsDisplay = true } }
    var stroke: NSColor? { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layerContentsRedrawPolicy = .onSetNeedsDisplay }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        // Resolve dynamic colors against this view's appearance (light/dark).
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill?.cgColor
            layer?.borderColor = stroke?.cgColor
        }
        layer?.borderWidth = stroke == nil ? 0 : 1
        layer?.cornerRadius = radius
    }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }
}

func symbolButton(_ name: String, _ target: AnyObject, _ sel: Selector, size: CGFloat = 13) -> NSButton {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: name)!
        .withSymbolConfiguration(.init(pointSize: size, weight: .regular))!
    let b = NSButton(image: img, target: target, action: sel)
    b.isBordered = false; b.contentTintColor = Theme.faint
    b.setButtonType(.momentaryChange)
    return b
}

// MARK: - Lite Mode: per-site "JavaScript off" for pages you only read

enum LiteMode {
    private static let key = "LiteSites"
    private static var privateHosts: Set<String> = []          // private windows never write to disk
    private static func saved() -> Set<String> { Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    static func site(_ url: URL?) -> String? {
        guard let h = url?.host?.lowercased(), !h.isEmpty else { return nil }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
    static func isOn(_ url: URL?, isPrivate: Bool) -> Bool {
        guard let s = site(url) else { return false }
        return saved().contains(s) || (isPrivate && privateHosts.contains(s))
    }
    static func toggle(_ url: URL?, isPrivate: Bool) {
        guard let s = site(url) else { return }
        if isPrivate && !saved().contains(s) {
            if privateHosts.contains(s) { privateHosts.remove(s) } else { privateHosts.insert(s) }
            return
        }
        var set = saved()
        if set.contains(s) { set.remove(s) } else { set.insert(s) }
        UserDefaults.standard.set(set.sorted(), forKey: key)
    }
}

// MARK: - Tab: owns one web view and all of its WebKit delegate logic

final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var owner: BrowserWindowController?
    private(set) var webView: WKWebView
    private var observers: [NSKeyValueObservation] = []
    private(set) var suspendedURL: URL?
    private(set) var suspendedTitle: String?
    var lastActive = Date()
    var onChange: (() -> Void)?
    private var httpAllowed: Set<String> = []
    private var pendingUpgrade: String?
    /// The bookmark this tab belongs to (Arc-style pinned tab), if any.
    var pinnedKey: String?
    /// Set while the tab shows the reader view of this page.
    private(set) var readerSource: URL?
    private var readerLoading = false
    var isReader: Bool { readerSource != nil }

    var title: String {
        if let t = suspendedTitle { return t }
        if let t = webView.title, !t.isEmpty { return t }
        return webView.url?.host ?? "New Tab"
    }
    var url: URL? { suspendedURL ?? readerSource ?? webView.url }
    var isSecure: Bool { url?.scheme == "https" && (suspendedURL != nil || readerSource != nil || webView.hasOnlySecureContent) }

    /// A restored tab starts asleep: only its URL and title are kept until it is shown.
    static func restored(_ url: URL, title: String, pinned: String?, store: WKWebsiteDataStore) -> Tab {
        let t = Tab(configuration: makeConfiguration(store: store))
        t.suspendedURL = url; t.suspendedTitle = title.isEmpty ? (url.host ?? url.absoluteString) : title; t.pinnedKey = pinned
        return t
    }

    /// Reader view: extract the article and show it on a local, script-free page.
    func toggleReader(_ done: @escaping (Bool) -> Void) {
        if readerSource != nil {
            if webView.canGoBack { webView.goBack() } else if let src = readerSource { webView.load(URLRequest(url: src)) }
            readerSource = nil; onChange?(); done(true); return
        }
        guard let page = webView.url, Store.recordable(page) else { done(false); return }
        webView.evaluateJavaScript(Reader.extractJS, in: nil, in: .defaultClient) { [weak self] result in
            guard let self, case .success(let v) = result, let str = v as? String, let data = str.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: String], let html = o["html"] else { done(false); return }
            self.readerSource = page; self.readerLoading = true
            self.webView.loadHTMLString(Reader.page(title: o["title"] ?? "", site: o["site"] ?? (page.host ?? ""),
                                                    byline: o["byline"] ?? "", lang: o["lang"] ?? "", body: html, source: page), baseURL: nil)
            self.onChange?(); done(true)
        }
    }

    init(configuration: WKWebViewConfiguration) {
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        wire()
    }

    static func makeConfiguration(store: WKWebsiteDataStore) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        c.websiteDataStore = store
        c.preferences.isFraudulentWebsiteWarningEnabled = true
        c.preferences.javaScriptCanOpenWindowsAutomatically = false
        c.upgradeKnownHostsToHTTPS = true
        c.defaultWebpagePreferences.preferredContentMode = .desktop
        if let rules = AppDelegate.shared.blockRules { c.userContentController.add(rules) }
        let d = UserDefaults.standard
        // Lightweight defaults (each can be turned off with `defaults write dev.yuuyuu86.PaperBrowser <key> -bool NO`).
        if d.object(forKey: "BlockAutoplay") as? Bool ?? true { c.mediaTypesRequiringUserActionForPlayback = .all }
        if d.object(forKey: "SuspendHiddenTabs") as? Bool ?? true { c.preferences.inactiveSchedulingPolicy = .suspend }
        if d.bool(forKey: "LockdownMode") { c.defaultWebpagePreferences.isLockdownModeEnabled = true }
        if d.bool(forKey: "DisableJavaScript") { c.defaultWebpagePreferences.allowsContentJavaScript = false }
        c.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        return c
    }

    private func wire() {
        let w = webView
        w.navigationDelegate = self; w.uiDelegate = self
        w.allowsBackForwardNavigationGestures = true
        w.allowsMagnification = true
        w.isInspectable = false
        w.underPageBackgroundColor = Theme.sheet
        let notify: (WKWebView) -> Void = { [weak self] _ in self?.onChange?() }
        observers = [
            w.observe(\.title) { v, _ in notify(v) },
            w.observe(\.url) { v, _ in notify(v) },
            w.observe(\.estimatedProgress) { v, _ in notify(v) },
            w.observe(\.hasOnlySecureContent) { v, _ in notify(v) },
            w.observe(\.canGoBack) { v, _ in notify(v) },
            w.observe(\.canGoForward) { v, _ in notify(v) },
        ]
    }

    func load(_ url: URL) { resumeIfNeeded(load: false); webView.load(URLRequest(url: url)) }

    /// Swaps in a fresh, never-loaded web view so WebKit terminates this page's content process.
    func suspend() {
        guard suspendedURL == nil, let u = webView.url, u.scheme != "about", !webView.isLoading else { return }
        suspendedURL = u; suspendedTitle = title
        let store = webView.configuration.websiteDataStore
        observers.removeAll()
        webView.stopLoading(); webView.navigationDelegate = nil; webView.uiDelegate = nil
        webView.removeFromSuperview()
        webView = WKWebView(frame: .zero, configuration: Tab.makeConfiguration(store: store))
        wire()
    }
    func resumeIfNeeded(load: Bool = true) {
        lastActive = Date()
        guard let u = suspendedURL else { return }
        suspendedURL = nil; suspendedTitle = nil
        if load { webView.load(URLRequest(url: u)) }
    }
    func close() {
        observers.removeAll(); webView.stopLoading()
        webView.navigationDelegate = nil; webView.uiDelegate = nil; webView.removeFromSuperview()
    }

    private var sheetWindow: NSWindow? { owner?.window }
    private func sheet(_ a: NSAlert, _ done: @escaping (NSApplication.ModalResponse) -> Void) {
        if let w = sheetWindow { a.beginSheetModal(for: w, completionHandler: done) } else { done(a.runModal()) }
    }

    // MARK: Navigation policy (security)
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction,
                 preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return decisionHandler(.cancel, preferences) }
        if action.shouldPerformDownload { return decisionHandler(.download, preferences) }
        // ⌘-click / middle-click opens a background tab.
        if action.navigationType == .linkActivated, action.modifierFlags.contains(.command) || action.buttonNumber == 2,
           allowedSchemes.contains(scheme) {
            decisionHandler(.cancel, preferences)
            owner?.openTab(url, select: action.modifierFlags.contains(.shift)); return
        }
        if allowedSchemes.contains(scheme) {
            // HTTPS-first: upgrade top-level plain-HTTP navigations; insecure fallback only after confirmation.
            if scheme == "http", action.targetFrame?.isMainFrame == true, !httpAllowed.contains(url.host ?? ""),
               var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                c.scheme = "https"; if c.port == 80 { c.port = nil }
                if let u = c.url { decisionHandler(.cancel, preferences); pendingUpgrade = url.host; w.load(URLRequest(url: u)); return }
            }
            if action.targetFrame?.isMainFrame ?? true {
                preferences.allowsContentJavaScript = !LiteMode.isOn(url, isPrivate: owner?.isPrivate ?? false)
                    && !UserDefaults.standard.bool(forKey: "DisableJavaScript")
            }
            return decisionHandler(.allow, preferences)
        }
        // Other schemes (mailto:, app links…) only after explicit user confirmation.
        decisionHandler(.cancel, preferences)
        guard action.navigationType == .linkActivated else { return }
        let a = NSAlert(); a.messageText = "Open external link?"; a.informativeText = url.absoluteString
        a.addButton(withTitle: "Open"); a.addButton(withTitle: "Cancel")
        sheet(a) { if $0 == .alertFirstButtonReturn { NSWorkspace.shared.open(url) } }
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError error: Error) {
        let e = error as NSError
        if e.code == NSURLErrorCancelled || e.code == 102 /* interrupted by download */ { return }
        if let host = pendingUpgrade, let failing = e.userInfo[NSURLErrorFailingURLErrorKey] as? URL, failing.host == host {
            pendingUpgrade = nil
            let a = NSAlert(); a.messageText = "\(host) does not support HTTPS"
            a.informativeText = "Continue over an insecure connection? Data you send could be read by others."
            a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Continue (Not Secure)")
            sheet(a) { [weak self] r in
                guard r == .alertSecondButtonReturn, var c = URLComponents(url: failing, resolvingAgainstBaseURL: false) else { return }
                self?.httpAllowed.insert(host); c.scheme = "http"; if let u = c.url { self?.load(u) }
            }
            return
        }
        let msg = e.localizedDescription.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        w.loadHTMLString("<meta charset=utf-8><body style='font:15px -apple-system;padding:60px;color:#8a8276;background:#fffdf8'><h2 style='font-weight:500;color:#2b2722'>Can’t open this page</h2><p>\(msg)</p>", baseURL: nil)
    }
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) {
        pendingUpgrade = nil
        if readerLoading { readerLoading = false } else if readerSource != nil { readerSource = nil; onChange?() }
    }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        AppDelegate.shared.relieveMemory()
        guard owner?.isPrivate == false, readerSource == nil, let u = w.url else { return }
        Store.shared.visit(u, title: w.title)
        Favicons.shared.learn(from: w)
    }
    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(r.canShowMIMEType ? .allow : .download)
    }
    func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome d: WKDownload) { d.delegate = Downloads.shared }
    func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = Downloads.shared }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { if suspendedURL == nil { w.reload() } }

    // MARK: UI delegate — popups, dialogs, file upload, permissions
    func webView(_ w: WKWebView, createWebViewWith cfg: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let owner else { return nil }
        return owner.add(Tab(configuration: cfg), select: true).webView
    }
    func webViewDidClose(_ w: WKWebView) { owner?.closeTab(self) }
    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = f.securityOrigin.host; a.informativeText = m
        sheet(a) { _ in completionHandler() }
    }
    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage m: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = f.securityOrigin.host; a.informativeText = m
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        sheet(a) { completionHandler($0 == .alertFirstButtonReturn) }
    }
    func webView(_ w: WKWebView, runJavaScriptTextInputPanelWithPrompt p: String, defaultText: String?, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = f.securityOrigin.host; a.informativeText = p
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        let t = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); t.stringValue = defaultText ?? ""; a.accessoryView = t
        sheet(a) { completionHandler($0 == .alertFirstButtonReturn ? t.stringValue : nil) }
    }
    func webView(_ w: WKWebView, runOpenPanelWith p: WKOpenPanelParameters, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let o = NSOpenPanel(); o.allowsMultipleSelection = p.allowsMultipleSelection; o.canChooseDirectories = p.allowsDirectories
        if let win = sheetWindow { o.beginSheetModal(for: win) { completionHandler($0 == .OK ? o.urls : nil) } } else { completionHandler(nil) }
    }
    func webView(_ w: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame f: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let what = type == .camera ? "camera" : type == .microphone ? "microphone" : "camera and microphone"
        let a = NSAlert(); a.messageText = "Allow \(origin.host) to use your \(what)?"
        a.addButton(withTitle: "Don’t Allow"); a.addButton(withTitle: "Allow")
        sheet(a) { decisionHandler($0 == .alertSecondButtonReturn ? .grant : .deny) }
    }
}

// MARK: - Tab item (works for both the sidebar and the top strip)

final class TabItemView: FlatView {
    let label = NSTextField(labelWithString: "")
    let dot = FlatView()
    let icon = NSImageView()
    var menuProvider: (() -> NSMenu?)?
    lazy var closeButton = symbolButton("xmark", self, #selector(closeClicked), size: 9)
    var onSelect: (() -> Void)?, onClose: (() -> Void)?
    var selected = false { didSet { restyle() } }
    var sleeping = false { didSet { restyle() } }
    var closable = true { didSet { restyle() } }
    func setIcon(_ img: NSImage?) { icon.image = img; restyle() }
    private var hovering = false { didSet { restyle() } }

    init(vertical: Bool) {
        super.init(frame: .zero)
        radius = 7
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.radius = 2.5; dot.fill = Theme.faint
        icon.imageScaling = .scaleProportionallyUpOrDown
        for v in [dot, icon, label, closeButton] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: vertical ? 30 : 28),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 5), dot.heightAnchor.constraint(equalToConstant: 5),
            icon.centerXAnchor.constraint(equalTo: dot.centerXAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 4),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func restyle() {
        fill = selected ? Theme.sheet : hovering ? Theme.hover : nil
        stroke = selected ? Theme.hair : nil
        label.textColor = selected ? Theme.ink : Theme.faint
        dot.fill = selected ? Theme.shu : sleeping ? Theme.hair : Theme.faint
        dot.isHidden = icon.image != nil
        icon.alphaValue = sleeping && !selected ? 0.45 : 1
        closeButton.isHidden = !(selected || hovering) || !closable
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func mouseDown(with e: NSEvent) { onSelect?() }
    override func otherMouseUp(with e: NSEvent) { if e.buttonNumber == 2 && closable { onClose?() } }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
    @objc private func closeClicked() { onClose?() }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private var run: () -> Void = {}
    convenience init(_ title: String, _ run: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire), keyEquivalent: ""); self.run = run; target = self
    }
    @objc private func fire() { run() }
}
func makeMenu(_ items: [NSMenuItem]) -> NSMenu { let m = NSMenu(); items.forEach(m.addItem); return m }

/// Arc-style favorite: a square tile with the site's icon.
final class FavoriteTile: FlatView {
    private let icon = NSImageView(), letter = NSTextField(labelWithString: "")
    var onClick: (() -> Void)?, menuProvider: (() -> NSMenu?)?
    var selected = false { didSet { restyle() } }
    private var hovering = false { didSet { restyle() } }
    init(title: String, image: NSImage?) {
        super.init(frame: .zero)
        radius = 10; toolTip = title
        icon.image = image; icon.imageScaling = .scaleProportionallyUpOrDown
        letter.stringValue = String(title.prefix(1)).uppercased(); letter.font = .systemFont(ofSize: 15, weight: .medium)
        letter.textColor = Theme.faint; letter.isHidden = image != nil
        for v in [icon, letter] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 20),
            letter.centerXAnchor.constraint(equalTo: centerXAnchor), letter.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }
    private func restyle() { fill = selected ? Theme.sheet : hovering ? Theme.hover : Theme.hover.withAlphaComponent(0.55); stroke = selected ? Theme.hair : nil }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func mouseDown(with e: NSEvent) { onClick?() }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() }
}

/// Row that separates pinned items from today's tabs, with a Clear button.
final class SeparatorRow: NSView {
    init(clear: (target: AnyObject, action: Selector)?) {
        super.init(frame: .zero)
        let line = FlatView(); line.fill = Theme.hair
        for v in [line] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        var cs = [heightAnchor.constraint(equalToConstant: 28),
                  line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                  line.centerYAnchor.constraint(equalTo: centerYAnchor), line.heightAnchor.constraint(equalToConstant: 1)]
        if let clear {
            let b = NSButton(title: "Clear", target: clear.target, action: clear.action)
            b.isBordered = false; b.font = .systemFont(ofSize: 11); b.contentTintColor = Theme.faint
            b.attributedTitle = NSAttributedString(string: "Clear", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Theme.faint])
            b.toolTip = "Close all tabs that are not pinned"
            b.translatesAutoresizingMaskIntoConstraints = false; addSubview(b)
            cs += [b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), b.centerYAnchor.constraint(equalTo: centerYAnchor),
                   line.trailingAnchor.constraint(equalTo: b.leadingAnchor, constant: -10)]
        } else { cs.append(line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)) }
        NSLayoutConstraint.activate(cs)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Clicks on empty chrome drag the window (titlebar is hidden).
final class ChromeView: FlatView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseUp(with e: NSEvent) { if e.clickCount == 2 { window?.performZoom(nil) } }
}

// MARK: - Window: chrome + tab list + content

final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    enum Layout: String { case vertical, horizontal }
    let isPrivate: Bool
    let store: WKWebsiteDataStore
    private(set) var tabs: [Tab] = []
    private(set) var selected: Tab?
    var layout: Layout = Layout(rawValue: UserDefaults.standard.string(forKey: "TabLayout") ?? "") ?? .vertical {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "TabLayout"); applyLayout() }
    }

    private let root = ChromeView()
    private let toolbar = ChromeView()
    private let sidebar = ChromeView()
    private let strip = ChromeView()
    private let sideList = NSStackView(), stripList = NSStackView()
    private let content = FlatView()
    private let address = NSTextField()
    private let addressBox = FlatView()
    private let lock = NSImageView()
    private let hairline = FlatView()          // the vermilion progress "hair"
    private var hairWidth: NSLayoutConstraint!
    private lazy var backButton = symbolButton("arrow.left", self, #selector(goBack))
    private lazy var forwardButton = symbolButton("arrow.right", self, #selector(goForward))
    private lazy var reloadButton = symbolButton("arrow.clockwise", self, #selector(reloadPage))
    private lazy var layoutButton = symbolButton("sidebar.left", self, #selector(toggleTabLayout))
    private lazy var liteButton = symbolButton("leaf", self, #selector(toggleLiteMode))
    private lazy var readerButton = symbolButton("doc.plaintext", self, #selector(toggleReader))
    private lazy var pinButton = symbolButton("pin", self, #selector(togglePin))
    private lazy var downloadsButton = symbolButton("arrow.down.circle", self, #selector(showDownloads))
    private let suggestions = SuggestionsPopup()
    private lazy var findBar: FindBar = {
        let f = FindBar()
        f.onSearch = { [weak self] q, back in self?.find(q, backwards: back) }
        f.onClose = { [weak self] in self?.hideFind() }
        return f
    }()
    private var lastFind = ""
    private var closedTabs: [(url: URL, title: String, pinned: String?)] = []
    private var layoutConstraints: [NSLayoutConstraint] = []

    init(isPrivate: Bool = false) {
        self.isPrivate = isPrivate
        store = isPrivate ? .nonPersistent() : .default()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.tabbingMode = .disallowed
        window.backgroundColor = Theme.paper
        window.minSize = NSSize(width: 520, height: 360)
        super.init(window: window)
        window.delegate = self
        buildChrome()
        suggestions.onPick = { [weak self] s in self?.suggestions.hide(); self?.loadInSelected(s.url) }
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(sidebarDataChanged), name: .pbBookmarksChanged, object: nil)
        nc.addObserver(self, selector: #selector(sidebarDataChanged), name: .pbFaviconsChanged, object: nil)
        nc.addObserver(self, selector: #selector(downloadsChanged), name: .pbDownloadsChanged, object: nil)
        downloadsChanged()
        applyLayout()
        window.setFrameAutosaveName("PaperBrowserMain")
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildChrome() {
        root.fill = Theme.paper
        content.fill = Theme.sheet
        content.radius = 9; content.stroke = Theme.hair; content.layer?.masksToBounds = true

        addressBox.fill = Theme.sheet; addressBox.radius = 8; addressBox.stroke = Theme.hair
        address.isBordered = false; address.drawsBackground = false; address.focusRingType = .none
        address.font = .systemFont(ofSize: 13); address.textColor = Theme.ink
        address.placeholderString = isPrivate ? "Private · search or enter address" : "Search or enter address"
        address.delegate = self; address.target = self; address.action = #selector(go)
        address.cell?.isScrollable = true; address.cell?.wraps = false; address.lineBreakMode = .byTruncatingTail
        lock.imageScaling = .scaleProportionallyDown
        hairline.fill = Theme.shu

        for v in [lock, address] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addressBox.addSubview(v) }
        NSLayoutConstraint.activate([
            lock.leadingAnchor.constraint(equalTo: addressBox.leadingAnchor, constant: 10),
            lock.centerYAnchor.constraint(equalTo: addressBox.centerYAnchor),
            lock.widthAnchor.constraint(equalToConstant: 12),
            address.leadingAnchor.constraint(equalTo: lock.trailingAnchor, constant: 7),
            address.trailingAnchor.constraint(equalTo: addressBox.trailingAnchor, constant: -10),
            address.centerYAnchor.constraint(equalTo: addressBox.centerYAnchor),
        ])

        let newTab = symbolButton("plus", self, #selector(newTab))
        let controls = NSStackView(views: [layoutButton, backButton, forwardButton, reloadButton])
        controls.spacing = 12
        let tb = NSStackView(views: [controls, addressBox, readerButton, pinButton, liteButton, downloadsButton, newTab])
        tb.spacing = 14; tb.alignment = .centerY
        for v in [tb, hairline] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; toolbar.addSubview(v) }
        hairWidth = hairline.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            tb.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            tb.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -14),
            tb.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            addressBox.heightAnchor.constraint(equalToConstant: 30),
            hairline.leadingAnchor.constraint(equalTo: addressBox.leadingAnchor, constant: 8),
            hairline.bottomAnchor.constraint(equalTo: addressBox.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
            hairWidth,
        ])

        for (list, vertical) in [(sideList, true), (stripList, false)] {
            list.orientation = vertical ? .vertical : .horizontal
            list.spacing = vertical ? 2 : 4
            list.alignment = vertical ? .leading : .centerY
            list.distribution = vertical ? .fill : .fillEqually
        }
        let sideScroll = NSScrollView(); sideScroll.drawsBackground = false; sideScroll.hasVerticalScroller = true
        sideScroll.autohidesScrollers = true; sideScroll.scrollerStyle = .overlay
        let doc = FlippedView(); doc.translatesAutoresizingMaskIntoConstraints = false
        sideList.translatesAutoresizingMaskIntoConstraints = false; doc.addSubview(sideList)
        sideScroll.documentView = doc
        let brand = NSTextField(labelWithString: isPrivate ? "紙 · private" : "紙")
        brand.font = .systemFont(ofSize: 11, weight: .medium); brand.textColor = Theme.faint
        for v in [brand, sideScroll] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(v) }
        NSLayoutConstraint.activate([
            brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 14),
            brand.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -14),
            sideScroll.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 44),
            sideScroll.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 8),
            sideScroll.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -4),
            sideScroll.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -8),
            doc.widthAnchor.constraint(equalTo: sideScroll.contentView.widthAnchor),
            sideList.topAnchor.constraint(equalTo: doc.topAnchor),
            sideList.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            sideList.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -4),
            sideList.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        stripList.translatesAutoresizingMaskIntoConstraints = false; strip.addSubview(stripList)
        NSLayoutConstraint.activate([
            stripList.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 10),
            stripList.trailingAnchor.constraint(lessThanOrEqualTo: strip.trailingAnchor, constant: -10),
            stripList.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
        ])
        for v in [sidebar, strip, toolbar, content] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        window?.contentView = root
    }

    private func applyLayout() {
        NSLayoutConstraint.deactivate(layoutConstraints)
        let v = layout == .vertical
        sidebar.isHidden = !v; strip.isHidden = v
        let traffic: CGFloat = 78
        if v {
            layoutConstraints = [
                sidebar.topAnchor.constraint(equalTo: root.topAnchor),
                sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                sidebar.widthAnchor.constraint(equalToConstant: 220),
                toolbar.topAnchor.constraint(equalTo: root.topAnchor),
                toolbar.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                toolbar.heightAnchor.constraint(equalToConstant: 46),
                content.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            ]
        } else {
            layoutConstraints = [
                toolbar.topAnchor.constraint(equalTo: root.topAnchor),
                toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: traffic),
                toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                toolbar.heightAnchor.constraint(equalToConstant: 46),
                strip.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
                strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                strip.heightAnchor.constraint(equalToConstant: 36),
                content.topAnchor.constraint(equalTo: strip.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            ]
        }
        layoutConstraints += [
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ]
        NSLayoutConstraint.activate(layoutConstraints)
        layoutButton.image = NSImage(systemSymbolName: v ? "rectangle.topthird.inset.filled" : "sidebar.left", accessibilityDescription: "Tab layout")!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        layoutButton.toolTip = v ? "Tabs on top (⌃⌘S)" : "Vertical tabs (⌃⌘S)"
        rebuildTabList()
    }

    // MARK: Tabs
    @discardableResult func add(_ tab: Tab, select: Bool, after: Tab? = nil) -> Tab {
        tab.owner = self
        tab.onChange = { [weak self, weak tab] in if let tab { self?.tabChanged(tab) } }
        if let after, let i = tabs.firstIndex(where: { $0 === after }) { tabs.insert(tab, at: i + 1) } else { tabs.append(tab) }
        if select || selected == nil { self.select(tab) } else { rebuildTabList() }
        return tab
    }
    func newTab(with url: URL?, select: Bool = true) -> Tab {
        let t = Tab(configuration: Tab.makeConfiguration(store: store))
        if let url { t.load(url) }
        return add(t, select: select, after: select ? nil : selected)
    }
    func openTab(_ url: URL, select: Bool) { _ = newTab(with: url, select: select) }

    func select(_ tab: Tab) {
        selected?.lastActive = Date()
        selected?.webView.removeFromSuperview()
        selected = tab
        tab.resumeIfNeeded()
        let w = tab.webView
        w.frame = content.bounds; w.autoresizingMask = [.width, .height]
        content.addSubview(w, positioned: .below, relativeTo: nil)     // stays under the find bar
        if itemViews[ObjectIdentifier(tab)] == nil && (tab.pinnedKey == nil || pinViews[tab.pinnedKey!] == nil && tileViews[tab.pinnedKey!] == nil) { rebuildTabList() }
        else { for (id, v) in itemViews { v.selected = id == ObjectIdentifier(tab) }; refreshPinnedState() }
        findBar.setFound(nil)
        syncChrome()
        AppDelegate.shared.saveSessionSoon()
        if tab.url == nil { focusAddress(nil) } else { window?.makeFirstResponder(w) }
    }
    func closeTab(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        remember(tab); tab.close(); tabs.remove(at: i)
        AppDelegate.shared.saveSessionSoon()
        if tabs.isEmpty { selected = nil; window?.close(); return }
        if selected === tab { selected = nil; rebuildTabList(); select(tabs[min(i, tabs.count - 1)]) } else { rebuildTabList() }
    }
    /// Unloads hidden tabs idle for `age` seconds.
    func suspendBackground(olderThan age: TimeInterval) {
        var changed = false
        for t in tabs where t !== selected && t.suspendedURL == nil && Date().timeIntervalSince(t.lastActive) >= age {
            t.suspend(); changed = t.suspendedURL != nil || changed
        }
        if changed { rebuildTabList() }
    }

    private var itemViews: [ObjectIdentifier: TabItemView] = [:]
    private var pinViews: [String: TabItemView] = [:]
    private var tileViews: [String: FavoriteTile] = [:]
    private func rebuildTabList() {
        sideList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stripList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        itemViews.removeAll(); pinViews.removeAll(); tileViews.removeAll()
        if layout == .horizontal {
            for t in tabs { addRow(for: t, to: stripList, vertical: false) }
            return
        }
        let list = sideList
        func fill(_ v: NSView) { list.addArrangedSubview(v); v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        // Favorites: icon tiles, three per row
        let favs = Store.shared.favorites
        for chunk in stride(from: 0, to: favs.count, by: 3).map({ Array(favs[$0..<min($0 + 3, favs.count)]) }) {
            var tiles: [NSView] = chunk.map { b in
                let tile = FavoriteTile(title: b.title, image: Favicons.shared.image(for: URL(string: b.url)))
                Favicons.shared.prefetch(URL(string: b.url))
                tile.onClick = { [weak self] in self?.openBookmark(b.url) }
                tile.menuProvider = { [weak self] in self?.bookmarkMenu(b.url) }
                tileViews[b.url] = tile
                return tile
            }
            while tiles.count < 3 { tiles.append(NSView()) }
            let row = NSStackView(views: tiles); row.distribution = .fillEqually; row.spacing = 6
            fill(row)
        }
        if !favs.isEmpty { let gap = NSView(); gap.heightAnchor.constraint(equalToConstant: 6).isActive = true; fill(gap) }
        // Pinned: bookmarks as rows; selecting one opens (or returns to) its tab
        let pins = Store.shared.pinned
        for b in pins {
            let v = TabItemView(vertical: true)
            v.label.stringValue = b.title; v.toolTip = b.url
            v.setIcon(Favicons.shared.image(for: URL(string: b.url)))
            Favicons.shared.prefetch(URL(string: b.url))
            v.onSelect = { [weak self] in self?.openBookmark(b.url) }
            v.onClose = { [weak self] in if let t = self?.tabs.first(where: { $0.pinnedKey == b.url }) { self?.closeTab(t) } }
            v.menuProvider = { [weak self] in self?.bookmarkMenu(b.url) }
            fill(v); pinViews[b.url] = v
        }
        let loose = tabs.filter { $0.pinnedKey == nil }
        if !favs.isEmpty || !pins.isEmpty {
            fill(SeparatorRow(clear: loose.isEmpty ? nil : (self, #selector(clearTabs))))
        }
        let newRow = TabItemView(vertical: true)
        newRow.label.stringValue = "New Tab"; newRow.closable = false
        newRow.setIcon(NSImage(systemSymbolName: "plus", accessibilityDescription: "New Tab"))
        newRow.icon.contentTintColor = Theme.faint
        newRow.onSelect = { [weak self] in self?.newTab(nil) }
        fill(newRow)
        for t in loose { addRow(for: t, to: list, vertical: true) }
        refreshPinnedState()
    }
    private func addRow(for t: Tab, to list: NSStackView, vertical: Bool) {
        let v = TabItemView(vertical: vertical)
        v.onSelect = { [weak self, weak t] in if let t { self?.select(t) } }
        v.onClose = { [weak self, weak t] in if let t { self?.closeTab(t) } }
        v.menuProvider = { [weak self, weak t] in t.flatMap { self?.tabMenu($0) } }
        list.addArrangedSubview(v)
        if vertical { v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
        else { v.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true; v.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true }
        itemViews[ObjectIdentifier(t)] = v
        update(v, t)
    }
    /// Highlights the favorite / pinned row whose tab is selected, and dims pinned items that are not open.
    private func refreshPinnedState() {
        for (k, v) in pinViews {
            let t = tabs.first { $0.pinnedKey == k }
            v.selected = t != nil && t === selected
            v.sleeping = t == nil || t?.suspendedURL != nil
            v.closable = t != nil
        }
        for (k, tile) in tileViews { tile.selected = selected?.pinnedKey == k }
    }
    @objc private func sidebarDataChanged() {
        // a bookmark removed elsewhere turns its open tab back into a normal tab
        for t in tabs where t.pinnedKey != nil && Store.shared.bookmark(t.pinnedKey) == nil { t.pinnedKey = nil }
        rebuildTabList(); syncChrome()
    }
    private func update(_ v: TabItemView, _ t: Tab) {
        v.label.stringValue = t.title; v.toolTip = t.title
        v.selected = t === selected; v.sleeping = t.suspendedURL != nil
        v.setIcon(Favicons.shared.image(for: t.url))
    }
    private func tabChanged(_ t: Tab) {
        if let v = itemViews[ObjectIdentifier(t)] { update(v, t) }
        if t === selected { syncChrome() }
        if !isPrivate, t.readerSource == nil, let u = t.webView.url, let title = t.webView.title { Store.shared.updateTitle(u, title) }
        AppDelegate.shared.saveSessionSoon()
    }

    // MARK: Pinned tabs & favorites (Arc-style bookmarks)
    func openBookmark(_ key: String) {
        if let t = tabs.first(where: { $0.pinnedKey == key }) { select(t); return }
        guard let u = URL(string: key) else { return }
        let t = Tab(configuration: Tab.makeConfiguration(store: store))
        t.pinnedKey = key; t.load(u)
        add(t, select: true)
    }
    private func bookmarkMenu(_ key: String) -> NSMenu {
        let fav = Store.shared.bookmark(key)?.favorite == true
        return makeMenu([
            ActionItem(fav ? "Move to Pinned" : "Add to Favorites") { Store.shared.setFavorite(key, !fav) },
            ActionItem("Move Up") { Store.shared.moveBookmark(key, by: -1) },
            ActionItem("Move Down") { Store.shared.moveBookmark(key, by: 1) },
            ActionItem("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key, forType: .string) },
            .separator(),
            ActionItem(fav ? "Remove from Favorites" : "Unpin") { Store.shared.removeBookmark(key) },
        ])
    }
    private func tabMenu(_ t: Tab) -> NSMenu {
        var items: [NSMenuItem] = []
        if let u = t.url, Store.recordable(u) {
            items += [ActionItem("Pin Tab") { [weak self, weak t] in if let t { self?.pin(t, favorite: false) } },
                      ActionItem("Add to Favorites") { [weak self, weak t] in if let t { self?.pin(t, favorite: true) } },
                      ActionItem("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.absoluteString, forType: .string) },
                      .separator()]
        }
        items.append(ActionItem("Close Tab") { [weak self, weak t] in if let t { self?.closeTab(t) } })
        return makeMenu(items)
    }
    private func pin(_ t: Tab, favorite: Bool) {
        guard let u = t.url, Store.recordable(u) else { return }
        t.pinnedKey = u.absoluteString
        Store.shared.addBookmark(u, title: t.title, favorite: favorite)
    }
    @objc func togglePin(_ s: Any? = nil) {
        guard let t = selected, let u = t.url, Store.recordable(u) else { NSSound.beep(); return }
        if let k = t.pinnedKey { Store.shared.removeBookmark(k); t.pinnedKey = nil }
        else if Store.shared.isBookmarked(u) { Store.shared.removeBookmark(u.absoluteString) }
        else { pin(t, favorite: false) }
    }
    @objc func clearTabs(_ s: Any? = nil) {
        let loose = tabs.filter { $0.pinnedKey == nil }
        for t in loose { remember(t); t.close() }
        tabs.removeAll { $0.pinnedKey == nil }
        if tabs.isEmpty { selected = nil; _ = newTab(with: isPrivate ? nil : homeURL); return }
        if let s = selected, !tabs.contains(where: { $0 === s }) { selected = nil; select(tabs[0]) }
        rebuildTabList()
        AppDelegate.shared.saveSessionSoon()
    }
    private func remember(_ t: Tab) {
        guard let u = t.url, Store.recordable(u) else { return }
        closedTabs.append((u, t.title, t.pinnedKey)); if closedTabs.count > 20 { closedTabs.removeFirst() }
    }
    @objc func reopenClosedTab(_ s: Any?) {
        guard let c = closedTabs.popLast() else { NSSound.beep(); return }
        if let k = c.pinned, Store.shared.bookmark(k) != nil { openBookmark(k); return }
        _ = newTab(with: c.url)
    }
    var savedState: SavedWindow? {
        let ts = tabs.compactMap { t -> SavedTab? in
            guard let u = t.url, Store.recordable(u) else { return nil }
            return SavedTab(url: u.absoluteString, title: t.title, pinned: t.pinnedKey)
        }
        guard !ts.isEmpty else { return nil }
        let live = tabs.filter { Store.recordable($0.url) }
        return SavedWindow(tabs: ts, selected: max(0, live.firstIndex { $0 === selected } ?? 0))
    }
    func restore(_ w: SavedWindow) {
        for st in w.tabs {
            guard let u = URL(string: st.url) else { continue }
            add(Tab.restored(u, title: st.title, pinned: st.pinned.flatMap { Store.shared.bookmark($0) != nil ? $0 : nil }, store: store), select: false)
        }
        if tabs.indices.contains(w.selected) { select(tabs[w.selected]) }
    }

    // MARK: Reader, find, downloads
    @objc func toggleReader(_ s: Any? = nil) {
        guard let t = selected else { return }
        t.toggleReader { [weak self] ok in
            if !ok { NSSound.beep(); self?.flashReaderUnavailable() }
            self?.syncChrome()
        }
    }
    private func flashReaderUnavailable() { readerButton.toolTip = "No article found on this page" }
    @objc func findInPage(_ s: Any?) {
        if findBar.superview == nil {
            findBar.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(findBar, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                findBar.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
                findBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
                findBar.widthAnchor.constraint(equalToConstant: 340), findBar.heightAnchor.constraint(equalToConstant: 36),
            ])
        }
        if findBar.field.stringValue.isEmpty { findBar.field.stringValue = lastFind }
        window?.makeFirstResponder(findBar.field); findBar.field.currentEditor()?.selectAll(nil)
    }
    private func find(_ q: String, backwards: Bool) {
        guard !q.isEmpty, let w = selected?.webView else { findBar.setFound(nil); return }
        lastFind = q
        let c = WKFindConfiguration(); c.backwards = backwards; c.wraps = true; c.caseSensitive = false
        w.find(q, configuration: c) { [weak self] r in self?.findBar.setFound(r.matchFound) }
    }
    @objc func findNext(_ s: Any?) { if lastFind.isEmpty { findInPage(nil) } else { find(lastFind, backwards: false) } }
    @objc func findPrevious(_ s: Any?) { if lastFind.isEmpty { findInPage(nil) } else { find(lastFind, backwards: true) } }
    private func hideFind() {
        findBar.removeFromSuperview(); findBar.setFound(nil)
        if let w = selected?.webView { window?.makeFirstResponder(w) }
    }
    @objc func showDownloads(_ s: Any? = nil) { LibraryWindowController.shared.show(.downloads) }
    @objc private func downloadsChanged() {
        let d = Downloads.shared
        downloadsButton.isHidden = d.items.isEmpty
        downloadsButton.contentTintColor = d.active > 0 ? Theme.shu : Theme.faint
        downloadsButton.toolTip = d.active > 0 ? "\(d.active) downloading (⇧⌘J)" : "Downloads (⇧⌘J)"
    }
    private func loadInSelected(_ u: URL) {
        guard let t = selected else { return }
        t.load(u); window?.makeFirstResponder(t.webView)
    }

    private func syncChrome() {
        guard let t = selected else { return }
        let w = t.webView
        if window?.firstResponder != address.currentEditor() { address.stringValue = t.url?.absoluteString ?? "" }
        let secure = t.isSecure
        lock.image = t.url == nil ? nil : NSImage(systemSymbolName: secure ? "lock" : "exclamationmark.triangle", accessibilityDescription: nil)
        lock.contentTintColor = secure ? Theme.faint : Theme.shu
        lock.toolTip = secure ? "Secure connection" : "Not secure"
        backButton.isEnabled = w.canGoBack; forwardButton.isEnabled = w.canGoForward
        let lite = LiteMode.isOn(t.url, isPrivate: isPrivate), site = LiteMode.site(t.url)
        liteButton.isEnabled = site != nil
        liteButton.image = NSImage(systemSymbolName: lite ? "leaf.fill" : "leaf", accessibilityDescription: "Lite Mode")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        liteButton.contentTintColor = lite ? Theme.shu : Theme.faint
        liteButton.toolTip = site.map { lite ? "Lite Mode is on for \($0) — JavaScript off (⌥⌘L)" : "Lite Mode for \($0): turn JavaScript off to save memory (⌥⌘L)" }
        let canRead = Store.recordable(t.url)
        readerButton.isEnabled = canRead || t.isReader
        readerButton.image = NSImage(systemSymbolName: t.isReader ? "doc.plaintext.fill" : "doc.plaintext", accessibilityDescription: "Reader")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        readerButton.contentTintColor = t.isReader ? Theme.shu : Theme.faint
        readerButton.toolTip = t.isReader ? "Exit Reader (⇧⌘R)" : "Reader: the article only, no scripts (⇧⌘R)"
        let pinned = t.pinnedKey != nil || Store.shared.isBookmarked(t.url)
        pinButton.isEnabled = canRead
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin", accessibilityDescription: "Pin")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        pinButton.contentTintColor = pinned ? Theme.shu : Theme.faint
        pinButton.toolTip = pinned ? "Unpin (⌘D)" : "Pin this tab to the sidebar (⌘D)"
        let p = w.estimatedProgress
        let full = max(addressBox.bounds.width - 16, 0)
        hairWidth.constant = (p > 0 && p < 1) ? full * p : 0
        window?.title = (isPrivate ? "Private — " : "") + t.title
    }

    // MARK: Actions
    @objc func go() { suggestions.hide(); if let u = resolve(address.stringValue) { loadInSelected(u) } }
    @objc func goBack() { selected?.webView.goBack() }
    @objc func goForward() { selected?.webView.goForward() }
    @objc func reloadPage() { selected?.webView.reload() }
    @objc func reloadIgnoringCache(_ s: Any?) { selected?.webView.reloadFromOrigin() }
    @objc func focusAddress(_ s: Any?) { window?.makeFirstResponder(address); address.currentEditor()?.selectAll(nil) }
    @objc func zoomIn(_ s: Any?) { if let w = selected?.webView { w.pageZoom = min(w.pageZoom + 0.1, 3) } }
    @objc func zoomOut(_ s: Any?) { if let w = selected?.webView { w.pageZoom = max(w.pageZoom - 0.1, 0.3) } }
    @objc func zoomReset(_ s: Any?) { selected?.webView.pageZoom = 1 }
    @objc func stopLoading(_ s: Any?) { selected?.webView.stopLoading() }
    @objc func newTab(_ s: Any? = nil) { _ = newTab(with: isPrivate ? nil : homeURL) }
    @objc func closeCurrentTab(_ s: Any?) { if let t = selected { closeTab(t) } }
    @objc func toggleTabLayout(_ s: Any? = nil) { layout = layout == .vertical ? .horizontal : .vertical }
    @objc func toggleLiteMode(_ s: Any? = nil) {
        guard let t = selected, let url = t.url, LiteMode.site(url) != nil else { NSSound.beep(); return }
        LiteMode.toggle(url, isPrivate: isPrivate)
        t.load(url)        // reload so the new JavaScript setting applies
        syncChrome()
    }
    @objc func nextTab(_ s: Any?) { cycle(1) }
    @objc func previousTab(_ s: Any?) { cycle(-1) }
    @objc func selectTabByNumber(_ s: NSMenuItem) {
        guard !tabs.isEmpty else { return }
        select(s.tag == 9 ? tabs[tabs.count - 1] : tabs[min(s.tag - 1, tabs.count - 1)])
    }
    private func cycle(_ d: Int) {
        guard let s = selected, let i = tabs.firstIndex(where: { $0 === s }), tabs.count > 1 else { return }
        select(tabs[(i + d + tabs.count) % tabs.count])
    }
    @objc func printPage(_ s: Any?) {
        guard let w = selected?.webView, let win = window else { return }
        w.printOperation(with: .shared).runModal(for: win, delegate: nil, didRun: nil, contextInfo: nil)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleTabLayout) { item.state = layout == .vertical ? .on : .off }
        if item.action == #selector(reopenClosedTab) { return !closedTabs.isEmpty }
        if item.action == #selector(toggleReader) { item.title = selected?.isReader == true ? "Exit Reader" : "Show Reader"; return Store.recordable(selected?.url) || selected?.isReader == true }
        if item.action == #selector(togglePin) {
            let pinned = selected?.pinnedKey != nil || Store.shared.isBookmarked(selected?.url)
            item.title = pinned ? "Unpin This Page" : "Pin This Page"; return Store.recordable(selected?.url)
        }
        if item.action == #selector(clearTabs) { return tabs.contains { $0.pinnedKey == nil } }
        if item.action == #selector(toggleLiteMode) {
            item.state = LiteMode.isOn(selected?.url, isPrivate: isPrivate) ? .on : .off
            return LiteMode.site(selected?.url) != nil
        }
        return true
    }

    func controlTextDidEndEditing(_ n: Notification) { suggestions.hide(); syncChrome() }
    func controlTextDidChange(_ n: Notification) {
        guard (n.object as? NSTextField) === address else { return }
        let q = address.stringValue.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { suggestions.hide() } else { suggestions.show(Store.shared.suggestions(q), under: addressBox) }
    }
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard c === address else { return false }
        switch sel {
        case #selector(NSResponder.moveDown(_:)) where suggestions.isVisible: suggestions.move(1); return true
        case #selector(NSResponder.moveUp(_:)) where suggestions.isVisible: suggestions.move(-1); return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSTextView.complete(_:)):   // esc arrives as complete:
            if suggestions.isVisible { suggestions.hide(); return true }
            address.stringValue = selected?.url?.absoluteString ?? ""
            if let w = selected?.webView { window?.makeFirstResponder(w) }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            if suggestions.isVisible, let s = suggestions.selected { suggestions.hide(); loadInSelected(s.url); return true }
            return false
        default: return false
        }
    }
    func windowDidResize(_ n: Notification) { syncChrome() }
    func windowWillClose(_ n: Notification) {
        suggestions.hide()
        NotificationCenter.default.removeObserver(self)
        tabs.forEach { $0.close() }; tabs.removeAll(); selected = nil
        AppDelegate.shared.windows.removeAll { $0 === self }
        AppDelegate.shared.saveSessionSoon()
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = AppDelegate()
    var windows: [BrowserWindowController] = []
    var blockRules: WKContentRuleList?
    private var memorySource: DispatchSourceMemoryPressure?
    var current: BrowserWindowController? {
        (NSApp.keyWindow?.windowController as? BrowserWindowController) ?? windows.last
    }
    /// Seconds before an unused background tab is unloaded (`defaults write dev.yuuyuu86.PaperBrowser SuspendAfter 120`).
    static var suspendAfter: TimeInterval { let v = UserDefaults.standard.double(forKey: "SuspendAfter"); return v > 0 ? v : 5 * 60 }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        startMemoryManagement()
        loadBlocker { [weak self] in
            guard let self else { return }
            self.blockerReady = true
            self.restoreSession()
            if !self.pendingURLs.isEmpty { self.openPending() }
            else if self.windows.isEmpty { self.newWindow(with: homeURL) }
            NSApp.activate()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        saveSessionNow(); terminating = true
        Store.shared.flush()
        return .terminateNow
    }

    // MARK: Session: tabs come back asleep, so restoring many costs almost nothing
    private var terminating = false
    private var sessionSave: DispatchWorkItem?
    static var restoreEnabled: Bool { UserDefaults.standard.object(forKey: "RestoreSession") as? Bool ?? true }
    func saveSessionSoon() {
        guard !terminating, AppDelegate.restoreEnabled else { return }
        sessionSave?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveSessionNow() }
        sessionSave = w; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
    }
    private func saveSessionNow() {
        guard !terminating, AppDelegate.restoreEnabled else { return }
        sessionSave?.cancel(); sessionSave = nil
        Store.shared.saveSession(windows.filter { !$0.isPrivate }.compactMap(\.savedState))
    }
    private func restoreSession() {
        guard AppDelegate.restoreEnabled else { return }
        for w in Store.shared.loadSession() where !w.tabs.isEmpty {
            let c = BrowserWindowController()
            windows.append(c)
            c.restore(w)
            if c.tabs.isEmpty { windows.removeLast(); continue }
            c.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// Opens a URL from the library or a menu in the frontmost browser window.
    func open(_ url: URL) {
        if let c = windows.first(where: { $0.window?.isMainWindow == true }) ?? windows.last {
            c.openTab(url, select: true); c.window?.makeKeyAndOrderFront(nil)
        } else { newWindow(with: url) }
    }
    @objc func showHistory(_ s: Any?) { LibraryWindowController.shared.show(.history) }
    @objc func showBookmarks(_ s: Any?) { LibraryWindowController.shared.show(.bookmarks) }
    @objc func showDownloadsList(_ s: Any?) { LibraryWindowController.shared.show(.downloads) }
    @objc private func openMenuURL(_ i: NSMenuItem) { if let u = i.representedObject as? URL { open(u) } }
    @objc private func openMenuBookmark(_ i: NSMenuItem) {
        guard let k = i.representedObject as? String else { return }
        if let c = current { c.openBookmark(k); c.window?.makeKeyAndOrderFront(nil) } else if let u = URL(string: k) { newWindow(with: u) }
    }

    /// History and Bookmarks menus list recent pages / bookmarks, rebuilt each time they open.
    private var historyMenu: NSMenu?, bookmarksMenu: NSMenu?
    private var historyFixed = 0, bookmarksFixed = 0
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === historyMenu {
            while menu.items.count > historyFixed { menu.removeItem(at: historyFixed) }
            for h in Store.shared.recentHistory(15) {
                guard let u = URL(string: h.url) else { continue }
                let i = NSMenuItem(title: String((h.title.isEmpty ? h.url : h.title).prefix(60)), action: #selector(openMenuURL), keyEquivalent: "")
                i.target = self; i.representedObject = u; i.image = Favicons.shared.image(for: u)
                menu.addItem(i)
            }
        } else if menu === bookmarksMenu {
            while menu.items.count > bookmarksFixed { menu.removeItem(at: bookmarksFixed) }
            for b in Store.shared.favorites + Store.shared.pinned {
                let i = NSMenuItem(title: String(b.title.prefix(60)), action: #selector(openMenuBookmark), keyEquivalent: "")
                i.target = self; i.representedObject = b.url; i.image = Favicons.shared.image(for: URL(string: b.url))
                menu.addItem(i)
            }
        }
    }

    /// URLs handed to us by other apps. Held until the block list is ready so the first page is already filtered,
    /// and so launching with a link opens only that link (no extra home tab).
    private var pendingURLs: [URL] = []
    private var blockerReady = false
    func application(_ app: NSApplication, open urls: [URL]) {
        pendingURLs += urls.filter { allowedSchemes.contains($0.scheme?.lowercased() ?? "") }
        if blockerReady { openPending() }
    }
    private func openPending() {
        let ok = pendingURLs; pendingURLs.removeAll()
        guard !ok.isEmpty else { return }
        if let c = current { ok.forEach { c.openTab($0, select: true) } } else {
            let c = newWindow(with: ok[0]); ok.dropFirst().forEach { c.openTab($0, select: false) }
        }
    }

    @discardableResult func newWindow(with url: URL?, isPrivate: Bool = false) -> BrowserWindowController {
        let c = BrowserWindowController(isPrivate: isPrivate)
        windows.append(c)
        _ = c.newTab(with: url)
        c.window?.makeKeyAndOrderFront(nil)
        if windows.count > 1, let prev = windows.dropLast().last?.window {
            c.window?.setFrameTopLeftPoint(NSPoint(x: prev.frame.minX + 24, y: prev.frame.maxY - 24))
        }
        return c
    }
    @objc func newWindowAction(_ s: Any?) { newWindow(with: homeURL) }
    @objc func newPrivateWindow(_ s: Any?) { newWindow(with: nil, isPrivate: true) }
    @objc func newTabAction(_ s: Any?) { if let c = current { c.newTab() } else { newWindow(with: homeURL) } }
    @objc func clearData(_ s: Any?) {
        let a = NSAlert(); a.messageText = "Clear all browsing data?"
        a.informativeText = "Cookies, cache, and site data will be deleted. You will be signed out of websites."
        a.addButton(withTitle: "Clear"); a.addButton(withTitle: "Cancel")
        a.informativeText = "History, cookies, cache and site data will be deleted. You will be signed out of websites. Bookmarks are kept."
        guard a.runModal() == .alertFirstButtonReturn else { return }
        Store.shared.clearHistory()
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
    }

    /// Hands freed-but-cached heap pages in this process back to the OS (cheap; coalesced).
    private var relief: DispatchWorkItem?
    func relieveMemory() {
        relief?.cancel()
        let w = DispatchWorkItem { malloc_zone_pressure_relief(nil, 0) }
        relief = w; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: w)
    }
    private func startMemoryManagement() {
        Timer.scheduledTimer(withTimeInterval: min(60, AppDelegate.suspendAfter / 2), repeats: true) { [weak self] _ in
            self?.windows.forEach { $0.suspendBackground(olderThan: AppDelegate.suspendAfter) }
        }
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in self?.windows.forEach { $0.suspendBackground(olderThan: 0) } }
        src.resume(); memorySource = src
    }

    /// Compiles the bundled ad/tracker block list once; WebKit caches the compiled form on disk.
    private func loadBlocker(then done: @escaping () -> Void) {
        guard let url = Bundle.main.url(forResource: "blocklist", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return done() }
        let domains = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let rules = domains.map { d -> [String: Any] in
            ["trigger": ["url-filter": "^https?://([^/]+\\.)?\(NSRegularExpression.escapedPattern(for: d))[:/]", "load-type": ["third-party"]],
             "action": ["type": "block"]]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules), let json = String(data: data, encoding: .utf8) else { return done() }
        let id = "blk-" + String(text.utf8.reduce(UInt64(5381)) { ($0 &* 33) ^ UInt64($1) }, radix: 36)
        let store = WKContentRuleListStore.default()!
        store.lookUpContentRuleList(forIdentifier: id) { [weak self] cached, _ in
            if let cached { self?.blockRules = cached; return done() }
            store.compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, err in
                if let err { NSLog("blocklist: \(err)") }
                self?.blockRules = list; done()
            }
        }
    }

    private func buildMenu() {
        let main = NSMenu()
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let m = NSMenu(title: title); items.forEach(m.addItem)
            let i = NSMenuItem(); i.submenu = m; main.addItem(i); return m
        }
        func item(_ t: String, _ a: Selector?, _ k: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: k); i.keyEquivalentModifierMask = mods; i.target = target; i.tag = tag; return i
        }
        typealias B = BrowserWindowController
        _ = menu("PaperBrowser", [
            item("About PaperBrowser", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""), .separator(),
            item("Clear Browsing Data…", #selector(clearData), "", target: self), .separator(),
            item("Hide PaperBrowser", #selector(NSApplication.hide), "h"),
            item("Quit PaperBrowser", #selector(NSApplication.terminate), "q"),
        ])
        _ = menu("File", [
            item("New Tab", #selector(newTabAction), "t", target: self),
            item("New Window", #selector(newWindowAction), "n", target: self),
            item("New Private Window", #selector(newPrivateWindow), "n", [.command, .shift], target: self),
            item("Open Location…", #selector(B.focusAddress), "l"), .separator(),
            item("Close Tab", #selector(B.closeCurrentTab), "w"),
            item("Reopen Closed Tab", #selector(B.reopenClosedTab), "t", [.command, .shift]),
            item("Close Window", #selector(NSWindow.performClose), "w", [.command, .shift]),
            item("Print…", #selector(B.printPage), "p"),
        ])
        _ = menu("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            item("Cut", #selector(NSText.cut), "x"), item("Copy", #selector(NSText.copy), "c"),
            item("Paste", #selector(NSText.paste), "v"), item("Select All", #selector(NSText.selectAll), "a"), .separator(),
            item("Find…", #selector(B.findInPage), "f"),
            item("Find Next", #selector(B.findNext), "g"),
            item("Find Previous", #selector(B.findPrevious), "g", [.command, .shift]),
        ])
        _ = menu("View", [
            item("Vertical Tabs", #selector(B.toggleTabLayout), "s", [.command, .control]),
            item("Lite Mode for This Site", #selector(B.toggleLiteMode), "l", [.command, .option]),
            item("Show Reader", #selector(B.toggleReader), "r", [.command, .shift]),
            item("Downloads", #selector(showDownloadsList), "j", [.command, .shift], target: self), .separator(),
            item("Reload", #selector(B.reloadPage), "r"),
            item("Reload Ignoring Cache", #selector(B.reloadIgnoringCache), "r", [.command, .option]),
            item("Stop", #selector(B.stopLoading), "."), .separator(),
            item("Zoom In", #selector(B.zoomIn), "+"),
            item("Zoom Out", #selector(B.zoomOut), "-"),
            item("Actual Size", #selector(B.zoomReset), "0"), .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen), "f", [.command, .control]),
        ])
        let hist = menu("History", [
            item("Back", #selector(B.goBack), "["),
            item("Forward", #selector(B.goForward), "]"), .separator(),
            item("Show All History", #selector(showHistory), "y", target: self), .separator(),
        ])
        hist.delegate = self; historyMenu = hist; historyFixed = hist.items.count
        let marks = menu("Bookmarks", [
            item("Pin This Page", #selector(B.togglePin), "d"),
            item("Show All Bookmarks", #selector(showBookmarks), "b", [.command, .option], target: self),
            item("Clear Unpinned Tabs", #selector(B.clearTabs), "k", [.command, .shift]), .separator(),
        ])
        marks.delegate = self; bookmarksMenu = marks; bookmarksFixed = marks.items.count
        var tabItems = [item("Next Tab", #selector(B.nextTab), "\t", .control),
                        item("Previous Tab", #selector(B.previousTab), "\t", [.control, .shift]),
                        item("Next Tab", #selector(B.nextTab), "]", [.command, .shift]),
                        item("Previous Tab", #selector(B.previousTab), "[", [.command, .shift]), .separator()]
        tabItems[2].isAlternate = false; tabItems[3].isAlternate = false
        for n in 1...9 { tabItems.append(item(n == 9 ? "Last Tab" : "Tab \(n)", #selector(B.selectTabByNumber), "\(n)", tag: n)) }
        _ = menu("Tabs", tabItems)
        let win = menu("Window", [item("Minimize", #selector(NSWindow.performMiniaturize), "m"),
                                  item("Zoom", #selector(NSWindow.performZoom), "")])
        NSApp.mainMenu = main; NSApp.windowsMenu = win
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = AppDelegate.shared
app.run()
