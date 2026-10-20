// Frame colours: production always framed, old entries keep their meaning; recent files, tabs, the saved format.
@testable import PlainDBKit
import Foundation

@main enum StoreTest {
    static func frame(production: Bool, frame: String? = nil, color: String? = nil) -> String {
        var c = Connection(production: production, frame: frame)
        c.color = color
        return c.frameColor
    }

    static func main() {
        // older entries: "color" was set on every connection but only meant something for production
        check(frame(production: true, color: "#8b5cf6") == "#8b5cf6")
        check(frame(production: false, color: "#e0342b") == "")
        check(frame(production: true) == "#e0342b")
        // new entries: "frame"
        check(frame(production: false, frame: "#2ea043") == "#2ea043")
        check(frame(production: false, frame: "") == "")
        check(frame(production: true, frame: "") == "#e0342b") // never unframed
        check(frame(production: true, frame: "#0a84ff", color: "#e0342b") == "#0a84ff")

        // recent files: newest first, one entry per path, at most 20; updates keep their place
        let a = Connection(name: "a.db", path: "/a.db"), b = Connection(name: "b.db", path: "/b.db")
        var list = updatedRecentFiles([], with: a, top: true)
        list = updatedRecentFiles(list, with: b, top: true)
        check(list.map(\.path) == ["/b.db", "/a.db"])
        list = updatedRecentFiles(list, with: Connection(name: "a.db", path: "/a.db", frame: "#2ea043"), top: false)
        check(list.map(\.path) == ["/b.db", "/a.db"] && list[1].frame == "#2ea043")
        list = updatedRecentFiles(list, with: a, top: true)
        check(list.map(\.path) == ["/a.db", "/b.db"])
        for i in 0..<30 { list = updatedRecentFiles(list, with: Connection(path: "/\(i).db"), top: true) }
        check(list.count == 20 && list[0].path == "/29.db")
        let fresh = ConnectionStore.fileConnection(path: "/nowhere/shop.sqlite")
        check(fresh.kind == "sqlite" && fresh.name == "shop.sqlite" && fresh.database == "/nowhere/shop.sqlite")

        // tabs: identity per connection, saved tab lists
        check(Connection(kind: "sqlite", path: "/x/a.db").identity == "file:/x/a.db")
        check(Connection(id: "c1", database: "shop").identity == "c1/shop")
        // SQLite on a server is a saved connection (id, database = the path) that opens like a file
        check(Connection(kind: "sqlite").isSQLite && Connection(kind: "sqlite-ssh").isSQLite && !Connection(id: "c1").isSQLite)
        check(Connection(id: "c2", kind: "sqlite-ssh", database: "/srv/pb/data.db").identity == "c2//srv/pb/data.db")
        // the same table twice (e.g. the connection was opened twice) is saved once, the first place it appears
        let twice = [SavedTab(schema: "public", table: "claims", page: 0), SavedTab(schema: "public", table: "drivers", page: 1),
                     SavedTab(schema: "public", table: "claims", page: 2)]
        check(uniqueTabs(twice) == Array(twice.prefix(2)))

        // entries saved by the Objective-C app (plist dictionaries, keys missing or extra) still load
        let old: [[String: Any]] = [["id": "c1", "name": "shop-prod", "host": "db", "production": true, "color": "#8b5cf6"],
                                    ["kind": "sqlite", "path": "/a.db"]]
        let data = try! PropertyListSerialization.data(fromPropertyList: old, format: .xml, options: 0)
        let loaded = try! PropertyListDecoder().decode([Connection].self, from: data)
        check(loaded[0].name == "shop-prod" && loaded[0].production && loaded[0].frame == nil && loaded[0].frameColor == "#8b5cf6")
        check(loaded[1].isSQLite && loaded[1].port == "" && !loaded[1].production)
        print("store_test: OK")
    }
}
