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
@end

NS_ASSUME_NONNULL_END
