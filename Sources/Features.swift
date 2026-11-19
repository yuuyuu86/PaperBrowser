// PaperBrowser — history, bookmarks, session, downloads, library window, address suggestions, find bar, reader.
import Cocoa
import WebKit

extension Notification.Name {
    static let pbStoreChanged = Notification.Name("PBStoreChanged")
    static let pbDownloadsChanged = Notification.Name("PBDownloadsChanged")
    static let pbBookmarksChanged = Notification.Name("PBBookmarksChanged")
    static let pbFaviconsChanged = Notification.Name("PBFaviconsChanged")
}

// MARK: - Store: history, bookmarks and the last session as small JSON files in the app's sandbox

struct HistoryItem: Codable { var url: String; var title: String; var last: Date; var visits: Int }
struct Bookmark: Codable { var url: String; var title: String; var added: Date; var favorite: Bool? }
struct SavedTab: Codable { var url: String; var title: String; var pinned: String? }
struct SavedWindow: Codable { var tabs: [SavedTab]; var selected: Int }
struct Suggestion { let title: String; let url: URL; let bookmarked: Bool }

final class Store {
    static let shared = Store()
    static let historyLimit = 5000
    private(set) var history: [String: HistoryItem] = [:]
    private(set) var bookmarks: [Bookmark] = []
    private let dir: URL
    private var pending: [String: DispatchWorkItem] = [:]

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("PaperBrowser", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i: HistoryItem in read("history") ?? [] { history[i.url] = i }
        bookmarks = read("bookmarks") ?? []
    }

