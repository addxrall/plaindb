#import "SchemaSheets.h"
#import "UI.h"

typedef NS_ENUM(NSInteger, SheetKind) { SheetAddColumn, SheetAddForeignKey };

@interface SchemaSheet () <NSTextFieldDelegate, NSComboBoxDelegate>
@end

@implementation SchemaSheet {
    SheetKind _kind;
    SchemaTable *_table;
    NSArray<SchemaTable *> *_tables;
    // Add Column
    NSTextField *_name, *_default;
    NSComboBox *_type;
    NSButton *_notNull;
    // Add Foreign Key
    NSPopUpButton *_column, *_refTable, *_refColumn, *_onDelete;
    // both
    NSTextField *_preview, *_error;
    NSButton *_run, *_cancel;
    NSProgressIndicator *_spinner;
}

+ (instancetype)addColumnSheetFor:(SchemaTable *)table types:(NSArray<NSString *> *)types production:(BOOL)production {
    SchemaSheet *sheet = [[self alloc] initWithKind:SheetAddColumn table:table];
    sheet->_name = [self field:@""];
    sheet->_type = [NSComboBox new];
    [sheet->_type addItemsWithObjectValues:types];
    sheet->_type.completes = YES;
    sheet->_type.delegate = sheet;
    sheet->_notNull = [NSButton checkboxWithTitle:@"NOT NULL" target:sheet action:@selector(changed:)];
    sheet->_default = [self field:L(@"none")];
    for (NSTextField *f in @[sheet->_name, sheet->_default]) f.delegate = sheet;
    [sheet buildWithTitle:[NSString stringWithFormat:L(@"Add a column to %@"), table.name] rows:@[
        @[L(@"Name:"), sheet->_name], @[L(@"Type:"), sheet->_type], @[@"", sheet->_notNull], @[L(@"Default:"), sheet->_default],
    ] production:production];
    return sheet;
}

+ (instancetype)addForeignKeySheetFor:(SchemaTable *)table column:(NSString *)column tables:(NSArray<SchemaTable *> *)tables production:(BOOL)production {
    SchemaSheet *sheet = [[self alloc] initWithKind:SheetAddForeignKey table:table];
    sheet->_tables = [tables sortedArrayUsingComparator:^NSComparisonResult(SchemaTable *a, SchemaTable *b) { return [a.qualifiedName compare:b.qualifiedName]; }];
    sheet->_column = [self popup:sheet];
    for (NSArray *c in table.columns) [sheet->_column addItemWithTitle:c[0]];
    NSString *preselect = column;
    if (!preselect) // the first column that isn't the primary key or already a key
        for (NSArray *c in table.columns)
            if (![c[2] isEqual:@"PK"] && ![table.foreignKeyColumns containsObject:c[0]]) { preselect = c[0]; break; }
    if (preselect) [sheet->_column selectItemWithTitle:preselect];
    sheet->_refTable = [self popup:sheet];
    for (SchemaTable *t in sheet->_tables) [sheet->_refTable addItemWithTitle:t.qualifiedName];
    sheet->_refColumn = [self popup:sheet];
    sheet->_onDelete = [self popup:sheet];
    [sheet->_onDelete addItemsWithTitles:@[L(@"No Action"), @"CASCADE", @"SET NULL"]];
    [sheet buildWithTitle:[NSString stringWithFormat:L(@"Add a foreign key to %@"), table.name] rows:@[
        @[L(@"Column:"), sheet->_column], @[L(@"References:"), sheet->_refTable], @[L(@"Referenced column:"), sheet->_refColumn],
        @[L(@"On delete:"), sheet->_onDelete],
    ] production:production];
    [sheet referencedTableChanged];
    return sheet;
}

+ (NSTextField *)field:(NSString *)placeholder {
    NSTextField *f = [NSTextField new];
    f.placeholderString = placeholder;
    f.font = [Theme mono:12];
    [f.widthAnchor constraintGreaterThanOrEqualToConstant:260].active = YES;
    return f;
}

+ (NSPopUpButton *)popup:(SchemaSheet *)target {
    NSPopUpButton *p = [NSPopUpButton new];
    p.target = target;
    p.action = @selector(changed:);
    [p.widthAnchor constraintGreaterThanOrEqualToConstant:260].active = YES;
    return p;
}

- (instancetype)initWithKind:(SheetKind)kind table:(SchemaTable *)table {
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        _kind = kind;
        _table = table;
    }
    return self;
}

