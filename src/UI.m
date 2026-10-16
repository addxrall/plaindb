#import "UI.h"

static NSColor *RGBA(uint32_t c) {
    return [NSColor colorWithSRGBRed:((c >> 24) & 0xff) / 255.0 green:((c >> 16) & 0xff) / 255.0
                                blue:((c >> 8) & 0xff) / 255.0 alpha:(c & 0xff) / 255.0];
}

static NSColor *Dynamic(uint32_t light, uint32_t dark) {
    NSColor *l = RGBA(light), *d = RGBA(dark);
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        return [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua ? d : l;
    }];
}

@implementation Theme
+ (NSColor *)head { return Dynamic(0xf8f8faff, 0x252528ff); }
+ (NSColor *)side { return Dynamic(0xefeef1ff, 0x28282bff); }
+ (NSColor *)fill { return Dynamic(0x0000000e, 0xffffff14); }
+ (NSColor *)rowSelection { return Dynamic(0xe3edffff, 0x22344fff); }
+ (NSColor *)sideSelection { return Dynamic(0x00000014, 0xffffff1a); }
+ (NSColor *)grid { return Dynamic(0x0000000f, 0xffffff0f); }
+ (NSColor *)changed { return Dynamic(0xfff0a8ff, 0x5a4c12ff); }
+ (NSColor *)changedDot { return Dynamic(0xe0a800ff, 0xf5c400ff); }
+ (NSColor *)added { return Dynamic(0xdff4dfff, 0x1d3a24ff); }
+ (NSColor *)deleted { return Dynamic(0xfde2e0ff, 0x4a2324ff); }
+ (NSColor *)red { return Dynamic(0xd1242fff, 0xff5a52ff); }
+ (NSColor *)green { return Dynamic(0x2ea043ff, 0x32d74bff); }
+ (NSColor *)orange { return Dynamic(0xd97706ff, 0xff9f0aff); }
+ (NSColor *)productionBanner { return Dynamic(0xd5322bff, 0xb3261eff); }
+ (NSColor *)errorFill { return Dynamic(0xfff4f3ff, 0x3a2121ff); }
+ (NSColor *)errorBorder { return Dynamic(0xf2cbc7ff, 0x5c2f2dff); }
+ (NSColor *)editor { return Dynamic(0xfcfcfdff, 0x1a1a1cff); }
+ (NSColor *)findHighlight { return Dynamic(0xffe066ff, 0x8a7314ff); }
+ (NSColor *)sqlKeyword { return Dynamic(0xa8329eff, 0xff7ab8ff); }
+ (NSColor *)sqlString { return Dynamic(0xc4351bff, 0xff8170ff); }
+ (NSColor *)sqlNumber { return Dynamic(0x2e4bd6ff, 0xd9c97cff); }
+ (NSColor *)sqlFunction { return Dynamic(0x3a6f8fff, 0x6bdfffff); }
+ (NSColor *)sqlComment { return Dynamic(0x8a8a8eff, 0x7f8c98ff); }
+ (NSColor *)text2 { return Dynamic(0x6c6c72ff, 0xa0a0a6ff); }
+ (NSColor *)text3 { return Dynamic(0xa3a3a8ff, 0x6e6e74ff); }
+ (NSColor *)box { return Dynamic(0xffffffff, 0x232326ff); }

+ (NSFont *)mono:(CGFloat)size {
    return [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular];
}