    private func file(_ n: String) -> URL { dir.appendingPathComponent(n + ".json") }
    private func read<T: Decodable>(_ n: String) -> T? {
        guard let d = try? Data(contentsOf: file(n)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(T.self, from: d)
    }
    private func write<T: Encodable>(_ n: String, _ v: T) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(v) { try? d.write(to: file(n), options: .atomic) }
    }
    /// Writes are coalesced: many visits in a row cost one small file write.
    private func saveSoon(_ n: String) {
        pending[n]?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow(n) }
        pending[n] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
        NotificationCenter.default.post(name: .pbStoreChanged, object: nil)
        if n == "bookmarks" { NotificationCenter.default.post(name: .pbBookmarksChanged, object: nil) }
    }
    private func saveNow(_ n: String) {
        pending[n] = nil
        if n == "history" { write(n, Array(history.values)) } else if n == "bookmarks" { write(n, bookmarks) }
    }
    func flush() { for n in Array(pending.keys) { pending[n]?.cancel(); saveNow(n) } }

    static func recordable(_ u: URL?) -> Bool {
        guard let s = u?.scheme?.lowercased() else { return false }
        return s == "https" || s == "http"
    }

    // History
    func visit(_ url: URL, title: String?) {
        guard Store.recordable(url) else { return }
        let k = url.absoluteString
        var i = history[k] ?? HistoryItem(url: k, title: "", last: Date(), visits: 0)
        i.visits += 1; i.last = Date()
        if let t = title, !t.isEmpty { i.title = t }
        history[k] = i
        if history.count > Store.historyLimit {
            for old in history.values.sorted(by: { $0.last < $1.last }).prefix(history.count - Store.historyLimit + 200) { history[old.url] = nil }
        }
        saveSoon("history")
    }
    func updateTitle(_ url: URL, _ title: String) {
        let k = url.absoluteString
        guard !title.isEmpty, var i = history[k], i.title != title else { return }
        i.title = title; history[k] = i; saveSoon("history")
    }
    func removeHistory(_ k: String) { history[k] = nil; saveSoon("history") }
    func clearHistory() { history.removeAll(); saveSoon("history") }
    func recentHistory(_ n: Int) -> [HistoryItem] { Array(history.values.sorted { $0.last > $1.last }.prefix(n)) }

    // Bookmarks
    func isBookmarked(_ url: URL?) -> Bool {
        guard let k = url?.absoluteString else { return false }
        return bookmarks.contains { $0.url == k }
    }
    /// Arc-style: favorites show as icon tiles, the rest as pinned rows.
    var favorites: [Bookmark] { bookmarks.filter { $0.favorite == true } }
    var pinned: [Bookmark] { bookmarks.filter { $0.favorite != true } }
    func bookmark(_ k: String?) -> Bookmark? { bookmarks.first { $0.url == k } }
    func addBookmark(_ url: URL, title: String, favorite: Bool = false) {
        let k = url.absoluteString
        if let i = bookmarks.firstIndex(where: { $0.url == k }) { bookmarks[i].favorite = favorite }
        else { bookmarks.append(Bookmark(url: k, title: title.isEmpty ? (url.host ?? k) : title, added: Date(), favorite: favorite)) }
        saveSoon("bookmarks")
    }
    func setFavorite(_ k: String, _ on: Bool) {
        guard let i = bookmarks.firstIndex(where: { $0.url == k }) else { return }
        bookmarks[i].favorite = on; saveSoon("bookmarks")
    }
    func moveBookmark(_ k: String, by d: Int) {
        guard let i = bookmarks.firstIndex(where: { $0.url == k }) else { return }
        // move within its own group (favorites or pinned)
        let fav = bookmarks[i].favorite == true
        let group = bookmarks.indices.filter { (bookmarks[$0].favorite == true) == fav }
        guard let gi = group.firstIndex(of: i), group.indices.contains(gi + d) else { return }
        bookmarks.swapAt(i, group[gi + d]); saveSoon("bookmarks")
    }
    func toggleBookmark(_ url: URL, title: String) {
        if isBookmarked(url) { removeBookmark(url.absoluteString) } else { addBookmark(url, title: title) }
    }
    func removeBookmark(_ k: String) { bookmarks.removeAll { $0.url == k }; saveSoon("bookmarks") }

    /// Address-bar suggestions: bookmarks first, then history ranked by visits and recency.
    func suggestions(_ q: String, limit: Int = 8) -> [Suggestion] {
        let terms = q.lowercased().split(separator: " ").map(String.init)
        guard let first = terms.first else { return [] }
        func matches(_ t: String, _ u: String) -> Bool { let h = (t + " " + u).lowercased(); return terms.allSatisfy { h.contains($0) } }
        func hostStarts(_ u: String) -> Bool {
            guard let h = URL(string: u)?.host?.lowercased() else { return false }
            return h.hasPrefix(first) || h.hasPrefix("www." + first)
        }
        var seen = Set<String>(), out: [(Double, Suggestion)] = []
        for b in bookmarks where matches(b.title, b.url) {
            guard let u = URL(string: b.url) else { continue }
            seen.insert(b.url)
            out.append((1000 + (hostStarts(b.url) ? 500 : 0), Suggestion(title: b.title, url: u, bookmarked: true)))
        }
        let now = Date()
        for h in history.values where !seen.contains(h.url) && matches(h.title, h.url) {
            guard let u = URL(string: h.url) else { continue }
            let days = now.timeIntervalSince(h.last) / 86400
            out.append((Double(h.visits) * 10 - days + (hostStarts(h.url) ? 500 : 0),
                        Suggestion(title: h.title.isEmpty ? (u.host ?? h.url) : h.title, url: u, bookmarked: false)))
        }
        return out.sorted { $0.0 > $1.0 }.prefix(limit).map { $0.1 }
    }

    // Session
    func saveSession(_ s: [SavedWindow]) { write("session", s) }
    func loadSession() -> [SavedWindow] { read("session") ?? [] }
}

// MARK: - Downloads

final class DownloadItem {
    enum State { case running, done, failed(String), cancelled }
    let name: String
    let file: URL
    var fraction: Double = 0
    var state: State = .running
    weak var download: WKDownload?
    var observation: NSKeyValueObservation?
    init(name: String, file: URL) { self.name = name; self.file = file }
    var isRunning: Bool { if case .running = state { return true }; return false }
}

final class Downloads: NSObject, WKDownloadDelegate {
    static let shared = Downloads()
    private(set) var items: [DownloadItem] = []
    private var map: [ObjectIdentifier: DownloadItem] = [:]
    private var lastPost = Date.distantPast
    var active: Int { items.filter(\.isRunning).count }

