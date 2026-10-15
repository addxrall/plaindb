#import "SchemaGraph.h"

const NSUInteger SchemaMaxRows = 20;
const CGFloat SchemaRowHeight = 20, SchemaHeaderHeight = 30, SchemaBoxWidth = 230;
static const CGFloat ColumnGap = 90, RowGap = 28, Margin = 40;

@implementation SchemaTable
- (NSString *)qualifiedName {
    return [NSString stringWithFormat:@"%@.%@", _schema, _name];
}
@end

@implementation SchemaEdge
@end

@implementation SchemaGraph {
    NSArray<SchemaTable *> *_tables;
    NSArray<SchemaEdge *> *_edges;
    NSDictionary<NSString *, SchemaTable *> *_byName;
}

- (instancetype)initWithTables:(NSArray<SchemaTable *> *)tables edges:(NSArray<SchemaEdge *> *)edges {
    if ((self = [super init])) {
        _tables = tables;
        _edges = edges;
        NSMutableDictionary *byName = [NSMutableDictionary new];
        for (SchemaTable *t in tables) byName[t.qualifiedName] = t;
        _byName = byName;
    }
    return self;
}

+ (instancetype)graphWithColumns:(DBResult *)columns foreignKeys:(DBResult *)keys {
    NSMutableArray<SchemaTable *> *tables = [NSMutableArray new];
    NSMutableDictionary<NSString *, NSMutableArray *> *columnsOf = [NSMutableDictionary new];
    for (NSArray *c in columns.rows) { // rows arrive grouped by table, in column order
        NSString *key = [NSString stringWithFormat:@"%@.%@", c[0], c[1]];
        if (!columnsOf[key]) {
            SchemaTable *t = [SchemaTable new];
            t.schema = c[0];
            t.name = c[1];
            [tables addObject:t];
            columnsOf[key] = [NSMutableArray new];
        }
        [columnsOf[key] addObject:@[c[2], c[3], c[4]]];
    }
    NSMutableDictionary<NSString *, NSMutableSet *> *keyColumns = [NSMutableDictionary new];
    NSMutableArray *edges = [NSMutableArray new];
    SchemaGraph *graph = [[self alloc] initWithTables:tables edges:@[]];
    for (NSArray *k in keys.rows) {
        SchemaTable *from = [graph tableNamed:[NSString stringWithFormat:@"%@.%@", k[0], k[1]]];
        SchemaTable *to = [graph tableNamed:[NSString stringWithFormat:@"%@.%@", k[3], k[4]]];
        if (!from || !to) continue;
        SchemaEdge *e = [SchemaEdge new];
        e.from = from;
        e.to = to;
        e.column = k[2];
        e.referencedColumn = k[5];
        e.many = k.count > 6 && [k[6] isEqual:@"many"];
        [edges addObject:e];
        if (!keyColumns[from.qualifiedName]) keyColumns[from.qualifiedName] = [NSMutableSet new];
        [keyColumns[from.qualifiedName] addObject:k[2]];
    }
    for (SchemaTable *t in tables) {
        t.columns = columnsOf[t.qualifiedName];
        t.foreignKeyColumns = keyColumns[t.qualifiedName] ?: [NSSet set];
    }
    return [[self alloc] initWithTables:tables edges:edges];
}

- (NSArray<SchemaTable *> *)tables {
    return _tables;
}

- (NSArray<SchemaEdge *> *)edges {
    return _edges;
}

- (SchemaTable *)tableNamed:(NSString *)qualifiedName {
    return _byName[qualifiedName];
}

