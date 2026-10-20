// Image detection (cheap, prefix-based) and decoding of the formats it accepts.
@testable import PlainDBKit
import AppKit

@main enum ImageTest {
    @MainActor static func main() async throws {
        // a real 1×1 PNG in the three encodings a database hands out
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let hex = "\\x" + png.map { String(format: "%02x", $0) }.joined()
        let base64 = png.base64EncodedString()
        let dataURI = "data:image/png;base64," + base64

        for value in [hex, base64, dataURI] {
            check(isImageValue(.text(value)))
            check(try await loadImageValue(value) == png)
        }
        check(isImageValue(.blob(hex))) // SQLite BLOBs are shown as bytea hex
        check(isImageValue("https://example.com/photos/cat.JPG?size=large"))
        check(isImageValue("\\xffd8ffe000104a464946")) // JPEG bytea
        check(isImageValue("\\x52494646a4000000574542505650")) // RIFF…WEBP

        check(!isImageValue("\\x0011223344556677")) // other bytea
        check(!isImageValue("\\x52494646a4000000415649204c495354")) // RIFF…AVI
        check(!isImageValue("https://example.com/index.html"))
        check(!isImageValue("hello world, this is plain text"))
        check(!isImageValue(.null) && !isImageValue(nil))
        // broken hex is an error, not a picture
        check((try? await loadImageValue("\\x89504e47zz")) == nil)

        // the preview builds with a loader, and shows a failure as text
        let preview = ImagePreview(title: "photo", name: "photo.png") { throw DBError("No such file.") }
        _ = preview.view
        try await Task.sleep(nanoseconds: 50_000_000)
        func labels(_ view: NSView) -> [String] { ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(labels) }
        check(labels(preview.view).contains("No such file."))
        print("image_test: OK")
    }
}