    private func changed(force: Bool = true) {
        guard force || Date().timeIntervalSince(lastPost) > 0.25 else { return }
        lastPost = Date()
        NotificationCenter.default.post(name: .pbDownloadsChanged, object: nil)
    }

    /// Saved to ~/Downloads with a unique name; never opened automatically.
    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename name: String, completionHandler: @escaping (URL?) -> Void) {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let safe = (name as NSString).lastPathComponent.replacingOccurrences(of: ":", with: "_")
        let base = (safe as NSString).deletingPathExtension, ext = (safe as NSString).pathExtension
        var dest = dir.appendingPathComponent(safe.isEmpty ? "download" : safe), i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) (\(i))" + (ext.isEmpty ? "" : ".\(ext)")); i += 1
        }
        let item = DownloadItem(name: dest.lastPathComponent, file: dest)
        item.download = d
        item.observation = d.progress.observe(\.fractionCompleted) { [weak self, weak item] p, _ in
            let f = p.fractionCompleted
            DispatchQueue.main.async { item?.fraction = f; self?.changed(force: false) }
        }
        items.insert(item, at: 0); map[ObjectIdentifier(d)] = item
        changed()
        completionHandler(dest)
    }
    func downloadDidFinish(_ d: WKDownload) {
        if let i = map.removeValue(forKey: ObjectIdentifier(d)) { i.state = .done; i.fraction = 1; i.observation = nil }
        NSSound(named: "Glass")?.play()
        changed()
    }
    func download(_ d: WKDownload, didFailWithError e: Error, resumeData: Data?) {
        if let i = map.removeValue(forKey: ObjectIdentifier(d)) {
            i.observation = nil
            if case .cancelled = i.state {} else { i.state = .failed(e.localizedDescription) }
        }
        changed()
    }
    func cancel(_ i: DownloadItem) {
        guard i.isRunning else { return }
        i.state = .cancelled
        i.download?.cancel { _ in }
        changed()
    }
    func remove(_ i: DownloadItem) {
        cancel(i)
        items.removeAll { $0 === i }
        changed()
    }
}

// MARK: - Library window: History · Bookmarks · Downloads

final class TwoLineCell: NSTableCellView {
    let title = NSTextField(labelWithString: ""), detail = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13); title.textColor = Theme.ink; title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11); detail.textColor = Theme.faint; detail.lineBreakMode = .byTruncatingMiddle
        for v in [title, detail] {
            v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v)
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class KeyTable: NSTableView {
    var onDelete: (() -> Void)?, onEnter: (() -> Void)?
    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 51, 117: onDelete?()        // delete, forward delete
        case 36, 76: onEnter?()          // return, enter
        default: super.keyDown(with: e)
        }
    }
}

