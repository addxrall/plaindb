import Foundation
import Security

// A saved connection, a local database or an SQLite file. Stored as a plist dictionary with these keys; SQLite on a
// server adds kind "sqlite-ssh" and path (database is set to the path too). A local file is kind "sqlite".
struct Connection: Codable, Hashable, Sendable {
    var id = "", name = "", kind = "", host = "", port = "", user = "", database = "", sshHost = "", path = ""
    var production = false // read-only until a write is confirmed
    // Window frame colour "#rrggbb", "" for none; nil in entries saved before it existed (see frameColor).
    var frame: String?
    var color: String? // older entries: the production frame colour, superseded by "frame"
    var s3Bucket = "", s3Region = "", awsProfile = ""

    init(id: String = "", name: String = "", kind: String = "", host: String = "", port: String = "", user: String = "",
         database: String = "", sshHost: String = "", path: String = "", production: Bool = false, frame: String? = nil) {
        (self.id, self.name, self.kind, self.host, self.port, self.user) = (id, name, kind, host, port, user)
        (self.database, self.sshHost, self.path, self.production, self.frame) = (database, sshHost, path, production, frame)
    }

    // Missing keys keep their defaults: entries are saved by every older version of the app.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ key: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: key)) ?? "" }
        (id, name, kind, host, port, user, database, sshHost, path) = (s(.id), s(.name), s(.kind), s(.host), s(.port), s(.user),
                                                                       s(.database), s(.sshHost), s(.path))
        production = (try? c.decodeIfPresent(Bool.self, forKey: .production)) ?? false
        frame = try? c.decodeIfPresent(String.self, forKey: .frame)
        color = try? c.decodeIfPresent(String.self, forKey: .color)
        (s3Bucket, s3Region, awsProfile) = (s(.s3Bucket), s(.s3Region), s(.awsProfile))
    }

    var isSQLite: Bool { kind == "sqlite" || kind == "sqlite-ssh" }

    // Which connection a window belongs to ("file:<path>" or "<id>/<database>"), for tabs.
    var identity: String { kind == "sqlite" ? "file:" + path : "\(id)/\(database)" }

    // Window frame colour as "#rrggbb", or "" for none. Production connections always get one (red by default).
    // Older entries only had "color", which was meant for production connections only.
    var frameColor: String {
        let f = frame ?? (production ? color ?? "" : "")
        return f.isEmpty && production ? "#e0342b" : f
    }
}

// A saved tab: which table, and which page (Data / Structure / SQL / Diagram).
struct SavedTab: Equatable, Sendable {
    var schema, table: String
    var page: Int
}

// Pure list update for recent files: replaces the entry with the same path; `top` moves it to the front.
func updatedRecentFiles(_ list: [Connection], with file: Connection, top: Bool) -> [Connection] {
    var out = list
    if let at = out.firstIndex(where: { $0.path == file.path }), !top {
        out[at] = file
    } else {
        out.removeAll { $0.path == file.path }
        out.insert(file, at: 0)
    }
    return Array(out.prefix(20))
}

// One tab per table, where it first appears.
func uniqueTabs(_ tabs: [SavedTab]) -> [SavedTab] {
    var seen = Set<[String]>()
    return tabs.filter { seen.insert([$0.schema, $0.table]).inserted }
}

// Saved connections: a plist in ~/Library/Application Support/PlainDB, passwords in the Keychain.
// Data saved under the old name (Tabula) is read as a fallback and moved over on the next save.
enum ConnectionStore {
    private static let name = "PlainDB", oldName = "Tabula" // the app's previous name
    private static let recentFilesKey = "recentFiles", openTabsKey = "openTabs", localFramesKey = "localFrameColors"
    private static var defaults: UserDefaults { .standard }

    private static func fileURL(_ appName: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(appName)
        if appName == name { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        return dir.appendingPathComponent("connections.plist")
    }

    // Connections ↔ the plist objects they're kept as (also in UserDefaults).
    private static func plist(_ connections: [Connection]) -> Any {
        let encoder = PropertyListEncoder()
        guard let data = try? encoder.encode(connections) else { return [Any]() }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) ?? [Any]()
    }

    private static func connections(_ object: Any?) -> [Connection]? {
        guard let object, let data = try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0) else { return nil }
        return try? PropertyListDecoder().decode([Connection].self, from: data)
    }

    static func load() -> [Connection] {
        let saved = [name, oldName].lazy.compactMap { try? Data(contentsOf: fileURL($0)) }.first
        return saved.flatMap { try? PropertyListDecoder().decode([Connection].self, from: $0) } ?? []
    }

    static func save(_ connections: [Connection]) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try? encoder.encode(connections).write(to: fileURL(name), options: .atomic)
    }

    private static func keychainQuery(_ service: String, _ connectionId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: connectionId]
    }

    private static func readPassword(_ service: String, _ connectionId: String) -> String? {
        var q = keychainQuery(service, connectionId)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var data: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &data) == errSecSuccess, let data = data as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func password(for connectionId: String) -> String? {
        readPassword(name, connectionId) ?? readPassword(oldName, connectionId)
    }

    static func setPassword(_ password: String?, for connectionId: String) {
        SecItemDelete(keychainQuery(oldName, connectionId) as CFDictionary)
        let q = keychainQuery(name, connectionId)
        SecItemDelete(q as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    // Frame colours of databases opened from the Local tab, by database name.
    static func localFrameColor(for database: String) -> String {
        defaults.dictionary(forKey: localFramesKey)?[database] as? String ?? ""
    }

    static func setLocalFrameColor(_ hex: String, for database: String) {
        var all = defaults.dictionary(forKey: localFramesKey) ?? [:]
        all[database] = hex.isEmpty ? nil : hex
        defaults.set(all, forKey: localFramesKey)
    }

    // SQLite files (kind "sqlite", path, name, production = read-only, frame), newest first.
    static func recentFiles() -> [Connection] {
        connections(defaults.array(forKey: recentFilesKey)) ?? []
    }

    static func rememberFile(_ file: Connection, moveToTop top: Bool) {
        defaults.set(plist(updatedRecentFiles(recentFiles(), with: file, top: top)), forKey: recentFilesKey)
    }

    static func forgetFile(_ path: String) {
        defaults.set(plist(recentFiles().filter { $0.path != path }), forKey: recentFilesKey)
    }

    static func fileConnection(path: String) -> Connection {
        recentFiles().first { $0.path == path }
            ?? Connection(id: "file", name: (path as NSString).lastPathComponent, kind: "sqlite", database: path, path: path, frame: "")
    }

    // The tabs a connection had open last time, in tab order. Kept as [schema, table, page] arrays.
    static func savedTabs(for identity: String) -> [SavedTab] {
        let saved = defaults.dictionary(forKey: openTabsKey)?[identity] as? [[Any]] ?? []
        return saved.compactMap { t in
            guard t.count == 3, let schema = t[0] as? String, let table = t[1] as? String, let page = t[2] as? Int else { return nil }
            return SavedTab(schema: schema, table: table, page: page)
        }
    }

    static func saveTabs(_ tabs: [SavedTab], for identity: String) {
        var all = defaults.dictionary(forKey: openTabsKey) ?? [:]
        let unique = uniqueTabs(tabs)
        all[identity] = unique.isEmpty ? nil : unique.map { [$0.schema, $0.table, $0.page] as [Any] }
        defaults.set(all, forKey: openTabsKey)
    }
}
