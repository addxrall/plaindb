#import "ImageValue.h"
#import "DBConnection.h"
#import "FileRefs.h"
#import <PDFKit/PDFKit.h>
#import "UI.h"

// Magic numbers of the formats NSImage reads, as Postgres prints them in bytea hex output.
static NSArray<NSString *> *HexSignatures(void) {
    return @[@"\\x89504e470d0a1a0a", @"\\xffd8ff", @"\\x47494638", @"\\x49492a00", @"\\x4d4d002a"];
}

static NSArray<NSString *> *Base64Signatures(void) {
    return @[@"iVBORw0KGgo", @"/9j/", @"R0lGOD", @"UklGR"];
}

BOOL ImageValueDetected(id value) {
    if (![value isKindOfClass:NSString.class] || [value length] < 12) return NO;
    NSString *s = value;
    NSString *head = [s substringToIndex:MIN(s.length, 32)].lowercaseString;
    if ([head hasPrefix:@"data:image/"]) return YES;
    for (NSString *sig in HexSignatures())
        if ([head hasPrefix:sig]) return YES;
    if ([head hasPrefix:@"\\x52494646"] && s.length > 26 && [[s substringWithRange:NSMakeRange(18, 8)].lowercaseString isEqual:@"57454250"]) return YES; // RIFF…WEBP
    for (NSString *sig in Base64Signatures())
        if ([s hasPrefix:sig] && s.length > 64) return YES;
    if (([head hasPrefix:@"http://"] || [head hasPrefix:@"https://"]) && s.length < 2048 && ![s containsString:@" "]) {
        NSString *extension = [NSURL URLWithString:s].path.pathExtension.lowercaseString;
        return [@[@"png", @"jpg", @"jpeg", @"gif", @"webp", @"heic", @"tif", @"tiff", @"bmp", @"svg"] containsObject:extension ?: @""];
    }
    return NO;
}

static NSData *HexData(NSString *s) {
    NSUInteger n = (s.length - 2) / 2;
    NSMutableData *data = [NSMutableData dataWithLength:n];
    uint8_t *bytes = data.mutableBytes;
    const char *hex = [s substringFromIndex:2].UTF8String;
    for (NSUInteger i = 0; i < n; i++) {
        unsigned value;
        if (sscanf(hex + 2 * i, "%2x", &value) != 1) return nil;
        bytes[i] = value;
    }
    return data;
}

void ImageValueLoad(NSString *value, void (^done)(NSData *data, NSError *error)) {
    NSString *head = [value substringToIndex:MIN(value.length, 16)].lowercaseString;
    if ([head hasPrefix:@"http://"] || [head hasPrefix:@"https://"]) {
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 15;
        [[[NSURLSession sessionWithConfiguration:config] dataTaskWithURL:[NSURL URLWithString:value]
                                                       completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(error ? nil : data, error); });
        }] resume];
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSData *data = nil;
        if ([head hasPrefix:@"data:"]) data = [NSData dataWithContentsOfURL:[NSURL URLWithString:value]];
        else if ([head hasPrefix:@"\\x"]) data = HexData(value);
        else data = [[NSData alloc] initWithBase64EncodedString:value options:NSDataBase64DecodingIgnoreUnknownCharacters];
        dispatch_async(dispatch_get_main_queue(), ^{ done(data, data ? nil : DBError(L(@"Couldn't decode the image."), nil)); });
    });
}

// Backdrop for the picture: diagonal stripes in a rounded frame, so transparent areas read as such.
@interface StripedView : NSView
@end

@implementation StripedView
- (void)drawRect:(NSRect)rect {
    NSBezierPath *frame = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:4 yRadius:4];
    [NSGraphicsContext saveGraphicsState];
    [frame addClip];
    [Theme.fill setFill];
    CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
    for (CGFloat x = -h; x < w; x += 16 * M_SQRT2) { // 8 pt bands at 135°
        NSBezierPath *band = [NSBezierPath bezierPath];
        [band moveToPoint:NSMakePoint(x, 0)];
        [band lineToPoint:NSMakePoint(x + 8 * M_SQRT2, 0)];
        [band lineToPoint:NSMakePoint(x + 8 * M_SQRT2 + h, h)];
        [band lineToPoint:NSMakePoint(x + h, h)];
        [band fill];
    }
    [NSGraphicsContext restoreGraphicsState];
    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:3.5 yRadius:3.5];
    [NSColor.separatorColor setStroke];
    [border stroke];
}
@end

@implementation ImagePreview {
    NSString *_title, *_name; // _name: set for files, which can be saved
    void (^_loader)(void (^)(NSData *, NSError *));
    NSImageView *_imageView;
    NSTextField *_info;
    NSLayoutConstraint *_width, *_height;
    NSImage *_image;
    NSData *_data;
    NSProgressIndicator *_spinner;
    NSButton *_copy, *_save;
}

- (instancetype)initWithTitle:(NSString *)title value:(NSString *)value {
    return [self initWithTitle:title name:nil loader:^(void (^done)(NSData *, NSError *)) { ImageValueLoad(value, done); }];
}

- (instancetype)initWithTitle:(NSString *)title name:(NSString *)name loader:(void (^)(void (^)(NSData *, NSError *)))loader {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _title = title;
        _name = name;
        _loader = loader;
    }
    return self;
}

