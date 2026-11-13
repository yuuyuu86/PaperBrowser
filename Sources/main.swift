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

// MARK: - Tab: owns one web view and all of its WebKit delegate logic

final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    weak var owner: BrowserWindowController?
    private(set) var webView: WKWebView
    private var observers: [NSKeyValueObservation] = []
    private(set) var suspendedURL: URL?
    private(set) var suspendedTitle: String?
    var lastActive = Date()
    var onChange: (() -> Void)?
    private var httpAllowed: Set<String> = []
    private var pendingUpgrade: String?

    var title: String {
        if let t = suspendedTitle { return t }
        if let t = webView.title, !t.isEmpty { return t }
        return webView.url?.host ?? "New Tab"
    }
    var url: URL? { suspendedURL ?? webView.url }
    var isSecure: Bool { url?.scheme == "https" && (suspendedURL != nil || webView.hasOnlySecureContent) }

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
    func webView(_ w: WKWebView, didCommit n: WKNavigation!) { pendingUpgrade = nil }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { AppDelegate.shared.relieveMemory() }
    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(r.canShowMIMEType ? .allow : .download)
    }
    func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome d: WKDownload) { d.delegate = self }
    func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = self }
    func webViewWebContentProcessDidTerminate(_ w: WKWebView) { if suspendedURL == nil { w.reload() } }

    // MARK: Downloads — saved to ~/Downloads, never auto-opened
    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename name: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let safe = (name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "_")
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
        var dest = dir.appendingPathComponent(safe.isEmpty ? "download" : safe), i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) (\(i))" + (ext.isEmpty ? "" : ".\(ext)")); i += 1
        }
        completionHandler(dest)
    }
    func downloadDidFinish(_ d: WKDownload) { NSSound(named: "Glass")?.play() }

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
    lazy var closeButton = symbolButton("xmark", self, #selector(closeClicked), size: 9)
    var onSelect: (() -> Void)?, onClose: (() -> Void)?
    var selected = false { didSet { restyle() } }
    var sleeping = false { didSet { restyle() } }
    private var hovering = false { didSet { restyle() } }

    init(vertical: Bool) {
        super.init(frame: .zero)
        radius = 7
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        dot.radius = 2.5; dot.fill = Theme.faint
        for v in [dot, label, closeButton] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: vertical ? 30 : 28),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 5), dot.heightAnchor.constraint(equalToConstant: 5),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
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
        closeButton.isHidden = !(selected || hovering)
    }
    override func mouseEntered(with e: NSEvent) { hovering = true }
    override func mouseExited(with e: NSEvent) { hovering = false }
    override func mouseDown(with e: NSEvent) { onSelect?() }
    override func otherMouseUp(with e: NSEvent) { if e.buttonNumber == 2 { onClose?() } }
    @objc private func closeClicked() { onClose?() }
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
        let tb = NSStackView(views: [controls, addressBox, newTab])
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
        content.addSubview(w)
        rebuildTabList(); syncChrome()
        if tab.url == nil { focusAddress(nil) } else { window?.makeFirstResponder(w) }
    }
    func closeTab(_ tab: Tab) {
        guard let i = tabs.firstIndex(where: { $0 === tab }) else { return }
        tab.close(); tabs.remove(at: i)
        if tabs.isEmpty { selected = nil; window?.close(); return }
        if selected === tab { selected = nil; select(tabs[min(i, tabs.count - 1)]) } else { rebuildTabList() }
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
    private func rebuildTabList() {
        let list = layout == .vertical ? sideList : stripList
        sideList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stripList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        itemViews.removeAll()
        for t in tabs {
            let v = TabItemView(vertical: layout == .vertical)
            v.onSelect = { [weak self, weak t] in if let t { self?.select(t) } }
            v.onClose = { [weak self, weak t] in if let t { self?.closeTab(t) } }
            list.addArrangedSubview(v)
            if layout == .vertical { v.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true }
            else { v.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true; v.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true }
            itemViews[ObjectIdentifier(t)] = v
            update(v, t)
        }
    }
    private func update(_ v: TabItemView, _ t: Tab) {
        v.label.stringValue = t.title; v.toolTip = t.title
        v.selected = t === selected; v.sleeping = t.suspendedURL != nil
    }
    private func tabChanged(_ t: Tab) {
        if let v = itemViews[ObjectIdentifier(t)] { update(v, t) }
        if t === selected { syncChrome() }
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
        let p = w.estimatedProgress
        let full = max(addressBox.bounds.width - 16, 0)
        hairWidth.constant = (p > 0 && p < 1) ? full * p : 0
        window?.title = (isPrivate ? "Private — " : "") + t.title
    }

    // MARK: Actions
    @objc func go() { if let u = resolve(address.stringValue), let t = selected { t.load(u); window?.makeFirstResponder(t.webView) } }
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
    @objc func findInPage(_ s: Any?) {
        guard let win = window else { return }
        let a = NSAlert(); a.messageText = "Find in Page"; a.addButton(withTitle: "Find"); a.addButton(withTitle: "Cancel")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); a.accessoryView = f
        a.window.initialFirstResponder = f
        a.beginSheetModal(for: win) { [weak self] r in
            guard r == .alertFirstButtonReturn, !f.stringValue.isEmpty else { return }
            let c = WKFindConfiguration(); c.wraps = true
            self?.selected?.webView.find(f.stringValue, configuration: c) { if !$0.matchFound { NSSound.beep() } }
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleTabLayout) { item.state = layout == .vertical ? .on : .off }
        return true
    }

    func controlTextDidEndEditing(_ n: Notification) { syncChrome() }
    func windowDidResize(_ n: Notification) { syncChrome() }
    func windowWillClose(_ n: Notification) {
        tabs.forEach { $0.close() }; tabs.removeAll(); selected = nil
        AppDelegate.shared.windows.removeAll { $0 === self }
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
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
            if !self.pendingURLs.isEmpty { self.openPending() }
            else if self.windows.isEmpty { self.newWindow(with: homeURL) }
            NSApp.activate()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

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
        guard a.runModal() == .alertFirstButtonReturn else { return }
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
            item("Close Window", #selector(NSWindow.performClose), "w", [.command, .shift]),
            item("Print…", #selector(B.printPage), "p"),
        ])
        _ = menu("Edit", [
            item("Undo", Selector(("undo:")), "z"), item("Redo", Selector(("redo:")), "z", [.command, .shift]), .separator(),
            item("Cut", #selector(NSText.cut), "x"), item("Copy", #selector(NSText.copy), "c"),
            item("Paste", #selector(NSText.paste), "v"), item("Select All", #selector(NSText.selectAll), "a"), .separator(),
            item("Find…", #selector(B.findInPage), "f"),
        ])
        _ = menu("View", [
            item("Vertical Tabs", #selector(B.toggleTabLayout), "s", [.command, .control]), .separator(),
            item("Reload", #selector(B.reloadPage), "r"),
            item("Reload Ignoring Cache", #selector(B.reloadIgnoringCache), "r", [.command, .shift]),
            item("Stop", #selector(B.stopLoading), "."), .separator(),
            item("Zoom In", #selector(B.zoomIn), "+"),
            item("Zoom Out", #selector(B.zoomOut), "-"),
            item("Actual Size", #selector(B.zoomReset), "0"), .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen), "f", [.command, .control]),
        ])
        _ = menu("History", [
            item("Back", #selector(B.goBack), "["),
            item("Forward", #selector(B.goForward), "]"),
        ])
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