final class LibraryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    static let shared = LibraryWindowController()
    enum Section: Int { case history, bookmarks, downloads }
    private struct Row { let title: String; let detail: String; let url: URL?; let key: String; let download: DownloadItem? }

    private let segment = NSSegmentedControl(labels: ["History", "Bookmarks", "Downloads"], trackingMode: .selectOne, target: nil, action: nil)
    private let search = NSSearchField()
    private let table = KeyTable()
    private let footer = NSTextField(labelWithString: "")
    private let clearButton = NSButton(title: "Clear History…", target: nil, action: nil)
    private var rows: [Row] = []
    private var section: Section = .history
    private let dateFormat: DateFormatter = { let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f }()
    private let bytes = ByteCountFormatter()

    private init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        w.title = "Library"; w.minSize = NSSize(width: 420, height: 300); w.isReleasedWhenClosed = false
        super.init(window: w)
        w.delegate = self
        build()
        w.setFrameAutosaveName("PaperBrowserLibrary")
        w.center()
        NotificationCenter.default.addObserver(self, selector: #selector(dataChanged), name: .pbStoreChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(dataChanged), name: .pbDownloadsChanged, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        segment.target = self; segment.action = #selector(segmentChanged)
        search.placeholderString = "Search"; search.delegate = self
        search.target = self; search.action = #selector(searchChanged)
        clearButton.target = self; clearButton.action = #selector(clearHistory); clearButton.bezelStyle = .rounded
        footer.font = .systemFont(ofSize: 11); footer.textColor = Theme.faint

        let col = NSTableColumn(identifier: .init("row")); col.resizingMask = .autoresizingMask
        table.addTableColumn(col); table.headerView = nil; table.rowHeight = 40
        table.style = .inset; table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self; table.delegate = self
        table.target = self; table.doubleAction = #selector(activate)
        table.onEnter = { [weak self] in self?.activate() }
        table.onDelete = { [weak self] in self?.deleteSelected() }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(activate), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Copy Link", action: #selector(copyLink), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Show in Finder", action: #selector(reveal), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Delete", action: #selector(deleteSelected), keyEquivalent: "").target = self
        table.menu = menu

        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let top = NSStackView(views: [segment, search]); top.spacing = 12
        let bottom = NSStackView(views: [footer, NSView(), clearButton]); bottom.spacing = 8
        let root = NSView()
        for v in [top, scroll, bottom] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(v) }
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            top.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            top.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            bottom.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            bottom.heightAnchor.constraint(equalToConstant: 24),
        ])
        window?.contentView = root
    }

    func show(_ s: Section) {
        section = s; segment.selectedSegment = s.rawValue
        reload()
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(table)
    }

    @objc private func segmentChanged() { section = Section(rawValue: segment.selectedSegment) ?? .history; reload() }
    @objc private func searchChanged() { reload() }
    func controlTextDidChange(_ n: Notification) { reload() }
    @objc private func dataChanged() { if window?.isVisible == true { reload() } }

    private func reload() {
        let q = search.stringValue.lowercased().trimmingCharacters(in: .whitespaces)
        func keep(_ a: String, _ b: String) -> Bool { q.isEmpty || a.lowercased().contains(q) || b.lowercased().contains(q) }
        switch section {
        case .history:
            rows = Store.shared.history.values.sorted { $0.last > $1.last }.lazy
                .filter { keep($0.title, $0.url) }.prefix(1000)
                .map { Row(title: $0.title.isEmpty ? $0.url : $0.title, detail: "\(self.dateFormat.string(from: $0.last))  ·  \($0.url)", url: URL(string: $0.url), key: $0.url, download: nil) }
            footer.stringValue = "\(Store.shared.history.count) pages"
        case .bookmarks:
            rows = Store.shared.bookmarks.filter { keep($0.title, $0.url) }
                .map { Row(title: $0.title, detail: $0.url, url: URL(string: $0.url), key: $0.url, download: nil) }
            footer.stringValue = "\(Store.shared.bookmarks.count) bookmarks  ·  ⌘D adds the current page"
        case .downloads:
            rows = Downloads.shared.items.filter { keep($0.name, $0.file.path) }.map { d in
                let status: String
                switch d.state {
                case .running: status = "Downloading… \(Int(d.fraction * 100))%"
                case .done:
                    let size = (try? d.file.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 }.map { bytes.string(fromByteCount: Int64($0)) } ?? ""
                    status = "Done" + (size.isEmpty ? "" : "  ·  \(size)")
                case .failed(let m): status = "Failed  ·  \(m)"
                case .cancelled: status = "Cancelled"
                }
                return Row(title: d.name, detail: status, url: nil, key: d.file.path, download: d)
            }
            footer.stringValue = rows.isEmpty ? "No downloads in this session" : "Saved to your Downloads folder  ·  double-click to show in Finder"
        }
        clearButton.isHidden = section != .history
        table.reloadData()
    }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let cell = (t.makeView(withIdentifier: .init("cell"), owner: nil) as? TwoLineCell) ?? {
            let v = TwoLineCell(); v.identifier = .init("cell"); return v
        }()
        cell.title.stringValue = rows[row].title; cell.detail.stringValue = rows[row].detail
        return cell
    }

    private var target: Int { table.clickedRow >= 0 ? table.clickedRow : table.selectedRow }
    @objc private func activate() {
        let i = target; guard i >= 0, i < rows.count else { return }
        if let d = rows[i].download { if case .done = d.state { NSWorkspace.shared.activateFileViewerSelecting([d.file]) }; return }
        if let u = rows[i].url { AppDelegate.shared.open(u) }
    }
    @objc private func copyLink() {
        let i = target; guard i >= 0, i < rows.count, let u = rows[i].url else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u.absoluteString, forType: .string)
    }
    @objc private func reveal() {
        let i = target; guard i >= 0, i < rows.count, let d = rows[i].download else { return }
        NSWorkspace.shared.activateFileViewerSelecting([d.file])
    }
    @objc private func deleteSelected() {
        let i = target; guard i >= 0, i < rows.count else { return }
        switch section {
        case .history: Store.shared.removeHistory(rows[i].key)
        case .bookmarks: Store.shared.removeBookmark(rows[i].key)
        case .downloads: if let d = rows[i].download { Downloads.shared.remove(d) }
        }
        reload()
    }
    @objc private func clearHistory() {
        let a = NSAlert(); a.messageText = "Clear all history?"; a.informativeText = "Bookmarks, cookies and site data are kept."
        a.addButton(withTitle: "Clear"); a.addButton(withTitle: "Cancel")
        guard let w = window else { return }
        a.beginSheetModal(for: w) { if $0 == .alertFirstButtonReturn { Store.shared.clearHistory() } }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let i = target, ok = i >= 0 && i < rows.count
        if item.action == #selector(reveal) { return ok && rows[i].download != nil }
        if item.action == #selector(copyLink) { return ok && rows[i].url != nil }
        return ok
    }
}