- (void)loadView {
    NSTextField *title = TBLabel(_title, 13, NSFontWeightSemibold, NSColor.labelColor);
    _info = TBLabel(L(@"Loading…"), 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    NSStackView *header = TBColumnInset(@[title, _info], nil, NSEdgeInsetsMake(12, 14, 8, 14));
    header.spacing = 1;

    _imageView = [NSImageView new];
    _imageView.imageScaling = NSImageScaleProportionallyDown;
    _spinner = TBSpinner(NSControlSizeRegular);
    NSView *stage = [NSView new];
    StripedView *backdrop = [StripedView new];
    TBPin(backdrop, stage, NSEdgeInsetsMake(10, 14, 10, 14));
    TBPin(_imageView, backdrop, NSEdgeInsetsMake(1, 1, 1, 1));
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [stage addSubview:_spinner];
    [NSLayoutConstraint activateConstraints:@[[_spinner.centerXAnchor constraintEqualToAnchor:stage.centerXAnchor],
                                              [_spinner.centerYAnchor constraintEqualToAnchor:stage.centerYAnchor]]];
    _width = [stage.widthAnchor constraintEqualToConstant:388];   // design: 388 × 384 pt popover
    _height = [stage.heightAnchor constraintEqualToConstant:291];
    _width.active = _height.active = YES;

    _copy = TBButton(L(@"Copy Image"), self, @selector(copyImage:));
    _copy.enabled = NO;
    _save = TBButton(L(@"Save As…"), self, @selector(saveFile:));
    _save.enabled = NO;
    _save.hidden = !_name;
    self.view = TBColumn(@[header, TBSeparator(), stage, TBSeparator(), TBBar(@[], @[_save, _copy], 40)], stage);
    [_spinner startAnimation:nil];

    __weak ImagePreview *weakSelf = self;
    _loader(^(NSData *data, NSError *error) { [weakSelf showData:data error:error]; });
}

- (void)showData:(NSData *)data error:(NSError *)error {
    [_spinner stopAnimation:nil];
    _data = data;
    _save.enabled = data != nil;
    NSString *size = [NSByteCountFormatter stringFromByteCount:data.length countStyle:NSByteCountFormatterCountStyleFile];
    PDFDocument *pdf = data && FileDataKind(data) == FileKindPDF ? [[PDFDocument alloc] initWithData:data] : nil;
    if (pdf) { // pages to scroll through, in the space the picture would take at most
        PDFView *pages = [PDFView new];
        pages.document = pdf;
        pages.autoScales = YES;
        pages.displayMode = kPDFDisplaySinglePageContinuous;
        pages.backgroundColor = NSColor.clearColor;
        TBPin(pages, _imageView.superview, NSEdgeInsetsMake(1, 1, 1, 1));
        _imageView.hidden = YES;
        _copy.hidden = YES;
        _info.stringValue = [NSString stringWithFormat:@"PDF · %@ · %@", LN(@"%lu pages", (NSUInteger)pdf.pageCount), size];
        _width.constant = 520 + 28;
        _height.constant = 400 + 20;
        return;
    }
    NSImage *image = data ? [[NSImage alloc] initWithData:data] : nil;
    if (!image && _name) _copy.hidden = YES; // a file that isn't a picture (or didn't load): nothing to copy as an image
    if (!image && data && _name) { // a file of another kind: it can still be saved
        _copy.hidden = YES;
        _info.stringValue = [NSString stringWithFormat:L(@"%@ · this kind of file can't be previewed"), size];
        return;
    }
    if (!image) { // the whole message, wrapped and selectable: it can hold a long path on the server
        _info.stringValue = error.localizedDescription ?: L(@"Couldn't decode the image.");
        _info.textColor = Theme.red;
        _info.lineBreakMode = NSLineBreakByCharWrapping;
        _info.maximumNumberOfLines = 0;
        _info.preferredMaxLayoutWidth = _width.constant - 28;
        _info.selectable = YES;
        return;
    }
    _image = image;
    _imageView.image = image;
    NSImageRep *rep = image.representations.firstObject;
    NSSize pixels = rep.pixelsWide > 0 ? NSMakeSize(rep.pixelsWide, rep.pixelsHigh) : image.size;
    NSString *bytes = [NSByteCountFormatter stringFromByteCount:data.length countStyle:NSByteCountFormatterCountStyleFile];
    _info.stringValue = [NSString stringWithFormat:@"%.0f × %.0f px · %@", pixels.width, pixels.height, bytes];
    // fit into 520 × 400, never upscaled; the frame is at least the design's 360 × 271
    CGFloat scale = MIN(1, MIN(520 / MAX(image.size.width, 1), 400 / MAX(image.size.height, 1)));
    _width.constant = MAX(image.size.width * scale + 2, 360) + 28;
    _height.constant = MAX(image.size.height * scale + 2, 271) + 20;
    _copy.enabled = YES;
}

// Saves the downloaded bytes where the user chooses (no temporary file on the way).
- (void)saveFile:(id)sender {
    NSData *data = _data;
    if (self.confirmsSave) {
        NSAlert *alert = [NSAlert new];
        alert.alertStyle = NSAlertStyleWarning;
        alert.messageText = [NSString stringWithFormat:L(@"Save %@ from the production database to this Mac?"), _name ?: @""];
        alert.informativeText = L(@"A copy on disk is outside the database's protection: Spotlight, backups and anyone with access to this Mac can see it.");
        [alert addButtonWithTitle:L(@"Save…")];
        [alert addButtonWithTitle:L(@"Cancel")];
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = _name ?: @"";
    [panel beginWithCompletionHandler:^(NSModalResponse response) {
        NSError *error = nil;
        if (response == NSModalResponseOK && ![data writeToURL:panel.URL options:NSDataWritingAtomic error:&error]) [NSApp presentError:error];
    }];
}

- (void)copyImage:(id)sender {
    TBCopyLocally(NSPasteboard.generalPasteboard, nil, _image);
}

@end
