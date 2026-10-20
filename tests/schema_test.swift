// Schema editing statements, without a database. `make test`.
@testable import PlainDBKit
@main enum SchemaTest {
    static func main() {
        // ending with ";", a foreign key over several indented lines
        check(addColumnStatement(schema: "public", table: "claims", column: "note", type: "text", notNull: false, defaultExpr: nil)
                     == "ALTER TABLE \"public\".\"claims\" ADD COLUMN \"note\" text;")
        check(addColumnStatement(schema: "public", table: "claims", column: "paid", type: "boolean", notNull: true, defaultExpr: "false")
                     == "ALTER TABLE \"public\".\"claims\" ADD COLUMN \"paid\" boolean NOT NULL DEFAULT false;")
        check(addColumnStatement(schema: "main", table: "we\"ird", column: "a b", type: "INTEGER", notNull: false, defaultExpr: "")
                     == "ALTER TABLE \"main\".\"we\"\"ird\" ADD COLUMN \"a b\" INTEGER;") // empty default = none
        check(addForeignKeyStatement(schema: "public", table: "claims", column: "driver_id", refSchema: "public", refTable: "drivers",
                                            refColumn: "id", onDelete: "")
                     == "ALTER TABLE \"public\".\"claims\"\n  ADD CONSTRAINT \"claims_driver_id_fkey\" FOREIGN KEY (\"driver_id\")\n"
                        + "  REFERENCES \"public\".\"drivers\" (\"id\");")
        check(addForeignKeyStatement(schema: "public", table: "claims", column: "driver_id", refSchema: "crm", refTable: "drivers",
                                            refColumn: "id", onDelete: "CASCADE")
                     .hasSuffix("\n  REFERENCES \"crm\".\"drivers\" (\"id\")\n  ON DELETE CASCADE;"))
        check(addForeignKeyStatement(schema: "public", table: "claims", column: "driver_id", refSchema: "public", refTable: "drivers",
                                            refColumn: "id", onDelete: "SET NULL").hasSuffix("\n  ON DELETE SET NULL;"))
        // inlined params for the preview: quotes doubled, NULL bare
        check(inlineParams("SET a = $1, b = $2 WHERE id = $3", ["a'2", nil, "1"]) == "SET a = 'a''2', b = NULL WHERE id = '1'")
        print("schema_test: OK")
    }
}
