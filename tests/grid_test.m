// GridView: swapping in a shorter result while rows are visible must not crash; change model and ⌫ handling.
#import "GridView.h"
#import "SQLText.h"
#import "UI.h"
#import <assert.h>

@interface GridView (Private)
- (void)setValue:(id)value row:(NSInteger)row column:(NSInteger)col;
- (void)beginEditingRow:(NSInteger)row column:(NSInteger)col;
- (void)activateRow:(NSInteger)row column:(NSInteger)col;
- (void)toggleDeletionFromRow:(NSInteger)row;
- (NSString *)deleteTitleForRow:(NSInteger)row;
@end

static NSTextField *Editor(GridView *grid) {
    for (NSView *v in grid.table.subviews)
        if ([v isKindOfClass:NSTextField.class]) return (NSTextField *)v;
    return nil;
}

// Ending an edit is asynchronous; under load (the whole `make test`) a fixed short wait wasn't always enough.
static void WaitForEditorToClose(GridView *grid) {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:2];
    while (Editor(grid) && limit.timeIntervalSinceNow > 0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
}

static DBResult *Result(NSArray *columns, NSUInteger rows) {
    NSMutableArray *data = [NSMutableArray new];
    for (NSUInteger r = 0; r < rows; r++) {
        NSMutableArray *row = [NSMutableArray new];
        for (NSUInteger c = 0; c < columns.count; c++) [row addObject:[NSString stringWithFormat:@"%lu", (unsigned long)r]];
        [data addObject:row];
    }
    DBResult *result = [DBResult new];
    result.columns = columns;
    result.rows = data;
    return result;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 600, 400)
                                                       styleMask:NSWindowStyleMaskTitled
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        GridView *grid = [[GridView alloc] initWithFrame:NSMakeRect(0, 0, 600, 400)];
        window.contentView = grid;

        // scroll bars stay classic (visible) even if the system asks for overlay ones
        grid.scrollerStyle = NSScrollerStyleOverlay;
        assert(grid.scrollerStyle == NSScrollerStyleLegacy && grid.hasHorizontalScroller);

        grid.result = Result(@[@"a", @"b"], 50);
        [window layoutIfNeeded];
        [grid displayIfNeeded];
        assert([grid.table rowViewAtRow:10 makeIfNecessary:NO] != nil); // rows really exist

        grid.result = Result(@[@"x", @"y", @"z"], 3); // used to crash here
        [window layoutIfNeeded];
        [grid displayIfNeeded];
        assert(grid.table.numberOfRows == 3 && grid.table.numberOfColumns == 4); // 3 data columns + row numbers

        // editing: changes are collected locally
        grid.editable = YES;
        [grid setValue:@"nowa" row:0 column:1];
        [grid setValue:@"1" row:1 column:0]; // same value as the original = no change
        assert(grid.changeCount == 1 && [grid.edits[@0][@1] isEqual:@"nowa"] && !grid.edits[@1]);

        // cell editing: a text field appears over the cell only while editing, Enter/focus change commits
        [grid beginEditingRow:2 column:0];
        assert(Editor(grid) && [Editor(grid).stringValue isEqual:@"2"]);
        Editor(grid).stringValue = @"typed";
        [window makeFirstResponder:grid.table]; // ends editing
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]; // the commit is async
        assert([grid.edits[@2][@0] isEqual:@"typed"] && !Editor(grid));
        [grid setValue:@"2" row:2 column:0]; // back to the original: no change

        // double-click / Enter: JSON opens the inspector, other values are edited in place
        __block NSInteger openedRow = -1;
        grid.onOpenJSON = ^(NSInteger row, NSInteger column) { openedRow = row; };
        [grid setValue:@"{\"a\": [1, 2]}" row:1 column:1];
        [grid activateRow:1 column:1];
        assert(openedRow == 1 && !Editor(grid));
        [grid activateRow:0 column:2];
        assert(Editor(grid));
        [window makeFirstResponder:grid.table];
        WaitForEditorToClose(grid);
        [grid setValue:@"1" row:1 column:1]; // back to the original

        // foreign key columns: editing opens the picker instead of a text field (only in editable grids)
        __block NSInteger pickedColumn = -1;
        grid.referenceColumns = [NSIndexSet indexSetWithIndex:2];
        grid.onPickReference = ^(NSInteger row, NSInteger column, NSRect rect) { pickedColumn = column; };
        [grid activateRow:0 column:2];
        assert(pickedColumn == 2 && !Editor(grid));
        grid.editable = NO;
        pickedColumn = -1;
        [grid activateRow:0 column:2];
        assert(pickedColumn == -1);
        grid.editable = YES;
        grid.referenceColumns = [NSIndexSet new];

        // boolean columns toggle t ↔ f instead of opening a text field; NULL toggles to true
        grid.columnKinds = @{@0: @"bool"};
        [grid setValue:@"t" row:2 column:0];
        [grid activateRow:2 column:0];
        assert([[grid valueAtRow:2 column:0] isEqual:@"f"] && !Editor(grid));
        [grid setValue:NSNull.null row:2 column:0];
        [grid activateRow:2 column:0];
        assert([[grid valueAtRow:2 column:0] isEqual:@"t"]);
        [grid setValue:@"2" row:2 column:0]; // back to the original
        grid.columnKinds = @{};

        // SQLite booleans: 1 / 0, read in either form
        grid.booleanTrue = @"1";
        grid.booleanFalse = @"0";
        grid.columnKinds = @{@0: @"bool"};
        [grid setValue:@"1" row:2 column:0];
        [grid activateRow:2 column:0];
        assert([[grid valueAtRow:2 column:0] isEqual:@"0"]);
        [grid setValue:@"t" row:2 column:0];
        [grid activateRow:2 column:0];
        assert([[grid valueAtRow:2 column:0] isEqual:@"0"]);
        [grid setValue:NSNull.null row:2 column:0];
        [grid activateRow:2 column:0];
        assert([[grid valueAtRow:2 column:0] isEqual:@"1"]);
        [grid setValue:@"2" row:2 column:0];
        grid.booleanTrue = @"t";
        grid.booleanFalse = @"f";

        // a date column whose value isn't a date (e.g. Unix seconds) is edited as text, not with the calendar
        __block BOOL pickedDate = NO;
        grid.onPickDate = ^(NSInteger row, NSInteger column, NSRect rect, NSString *kind) { pickedDate = YES; };
        grid.columnKinds = @{@0: @"timestamp"};
        [grid activateRow:2 column:0]; // value "2"
        assert(!pickedDate && Editor(grid));
        [window makeFirstResponder:grid.table];
        WaitForEditorToClose(grid);
        [grid setValue:@"2" row:2 column:0];
        grid.columnKinds = @{};
        grid.onPickDate = nil;

        // ⌫ in the table must reach GridView through the responder chain
        [grid.table selectRowIndexes:[NSIndexSet indexSetWithIndex:2] byExtendingSelection:NO];
        NSEvent *backspace = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
                                          windowNumber:window.windowNumber context:nil characters:@"\x7f"
                           charactersIgnoringModifiers:@"\x7f" isARepeat:NO keyCode:51];
        [grid.table keyDown:backspace];
        assert([grid.deletedRows containsIndex:2] && grid.changeCount == 2);
        [grid.table keyDown:backspace]; // second press restores
        assert(grid.deletedRows.count == 0);

        // right-click "Delete Row": the clicked row, or the whole selection when the click is inside it
        [grid.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        // (titles through LN: the test binary has no .lproj, so they come out as the keys)
        assert([[grid deleteTitleForRow:2] isEqual:LN(@"Delete %lu rows", 1)]);
        [grid toggleDeletionFromRow:2]; // outside the selection: only row 2
        assert([grid.deletedRows isEqual:[NSIndexSet indexSetWithIndex:2]]);
        assert([[grid deleteTitleForRow:2] isEqual:LN(@"Restore %lu rows", 1)]);
        [grid.table selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, 2)] byExtendingSelection:NO];
        assert([[grid deleteTitleForRow:1] isEqual:LN(@"Delete %lu rows", 2)]);
        [grid toggleDeletionFromRow:1]; // inside the selection: rows 0 and 1
        assert(grid.deletedRows.count == 3);
        [grid toggleDeletionFromRow:0]; // again: restores the selection, row 2 stays deleted
        assert([grid.deletedRows isEqual:[NSIndexSet indexSetWithIndex:2]]);
        [grid toggleDeletionFromRow:2];
        assert(grid.deletedRows.count == 0);

        [grid addRow];
        assert(grid.table.numberOfRows == 4 && grid.insertedRows.count == 1);
        [grid setValue:NSNull.null row:3 column:2];
        assert(grid.insertedRows[0][@2] == NSNull.null);
        [grid deleteSelectedRows]; // the new row is selected: it disappears entirely
        assert(grid.table.numberOfRows == 3 && grid.changeCount == 1);

        grid.result = Result(@[], 0); // a new result clears changes
        assert(grid.table.numberOfRows == 0 && grid.changeCount == 0);
        // copies stay on this Mac and are marked so clipboard managers don't keep them (a private pasteboard here)
        NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
        TBCopyLocally(board, @"anna.kowalska@example.com", nil);
        assert([[board stringForType:NSPasteboardTypeString] isEqual:@"anna.kowalska@example.com"]);
        assert([board.types containsObject:@"org.nspasteboard.ConcealedType"] && [board.types containsObject:@"org.nspasteboard.TransientType"]);
        NSImage *dot = [NSImage imageWithSize:NSMakeSize(2, 2) flipped:NO drawingHandler:^BOOL(NSRect r) { NSRectFill(r); return YES; }];
        TBCopyLocally(board, nil, dot);
        assert([board dataForType:NSPasteboardTypePNG].length && ![board stringForType:NSPasteboardTypeString]);
        assert([board.types containsObject:@"org.nspasteboard.ConcealedType"]);
        // the SQL editor and JSON text are the text view that copies through it
        NSTextView *sqlText = nil;
        SQLTextScrollView(&sqlText, YES, NO);
        assert([NSStringFromClass(sqlText.class) isEqual:@"LocalCopyTextView"]);
        [board releaseGlobally];
        puts("grid_test: OK");
    }
    return 0;
}
