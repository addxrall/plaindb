// Frame colours: production always framed, old entries keep their meaning.
#import "ConnectionStore.h"
#import <assert.h>

static BOOL Frame(NSDictionary *connection, NSString *expected) {
    return [[ConnectionStore frameColorFor:connection] isEqual:expected];
}

int main(void) {
    @autoreleasepool {
        // older entries: "color" was set on every connection but only meant something for production
        assert(Frame(@{@"production": @YES, @"color": @"#8b5cf6"}, @"#8b5cf6"));
        assert(Frame(@{@"production": @NO, @"color": @"#e0342b"}, @""));
        assert(Frame(@{@"production": @YES}, @"#e0342b"));
        // new entries: "frame"
        assert(Frame(@{@"production": @NO, @"frame": @"#2ea043"}, @"#2ea043"));
        assert(Frame(@{@"production": @NO, @"frame": @""}, @""));
        assert(Frame(@{@"production": @YES, @"frame": @""}, @"#e0342b")); // never unframed
        assert(Frame(@{@"production": @YES, @"frame": @"#0a84ff", @"color": @"#e0342b"}, @"#0a84ff"));
        puts("store_test: OK");
    }
    return 0;
}