// MARK: - Address-bar suggestions (a small panel under the address field)

final class SuggestionsPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private(set) var items: [Suggestion] = []
    var onPick: ((Suggestion) -> Void)?
    var isVisible: Bool { panel.isVisible }
    var selected: Suggestion? { let r = table.selectedRow; return r >= 0 && r < items.count ? items[r] : nil }

    override init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        let bg = FlatView(); bg.fill = Theme.sheet; bg.stroke = Theme.hair; bg.radius = 8
        let col = NSTableColumn(identifier: .init("s")); col.resizingMask = .autoresizingMask
        table.addTableColumn(col); table.headerView = nil; table.rowHeight = 28
        table.style = .plain; table.backgroundColor = .clear; table.intercellSpacing = .zero
        table.dataSource = self; table.delegate = self
        table.target = self; table.action = #selector(clicked)
        scroll.documentView = table; scroll.drawsBackground = false; scroll.hasVerticalScroller = false
        scroll.translatesAutoresizingMaskIntoConstraints = false; bg.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: bg.topAnchor, constant: 4), scroll.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 4), scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -4),
        ])
        panel.contentView = bg
    }

    func show(_ items: [Suggestion], under anchor: NSView) {
        self.items = items
        guard !items.isEmpty, let win = anchor.window else { hide(); return }
        table.reloadData(); table.deselectAll(nil)
        let r = win.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let h = CGFloat(items.count) * 28 + 8
        panel.setFrame(NSRect(x: r.minX, y: r.minY - h - 4, width: r.width, height: h), display: true)
        if panel.parent == nil { win.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }
    func hide() { panel.parent?.removeChildWindow(panel); panel.orderOut(nil) }
    func move(_ d: Int) {
        guard !items.isEmpty else { return }
        let n = table.selectedRow
        let next = n < 0 ? (d > 0 ? 0 : items.count - 1) : max(0, min(items.count - 1, n + d))
        table.selectRowIndexes([next], byExtendingSelection: false)
    }
    @objc private func clicked() { let r = table.clickedRow; if r >= 0, r < items.count { onPick?(items[r]) } }

    func numberOfRows(in t: NSTableView) -> Int { items.count }
    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let s = items[row]
        let shown = (s.url.host ?? "") + (s.url.path == "/" ? "" : s.url.path)
        let text = NSMutableAttributedString(string: (s.bookmarked ? "★ " : "") + s.title,
                                             attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Theme.ink])
        text.append(NSAttributedString(string: "   " + shown, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: Theme.faint]))
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
        let cell = NSTableCellView(); label.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - Find bar (floats over the top-right of the page)

