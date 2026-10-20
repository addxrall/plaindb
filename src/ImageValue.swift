import AppKit
import PDFKit

// Magic numbers of the formats NSImage reads, as Postgres prints them in bytea hex output.
private let hexSignatures = ["\\x89504e470d0a1a0a", "\\xffd8ff", "\\x47494638", "\\x49492a00", "\\x4d4d002a"]
private let base64Signatures = ["iVBORw0KGgo", "/9j/", "R0lGOD", "UklGR"]
private let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "svg"]

// True for values that look like an image: bytea (\x…) holding PNG/JPEG/GIF/WebP/TIFF, data:image/… URIs,
// base64 of those formats, or http(s) URLs ending in an image extension. Checks the start only, so it's cheap
// enough to call for every cell drawn.
func isImageValue(_ value: DBValue?) -> Bool {
    guard let s = value?.string else { return false }
    let utf16 = s.utf16
    // the length only matters up to these limits, and counting a long string is not free
    func longer(than n: Int) -> Bool { utf16.dropFirst(n).first != nil }
    guard longer(than: 11) else { return false }
    let head = String(s.prefix(32)).lowercased()
    if head.hasPrefix("data:image/") { return true }
    if hexSignatures.contains(where: head.hasPrefix) { return true }
    if head.hasPrefix("\\x52494646"), longer(than: 26), String(s.dropFirst(18).prefix(8)).lowercased() == "57454250" { return true } // RIFF…WEBP
    if base64Signatures.contains(where: s.hasPrefix), longer(than: 64) { return true }
    if head.hasPrefix("http://") || head.hasPrefix("https://"), !longer(than: 2047), !s.contains(" ") {
        let ext = (URL(string: s)?.path as NSString?)?.pathExtension.lowercased() ?? ""
        return imageExtensions.contains(ext)
    }
    return false
}

private func hexData(_ s: String) -> Data? {
    let hex = Array(s.utf8.dropFirst(2))
    func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30...0x39: c - 0x30
        case 0x61...0x66: c - 0x61 + 10
        case 0x41...0x46: c - 0x41 + 10
        default: nil
        }
    }
    var data = Data(capacity: hex.count / 2)
    var i = 0
    while i + 1 < hex.count {
        guard let hi = nibble(hex[i]), let lo = nibble(hex[i + 1]) else { return nil }
        data.append(hi << 4 | lo)
        i += 2
    }
    return data
}

// The image bytes behind such a value: decoded from hex / base64 / a data URI, or downloaded for URLs (on request
// only).
func loadImageValue(_ value: String) async throws -> Data {
    let head = String(value.prefix(16)).lowercased()
    if head.hasPrefix("http://") || head.hasPrefix("https://") {
        guard let url = URL(string: value) else { throw DBError(L("Couldn't decode the image.")) }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        return try await URLSession(configuration: config).data(from: url).0
    }
    let data: Data? = await Task.detached(priority: .userInitiated) {
        if head.hasPrefix("data:") { return URL(string: value).flatMap { try? Data(contentsOf: $0) } }
        if head.hasPrefix("\\x") { return hexData(value) }
        return Data(base64Encoded: value, options: .ignoreUnknownCharacters)
    }.value
    guard let data else { throw DBError(L("Couldn't decode the image.")) }
    return data
}

// Backdrop for the picture: diagonal stripes in a rounded frame, so transparent areas read as such.
private final class StripedView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        Theme.fill.setFill()
        let (w, h) = (bounds.width, bounds.height), band = 8 * 2.squareRoot()
        var x = -h
        while x < w { // 8 pt bands at 135°
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: 0))
            p.line(to: NSPoint(x: x + band, y: 0))
            p.line(to: NSPoint(x: x + band + h, y: h))
            p.line(to: NSPoint(x: x + h, y: h))
            p.fill()
            x += 2 * band
        }
        NSGraphicsContext.restoreGraphicsState()
        Theme.boxB.setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5).stroke()
    }
}

// Popover content: the image, scaled down to fit, with its type, size and dimensions, and Copy Image.
final class ImagePreview: NSViewController {
    // Production: Save As… asks first, since the file then leaves the database's protection for this Mac's disk.
    var confirmsSave = false
    private let titleText: String
    private let name: String? // set for files, which can be saved
    private let loader: @MainActor () async throws -> Data
    private let imageView = NSImageView()
    private let info = label(L("Loading…"), 11, .regular, Theme.t2)
    private var width: NSLayoutConstraint!, height: NSLayoutConstraint!
    private var image: NSImage?
    private var data: Data?
    private let progress = spinner(.regular)
    private var copyButton: PillButton!, saveButton: PillButton!

    convenience init(title: String, value: String) {
        self.init(title: title, name: nil) { try await loadImageValue(value) }
    }

