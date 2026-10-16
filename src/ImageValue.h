#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// YES for values that look like an image: bytea (\x…) holding PNG/JPEG/GIF/WebP/TIFF, data:image/… URIs,
// base64 of those formats, or http(s) URLs ending in an image extension. Checks the start only, so it's cheap
// enough to call for every cell drawn.
BOOL ImageValueDetected(id _Nullable value);

// The image bytes behind such a value: decoded from hex / base64 / a data URI, or downloaded for URLs (on request
// only). `done` runs on the main thread.
void ImageValueLoad(NSString *value, void (^done)(NSData *_Nullable data, NSError *_Nullable error));

// Popover content: the image, scaled down to fit, with its type, size and dimensions, and Copy Image.
@interface ImagePreview : NSViewController
- (instancetype)initWithTitle:(NSString *)title value:(NSString *)value;
// A file fetched by `loader` (S3, PocketBase storage): an image as above, a PDF in a page view, anything else as
// its name and size; all with Save As…
- (instancetype)initWithTitle:(NSString *)title name:(nullable NSString *)name
                       loader:(void (^)(void (^done)(NSData *_Nullable data, NSError *_Nullable error)))loader;
// Production: Save As… asks first, since the file then leaves the database's protection for this Mac's disk.
@property (nonatomic) BOOL confirmsSave;
@end

NS_ASSUME_NONNULL_END