final class FindBar: FlatView, NSTextFieldDelegate {
    let field = NSTextField()
    private let status = NSTextField(labelWithString: "")
    var onSearch: ((String, Bool) -> Void)?
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        fill = Theme.sheet; stroke = Theme.hair; radius = 8
        shadow = NSShadow(); layer?.shadowOpacity = 0.12; layer?.shadowRadius = 6; layer?.shadowOffset = CGSize(width: 0, height: -2)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .systemFont(ofSize: 13); field.placeholderString = "Find in page"; field.delegate = self
        status.font = .systemFont(ofSize: 11); status.textColor = Theme.shu
        let prev = symbolButton("chevron.up", self, #selector(prevTapped), size: 11)
        let next = symbolButton("chevron.down", self, #selector(nextTapped), size: 11)
        let done = symbolButton("xmark", self, #selector(doneTapped), size: 10)
        prev.toolTip = "Previous (⇧⌘G)"; next.toolTip = "Next (⌘G)"; done.toolTip = "Done (esc)"
        let row = NSStackView(views: [field, status, prev, next, done]); row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setFound(_ found: Bool?) { status.stringValue = found == false ? "Not found" : "" }
    func controlTextDidChange(_ n: Notification) { onSearch?(field.stringValue, false) }
    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) {
            onSearch?(field.stringValue, NSApp.currentEvent?.modifierFlags.contains(.shift) == true); return true
        }
        if sel == #selector(NSResponder.cancelOperation(_:)) || sel == #selector(NSTextView.complete(_:)) { onClose?(); return true }
        return false
    }
    @objc private func prevTapped() { onSearch?(field.stringValue, true) }
    @objc private func nextTapped() { onSearch?(field.stringValue, false) }
    @objc private func doneTapped() { onClose?() }
}

// MARK: - Reader: the article only, on paper, with no scripts at all

enum Reader {
    /// Finds the block with the most paragraph text and copies it through a tag whitelist.
    /// Runs in the app's own content world, so the page cannot tamper with it.
    static let extractJS = #"""
    (() => {
      const KEEP = new Set(['P','H1','H2','H3','H4','H5','H6','UL','OL','LI','BLOCKQUOTE','PRE','CODE','IMG','FIGURE','FIGCAPTION','A','EM','STRONG','B','I','BR','HR','TABLE','THEAD','TBODY','TR','TH','TD','SUP','SUB','DL','DT','DD']);
      const DROP = new Set(['SCRIPT','STYLE','NOSCRIPT','IFRAME','FORM','BUTTON','INPUT','SELECT','TEXTAREA','NAV','ASIDE','FOOTER','HEADER','SVG','CANVAS','VIDEO','AUDIO','OBJECT','EMBED','DIALOG','TEMPLATE']);
      const BAD = /comment|share|social|related|recommend|promo|advert|sponsor|banner|footer|nav|menu|sidebar|cookie|subscribe|newsletter|ranking|editsection|noprint|mw-jump|toc|infobox|navbox|metadata|ambox|mbox|hatnote|reflist|references|catlinks|printfooter/i;
      const esc = s => s.replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
      const abs = u => { try { const x = new URL(u, location.href); return /^https?:$/.test(x.protocol) ? x.href : ''; } catch (e) { return ''; } };
      const label = el => (el.className && el.className.baseVal === undefined ? el.className : '') + ' ' + (el.id || '');
      const score = new Map(), counted = [];
      for (const p of document.querySelectorAll('p, pre, blockquote')) {
        const len = p.textContent.trim().length;
        if (len < 25) continue;
        counted.push([p, len]);
        const add = 1 + Math.min(len / 100, 3) + p.textContent.split(/[,、。]/).length;
        let a = p.parentElement, d = 0;
        while (a && d < 3) {
          if (!BAD.test(label(a))) score.set(a, (score.get(a) || 0) + add / (d + 1));
          a = a.parentElement; d++;
        }
      }
      let best = null, bs = 0;
      for (const [el, s] of score) if (s > bs) { bs = s; best = el; }
      if (!best || bs < 8) return JSON.stringify({ error: 'no article' });
      // widen while the parent adds article text (keeps the intro and every section)
      const total = counted.reduce((a, x) => a + x[1], 0);
      const inside = el => counted.reduce((a, x) => a + (el.contains(x[0]) ? x[1] : 0), 0);
      while (best.parentElement && best.parentElement !== document.body && inside(best.parentElement) > inside(best) * 1.05) best = best.parentElement;
      const title = (document.querySelector('meta[property="og:title"]')?.content || document.querySelector('h1')?.textContent || document.title || '').trim();
      const out = [];
      const walk = node => {
        for (const ch of node.childNodes) {
          if (ch.nodeType === 3) { out.push(esc(ch.textContent)); continue; }
          if (ch.nodeType !== 1 || DROP.has(ch.tagName)) continue;
          const tag = ch.tagName;
          if (tag !== 'P' && BAD.test(label(ch))) continue;
          const st = getComputedStyle(ch);
          if (st.display === 'none' || st.visibility === 'hidden') continue;
          if (tag === 'H1' && ch.textContent.trim() === title) continue;
          if (!KEEP.has(tag)) { walk(ch); continue; }
          const t = tag.toLowerCase();
          if (t === 'img') {
            const src = abs(ch.currentSrc || ch.src || ch.dataset.src || '');
            if (src) out.push(`<img src="${esc(src)}" alt="${esc(ch.alt || '')}">`);
            continue;
          }
          if (t === 'br' || t === 'hr') { out.push(`<${t}>`); continue; }
          let attrs = '';
          if (t === 'a') { const h = abs(ch.getAttribute('href') || ''); if (h) attrs = ` href="${esc(h)}"`; }
          out.push(`<${t}${attrs}>`); walk(ch); out.push(`</${t}>`);
        }
      };
      walk(best);
      const meta = n => document.querySelector(`meta[name="${n}"], meta[property="${n}"]`)?.content || '';
      return JSON.stringify({
        title, html: out.join(''),
        byline: meta('author') || meta('article:author'),
        site: meta('og:site_name') || location.hostname,
        lang: document.documentElement.lang || ''
      });
    })()
    """#

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func page(title: String, site: String, byline: String, lang: String, body: String, source: URL) -> String {
        """
        <!doctype html><html lang="\(esc(lang))"><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data:; style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width"><title>\(esc(title))</title>
        <style>
        :root{color-scheme:light dark;--bg:#F4EFE6;--ink:#2B2722;--faint:#8A8276;--hair:rgba(43,39,34,.12);--shu:#C23B27}
        @media(prefers-color-scheme:dark){:root{--bg:#1B1A18;--ink:#ECE6DA;--faint:#8E877B;--hair:rgba(236,230,218,.12);--shu:#F0604A}}
        html{background:var(--bg)}
        body{margin:0;color:var(--ink);font:19px/1.95 "Hiragino Mincho ProN","Yu Mincho",Georgia,serif;-webkit-font-smoothing:antialiased}
        article{max-width:680px;margin:0 auto;padding:64px 28px 96px}
        .site,.by,.src,figcaption{font-family:-apple-system,"Hiragino Sans",sans-serif}
        .site{font-size:13px;color:var(--faint);margin:0 0 12px}
        h1{font-size:34px;line-height:1.45;font-weight:600;margin:0}
        .by{font-size:14px;color:var(--faint);margin:12px 0 0}
        .rule{width:48px;height:1px;background:var(--shu);margin:28px 0 36px}
        h2,h3,h4,h5,h6{line-height:1.5;font-weight:600;margin:2em 0 .6em}h2{font-size:24px}h3{font-size:20px}
        p{margin:0 0 1.2em}
        a{color:inherit;text-decoration-color:var(--shu);text-underline-offset:3px}
        img{max-width:100%;height:auto;border-radius:4px;display:block;margin:1.6em auto}
        figure{margin:1.6em 0}figcaption{font-size:13px;line-height:1.6;color:var(--faint);text-align:center}
        blockquote{margin:1.4em 0;padding-left:1.2em;border-left:1px solid var(--shu);color:var(--faint)}
        pre,code{font:14px/1.6 ui-monospace,Menlo,monospace}pre{overflow:auto;padding:16px;border:1px solid var(--hair);border-radius:8px}
        table{border-collapse:collapse;font-size:15px}td,th{border:1px solid var(--hair);padding:6px 10px}
        hr{border:0;border-top:1px solid var(--hair);margin:2em 0}
        .src{margin-top:3em;font-size:13px;color:var(--faint)}
        </style></head><body><article>
        <p class="site">\(esc(site))</p><h1>\(esc(title))</h1>\(byline.isEmpty ? "" : "<p class=\"by\">\(esc(byline))</p>")
        <div class="rule"></div>
        \(body)
        <p class="src"><a href="\(esc(source.absoluteString))">View original page</a></p>
        </article></body></html>
        """
    }
}

// MARK: - Favicons: learned from pages you visit, fetched without cookies, stored as tiny PNGs

final class Favicons {
    static let shared = Favicons()
    private var cache: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var inflight: Set<String> = []
    private let dir: URL
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10; c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCache = nil
        return URLSession(configuration: c)
    }()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("PaperBrowser/icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    static func key(_ u: URL?) -> String? { u?.host?.lowercased() }
    private func file(_ k: String) -> URL { dir.appendingPathComponent(k.replacingOccurrences(of: "/", with: "_") + ".png") }

    func image(for u: URL?) -> NSImage? {
        guard let k = Favicons.key(u) else { return nil }
        if let i = cache[k] { return i }
        if missing.contains(k) { return nil }
        if let i = NSImage(contentsOf: file(k)) { i.size = NSSize(width: 16, height: 16); cache[k] = i; return i }
        missing.insert(k); return nil
    }

    /// For bookmarks never opened yet: try the site's /favicon.ico (no cookies), once per launch.
    private var tried: Set<String> = []
    func prefetch(_ u: URL?) {
        guard let u, Store.recordable(u), let k = Favicons.key(u), image(for: u) == nil,
              !inflight.contains(k), !tried.contains(k) else { return }
        tried.insert(k); inflight.insert(k)
        fetch(URL(string: "https://\(k)/favicon.ico"), k)
    }
    func learn(from w: WKWebView) {
        guard let page = w.url, Store.recordable(page), let k = Favicons.key(page),
              cache[k] == nil, !inflight.contains(k), !FileManager.default.fileExists(atPath: file(k).path) else { return }
        inflight.insert(k)
        let js = #"""
        (() => {
          let best = null, bs = -1;
          for (const l of document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"]')) {
            const n = parseInt(((l.sizes && l.sizes.value) || '').split('x')[0]) || (l.rel.includes('apple') ? 180 : 16);
            const sc = n >= 32 && n <= 192 ? 1000 - n : n;
            if (sc > bs) { bs = sc; best = l.href; }
          }
          return best || (location.origin + '/favicon.ico');
        })()
        """#
        w.evaluateJavaScript(js, in: nil, in: .defaultClient) { [weak self] r in
            var src = URL(string: "https://\(k)/favicon.ico")
            if case .success(let v) = r, let s = v as? String, let u = URL(string: s), ["https", "http", "data"].contains(u.scheme ?? "") { src = u }
            self?.fetch(src, k)
        }
    }
    private func fetch(_ u: URL?, _ k: String) {
        guard let u else { inflight.remove(k); return }
        if u.scheme == "data" { store(try? Data(contentsOf: u), k); return }
        session.dataTask(with: u) { [weak self] d, _, _ in DispatchQueue.main.async { self?.store(d, k) } }.resume()
    }
    private func store(_ d: Data?, _ k: String) {
        inflight.remove(k)
        guard let d, d.count < 512_000, let src = NSImage(data: d), src.size.width > 0 else { return }
        let px = 64
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: file(k), options: .atomic)
        let img = NSImage(data: png); img?.size = NSSize(width: 16, height: 16)
        cache[k] = img; missing.remove(k)
        NotificationCenter.default.post(name: .pbFaviconsChanged, object: nil)
    }
}
