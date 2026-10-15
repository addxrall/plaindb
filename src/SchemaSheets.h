#import <Cocoa/Cocoa.h>
#import "SchemaGraph.h"

NS_ASSUME_NONNULL_BEGIN

// Sheets for changing the schema from the diagram: "Add Column…" and "Add Foreign Key…". Both show the exact SQL
// as the fields change and only run it on "Run"; the owner executes it and reports back. A database error stays in
// the sheet; success closes it.
@interface SchemaSheet : NSWindowController
+ (instancetype)addColumnSheetFor:(SchemaTable *)table types:(NSArray<NSString *> *)types production:(BOOL)production;
// `column`: preselected (the row that was right-clicked), or nil for the table's first non-key column.
+ (instancetype)addForeignKeySheetFor:(SchemaTable *)table column:(nullable NSString *)column tables:(NSArray<SchemaTable *> *)tables
                           production:(BOOL)production;
@property (nonatomic, copy, nullable) void (^onRun)(NSString *sql, void (^done)(NSError *_Nullable error));
@property (nonatomic, readonly, nullable) NSString *sql; // the statement as it stands, nil while incomplete
- (void)beginSheetOnWindow:(NSWindow *)window;
@end

NS_ASSUME_NONNULL_END