- (SchemaGraph *)neighboursOf:(SchemaTable *)focus {
    NSMutableOrderedSet<SchemaTable *> *picked = [NSMutableOrderedSet orderedSetWithObject:focus];
    for (SchemaEdge *e in _edges) {
        if (e.from == focus) [picked addObject:e.to];
        if (e.to == focus) [picked addObject:e.from];
    }
    NSMutableDictionary<NSString *, SchemaTable *> *copies = [NSMutableDictionary new];
    for (SchemaTable *t in picked) {
        SchemaTable *c = [SchemaTable new];
        c.schema = t.schema;
        c.name = t.name;
        c.columns = t.columns;
        c.foreignKeyColumns = t.foreignKeyColumns;
        copies[t.qualifiedName] = c;
    }
    NSMutableArray *edges = [NSMutableArray new];
    for (SchemaEdge *e in _edges) {
        if (e.from != focus && e.to != focus) continue; // only the focus's own keys
        SchemaEdge *c = [SchemaEdge new];
        c.from = copies[e.from.qualifiedName];
        c.to = copies[e.to.qualifiedName];
        c.column = e.column;
        c.referencedColumn = e.referencedColumn;
        c.many = e.many;
        [edges addObject:c];
    }
    NSMutableArray *tables = [NSMutableArray new];
    for (SchemaTable *t in picked) [tables addObject:copies[t.qualifiedName]];
    return [[SchemaGraph alloc] initWithTables:tables edges:edges];
}

@end

static CGFloat BoxHeight(SchemaTable *t) {
    NSUInteger rows = MIN(t.columns.count, SchemaMaxRows) + (t.columns.count > SchemaMaxRows ? 1 : 0);
    return SchemaHeaderHeight + rows * SchemaRowHeight;
}

// 0 for tables referencing nothing, otherwise one more than the highest table they reference.
// A reference back to a table still being ranked (a cycle) or to itself is ignored.
static NSInteger Rank(SchemaTable *t, NSDictionary<NSString *, NSArray<SchemaTable *> *> *references,
                      NSMutableDictionary<NSString *, NSNumber *> *ranks, NSMutableSet<NSString *> *visiting) {
    NSNumber *known = ranks[t.qualifiedName];
    if (known) return known.integerValue;
    [visiting addObject:t.qualifiedName];
    NSInteger rank = 0;
    for (SchemaTable *parent in references[t.qualifiedName]) {
        if (parent == t || [visiting containsObject:parent.qualifiedName]) continue;
        rank = MAX(rank, Rank(parent, references, ranks, visiting) + 1);
    }
    [visiting removeObject:t.qualifiedName];
    ranks[t.qualifiedName] = @(rank);
    return rank;
}

