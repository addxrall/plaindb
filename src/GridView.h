#import <Cocoa/Cocoa.h>
#import "DBConnection.h"

NS_ASSUME_NONNULL_BEGIN

// Grid showing a DBResult. Columns are built from the result, NULL is shown in grey italics,
// numeric columns are right-aligned. With `editable` it collects changes (cell edits, new and
// deleted rows) without sending them to the database.
@interface GridView : NSScrollView <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuItemValidation>
@property (nonatomic, readonly) NSTableView *table;
// Setting a result clears unsaved changes.
@property (nonatomic, strong, nullable) DBResult *result;
// When set, column headers are clickable and the caller does the sorting (e.g. ORDER BY in SQL).
@property (nonatomic, copy, nullable) void (^onSort)(NSString *column, BOOL ascending);
- (void)resetSort;

// Leading column with row numbers (on by default). Set before `result`.
@property (nonatomic) BOOL showsRowNumbers;
// Number shown for the first row minus one, e.g. the page offset.
@property (nonatomic) NSInteger rowNumberOffset;
// Text shown for SQL NULL (default "NULL").
@property (nonatomic, copy) NSString *nullText;
// Text colour per column index, for non-NULL values.
@property (nonatomic, copy) NSDictionary<NSNumber *, NSColor *> *columnColors;
// Search term marked in every cell where it occurs (ignoring case), or nil.
@property (nonatomic, copy, nullable) NSString *highlight;
// Whole cells marked like a search match: column index → values. For foreign keys whose referenced row matched.
@property (nonatomic, copy, nullable) NSDictionary<NSNumber *, NSSet<NSString *> *> *highlightedValues;

@property (nonatomic) BOOL editable;
// Columns with a default value: new rows show "DEFAULT" there instead of "NULL".
@property (nonatomic, copy) NSIndexSet *defaultColumns;
// Called whenever the set of unsaved changes changes.
@property (nonatomic, copy, nullable) void (^onChange)(void);

// row → (column → new value: NSString or NSNull)
@property (nonatomic, readonly) NSDictionary<NSNumber *, NSDictionary<NSNumber *, id> *> *edits;
@property (nonatomic, readonly) NSIndexSet *deletedRows;
// column → value; a missing column means DEFAULT
@property (nonatomic, readonly) NSArray<NSDictionary<NSNumber *, id> *> *insertedRows;
@property (nonatomic, readonly) NSUInteger changeCount;     // number of changed rows
@property (nonatomic, readonly) NSUInteger editedCellCount;

- (void)addRow;
- (void)deleteSelectedRows; // calling it again on deleted rows restores them
- (void)discardChanges;

// Columns with a foreign key. Their values get a ↗ that calls onOpenReference; editing them calls onPickReference
// (instead of a text field) so the caller can offer a search in the referenced table. Rects are in `table` coordinates.
@property (nonatomic, copy) NSIndexSet *referenceColumns;
@property (nonatomic, copy, nullable) void (^onOpenReference)(NSInteger row, NSInteger column, NSRect cellRect);
@property (nonatomic, copy, nullable) void (^onPickReference)(NSInteger row, NSInteger column, NSRect cellRect);

// Column index → TBValueKind (see DatePicker.h). Booleans show a checkbox that toggles (click on it, double-click,
// Enter); date/time columns call onPickDate instead of inline editing.
@property (nonatomic, copy) NSDictionary<NSNumber *, NSString *> *columnKinds;
@property (nonatomic, copy, nullable) void (^onPickDate)(NSInteger row, NSInteger column, NSRect cellRect, NSString *kind);

// Cells whose value looks like an image (see ImageValueDetected) get a 🖼 badge; it, double-click and Enter call this.
@property (nonatomic, copy, nullable) void (^onOpenImage)(NSInteger row, NSInteger column, NSRect cellRect);

// Double-click / Enter on a cell holding a JSON object or array calls this instead of inline editing.
@property (nonatomic, copy, nullable) void (^onOpenJSON)(NSInteger row, NSInteger column);
// Called when the user clicks a cell.
@property (nonatomic, copy, nullable) void (^onSelectCell)(NSInteger row, NSInteger column);
// Current value (NSString, NSNull, or nil for an unset column of a new row) and setting it as a pending edit.
- (nullable id)valueAtRow:(NSInteger)row column:(NSInteger)column;
- (void)updateValue:(id)value row:(NSInteger)row column:(NSInteger)column;
- (BOOL)isRowDeleted:(NSInteger)row;
@end

NS_ASSUME_NONNULL_END