- (void)buildWithTitle:(NSString *)title rows:(NSArray<NSArray *> *)rows production:(BOOL)production {
    NSTextField *heading = TBLabel(title, 13, NSFontWeightBold, NSColor.labelColor);
    NSMutableArray *gridRows = [NSMutableArray new];
    for (NSArray *r in rows) [gridRows addObject:@[[r[0] length] ? [NSTextField labelWithString:r[0]] : NSGridCell.emptyContentView, r[1]]];
    NSGridView *grid = [NSGridView gridViewWithViews:gridRows];
    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;
    grid.rowSpacing = 8;
    grid.columnSpacing = 8;

    NSTextField *sqlLabel = TBLabel(L(@"This SQL will run:"), 11, NSFontWeightSemibold, NSColor.secondaryLabelColor);
    _preview = TBWrappingLabel(@"", 12, NSColor.labelColor);
    _preview.font = [Theme mono:12];
    _preview.preferredMaxLayoutWidth = 420;
    NSBox *box = TBPanel(Theme.editor);
    box.cornerRadius = 6;
    box.borderWidth = 1;
    box.borderColor = NSColor.separatorColor;
    box.boxType = NSBoxCustom;
    TBPin(_preview, box.contentView, NSEdgeInsetsMake(8, 10, 8, 10));
    _error = TBWrappingLabel(@"", 12, Theme.red);
    _error.preferredMaxLayoutWidth = 420;
    _error.hidden = YES;
    NSTextField *note = TBWrappingLabel(L(@"Production: this changes the schema of the production database."), 12, Theme.red);
    note.preferredMaxLayoutWidth = 420;
    note.hidden = !production;

    _spinner = TBSpinner(NSControlSizeSmall);
    _cancel = TBButton(L(@"Cancel"), self, @selector(cancel:));
    _cancel.keyEquivalent = @"\e";
    _run = TBButton(L(@"Run"), self, @selector(run:));
    _run.keyEquivalent = @"\r";
    NSStackView *buttons = TBBar(@[_spinner], @[_cancel, _run], 28);
    buttons.edgeInsets = NSEdgeInsetsMake(0, 0, 0, 0);

    NSStackView *content = TBColumnInset(@[heading, grid, sqlLabel, box, _error, note, buttons], nil, NSEdgeInsetsMake(20, 20, 20, 20));
    content.spacing = 12;
    [content setCustomSpacing:4 afterView:sqlLabel];
    [content.widthAnchor constraintEqualToConstant:480].active = YES;
    self.window.contentView = content;
    [self changed:nil];
}

- (void)beginSheetOnWindow:(NSWindow *)window {
    [window beginSheet:self.window completionHandler:nil];
    [self.window makeFirstResponder:_kind == SheetAddColumn ? _name : _column];
}

#pragma mark - Fields

- (void)controlTextDidChange:(NSNotification *)notification {
    [self changed:nil];
}

- (void)comboBoxSelectionDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{ [self changed:nil]; }); // the combo's text updates after this call
}

- (void)changed:(id)sender {
    if (sender && sender == _refTable) [self referencedTableChanged]; // (both nil in the Add Column sheet)
    NSString *sql = self.sql;
    _preview.stringValue = sql ?: L(@"Fill in the fields above.");
    _preview.textColor = sql ? NSColor.labelColor : NSColor.tertiaryLabelColor;
    _run.enabled = sql != nil;
    _error.hidden = YES;
}

// The referenced table's columns, its primary key preselected.
- (void)referencedTableChanged {
    SchemaTable *ref = [self referencedTable];
    [_refColumn removeAllItems];
    for (NSArray *c in ref.columns) [_refColumn addItemWithTitle:c[0]];
    for (NSArray *c in ref.columns)
        if ([c[2] isEqual:@"PK"]) { [_refColumn selectItemWithTitle:c[0]]; break; }
    [self changed:nil];
}

- (SchemaTable *)referencedTable {
    NSInteger i = _refTable.indexOfSelectedItem;
    return i >= 0 && i < (NSInteger)_tables.count ? _tables[i] : nil;
}

- (NSString *)sql {
    NSCharacterSet *space = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    if (_kind == SheetAddColumn) {
        NSString *name = [_name.stringValue stringByTrimmingCharactersInSet:space], *type = [_type.stringValue stringByTrimmingCharactersInSet:space];
        if (!name.length || !type.length) return nil;
        return DBAddColumnStatement(_table.schema, _table.name, name, type, _notNull.state == NSControlStateValueOn,
                                    [_default.stringValue stringByTrimmingCharactersInSet:space]);
    }
    SchemaTable *ref = [self referencedTable];
    if (!_column.titleOfSelectedItem.length || !ref || !_refColumn.titleOfSelectedItem.length) return nil;
    NSString *onDelete = _onDelete.indexOfSelectedItem > 0 ? _onDelete.titleOfSelectedItem : @"";
    return DBAddForeignKeyStatement(_table.schema, _table.name, _column.titleOfSelectedItem, ref.schema, ref.name,
                                    _refColumn.titleOfSelectedItem, onDelete);
}

#pragma mark - Buttons

- (void)run:(id)sender {
    NSString *sql = self.sql;
    if (!sql || !self.onRun) return;
    _run.enabled = _cancel.enabled = NO;
    [_spinner startAnimation:nil];
    __weak SchemaSheet *weakSelf = self;
    self.onRun(sql, ^(NSError *error) {
        SchemaSheet *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf->_spinner stopAnimation:nil];
        strongSelf->_run.enabled = strongSelf->_cancel.enabled = YES;
        if (!error) return [strongSelf close:nil];
        strongSelf->_error.stringValue = error.localizedDescription ?: L(@"Unknown error");
        strongSelf->_error.hidden = NO;
    });
}

- (void)cancel:(id)sender {
    [self close:nil];
}

- (void)close:(id)sender {
    [self.window.sheetParent endSheet:self.window];
}

@end
