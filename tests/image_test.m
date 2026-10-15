// Image detection (cheap, prefix-based) and decoding of the formats it accepts.
#import "ImageValue.h"
#import <assert.h>

static NSData *Decode(NSString *value) {
    __block NSData *result = nil;
    __block BOOL finished = NO;
    ImageValueLoad(value, ^(NSData *data, NSError *error) {
        result = data;
        finished = YES;
    });
    while (!finished) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    return result;
}

int main(void) {
    @autoreleasepool {
        // a real 1×1 PNG in the three encodings a database hands out
        NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1 pixelsHigh:1 bitsPerSample:8
                                                                   samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
                                                                       bytesPerRow:0 bitsPerPixel:0];
        NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        NSMutableString *hex = [NSMutableString stringWithString:@"\\x"];
        for (NSUInteger i = 0; i < png.length; i++) [hex appendFormat:@"%02x", ((const uint8_t *)png.bytes)[i]];
        NSString *base64 = [png base64EncodedStringWithOptions:0];
        NSString *dataURI = [@"data:image/png;base64," stringByAppendingString:base64];

        for (NSString *value in @[hex, base64, dataURI]) {
            assert(ImageValueDetected(value));
            assert([Decode(value) isEqual:png]);
        }
        assert(ImageValueDetected(@"https://example.com/photos/cat.JPG?size=large"));
        assert(ImageValueDetected(@"\\xffd8ffe000104a464946")); // JPEG bytea

        assert(!ImageValueDetected(@"\\x0011223344556677"));   // other bytea
        assert(!ImageValueDetected(@"https://example.com/index.html"));
        assert(!ImageValueDetected(@"hello world, this is plain text"));
        assert(!ImageValueDetected(NSNull.null) && !ImageValueDetected(nil));
        puts("image_test: OK");
    }
    return 0;
}
