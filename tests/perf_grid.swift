// Scroll performance of GridView on a "big table" page: `make perf`.
// Opens a real window (it shows up for a few seconds), loads 200 rows × 30 columns of realistic
// values (UUIDs, numbers, NULLs, multi-line text, 4 KB JSON) and scrolls step by step, timing each
// step including layout and Core Animation commit. Fails above the frame budget for 120 Hz.
// Timings depend on the machine, so this is not part of `make test`.
@testable import PlainDBKit
import AppKit
import QuartzCore

@main enum PerfGrid {
    static let budget = 8.3 // ms per frame at 120 Hz

    static func bigPage(rows: Int, columns: Int) -> DBResult {
        srand48(42)
        let json = String(repeating: "{\"key\": \"value\", \"n\": 12345}, ", count: 200).prefix(4000)
        let data: [[DBValue]] = (0..<rows).map { r in
            (0..<columns).map { c in
                switch c % 6 {
                case 0: .text(UUID().uuidString.lowercased())
                case 1: .integer(String(Int(drand48() * 100000)))
                case 2: .real(String(format: "%.2f", drand48() * 1000))
                case 3: drand48() < 0.3 ? .null : "2025-04-04 12:34:56+02"
                case 4: .text("Some longer text value number \(r)\nwith a second line")
                default: .text(String(json))
                }
            }
        }
        return DBResult(columns: (0..<columns).map { "column_\($0)" }, rows: data)
    }

    static func now() -> Double { CACurrentMediaTime() * 1000 }

    // CPU time used by the process so far (user + system), ms.
    static func cpu() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) * 1000 + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1000
    }

    // Memory as Activity Monitor shows it ("Memory" column), MB.
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return Double(info.phys_footprint) / 1048576
    }

    // Returns the average step time.
    static func report(_ name: String, _ times: [Double]) -> Double {
        let sorted = times.sorted(), average = times.reduce(0, +) / Double(times.count)
        let slow = times.filter { $0 > 2 * budget }.count
        print(String(format: "%@ %3d steps  avg %6.2f ms  p95 %6.2f ms  max %6.2f ms  dropped frames (>%.0f ms): %d",
                     name.padding(toLength: 11, withPad: " ", startingAt: 0), times.count, average, sorted[Int(Double(sorted.count) * 0.95)],
                     sorted.last!, 2 * budget, slow))
        return average
    }

    @MainActor static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        let grid = GridView(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        grid.onSort = { _, _ in }
        grid.onOpenImage = { _, _, _ in } // as in the app: every cell is checked for images
        window.contentView = grid
        window.orderFrontRegardless()
        let page = bigPage(rows: 200, columns: 30)
        let memoryBefore = footprint()

        let t0 = now()
        grid.result = page
        window.displayIfNeeded()
        CATransaction.flush()
        let load = now() - t0
        print(String(format: "load page  %.1f ms", load))

        var vertical: [Double] = [], horizontal: [Double] = []
        let clip = grid.contentView
        func step(_ p: NSPoint, _ times: inout [Double]) {
            let t = now()
            clip.scroll(to: p)
            grid.reflectScrolledClipView(clip)
            window.displayIfNeeded()
            CATransaction.flush()
            times.append(now() - t)
        }
        let cpu0 = cpu(), wall0 = now()
        for _ in 0..<2 {
            var y: CGFloat = 0
            while y < grid.table.frame.height - 600 { step(NSPoint(x: 0, y: y), &vertical); y += 40 }
            var x: CGFloat = 0
            while x < grid.table.frame.width - 1000 { step(NSPoint(x: x, y: 0), &horizontal); x += 60 }
        }
        let cpuUsed = cpu() - cpu0, wall = now() - wall0, steps = Double(vertical.count + horizontal.count)
        let v = report("vertical", vertical), h = report("horizontal", horizontal)
        print(String(format: "cpu        %.0f ms of CPU for %.0f steps (%.2f ms per step, %.0f%% of one core while scrolling)", cpuUsed, steps,
                     cpuUsed / steps, 100 * cpuUsed / wall))
        print(String(format: "memory     %.1f MB for the grid with a loaded page (process %.1f MB)", footprint() - memoryBefore, footprint()))
        let ok = v <= budget && h <= budget && load < 100
        print(String(format: "perf_grid: %@ (budget %.1f ms per step, 100 ms per page)", ok ? "OK" : "TOO SLOW", budget))
        exit(ok ? 0 : 1)
    }
}
