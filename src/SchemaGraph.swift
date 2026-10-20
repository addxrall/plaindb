import CoreGraphics
import Foundation

// The tables and foreign keys of a database, for the diagram. No AppKit: the layout is plain geometry.
final class SchemaTable {
    let schema, name: String
    var columns: [(name: String, type: String, key: String)] = [] // key: "PK" or ""
    var foreignKeyColumns: Set<String> = []
    var frame = CGRect.zero // set by schemaLayout, moved by dragging
    var qualifiedName: String { "\(schema).\(name)" }

    init(schema: String, name: String) {
        self.schema = schema
        self.name = name
    }
}

// From the table holding the key to the table it references.
struct SchemaEdge {
    let from, to: SchemaTable
    let column, referencedColumn: String
    let many: Bool // the column holds several references (PocketBase multi relation): drawn dashed
}

final class SchemaGraph {
    let tables: [SchemaTable]
    let edges: [SchemaEdge]
    private let byName: [String: SchemaTable]

    private init(tables: [SchemaTable], edges: [SchemaEdge]) {
        self.tables = tables
        self.edges = edges
        byName = Dictionary(tables.map { ($0.qualifiedName, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // From the rows of allColumns() and allForeignKeys() (keys to tables that aren't in `columns` are left out).
    convenience init(columns: DBResult, foreignKeys keys: DBResult) {
        var tables: [SchemaTable] = [], byName: [String: SchemaTable] = [:]
        for c in columns.rows { // rows arrive grouped by table, in column order
            let s = c.map { $0.string ?? "" }
            let key = "\(s[0]).\(s[1])"
            let t = byName[key] ?? {
                let t = SchemaTable(schema: s[0], name: s[1])
                tables.append(t)
                byName[key] = t
                return t
            }()
            t.columns.append((s[2], s[3], s[4]))
        }
        var edges: [SchemaEdge] = []
        for k in keys.rows {
            let s = k.map { $0.string ?? "" }
            guard let from = byName["\(s[0]).\(s[1])"], let to = byName["\(s[3]).\(s[4])"] else { continue }
            edges.append(SchemaEdge(from: from, to: to, column: s[2], referencedColumn: s[5], many: s.count > 6 && s[6] == "many"))
            from.foreignKeyColumns.insert(s[2])
        }
        self.init(tables: tables, edges: edges)
    }

    func table(named qualifiedName: String) -> SchemaTable? { byName[qualifiedName] }

    // The focus, the tables it references and the tables referencing it, as a new graph (its own tables and frames).
    func neighbours(of focus: SchemaTable) -> SchemaGraph {
        var picked = [focus]
        for e in edges {
            if e.from === focus, !picked.contains(where: { $0 === e.to }) { picked.append(e.to) }
            if e.to === focus, !picked.contains(where: { $0 === e.from }) { picked.append(e.from) }
        }
        var copies: [String: SchemaTable] = [:]
        for t in picked {
            let c = SchemaTable(schema: t.schema, name: t.name)
            c.columns = t.columns
            c.foreignKeyColumns = t.foreignKeyColumns
            copies[t.qualifiedName] = c
        }
        let edges = self.edges.filter { $0.from === focus || $0.to === focus }.map { // only the focus's own keys
            SchemaEdge(from: copies[$0.from.qualifiedName]!, to: copies[$0.to.qualifiedName]!, column: $0.column,
                       referencedColumn: $0.referencedColumn, many: $0.many)
        }
        return SchemaGraph(tables: picked.map { copies[$0.qualifiedName]! }, edges: edges)
    }
}

let schemaMaxRows = 20 // columns shown per box; more become a "+ N more" row
let schemaRowHeight: CGFloat = 20, schemaHeaderHeight: CGFloat = 30, schemaBoxWidth: CGFloat = 220
private let columnGap: CGFloat = 34, rowGap: CGFloat = 34, neighbourRowGap: CGFloat = 24, margin: CGFloat = 24, bottomPadding: CGFloat = 6

func schemaBoxHeight(_ t: SchemaTable) -> CGFloat {
    let rows = min(t.columns.count, schemaMaxRows) + (t.columns.count > schemaMaxRows ? 1 : 0)
    return schemaHeaderHeight + CGFloat(rows) * schemaRowHeight + bottomPadding
}

// 0 for tables referencing nothing, otherwise one more than the highest table they reference.
// A reference back to a table still being ranked (a cycle) or to itself is ignored.
private func rank(_ t: SchemaTable, _ references: [String: [SchemaTable]], _ ranks: inout [String: Int], _ visiting: inout Set<String>) -> Int {
    if let known = ranks[t.qualifiedName] { return known }
    visiting.insert(t.qualifiedName)
    var r = 0
    for parent in references[t.qualifiedName] ?? [] where parent !== t && !visiting.contains(parent.qualifiedName) {
        r = max(r, rank(parent, references, &ranks, &visiting) + 1)
    }
    visiting.remove(t.qualifiedName)
    ranks[t.qualifiedName] = r
    return r
}

// Lays the tables out left to right: referenced tables before the tables pointing at them (a cycle or a
// self-reference is broken, not followed), each column ordered by where its connected tables are. `saved`
// ("schema.table" → point) fixes those tables' positions; the rest are placed around them without overlapping.
// With `focus` (neighbours mode): the focus in the middle, referenced tables left, referencing right.
func schemaLayout(_ graph: SchemaGraph, focus: SchemaTable?, saved: [String: CGPoint]) {
    var references: [String: [SchemaTable]] = [:], connected: [String: [SchemaTable]] = [:]
    for e in graph.edges {
        references[e.from.qualifiedName, default: []].append(e.to)
        connected[e.from.qualifiedName, default: []].append(e.to)
        connected[e.to.qualifiedName, default: []].append(e.from)
    }

    // ranks → columns
    var ranks: [String: Int] = [:]
    for t in graph.tables {
        if let focus {
            let refersToFocus = references[t.qualifiedName]?.contains { $0 === focus } ?? false
            let focusRefers = references[focus.qualifiedName]?.contains { $0 === t } ?? false
            ranks[t.qualifiedName] = t === focus ? 1 : refersToFocus && !focusRefers ? 2 : 0
        } else {
            var visiting = Set<String>()
            _ = rank(t, references, &ranks, &visiting)
        }
    }
    let maxRank = ranks.values.max() ?? 0
    var columns = [[SchemaTable]](repeating: [], count: maxRank + 1)
    for t in graph.tables.sorted(by: { $0.qualifiedName < $1.qualifiedName }) { columns[ranks[t.qualifiedName]!].append(t) }

    // order within a column by the mean position of connected tables in the neighbouring column; two sweeps
    for forward in [true, false] {
        for c in forward ? Array(stride(from: 1, through: maxRank, by: 1)) : Array(stride(from: maxRank - 1, through: 0, by: -1)) {
            let next = columns[forward ? c - 1 : c + 1]
            var key: [String: Double] = [:]
            for (i, t) in columns[c].enumerated() {
                let at = (connected[t.qualifiedName] ?? []).compactMap { other in next.firstIndex { $0 === other } }
                key[t.qualifiedName] = at.isEmpty ? Double(i) : Double(at.reduce(0, +)) / Double(at.count) // unconnected keep their place
            }
            columns[c] = columns[c].enumerated().sorted { // stable
                let (a, b) = (key[$0.element.qualifiedName]!, key[$1.element.qualifiedName]!)
                return a != b ? a < b : $0.offset < $1.offset
            }.map(\.element)
        }
    }

    // saved positions first, then each column top to bottom, stepping past anything already placed
    var placed: [CGRect] = []
    for t in graph.tables {
        guard focus == nil, let at = saved[t.qualifiedName] else { continue }
        t.frame = CGRect(x: at.x, y: at.y, width: schemaBoxWidth, height: schemaBoxHeight(t))
        placed.append(t.frame)
    }
    let gap = focus == nil ? rowGap : neighbourRowGap
    let area = columns.joined().reduce(0) { $0 + (schemaBoxHeight($1) + gap) * (schemaBoxWidth + columnGap) }
    // A column taller than this wraps into further sub-columns, so a database without keys (one rank) or with
    // many root tables comes out roughly square instead of as one long strip. Neighbours mode never wraps.
    let limit = focus == nil ? max(300, area.squareRoot()) : .greatestFiniteMagnitude
    var x = margin
    for column in columns {
        var y = margin // every column starts at the top, neighbours mode too
        var started = false
        for t in column where focus != nil || saved[t.qualifiedName] == nil {
            if started && y + schemaBoxHeight(t) > margin + limit { // next sub-column
                x += schemaBoxWidth + columnGap
                y = margin
            }
            started = true
            var frame = CGRect(x: x, y: y, width: schemaBoxWidth, height: schemaBoxHeight(t))
            var moved = true
            while moved {
                moved = false
                for other in placed where frame.insetBy(dx: 0, dy: -gap / 2).intersects(other) {
                    frame.origin.y = other.maxY + gap
                    moved = true
                }
            }
            t.frame = frame
            placed.append(frame)
            y = frame.maxY + gap
        }
        x += schemaBoxWidth + columnGap // the next rank starts right of this one's last sub-column
    }
}
