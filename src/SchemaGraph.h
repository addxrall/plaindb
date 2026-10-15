#import <Foundation/Foundation.h>
#import "DBConnection.h"

NS_ASSUME_NONNULL_BEGIN

// The tables and foreign keys of a database, for the diagram. No AppKit: the layout is plain geometry.
@interface SchemaTable : NSObject
@property (nonatomic, copy) NSString *schema, *name;
@property (nonatomic, readonly) NSString *qualifiedName; // "schema.table"
@property (nonatomic, copy) NSArray<NSArray<NSString *> *> *columns; // [name, type, @"PK" or @""]
@property (nonatomic, copy) NSSet<NSString *> *foreignKeyColumns;
@property (nonatomic) NSRect frame; // set by SchemaLayout, moved by dragging
@end

// From the table holding the key to the table it references.
@interface SchemaEdge : NSObject
@property (nonatomic, weak) SchemaTable *from, *to;
@property (nonatomic, copy) NSString *column, *referencedColumn;
@property (nonatomic) BOOL many; // the column holds several references (PocketBase multi relation): drawn dashed
@end

@interface SchemaGraph : NSObject
// From the rows of allColumns: and allForeignKeys: (keys to tables that aren't in `columns` are left out).
+ (instancetype)graphWithColumns:(DBResult *)columns foreignKeys:(DBResult *)keys;
@property (nonatomic, readonly) NSArray<SchemaTable *> *tables;
@property (nonatomic, readonly) NSArray<SchemaEdge *> *edges;
- (nullable SchemaTable *)tableNamed:(NSString *)qualifiedName;
// The focus, the tables it references and the tables referencing it, as a new graph (its own tables and frames).
- (SchemaGraph *)neighboursOf:(SchemaTable *)focus;
@end

extern const NSUInteger SchemaMaxRows; // columns shown per box; more become a "+ N more" row
extern const CGFloat SchemaRowHeight, SchemaHeaderHeight, SchemaBoxWidth;

// Lays the tables out left to right: referenced tables before the tables pointing at them (a cycle or a
// self-reference is broken, not followed), each column ordered by where its connected tables are. `saved`
// ("schema.table" → NSValue point) fixes those tables' positions; the rest are placed around them without
// overlapping. With `focus` (neighbours mode): the focus in the middle, referenced tables left, referencing right.
void SchemaLayout(SchemaGraph *graph, SchemaTable *_Nullable focus, NSDictionary<NSString *, NSValue *> *saved);

NS_ASSUME_NONNULL_END
