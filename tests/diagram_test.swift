// SchemaGraph and schemaLayout: who goes where on the diagram. `make test`.
@testable import PlainDBKit
import Foundation

@main enum DiagramTest {
    // tables: name → number of columns (the first is the PK "id"); keys: [table, column, referenced table]
    static func graph(_ tables: [String: Int], _ keys: [[String]]) -> SchemaGraph {
        var columns: [[DBValue]] = [], refs: [[DBValue]] = []
        for t in tables.keys.sorted() {
            columns.append(["public", .text(t), "id", "integer", "PK"])
            for i in 1..<max(tables[t]!, 1) { columns.append(["public", .text(t), .text("c\(i)"), "text", ""]) }
        }
        for k in keys {
            columns.append(["public", .text(k[0]), .text(k[1]), "integer", ""])
            refs.append(["public", .text(k[0]), .text(k[1]), "public", .text(k[2]), "id"])
        }
        return SchemaGraph(columns: DBResult(rows: columns), foreignKeys: DBResult(rows: refs))
    }

    static func frame(_ g: SchemaGraph, _ name: String) -> CGRect { g.table(named: "public." + name)!.frame }

    static func noOverlaps(_ g: SchemaGraph) -> Bool {
        g.tables.allSatisfy { a in g.tables.allSatisfy { b in a === b || !a.frame.intersects(b.frame) } }
    }

    static func main() {
        // parents (referenced) to the left of children; edges know their tables and columns
        let g = graph(["claims": 3, "drivers": 2, "vehicles": 2, "companies": 2],
                      [["claims", "driver_id", "drivers"], ["claims", "vehicle_id", "vehicles"], ["drivers", "company_id", "companies"]])
        check(g.tables.count == 4 && g.edges.count == 3)
        check(!g.edges[0].column.isEmpty && g.edges[0].referencedColumn == "id")
        check(g.table(named: "public.claims")!.foreignKeyColumns.contains("driver_id"))
        schemaLayout(g, focus: nil, saved: [:])
        check(frame(g, "companies").maxX < frame(g, "drivers").minX)
        check(frame(g, "drivers").maxX < frame(g, "claims").minX)
        check(frame(g, "vehicles").maxX < frame(g, "claims").minX)
        check(noOverlaps(g))

        // a cycle and a self-reference finish and don't overlap
        let cycle = graph(["a": 2, "b": 2, "employees": 2],
                          [["a", "b_id", "b"], ["b", "a_id", "a"], ["employees", "manager_id", "employees"]])
        schemaLayout(cycle, focus: nil, saved: [:])
        check(noOverlaps(cycle))

        // no tables at all; no foreign keys at all
        let empty = graph([:], [])
        schemaLayout(empty, focus: nil, saved: [:])
        check(empty.tables.isEmpty)
        let flat = graph(["a": 2, "b": 2, "c": 2, "d": 2, "e": 2, "f": 2, "g": 2], [])
        schemaLayout(flat, focus: nil, saved: [:])
        check(noOverlaps(flat))
        check(Set(flat.tables.map(\.frame.minX)).count > 1) // a grid, not one long column

        // 300 tables without keys: roughly square, not a 77 000 pt strip
        var many: [String: Int] = [:]
        for i in 0..<300 { many[String(format: "t%03d", i)] = 10 }
        let big = graph(many, [])
        schemaLayout(big, focus: nil, saved: [:])
        let all = big.tables.reduce(CGRect.null) { $0.union($1.frame) }
        check(noOverlaps(big) && all.height < 3 * all.width && all.width < 3 * all.height)

        // a 40-column table is capped: header, 20 rows and one "+ N more" row, then the 6 pt bottom padding
        let wide = graph(["wide": 40], [])
        schemaLayout(wide, focus: nil, saved: [:])
        check(frame(wide, "wide").height == schemaHeaderHeight + CGFloat(schemaMaxRows + 1) * schemaRowHeight + 6)
        check(frame(wide, "wide").width == 220)

        // saved positions win; a saved table that no longer exists is ignored; the others don't overlap them
        schemaLayout(g, focus: nil, saved: ["public.claims": CGPoint(x: 40, y: 40), "public.dropped": .zero])
        check(frame(g, "claims").origin == CGPoint(x: 40, y: 40))
        check(noOverlaps(g))

        // neighbours of drivers: companies (referenced) left, drivers in the middle, claims (referencing) right
        let n = g.neighbours(of: g.table(named: "public.drivers")!)
        check(n.tables.count == 3 && n.table(named: "public.vehicles") == nil)
        schemaLayout(n, focus: n.table(named: "public.drivers"), saved: [:])
        check(frame(n, "companies").maxX < frame(n, "drivers").minX)
        check(frame(n, "drivers").maxX < frame(n, "claims").minX)
        check(noOverlaps(n))
        // every column starts at the top margin, 34 pt between columns
        check(frame(n, "companies").minY == frame(n, "drivers").minY && frame(n, "drivers").minY == frame(n, "claims").minY)
        check(frame(n, "drivers").minY == 24 && frame(n, "drivers").minX - frame(n, "companies").maxX == 34)

        // a "many" relation (PocketBase multi relation) is an edge marked as such; rows without the column are plain keys
        let pb = SchemaGraph(columns: DBResult(rows: [["main", "posts", "id", "TEXT", "PK"], ["main", "posts", "tags", "JSON", ""],
                                                      ["main", "tags", "id", "TEXT", "PK"]]),
                             foreignKeys: DBResult(rows: [["main", "posts", "tags", "main", "tags", "id", "many"]]))
        check(pb.edges.count == 1 && pb.edges[0].many && !g.edges[0].many)
        print("diagram_test: OK")
    }
}
