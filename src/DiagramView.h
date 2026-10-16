#import <Cocoa/Cocoa.h>
#import "SchemaGraph.h"

NS_ASSUME_NONNULL_BEGIN

// Draws a laid-out SchemaGraph: boxes with columns, and foreign key arrows from the key column to the referenced
// table. Put it in a scroll view with magnification. A click selects a box (it and its arrows are highlighted), a
// drag moves it, a double-click asks for its neighbours; opening a table only goes through the box's menu.
// Dragging the background or dragging with the middle button pans; ⌘ + mouse wheel zooms around the cursor.
@interface DiagramView : NSView
@property (nonatomic, strong, nullable) SchemaGraph *graph;
@property (nonatomic, weak, nullable) SchemaTable *selected;
@property (nonatomic, copy, nullable) void (^onSelect)(SchemaTable *_Nullable table);
@property (nonatomic, copy, nullable) void (^onShowNeighbours)(SchemaTable *table);
@property (nonatomic, copy, nullable) void (^onOpen)(SchemaTable *table);
@property (nonatomic, copy, nullable) void (^onOpenInNewTab)(SchemaTable *table);
@property (nonatomic, copy, nullable) void (^onMoved)(SchemaTable *table); // after a drag ends
// Schema editing from the box menu; `column` is the row that was right-clicked (nil on the header).
@property (nonatomic, copy, nullable) void (^onAddColumn)(SchemaTable *table);
@property (nonatomic, copy, nullable) void (^onAddForeignKey)(SchemaTable *table, NSString *_Nullable column);
// When an item can't be used, why (shown as its tooltip); nil = enabled.
@property (nonatomic, copy, nullable) NSString *addColumnBlockedReason, *addForeignKeyBlockedReason;
// Grows or shrinks the view to the boxes (at least the visible area), e.g. after a new layout. Also done by itself
// after zooming and when the scroll view changes size.
- (void)fitToContent;
// The boxes plus a margin: what an export contains, whatever the zoom.
@property (nonatomic, readonly) NSRect contentRect;
@end

NS_ASSUME_NONNULL_END