+ (NSColor *)colorFromHex:(NSString *)hex fallback:(NSColor *)fallback {
    if (hex.length != 7 || ![hex hasPrefix:@"#"]) return fallback;
    unsigned value = 0;
    [[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexInt:&value];
    return RGBA(value << 8 | 0xff);
}
@end

void TBCopyLocally(NSPasteboard *pasteboard, NSString *text, NSImage *image) {
    NSPasteboardItem *item = [NSPasteboardItem new];
    if (text) [item setString:text forType:NSPasteboardTypeString];
    if (image) {
        NSData *tiff = image.TIFFRepresentation;
        [item setData:tiff forType:NSPasteboardTypeTIFF];
        [item setData:[[NSBitmapImageRep imageRepWithData:tiff] representationUsingType:NSBitmapImageFileTypePNG properties:@{}] forType:NSPasteboardTypePNG];
    }
    for (NSString *marker in @[@"org.nspasteboard.ConcealedType", @"org.nspasteboard.TransientType"]) [item setData:[NSData data] forType:marker];
    [pasteboard prepareForNewContentsWithOptions:NSPasteboardContentsCurrentHostOnly]; // also empties it
    [pasteboard writeObjects:@[item]];
}

NSTextField *TBLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = [NSFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return l;
}

NSTextField *TBWrappingLabel(NSString *text, CGFloat size, NSColor *color) {
    NSTextField *l = [NSTextField wrappingLabelWithString:text];
    l.font = [NSFont systemFontOfSize:size];
    l.textColor = color;
    l.selectable = YES;
    return l;
}

NSButton *TBButton(NSString *title, id target, SEL action) {
    NSButton *b = [NSButton buttonWithTitle:title target:target action:action];
    b.controlSize = NSControlSizeRegular;
    return b;
}

NSButton *TBSymbolButton(NSString *symbol, NSString *tip, id target, SEL action) {
    NSButton *b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip] target:target action:action];
    b.bezelStyle = NSBezelStyleTexturedRounded;
    b.toolTip = tip;
    return b;
}

@implementation TBToolButton
+ (instancetype)buttonWithSymbol:(NSString *)symbol tip:(NSString *)tip target:(id)target action:(SEL)action {
    TBToolButton *b = [self buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip] target:target action:action];
    b.bordered = NO;
    b.toolTip = tip;
    b.wantsLayer = YES;
    b.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium];
    [NSLayoutConstraint activateConstraints:@[[b.widthAnchor constraintEqualToConstant:26], [b.heightAnchor constraintEqualToConstant:22]]];
    b.on = NO;
    return b;
}

- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)setOn:(BOOL)on {
    _on = on;
    self.contentTintColor = on ? NSColor.whiteColor : NSColor.secondaryLabelColor;
    self.needsDisplay = YES;
}

- (void)updateLayer {
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.layer.cornerRadius = 5;
        self.layer.backgroundColor = (self->_on ? NSColor.controlAccentColor : Dynamic(0xffffffff, 0x3a3a3dff)).CGColor;
        self.layer.borderWidth = self->_on ? 0 : 0.5;
        self.layer.borderColor = Dynamic(0x00000029, 0xffffff0f).CGColor;
    }];
}
@end

NSBox *TBPanel(NSColor *fill) {
    NSBox *box = [NSBox new];
    box.boxType = NSBoxCustom;
    box.borderWidth = 0;
    box.cornerRadius = 0;
    box.contentViewMargins = NSZeroSize;
    box.fillColor = fill;
    box.titlePosition = NSNoTitle;
    return box;
}

NSBox *TBSeparator(void) {
    NSBox *line = [NSBox new];
    line.boxType = NSBoxSeparator;
    return line;
}

NSView *TBBadge(NSString *text, NSColor *textColor, NSColor *fill) {
    NSBox *box = TBPanel(fill);
    box.cornerRadius = 4;
    NSTextField *label = TBLabel(text, 10.5, NSFontWeightSemibold, textColor);
    TBPin(label, box.contentView, NSEdgeInsetsMake(1, 6, 1, 6));
    [box setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return box;
}

@implementation TBSwitcher {
    NSArray<NSView *> *_views;
}

- (instancetype)initWithViews:(NSArray<NSView *> *)views {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _views = views;
        for (NSView *v in views) TBPin(v, self, NSEdgeInsetsMake(0, 0, 0, 0));
        self.selectedIndex = 0;
    }
    return self;
}

- (void)setSelectedIndex:(NSInteger)index {
    _selectedIndex = index;
    [_views enumerateObjectsUsingBlock:^(NSView *v, NSUInteger i, BOOL *stop) { v.hidden = (NSInteger)i != index; }];
}
@end

@implementation TBFlippedView
- (BOOL)isFlipped {
    return YES;
}
@end

NSStackView *TBColumn(NSArray<NSView *> *views, NSView *grow) {
    return TBColumnInset(views, grow, NSEdgeInsetsMake(0, 0, 0, 0));
}

