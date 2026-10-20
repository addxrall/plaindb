import Foundation

struct SQLSuggestion: Equatable {
    enum Kind { case column, table, function, keyword }
    var text: String   // what gets inserted
    var detail: String // a column's type and table, …
    var kind: Kind
}

private let keywords = ("select from where join left right inner outer full cross on as and or not in is null like ilike between exists "
    + "group by order asc desc limit offset having distinct union all case when then else end insert into values update "
    + "set delete returning with create table alter add column drop index primary key references default true false")
    .components(separatedBy: " ")

private let functions = ["count", "sum", "avg", "min", "max", "coalesce", "lower", "upper", "length", "concat", "now", "date_trunc",
                         "round", "cast", "substring", "trim", "replace", "json_extract"]

private let notAliases = Set(("where join left right inner outer full cross on group order limit set values using natural "
    + "union having select returning as").components(separatedBy: " "))

// tables of a statement, by name and by alias
private let sources = try! NSRegularExpression(
    pattern: "\\b(?:from|join|update|into)\\s+((?:\"[^\"]+\"|\\w+)(?:\\.(?:\"[^\"]+\"|\\w+))?)(?:\\s+(?:as\\s+)?(\"[^\"]+\"|\\w+))?",
    options: .caseInsensitive)

private func isWordChar(_ c: unichar) -> Bool {
    (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95 || c > 127
}

private func isDefaultSchema(_ schema: String) -> Bool { schema == "public" || schema == "main" }

private func unquote(_ s: String) -> String {
    s.count >= 2 && s.hasPrefix("\"") && s.hasSuffix("\"") ? String(s.dropFirst().dropLast()) : s
}

// "schema.table", "table" or quoted forms → the graph's table (a bare name prefers the default schema).
private func findTable(_ schema: SchemaGraph?, _ name: String) -> SchemaTable? {
    guard let schema else { return nil }
    let parts = name.components(separatedBy: ".")
    if parts.count == 2 { return schema.table(named: "\(unquote(parts[0])).\(unquote(parts[1]))") }
    let bare = unquote(name)
    var found: SchemaTable?
    for t in schema.tables where t.name.caseInsensitiveCompare(bare) == .orderedSame && (found == nil || isDefaultSchema(t.schema)) { found = t }
    return found
}

// Is `cursor` inside a string literal or a comment of `text` (scanning from `start`)?
private func inStringOrComment(_ text: NSString, _ start: Int, _ cursor: Int) -> Bool {
    var string = false, line = false, block = false
    var i = start
    while i < cursor {
        let c = text.character(at: i), next: unichar = i + 1 < text.length ? text.character(at: i + 1) : 0
        if line { if c == 10 { line = false } }
        else if block { if c == 42 && next == 47 { block = false; i += 1 } } // */
        else if string { if c == 39 { string = false } }
        else if c == 39 { string = true }
        else if c == 45 && next == 45 { line = true } // --
        else if c == 47 && next == 42 { block = true } // /*
        i += 1
    }
    return string || line || block
}

private func tableText(_ t: SchemaTable) -> String { isDefaultSchema(t.schema) ? t.name : t.qualifiedName }

// What the SQL editor offers at `cursor` (a UTF-16 offset, as NSTextView counts): tables after FROM / JOIN / UPDATE /
// INTO, a table's columns after "alias." or "table." (also with nothing typed yet), a schema's tables after
// "schema.", otherwise the columns of the current statement's tables, tables, functions and keywords. Nothing
// inside strings or comments, nothing when no word is being typed (except after a dot) unless `evenWithoutWord`
// (asked for with ⌃Space). `replace` is the range of the word being typed.
func sqlSuggestions(_ sql: String, cursor: Int, schema: SchemaGraph?, evenWithoutWord: Bool = false) -> (suggestions: [SQLSuggestion], replace: NSRange) {
    let ns = sql as NSString
    let cursor = min(cursor, ns.length)
    // the current statement: between the semicolons around the cursor
    let before = ns.range(of: ";", options: .backwards, range: NSRange(location: 0, length: cursor))
    let start = before.location == NSNotFound ? 0 : NSMaxRange(before)
    let after = ns.range(of: ";", options: [], range: NSRange(location: cursor, length: ns.length - cursor))
    let end = after.location == NSNotFound ? ns.length : after.location
    let statement = ns.substring(with: NSRange(location: start, length: end - start))

    // the word being typed, and "qualifier." in front of it
    var wordStart = cursor
    while wordStart > start && isWordChar(ns.character(at: wordStart - 1)) { wordStart -= 1 }
    let replace = NSRange(location: wordStart, length: cursor - wordStart)
    if inStringOrComment(ns, start, wordStart) { return ([], replace) }
    let prefix = ns.substring(with: replace)
    var qualifier: String?
    if wordStart > start && ns.character(at: wordStart - 1) == 46 { // .
        let q = wordStart - 1
        if q > start && ns.character(at: q - 1) == 34 { // "quoted".
            let open = ns.range(of: "\"", options: .backwards, range: NSRange(location: start, length: q - 1 - start))
            if open.location != NSNotFound { qualifier = ns.substring(with: NSRange(location: open.location + 1, length: q - 2 - open.location)) }
        } else {
            var qs = q
            while qs > start && isWordChar(ns.character(at: qs - 1)) { qs -= 1 }
            if qs < q { qualifier = ns.substring(with: NSRange(location: qs, length: q - qs)) }
        }
    }
    if qualifier == nil && prefix.isEmpty && !evenWithoutWord { return ([], replace) }

    let st = statement as NSString
    var aliases: [String: SchemaTable] = [:]
    var used: [SchemaTable] = []
    for m in sources.matches(in: statement, range: NSRange(location: 0, length: st.length)) {
        guard let t = findTable(schema, st.substring(with: m.range(at: 1))) else { continue }
        if !used.contains(where: { $0 === t }) { used.append(t) }
        aliases[t.name.lowercased()] = t
        if m.range(at: 2).location != NSNotFound {
            let alias = unquote(st.substring(with: m.range(at: 2)))
            if !notAliases.contains(alias.lowercased()) { aliases[alias.lowercased()] = t }
        }
    }

    let lowerPrefix = prefix.lowercased()
    func matches(_ candidate: String) -> Bool { prefix.isEmpty || candidate.lowercased().hasPrefix(lowerPrefix) }
    var out: [SQLSuggestion] = []

    if let qualifier { // alias. / table. → columns; schema. → tables
        if let t = aliases[unquote(qualifier).lowercased()] ?? findTable(schema, qualifier) {
            out = t.columns.filter { matches($0.name) }.map { SQLSuggestion(text: $0.name, detail: $0.type, kind: .column) }
        } else {
            out = (schema?.tables ?? []).filter { $0.schema.caseInsensitiveCompare(unquote(qualifier)) == .orderedSame && matches($0.name) }
                .map { SQLSuggestion(text: $0.name, detail: "", kind: .table) }
        }
        return (out, replace)
    }

    // the keyword right before the word decides between tables and everything else
    let head = ns.substring(with: NSRange(location: start, length: wordStart - start)).trimmingCharacters(in: .whitespacesAndNewlines)
    let previous = head.range(of: "[A-Za-z_]+$", options: .regularExpression).map { head[$0].lowercased() } ?? ""
    let tables = (schema?.tables ?? []).sorted { tableText($0) < tableText($1) }
    if ["from", "join", "update", "into", "table"].contains(previous) {
        return (tables.filter { matches($0.name) || matches(tableText($0)) }.map { SQLSuggestion(text: tableText($0), detail: "", kind: .table) }, replace)
    }

    var seen = Set<String>()
    for t in used {
        for c in t.columns where matches(c.name) && seen.insert(c.name).inserted {
            out.append(SQLSuggestion(text: c.name, detail: "\(c.type) · \(t.name)", kind: .column))
        }
    }
    out += tables.filter { matches($0.name) }.map { SQLSuggestion(text: tableText($0), detail: "", kind: .table) }
    let upper = prefix == prefix.uppercased() && prefix != prefix.lowercased()
    out += functions.filter(matches).map { SQLSuggestion(text: (upper ? $0.uppercased() : $0) + "(", detail: "", kind: .function) }
    out += keywords.filter { matches($0) && $0 != lowerPrefix }.map { SQLSuggestion(text: upper ? $0.uppercased() : $0, detail: "", kind: .keyword) }
    return (Array(out.prefix(60)), replace)
}
