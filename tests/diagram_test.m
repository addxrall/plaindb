// SchemaGraph and SchemaLayout: who goes where on the diagram. `make test`.
#import "SchemaGraph.h"
#import <assert.h>

static DBResult *Rows(NSArray *rows) {
    DBResult *r = [DBResult new];
    r.columns = @[];
    r.rows = rows;
    return r;
}

// tables: name → number of columns (the first is the PK "id"); keys: @[table, column, referenced table]
static SchemaGraph *Graph(NSDictionary<NSString *, NSNumber *> *tables, NSArray<NSArray *> *keys) {
    NSMutableArray *columns = [NSMutableArray new], *refs = [NSMutableArray new];
    for (NSString *t in [tables.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [columns addObject:@[@"public", t, @"id", @"integer", @"PK"]];
        for (NSInteger i = 1; i < tables[t].integerValue; i++)
            [columns addObject:@[@"public", t, [NSString stringWithFormat:@"c%ld", (long)i], @"text", @""]];
    }
    for (NSArray *k in keys) {
        [columns addObject:@[@"public", k[0], k[1], @"integer", @""]];
        [refs addObject:@[@"public", k[0], k[1], @"public", k[2], @"id"]];
    }
    return [SchemaGraph graphWithColumns:Rows(columns) foreignKeys:Rows(refs)];
}

static NSRect Frame(SchemaGraph *g, NSString *name) {
    return [g tableNamed:[@"public." stringByAppendingString:name]].frame;
}

static BOOL NoOverlaps(SchemaGraph *g) {
    for (SchemaTable *a in g.tables)
        for (SchemaTable *b in g.tables)
            if (a != b && NSIntersectsRect(a.frame, b.frame)) return NO;
    return YES;
}

int main(void) {
    @autoreleasepool {
        // parents (referenced) to the left of children; edges know their tables and columns
        SchemaGraph *g = Graph(@{@"claims": @3, @"drivers": @2, @"vehicles": @2, @"companies": @2},
                               @[@[@"claims", @"driver_id", @"drivers"], @[@"claims", @"vehicle_id", @"vehicles"], @[@"drivers", @"company_id", @"companies"]]);
        assert(g.tables.count == 4 && g.edges.count == 3);
        SchemaEdge *e = g.edges[0];
        assert(e.from && e.to && e.column.length && [e.referencedColumn isEqual:@"id"]);
        assert([[g tableNamed:@"public.claims"].foreignKeyColumns containsObject:@"driver_id"]);
        SchemaLayout(g, nil, @{});
        assert(NSMaxX(Frame(g, @"companies")) < NSMinX(Frame(g, @"drivers")));
        assert(NSMaxX(Frame(g, @"drivers")) < NSMinX(Frame(g, @"claims")));
        assert(NSMaxX(Frame(g, @"vehicles")) < NSMinX(Frame(g, @"claims")));
        assert(NoOverlaps(g));

        // a cycle and a self-reference finish and don't overlap
        SchemaGraph *cycle = Graph(@{@"a": @2, @"b": @2, @"employees": @2},
                                   @[@[@"a", @"b_id", @"b"], @[@"b", @"a_id", @"a"], @[@"employees", @"manager_id", @"employees"]]);
        SchemaLayout(cycle, nil, @{});
        assert(NoOverlaps(cycle));

        // no tables at all; no foreign keys at all
        SchemaGraph *empty = Graph(@{}, @[]);
        SchemaLayout(empty, nil, @{});
        assert(empty.tables.count == 0);
        SchemaGraph *flat = Graph(@{@"a": @2, @"b": @2, @"c": @2, @"d": @2, @"e": @2, @"f": @2, @"g": @2}, @[]);
        SchemaLayout(flat, nil, @{});
        assert(NoOverlaps(flat));
        NSMutableSet *xs = [NSMutableSet new];
        for (SchemaTable *t in flat.tables) [xs addObject:@(NSMinX(t.frame))];
        assert(xs.count > 1); // a grid, not one long column

        // 300 tables without keys: roughly square, not a 77 000 pt strip
        NSMutableDictionary *many = [NSMutableDictionary new];
        for (int i = 0; i < 300; i++) many[[NSString stringWithFormat:@"t%03d", i]] = @10;
        SchemaGraph *big = Graph(many, @[]);
        SchemaLayout(big, nil, @{});
        NSRect all = NSZeroRect;
        for (SchemaTable *t in big.tables) all = NSUnionRect(all, t.frame);
        assert(NoOverlaps(big) && NSHeight(all) < 3 * NSWidth(all) && NSWidth(all) < 3 * NSHeight(all));

        // a 40-column table is capped: header, 20 rows and one "+ N more" row
        SchemaGraph *wide = Graph(@{@"wide": @40}, @[]);
        SchemaLayout(wide, nil, @{});
        assert(NSHeight(Frame(wide, @"wide")) == SchemaHeaderHeight + (SchemaMaxRows + 1) * SchemaRowHeight);

        // saved positions win; a saved table that no longer exists is ignored; the others don't overlap them
        SchemaLayout(g, nil, @{@"public.claims": [NSValue valueWithPoint:NSMakePoint(40, 40)],
                               @"public.dropped": [NSValue valueWithPoint:NSMakePoint(0, 0)]});
        assert(NSEqualPoints(Frame(g, @"claims").origin, NSMakePoint(40, 40)));
        assert(NoOverlaps(g));

        // neighbours of drivers: companies (referenced) left, drivers in the middle, claims (referencing) right
        SchemaGraph *n = [g neighboursOf:[g tableNamed:@"public.drivers"]];
        assert(n.tables.count == 3 && ![n tableNamed:@"public.vehicles"]);
        SchemaLayout(n, [n tableNamed:@"public.drivers"], @{});
        assert(NSMaxX(Frame(n, @"companies")) < NSMinX(Frame(n, @"drivers")));
        assert(NSMaxX(Frame(n, @"drivers")) < NSMinX(Frame(n, @"claims")));
        assert(NoOverlaps(n));
        // a "many" relation (PocketBase multi relation) is an edge marked as such; rows without the column are plain keys
        SchemaGraph *pb = [SchemaGraph graphWithColumns:Rows(@[@[@"main", @"posts", @"id", @"TEXT", @"PK"], @[@"main", @"posts", @"tags", @"JSON", @""],
                                                                @[@"main", @"tags", @"id", @"TEXT", @"PK"]])
                                            foreignKeys:Rows(@[@[@"main", @"posts", @"tags", @"main", @"tags", @"id", @"many"]])];
        assert(pb.edges.count == 1 && pb.edges[0].many && !g.edges[0].many);
        puts("diagram_test: OK");
    }
    return 0;
}
