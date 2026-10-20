import AppKit

private let languagesKey = "AppleLanguages"

// Interface languages: code (nil = follow the system) and the name shown, each in its own language.
func settingsLanguages() -> [(code: String?, name: String)] {
    [(nil, L("System default")), ("en", "English"), ("pl", "Polski")]
}

// The menu item for the language the app was set to (the first AppleLanguages entry); unknown or none: System default.
func languageIndex(current: String?) -> Int {
    settingsLanguages().firstIndex { $0.code != nil && $0.code == current } ?? 0
}

// /bin/sh arguments that wait for process `pid` to exit, then start a fresh copy of the app with `open -n`.
func restartArguments(pid: Int32, bundlePath: String) -> [String] {
    ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open -n \"$0\"", bundlePath]
}

// A field-style box around a borderless pop-up button.
private final class PopUpBox: LayerView {
    let popUp = NSPopUpButton(frame: .zero, pullsDown: false)

    override init(frame: NSRect) {
        super.init(frame: frame)
        popUp.isBordered = false
        popUp.font = Theme.font(12.5)
        (popUp.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        pin(popUp, self, NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 4))
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateColors() {
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Theme.fill.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.fieldB.cgColor
    }
}

// Settings (⌘,): interface language. The choice is stored in the app's AppleLanguages default and takes effect after
// a restart, which the window offers to do.
final class SettingsWindowController: NSWindowController {
    private let language = PopUpBox()
    private let note = label(L("Restart PlainDB to apply the new language."), 11, .regular, Theme.t2)
    private var restart: PillButton!

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 182),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.isReleasedWhenClosed = false
        window.title = L("Settings")
        window.titlebarAppearsTransparent = true

        let popUp = language.popUp
        for l in settingsLanguages() { popUp.addItem(withTitle: l.name) }
        let current = Bundle.main.bundleIdentifier
            .flatMap { UserDefaults.standard.persistentDomain(forName: $0)?[languagesKey] as? [String] }?.first
        popUp.selectItem(at: languageIndex(current: current))
        popUp.target = self
        popUp.action = #selector(languageChanged)
        language.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        restart = PillButton(L("Restart Now"), style: .accent, height: 26, target: self, action: #selector(restartNow))
        note.isHidden = true
        restart.isHidden = true

        let languageLabel = label(L("Language:"), 12.5, .regular, Theme.t2)
        languageLabel.alignment = .right
        let grid = NSGridView(views: [
            [languageLabel, language],
            [NSGridCell.emptyContentView, note],
            [NSGridCell.emptyContentView, restart],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.cell(for: restart)?.xPlacement = .leading
        grid.rowAlignment = .none
        grid.cell(for: languageLabel)?.yPlacement = .center
        grid.row(at: 0).yPlacement = .center
        grid.rowSpacing = 10
        grid.columnSpacing = 12

        let panel = Panel(fill: Theme.panel, border: Theme.pb, radius: 16, shadow: true)
        grid.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: panel.topAnchor, constant: 18),
            grid.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
        ])
        let root = NSView()
        pin(WindowBackground(), root)
        pin(panel, root, NSEdgeInsets(top: 40, left: 12, bottom: 12, right: 12))
        NSLayoutConstraint.activate([root.widthAnchor.constraint(equalToConstant: 420), root.heightAnchor.constraint(equalToConstant: 182)])
        window.contentView = root
        window.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func languageChanged(_ sender: Any?) {
        if let code = settingsLanguages()[language.popUp.indexOfSelectedItem].code {
            UserDefaults.standard.set([code], forKey: languagesKey)
        } else {
            UserDefaults.standard.removeObject(forKey: languagesKey)
        }
        guard note.isHidden else { return }
        note.isHidden = false
        restart.isHidden = false
        for (i, v) in [note, restart as NSView].enumerated() {
            v.wantsLayer = true
            Motion.enter(v.layer, dy: -6, duration: 0.32, delay: 0.04 * Double(i))
        }
    }

    // A shell waits for this process to exit, then `open -n` starts a fresh copy.
    // Unsaved grid changes still get their prompt in applicationShouldTerminate.
    @objc private func restartNow(_ sender: Any?) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = restartArguments(pid: ProcessInfo.processInfo.processIdentifier, bundlePath: Bundle.main.bundlePath)
        try? task.run()
        NSApp.terminate(nil)
    }
}