void SchemaLayout(SchemaGraph *graph, SchemaTable *focus, NSDictionary<NSString *, NSValue *> *saved) {
    NSMutableDictionary<NSString *, NSMutableArray<SchemaTable *> *> *references = [NSMutableDictionary new], *connected = [NSMutableDictionary new];
    for (SchemaEdge *e in graph.edges) {
        if (!references[e.from.qualifiedName]) references[e.from.qualifiedName] = [NSMutableArray new];
        [references[e.from.qualifiedName] addObject:e.to];
        for (NSArray<SchemaTable *> *pair in @[@[e.from, e.to], @[e.to, e.from]]) {
            if (!connected[pair[0].qualifiedName]) connected[pair[0].qualifiedName] = [NSMutableArray new];
            [connected[pair[0].qualifiedName] addObject:pair[1]];
        }
    }

    // ranks → columns
    NSMutableDictionary<NSString *, NSNumber *> *ranks = [NSMutableDictionary new];
    for (SchemaTable *t in graph.tables) {
        if (!focus) Rank(t, references, ranks, [NSMutableSet new]);
        else if (t == focus) ranks[t.qualifiedName] = @1;
        else ranks[t.qualifiedName] = [references[t.qualifiedName] containsObject:focus] && ![references[focus.qualifiedName] containsObject:t] ? @2 : @0;
    }
    NSInteger maxRank = 0;
    for (NSNumber *r in ranks.allValues) maxRank = MAX(maxRank, r.integerValue);
    NSMutableArray<NSMutableArray<SchemaTable *> *> *columns = [NSMutableArray new];
    for (NSInteger i = 0; i <= maxRank; i++) [columns addObject:[NSMutableArray new]];
    for (SchemaTable *t in [graph.tables sortedArrayUsingComparator:^NSComparisonResult(SchemaTable *a, SchemaTable *b) {
             return [a.qualifiedName compare:b.qualifiedName];
         }])
        [columns[ranks[t.qualifiedName].integerValue] addObject:t];

    // order within a column by the mean position of connected tables in the neighbouring column; two sweeps
    for (NSInteger pass = 0; pass < 2; pass++) {
        BOOL forward = pass == 0;
        for (NSInteger c = forward ? 1 : maxRank - 1; forward ? c <= maxRank : c >= 0; c += forward ? 1 : -1) {
            NSArray<SchemaTable *> *next = columns[forward ? c - 1 : c + 1];
            NSMutableDictionary<NSString *, NSNumber *> *key = [NSMutableDictionary new];
            [columns[c] enumerateObjectsUsingBlock:^(SchemaTable *t, NSUInteger i, BOOL *stop) {
                double sum = 0, n = 0;
                for (SchemaTable *other in connected[t.qualifiedName]) {
                    NSUInteger at = [next indexOfObjectIdenticalTo:other];
                    if (at != NSNotFound) sum += at, n++;
                }
                key[t.qualifiedName] = @(n ? sum / n : (double)i); // unconnected tables keep their place
            }];
            [columns[c] sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(SchemaTable *a, SchemaTable *b) {
                return [key[a.qualifiedName] compare:key[b.qualifiedName]];
            }];
        }
    }

    // saved positions first, then each column top to bottom, stepping past anything already placed
    NSMutableArray<NSValue *> *placed = [NSMutableArray new];
    for (SchemaTable *t in graph.tables) {
        NSValue *at = focus ? nil : saved[t.qualifiedName];
        if (!at) continue;
        t.frame = NSMakeRect(at.pointValue.x, at.pointValue.y, SchemaBoxWidth, BoxHeight(t));
        [placed addObject:[NSValue valueWithRect:t.frame]];
    }
    CGFloat tallest = 0, area = 0;
    for (NSArray<SchemaTable *> *column in columns) {
        CGFloat height = 0;
        for (SchemaTable *t in column) {
            height += BoxHeight(t) + RowGap;
            area += (BoxHeight(t) + RowGap) * (SchemaBoxWidth + ColumnGap);
        }
        tallest = MAX(tallest, height);
    }
    // A column taller than this wraps into further sub-columns, so a database without keys (one rank) or with
    // many root tables comes out roughly square instead of as one long strip. Neighbours mode never wraps.
    CGFloat limit = focus ? CGFLOAT_MAX : MAX(300, sqrt(area));
    __block CGFloat x = Margin;
    [columns enumerateObjectsUsingBlock:^(NSMutableArray<SchemaTable *> *column, NSUInteger c, BOOL *stop) {
        CGFloat height = 0;
        for (SchemaTable *t in column) height += BoxHeight(t) + RowGap;
        CGFloat y = Margin + (focus ? (tallest - height) / 2 : 0); // neighbours mode: columns centred on each other
        BOOL started = NO;
        for (SchemaTable *t in column) {
            if (!focus && saved[t.qualifiedName]) continue;
            if (started && y + BoxHeight(t) > Margin + limit) { // next sub-column
                x += SchemaBoxWidth + ColumnGap;
                y = Margin;
            }
            started = YES;
            NSRect frame = NSMakeRect(x, y, SchemaBoxWidth, BoxHeight(t));
            for (BOOL moved = YES; moved;) {
                moved = NO;
                for (NSValue *other in placed)
                    if (NSIntersectsRect(NSInsetRect(frame, 0, -RowGap / 2), other.rectValue)) {
                        frame.origin.y = NSMaxY(other.rectValue) + RowGap;
                        moved = YES;
                    }
            }
            t.frame = frame;
            [placed addObject:[NSValue valueWithRect:frame]];
            y = NSMaxY(frame) + RowGap;
        }
        x += SchemaBoxWidth + ColumnGap; // the next rank starts right of this one's last sub-column
    }];
}
