import Foundation

// Opens the connection `info` describes, through an SSH tunnel when it has one, in the background.
func connect(_ info: Connection, password: String) async throws -> (DBConnection, SSHTunnel?) {
    try await withCheckedThrowingContinuation { done in
        DispatchQueue.global(qos: .userInitiated).async {
            done.resume(with: Result { try openConnection(info, password: password) })
        }
    }
}

private func openConnection(_ info: Connection, password: String) throws -> (DBConnection, SSHTunnel?) {
    if info.isSQLite { // a local file, or one on a server through ssh: no tunnel, no password
        let conn = info.kind == "sqlite-ssh"
            ? SQLiteConnection(sshHost: info.sshHost, path: info.path, readOnly: info.production)
            : SQLiteConnection(path: info.path, readOnly: info.production)
        try conn.open()
        return (conn, nil)
    }
    var host = info.host, port = info.port.isEmpty ? "5432" : info.port
    var tunnel: SSHTunnel?
    if !info.sshHost.isEmpty {
        let t = SSHTunnel(sshHost: info.sshHost, remoteHost: host.isEmpty ? "localhost" : host, remotePort: port)
        try t.start()
        tunnel = t
        host = "127.0.0.1"
        port = String(t.localPort)
    }
    var params = ["port": port]
    if !host.isEmpty { params["host"] = host } // empty host = local socket
    if !info.user.isEmpty { params["user"] = info.user }
    if !password.isEmpty { params["password"] = password }
    if !info.database.isEmpty { params["dbname"] = info.database }
    let conn = PGConnection(params: params, readOnly: info.production)
    do {
        try conn.open()
    } catch {
        tunnel?.stop()
        throw error
    }
    return (conn, tunnel)
}
