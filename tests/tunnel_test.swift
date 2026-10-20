// SSHTunnel's status reaches every window sharing the tunnel (tabs), and new windows can read the current state.
@testable import PlainDBKit
import Foundation

@main enum TunnelTest {
    @MainActor static func main() {
        let tunnel = SSHTunnel(sshHost: "example", remoteHost: "localhost", remotePort: "5432")
        check(!tunnel.connected) // not started
        nonisolated(unsafe) var heard = 0
        nonisolated(unsafe) var last = true
        for _ in 0..<2 { // two windows
            NotificationCenter.default.addObserver(forName: SSHTunnel.statusNotification, object: tunnel, queue: nil) { n in
                heard += 1
                last = (n.object as! SSHTunnel).connected
            }
        }
        tunnel.report(false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        check(heard == 2 && !last && !tunnel.connected)
        tunnel.report(true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        check(heard == 4 && last && tunnel.connected)
        print("tunnel_test: OK")
    }
}
