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
        // recent files: newest first, one entry per path, at most 20; updates keep their place
        NSDictionary *a = @{@"path": @"/a.db", @"name": @"a.db"}, *b = @{@"path": @"/b.db", @"name": @"b.db"};
        NSArray *list = DBRecentFilesWith(@[], a, YES);
        list = DBRecentFilesWith(list, b, YES);
        assert(([[list valueForKey:@"path"] isEqual:(@[@"/b.db", @"/a.db"])]));
        list = DBRecentFilesWith(list, @{@"path": @"/a.db", @"name": @"a.db", @"frame": @"#2ea043"}, NO);
        assert(([[list valueForKey:@"path"] isEqual:(@[@"/b.db", @"/a.db"])] && [list[1][@"frame"] isEqual:@"#2ea043"]));
        list = DBRecentFilesWith(list, a, YES);
        assert(([[list valueForKey:@"path"] isEqual:(@[@"/a.db", @"/b.db"])]));
        for (int i = 0; i < 30; i++) list = DBRecentFilesWith(list, @{@"path": [NSString stringWithFormat:@"/%d.db", i]}, YES);
        assert(list.count == 20 && [list[0][@"path"] isEqual:@"/29.db"]);
        NSDictionary *fresh = [ConnectionStore fileConnectionForPath:@"/nowhere/shop.sqlite"];
        assert([fresh[@"kind"] isEqual:@"sqlite"] && [fresh[@"name"] isEqual:@"shop.sqlite"] && [fresh[@"database"] isEqual:@"/nowhere/shop.sqlite"]);
        // tabs: identity per connection, a connection stays open while another window uses it, saved tab lists
        assert([TBConnectionIdentity(@{@"kind": @"sqlite", @"path": @"/x/a.db"}) isEqual:@"file:/x/a.db"]);
        assert([TBConnectionIdentity(@{@"id": @"c1", @"database": @"shop"}) isEqual:@"c1/shop"]);
        NSObject *c1 = [NSObject new], *c2 = [NSObject new];
        assert(TBConnectionStillUsed(@[c2, c1], c1) && !TBConnectionStillUsed(@[c2], c1) && !TBConnectionStillUsed(@[], c1));
        NSDictionary *saved = TBSavedTabsWith(@{}, @"c1/shop", @[@[@"public", @"claims", @0], @[@"public", @"drivers", @1]]);
        assert([saved[@"c1/shop"] count] == 2);
        assert(TBSavedTabsWith(saved, @"c1/shop", @[])[@"c1/shop"] == nil);
        // the same table twice (e.g. the connection was opened twice) is saved once, the first place it appears
        NSArray *twice = @[@[@"public", @"claims", @0], @[@"public", @"drivers", @1], @[@"public", @"claims", @2]];
        assert(([TBSavedTabsWith(@{}, @"c1/shop", twice)[@"c1/shop"] isEqual:(@[@[@"public", @"claims", @0], @[@"public", @"drivers", @1]])]));
        puts("store_test: OK");
    }
    return 0;
}