NSStackView *TBColumnInset(NSArray<NSView *> *views, NSView *grow, NSEdgeInsets insets) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.distribution = NSStackViewDistributionFill;
    s.spacing = 0;
    s.edgeInsets = insets;
    // Explicit widths: NSLayoutAttributeWidth alignment leaves views with an intrinsic width narrow.
    for (NSView *v in views) {
        [v.leadingAnchor constraintEqualToAnchor:s.leadingAnchor constant:insets.left].active = YES;
        [v.trailingAnchor constraintEqualToAnchor:s.trailingAnchor constant:-insets.right].active = YES;
        if (v != grow) [v setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationVertical];
    }
    [grow setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    return s;
}

NSStackView *TBBar(NSArray<NSView *> *leading, NSArray<NSView *> *trailing, CGFloat height) {
    NSStackView *s = [NSStackView new];
    s.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    s.spacing = 8;
    s.edgeInsets = NSEdgeInsetsMake(0, 12, 0, 12);
    for (NSView *v in leading) [s addView:v inGravity:NSStackViewGravityLeading];
    for (NSView *v in trailing) [s addView:v inGravity:NSStackViewGravityTrailing];
    [s.heightAnchor constraintEqualToConstant:height].active = YES;
    return s;
}

void TBPin(NSView *view, NSView *container, NSEdgeInsets insets) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.topAnchor constraintEqualToAnchor:container.topAnchor constant:insets.top],
        [view.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:insets.left],
        [view.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-insets.right],
        [view.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-insets.bottom],
    ]];
}

NSView *TBCenteredState(NSArray<NSView *> *views) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *container = [NSView new];
    [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [stack.widthAnchor constraintLessThanOrEqualToAnchor:container.widthAnchor constant:-80],
    ]];
    return container;
}

NSProgressIndicator *TBSpinner(NSControlSize size) {
    NSProgressIndicator *spinner = [NSProgressIndicator new];
    spinner.style = NSProgressIndicatorStyleSpinning;
    spinner.controlSize = size;
    spinner.displayedWhenStopped = NO;
    return spinner;
}

@implementation TBRowView
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    [(self.selectionColor ?: Theme.rowSelection) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, self.selectionInset, 0)
                                     xRadius:self.selectionRadius yRadius:self.selectionRadius] fill];
}
- (NSBackgroundStyle)interiorBackgroundStyle {
    return NSBackgroundStyleNormal;
}
@end

@implementation TBCellView
- (BOOL)wantsUpdateLayer {
    return YES;
}
- (void)updateLayer {
    self.layer.backgroundColor = self.fill.CGColor;
    self.layer.borderWidth = self.ring ? 2 : 0;
    self.layer.borderColor = NSColor.controlAccentColor.CGColor;
}
- (void)setFill:(NSColor *)fill {
    _fill = fill;
    self.needsDisplay = YES;
}
- (void)setRing:(BOOL)ring {
    _ring = ring;
    self.needsDisplay = YES;
}
@end

TBCellView *TBCell(NSTableView *table, NSString *identifier, BOOL withImage) {
    TBCellView *cell = [table makeViewWithIdentifier:identifier owner:nil];
    if (cell) return cell;
    cell = [TBCellView new];
    cell.identifier = identifier;
    cell.wantsLayer = YES;

    NSTextField *field = [NSTextField labelWithString:@""];
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [cell addSubview:field];
    cell.textField = field;

    NSLayoutXAxisAnchor *leading = cell.leadingAnchor;
    CGFloat inset = 8;
    if (withImage) {
        NSImageView *image = [NSImageView new];
        image.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:image];
        cell.imageView = image;
        [NSLayoutConstraint activateConstraints:@[
            [image.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:6],
            [image.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [image.widthAnchor constraintEqualToConstant:16],
        ]];
        leading = image.trailingAnchor;
        inset = 7;
    }
    [NSLayoutConstraint activateConstraints:@[
        [field.leadingAnchor constraintEqualToAnchor:leading constant:inset],
        [field.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],
        [field.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];
    return cell;
}