    // A file fetched by `loader` (S3, PocketBase storage): an image as above, a PDF in a page view, anything else as
    // its name and size; all with Save As…
    init(title: String, name: String?, loader: @escaping @MainActor () async throws -> Data) {
        (titleText, self.name, self.loader) = (title, name, loader)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = label(titleText, 13, .semibold)
        let header = column([title, info], insets: NSEdgeInsets(top: 12, left: 14, bottom: 8, right: 14), spacing: 1)

        imageView.imageScaling = .scaleProportionallyDown
        let stage = NSView()
        let backdrop = StripedView()
        pin(backdrop, stage, NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14))
        pin(imageView, backdrop, NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
        progress.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(progress)
        width = stage.widthAnchor.constraint(equalToConstant: 388)
        height = stage.heightAnchor.constraint(equalToConstant: 291)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: stage.centerXAnchor), progress.centerYAnchor.constraint(equalTo: stage.centerYAnchor),
            width, height,
        ])

        copyButton = PillButton(L("Copy Image"), target: self, action: #selector(copyImage(_:)))
        copyButton.isEnabled = false
        saveButton = PillButton(L("Save As…"), target: self, action: #selector(saveFile(_:)))
        saveButton.isEnabled = false
        saveButton.isHidden = name == nil
        view = column([header, separator(), stage, separator(), bar([], [saveButton, copyButton], height: 40)], grow: stage)
        progress.startAnimation(nil)

        Task { @MainActor [weak self, loader] in
            do {
                let data = try await loader()
                self?.show(data, error: nil)
            } catch {
                self?.show(nil, error: error)
            }
        }
    }

    private func show(_ data: Data?, error: Error?) {
        progress.stopAnimation(nil)
        self.data = data
        saveButton.isEnabled = data != nil
        let size = ByteCountFormatter.string(fromByteCount: Int64(data?.count ?? 0), countStyle: .file)
        if let data, fileKind(data) == .pdf, let pdf = PDFDocument(data: data) { // pages to scroll through, in the space the picture would take at most
            let pages = PDFView()
            pages.document = pdf
            pages.autoScales = true
            pages.displayMode = .singlePageContinuous
            pages.backgroundColor = .clear
            pin(pages, imageView.superview!, NSEdgeInsets(top: 1, left: 1, bottom: 1, right: 1))
            imageView.isHidden = true
            copyButton.isHidden = true
            info.stringValue = "PDF · \(LN("%lu pages", pdf.pageCount)) · \(size)"
            width.constant = 520 + 28
            height.constant = 400 + 20
            return
        }
        guard let data, let image = NSImage(data: data) else {
            if name != nil { copyButton.isHidden = true } // a file that isn't a picture (or didn't load): nothing to copy as an image
            if data != nil && name != nil { // a file of another kind: it can still be saved
                info.stringValue = String(format: L("%@ · this kind of file can't be previewed"), size)
                return
            }
            // the whole message, wrapped and selectable: it can hold a long path on the server
            info.stringValue = error?.localizedDescription ?? L("Couldn't decode the image.")
            info.textColor = Theme.red
            info.lineBreakMode = .byCharWrapping
            info.maximumNumberOfLines = 0
            info.preferredMaxLayoutWidth = width.constant - 28
            info.isSelectable = true
            return
        }
        self.image = image
        imageView.image = image
        let rep = image.representations.first
        let pixels = (rep?.pixelsWide ?? 0) > 0 ? NSSize(width: rep!.pixelsWide, height: rep!.pixelsHigh) : image.size
        info.stringValue = String(format: "%.0f × %.0f px · %@", pixels.width, pixels.height, size)
        let scale = min(1, min(520 / max(image.size.width, 1), 400 / max(image.size.height, 1)))
        width.constant = max(image.size.width * scale + 2, 360) + 28
        height.constant = max(image.size.height * scale + 2, 271) + 20
        copyButton.isEnabled = true
    }

    // Saves the downloaded bytes where the user chooses (no temporary file on the way).
    @objc private func saveFile(_ sender: Any?) {
        guard let data else { return }
        if confirmsSave {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(format: L("Save %@ from the production database to this Mac?"), name ?? "")
            alert.informativeText = L("A copy on disk is outside the database's protection: Spotlight, backups and anyone with access to this Mac can see it.")
            alert.addButton(withTitle: L("Save…"))
            alert.addButton(withTitle: L("Cancel"))
            if alert.runModal() != .alertFirstButtonReturn { return }
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name ?? ""
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try data.write(to: url, options: .atomic) } catch { NSApp.presentError(error) }
        }
    }

    @objc private func copyImage(_ sender: Any?) {
        copyLocally(.general, text: nil, image: image)
    }
}
