import AppKit

@main @MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var connect: ConnectWindowController!
    private var settings: SettingsWindowController?
    private var windows: [MainWindowController] = []
    private var terminating = false

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
        connect = ConnectWindowController()
        connect.onConnected = { [weak self] connection, tunnel, info in _ = self?.openWindow(connection: connection, tunnel: tunnel, info: info) }
        connect.onOpenFile = { [weak self] path in self?.openFile(atPath: path) }
        connect.onOpenPanel = { [weak self] in self?.openDocument(nil) }
        connect.showWindow(nil)
        NSApp.activate()
    }

    // A newly opened connection: one window, plus the tabs it had open last time.
    @discardableResult
    private func openWindow(connection: DBConnection, tunnel: SSHTunnel?, info: Connection) -> MainWindowController {
        if info.kind == "sqlite" { ConnectionStore.rememberFile(info, moveToTop: true) } // every way of opening a file
        // Already open in another window: a plain new window, without restoring (the tabs are there already).
        let saved = controllers(of: info).isEmpty ? ConnectionStore.savedTabs(for: info.identity) : []
        let controller = makeController(connection: connection, tunnel: tunnel, info: info)
        controller.showWindow(nil)
        connect.window?.orderOut(nil)
        guard !saved.isEmpty else { return controller }
        // Tables that no longer exist are skipped: the list is read once, on the connection's queue, before any tab opens.
        connection.queue.async {
            let existing = Set(((try? connection.tables())?.rows ?? []).map { [$0[0].string ?? "", $0[1].string ?? ""] })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let tabs = saved.filter { existing.contains([$0.schema, $0.table]) }
                    guard let first = tabs.first, controller.window?.isVisible == true else { return }
                    controller.openTable(schema: first.schema, name: first.table, tab: Tab(rawValue: first.page) ?? .data)
                    var last = controller // each tab after the previous one, keeping the saved order
                    for tab in tabs.dropFirst() { last = self.openTab(after: last, schema: tab.schema, table: tab.table, tab: Tab(rawValue: tab.page) ?? .data) }
                    controller.window?.makeKeyAndOrderFront(nil) // the first tab, as before
                }
            }
        }
        return controller
    }

    private func makeController(connection: DBConnection, tunnel: SSHTunnel?, info: Connection) -> MainWindowController {
        let controller = MainWindowController(connection: connection, tunnel: tunnel, info: info)
        controller.onClose = { [weak self] c in self?.windowClosed(c) }
        controller.onTabsChanged = { [weak self] c in self?.saveTabs(of: c.info) }
        controller.onOpenInNewTab = { [weak self] c, schema, table in _ = self?.openTab(after: c, schema: schema, table: table, tab: .data) }
        // Switching from the toolbar: the new window takes the old one's place and size. A tab only closes itself; the
        // new window is offset so the old connection's other tabs stay in sight instead of hiding behind it.
        controller.onReplace = { [weak self] old, connection, tunnel, info in
            guard let self, let oldWindow = old.window else { return }
            let replacement = openWindow(connection: connection, tunnel: tunnel, info: info)
            var frame = oldWindow.frame
            if (oldWindow.tabbedWindows?.count ?? 0) > 1 { frame = frame.offsetBy(dx: 28, dy: -28) }
            replacement.window?.setFrame(frame, display: true)
            oldWindow.close()
        }
        windows.append(controller)
        return controller
    }

    // A tab right after `source`'s, on the same connection (no new login or tunnel).
    private func openTab(after source: MainWindowController, schema: String?, table: String?, tab: Tab) -> MainWindowController {
        let controller = makeController(connection: source.connection, tunnel: source.tunnel, info: source.info)
        if let window = controller.window { source.window?.addTabbedWindow(window, ordered: .above) }
        controller.window?.makeKeyAndOrderFront(nil)
        if let schema, let table { controller.openTable(schema: schema, name: table, tab: tab) } // no table: an empty tab to pick one in
        return controller
    }

    // The windows of one connection, in tab order (tabs first, then any separate windows).
    private func controllers(of info: Connection) -> [MainWindowController] {
        var ordered: [MainWindowController] = []
        for c in windows where c.info.identity == info.identity && !ordered.contains(where: { $0 === c }) {
            for w in c.window?.tabbedWindows ?? [c.window].compactMap({ $0 }) {
                for other in windows where other.window === w && !ordered.contains(where: { $0 === other }) { ordered.append(other) }
            }
        }
        return ordered
    }

    private func saveTabs(of info: Connection) {
        guard !terminating else { return } // saved once, before the windows close one by one
        let tabs = controllers(of: info).compactMap { $0.openTable }
        if !tabs.isEmpty { ConnectionStore.saveTabs(tabs, for: info.identity) }
    }

    // Closing one tab saves the remaining ones. Closing the whole window closes its tabs one after another in the same
    // event, so the save waits for the next turn of the run loop: if no window of the connection is left by then, the
    // list from before (all of them) stays and comes back next time. The connection closes with its last window.
    private func windowClosed(_ closed: MainWindowController) {
        windows.removeAll { $0 === closed }
        let info = closed.info
        DispatchQueue.main.async {
            MainActor.assumeIsolated { if !self.controllers(of: info).isEmpty { self.saveTabs(of: info) } }
        }
        if windows.contains(where: { $0.connection === closed.connection }) { return }
        closed.tunnel?.stop()
        let conn = closed.connection
        conn.queue.async { conn.close() }
    }

    @objc func showConnections(_ sender: Any?) {
        connect.showWindow(nil)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.message = L("Choose an SQLite database file.")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openFile(atPath: url.path) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL { openFile(atPath: url.path) }
    }

    // Opens a window for the file, or shows why it couldn't.
    private func openFile(atPath path: String) {
        let info = ConnectionStore.fileConnection(path: path)
        Task { @MainActor in
            do {
                let (connection, tunnel) = try await PlainDB.connect(info, password: "")
                openWindow(connection: connection, tunnel: tunnel, info: info)
            } catch {
                let alert = NSAlert()
                alert.messageText = String(format: L("Couldn't open %@"), (path as NSString).lastPathComponent)
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc func showSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsWindowController() }
        settings?.showWindow(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows visible: Bool) -> Bool {
        if !visible { showConnections(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        windows.allSatisfy { $0.confirmDiscard() } ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        for c in windows { saveTabs(of: c.info) }
        terminating = true
        for c in windows { c.window?.close() } // closes connections and ssh tunnels
    }

    private func buildMenu() -> NSMenu {
        let bar = NSMenu()

        let app = submenu("PlainDB", in: bar)
        app.addItem(withTitle: L("About PlainDB"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: L("Hide PlainDB"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: L("Quit PlainDB"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = submenu(L("File"), in: bar)
        file.addItem(withTitle: L("Connections…"), action: #selector(showConnections), keyEquivalent: "n")
        file.addItem(withTitle: L("Open…"), action: #selector(openDocument), keyEquivalent: "o")
        file.addItem(withTitle: L("New Tab"), action: #selector(NSResponder.newWindowForTab(_:)), keyEquivalent: "t") // the open table again
        file.addItem(withTitle: L("Close Window"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = submenu(L("Edit"), in: bar)
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Find…"), action: #selector(MainWindowController.showFind(_:)), keyEquivalent: "f")

        let query = submenu(L("Query"), in: bar)
        query.addItem(withTitle: L("Run / Refresh"), action: #selector(MainWindowController.runQuery(_:)), keyEquivalent: "r")
        query.addItem(withTitle: L("Save Changes"), action: #selector(MainWindowController.saveChanges(_:)), keyEquivalent: "s")

        let window = submenu(L("Window"), in: bar)
        window.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = window
        return bar
    }

    private func submenu(_ title: String, in bar: NSMenu) -> NSMenu {
        let menu = NSMenu(title: title)
        bar.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = menu
        return menu
    }
}
