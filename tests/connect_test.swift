// The Connections and Settings windows' logic: what the form saves, frame colour choices, what the list and
// status show, profile completion, languages and the restart command. No server, Keychain or defaults needed.
@testable import PlainDBKit
import AppKit

@main enum ConnectTest {
    static func form(_ values: [FormField: String] = [:], sqlite: Bool = false, production: Bool = false, frame: String = "",
                     to original: Connection = Connection(id: "c1")) -> (connection: Connection, clearedDatabase: Bool) {
        applyForm(values, sqliteOverSSH: sqlite, production: production, frame: frame, to: original)
    }

    @MainActor static func main() {
        // a new connection: its own id, local defaults
        let a = newSavedConnection(), b = newSavedConnection()
        check(a.id != b.id && !a.id.isEmpty && a.host == "localhost" && a.port == "5432" && a.kind.isEmpty)

        // the form: values trimmed, the old "color" replaced by "frame", a name always set
        var old = Connection(id: "c1", name: "shop", host: "db")
        old.color = "#8b5cf6"
        let (saved, cleared) = form([.name: "  shop-prod \n", .host: " db.internal ", .port: "5433", .user: "app", .sshHost: "bastion",
                                     .s3Bucket: "files", .s3Region: "eu-west-1", .awsProfile: "prod"],
                                    production: true, frame: "#2ea043", to: old)
        check(!cleared && saved.id == "c1" && saved.name == "shop-prod" && saved.host == "db.internal" && saved.port == "5433")
        check(saved.user == "app" && saved.sshHost == "bastion" && saved.kind.isEmpty && saved.production)
        check(saved.s3Bucket == "files" && saved.s3Region == "eu-west-1" && saved.awsProfile == "prod")
        check(saved.frame == "#2ea043" && saved.color == nil && saved.frameColor == "#2ea043")
        check(form([.host: "db"]).connection.name == "db")
        check(form([.host: "  "]).connection.name == L("Untitled"))

        // SQLite over SSH: the path stands in for the database; switching back clears it, but not a real database
        let remote = form([.name: "pb", .sshHost: "srv", .path: "/pb/data.db", .database: "shop"], sqlite: true).connection
        check(remote.kind == "sqlite-ssh" && remote.database == "/pb/data.db" && remote.isSQLite)
        let back = form([.name: "pb", .sshHost: "srv", .path: "/pb/data.db", .database: "/pb/data.db"], to: remote)
        check(back.clearedDatabase && back.connection.database.isEmpty && back.connection.kind.isEmpty)
        let kept = form([.name: "pb", .path: "/pb/data.db", .database: "shop"], to: remote)
        check(!kept.clearedDatabase && kept.connection.database == "shop")
        // a Postgres connection whose database happens to equal its (unused) path keeps it
        check(!form([.database: "x", .path: "x"]).clearedDatabase)

        // validation and status
        check(connectProblem(Connection(kind: "sqlite-ssh", sshHost: "srv")) != nil)
        check(connectProblem(Connection(kind: "sqlite-ssh", path: "/a.db")) != nil)
        check(connectProblem(Connection(kind: "sqlite-ssh", sshHost: "srv", path: "/a.db")) == nil)
        check(connectProblem(Connection(id: "c1")) == nil) // Postgres needs nothing: the defaults are the local server
        check(connectingStatus(Connection(kind: "sqlite-ssh", sshHost: "srv")) == String(format: L("Connecting to %@…"), "srv"))
        check(connectingStatus(Connection(host: "db", sshHost: "bastion")) == String(format: L("Opening tunnel via %@…"), "bastion"))
        check(connectingStatus(Connection()) == String(format: L("Connecting to %@…"), "localhost"))

        // the list's second line
        check(connectionSubtitle(Connection()) == "localhost:5432")
        check(connectionSubtitle(Connection(host: "db", port: "6432")) == "db:6432")
        check(connectionSubtitle(Connection(host: "db", sshHost: "bastion")) == String(format: L("via %@"), "bastion"))
        check(connectionSubtitle(Connection(kind: "sqlite-ssh", sshHost: "srv", path: "/pb/pb_data/data.db"))
              == String(format: L("%@ via %@"), "data.db", "srv"))

        // frame colours: production is always framed (red by default); other colours go on the custom swatch
        check(frameColorChoices().count == 8 && frameColorChoices()[0].hex == "#e0342b")
        check(formFrameColor("", production: true) == "#e0342b" && formFrameColor("", production: false) == "")
        check(formFrameColor("#0a84ff", production: true) == "#0a84ff")
        check(isPresetFrameColor("") && isPresetFrameColor("#8b5cf6") && !isPresetFrameColor("#123456"))
        check(hexString(NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)) == "#ff8000")
        check(hexString(Theme.color(hex: "#14a5b8", fallback: .clear)) == "#14a5b8")
        check(hexString(NSColor(white: 1, alpha: 1)) == "#ffffff") // a grey colour space converts too

        // Local tab: the OS user on the local socket, with the database's own frame colour
        let local = localConnection(database: "shop", frame: "#2ea043")
        check(local.id == "local" && local.name == "shop" && local.database == "shop" && local.user == NSUserName())
        check(local.host.isEmpty && local.port.isEmpty && local.frameColor == "#2ea043" && local.identity == "local/shop")

        // recent files' second line
        check(fileDetail(path: "/tmp/x/a.db", exists: false, size: 0) == "\(L("File not found")) · /tmp/x")
        check(fileDetail(path: NSHomeDirectory() + "/db/a.db", exists: true, size: 2048).hasPrefix("~/db · "))

        // AWS profile completion: forward only, the first longer match
        let profiles = ["default", "prod", "prod-eu", "staging"]
        check(profileCompletion("pr", in: profiles) == "prod" && profileCompletion("prod-", in: profiles) == "prod-eu")
        check(profileCompletion("prod-eu", in: profiles) == nil && profileCompletion("", in: profiles) == nil)
        check(profileCompletion("x", in: profiles) == nil)

        // Settings: the language menu and the restart command
        check(settingsLanguages().map(\.code) == [nil, "en", "pl"])
        check(languageIndex(current: nil) == 0 && languageIndex(current: "pl") == 2 && languageIndex(current: "de") == 0)
        let args = restartArguments(pid: 42, bundlePath: "/Applications/Plain DB.app")
        check(args[0] == "-c" && args[1].contains("kill -0 42") && args[1].hasSuffix("open -n \"$0\"") && args[2] == "/Applications/Plain DB.app")

        print("connect_test: OK")
    }
}
