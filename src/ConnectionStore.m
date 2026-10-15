#import "ConnectionStore.h"
#import <Security/Security.h>

static NSString *const Name = @"PlainDB";
static NSString *const OldName = @"Tabula"; // the app's previous name
static NSString *const RecentFilesKey = @"recentFiles";

static NSString *const OpenTabsKey = @"openTabs";

NSString *TBConnectionIdentity(NSDictionary *info) {
    if ([info[@"kind"] isEqual:@"sqlite"]) return [@"file:" stringByAppendingString:info[@"path"] ?: @""];
    return [NSString stringWithFormat:@"%@/%@", info[@"id"] ?: @"", info[@"database"] ?: @""];
}

BOOL TBConnectionStillUsed(NSArray *connectionsOfOtherWindows, id connection) {
    for (id c in connectionsOfOtherWindows)
        if (c == connection) return YES;
    return NO;
}

NSDictionary *TBSavedTabsWith(NSDictionary *all, NSString *identity, NSArray<NSArray *> *tabs) {
    NSMutableArray *unique = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    for (NSArray *tab in tabs) { // one tab per table, where it first appears
        NSArray *table = @[tab[0], tab[1]];
        if ([seen containsObject:table]) continue;
        [seen addObject:table];
        [unique addObject:tab];
    }
    NSMutableDictionary *out = [all mutableCopy] ?: [NSMutableDictionary new];
    out[identity] = unique.count ? unique : nil;
    return out;
}

NSArray<NSDictionary *> *DBRecentFilesWith(NSArray<NSDictionary *> *list, NSDictionary *file, BOOL top) {
    NSMutableArray *out = [list mutableCopy];
    NSUInteger at = [out indexOfObjectPassingTest:^BOOL(NSDictionary *f, NSUInteger i, BOOL *stop) { return [f[@"path"] isEqual:file[@"path"]]; }];
    if (at != NSNotFound && !top) out[at] = file;
    else {
        if (at != NSNotFound) [out removeObjectAtIndex:at];
        [out insertObject:file atIndex:0];
    }
    return [out subarrayWithRange:NSMakeRange(0, MIN(out.count, 20))];
}

static NSURL *FileURL(NSString *appName) {
    NSURL *dir = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject
                  URLByAppendingPathComponent:appName];
    if ([appName isEqual:Name])
        [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"connections.plist"];
}

static NSDictionary *KeychainQuery(NSString *service, NSString *connectionId) {
    return @{(id)kSecClass: (id)kSecClassGenericPassword,
             (id)kSecAttrService: service,
             (id)kSecAttrAccount: connectionId};
}

static NSString *ReadPassword(NSString *service, NSString *connectionId) {
    NSMutableDictionary *q = [KeychainQuery(service, connectionId) mutableCopy];
    q[(id)kSecReturnData] = @YES;
    q[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
    CFTypeRef data = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &data) != errSecSuccess) return nil;
    return [[NSString alloc] initWithData:CFBridgingRelease(data) encoding:NSUTF8StringEncoding];
}

@implementation ConnectionStore

+ (NSMutableArray<NSMutableDictionary *> *)load {
    NSArray *saved = [NSArray arrayWithContentsOfURL:FileURL(Name)] ?: [NSArray arrayWithContentsOfURL:FileURL(OldName)];
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *c in saved) [result addObject:[c mutableCopy]];
    return result;
}

+ (void)save:(NSArray<NSDictionary *> *)connections {
    [connections writeToURL:FileURL(Name) error:nil];
}

+ (NSString *)passwordFor:(NSString *)connectionId {
    return ReadPassword(Name, connectionId) ?: ReadPassword(OldName, connectionId);
}

+ (NSString *)frameColorFor:(NSDictionary *)connection {
    BOOL production = [connection[@"production"] boolValue];
    NSString *frame = connection[@"frame"] ?: (production ? connection[@"color"] : @"");
    return frame.length || !production ? (frame ?: @"") : @"#e0342b";
}

+ (NSString *)localFrameColorFor:(NSString *)database {
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:@"localFrameColors"][database] ?: @"";
}

+ (void)setLocalFrameColor:(NSString *)hex for:(NSString *)database {
    NSMutableDictionary *all = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"localFrameColors"] mutableCopy] ?: [NSMutableDictionary new];
    all[database] = hex.length ? hex : nil;
    [NSUserDefaults.standardUserDefaults setObject:all forKey:@"localFrameColors"];
}

+ (void)setPassword:(NSString *)password for:(NSString *)connectionId {
    SecItemDelete((__bridge CFDictionaryRef)KeychainQuery(OldName, connectionId));
    NSDictionary *q = KeychainQuery(Name, connectionId);
    SecItemDelete((__bridge CFDictionaryRef)q);
    if (!password.length) return;
    NSMutableDictionary *add = [q mutableCopy];
    add[(id)kSecValueData] = [password dataUsingEncoding:NSUTF8StringEncoding];
    SecItemAdd((__bridge CFDictionaryRef)add, NULL);
}

+ (NSArray<NSDictionary *> *)recentFiles {
    return [NSUserDefaults.standardUserDefaults arrayForKey:RecentFilesKey] ?: @[];
}

+ (void)rememberFile:(NSDictionary *)file moveToTop:(BOOL)top {
    [NSUserDefaults.standardUserDefaults setObject:DBRecentFilesWith([self recentFiles], file, top) forKey:RecentFilesKey];
}

+ (void)forgetFile:(NSString *)path {
    NSPredicate *other = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *f, NSDictionary *bindings) { return ![f[@"path"] isEqual:path]; }];
    [NSUserDefaults.standardUserDefaults setObject:[[self recentFiles] filteredArrayUsingPredicate:other] forKey:RecentFilesKey];
}

+ (NSDictionary *)fileConnectionForPath:(NSString *)path {
    for (NSDictionary *f in [self recentFiles])
        if ([f[@"path"] isEqual:path]) return f;
    return @{@"kind": @"sqlite", @"id": @"file", @"path": path, @"database": path, @"name": path.lastPathComponent,
             @"production": @NO, @"frame": @""};
}

+ (NSArray<NSArray *> *)savedTabsFor:(NSString *)identity {
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:OpenTabsKey][identity] ?: @[];
}

+ (void)saveTabs:(NSArray<NSArray *> *)tabs for:(NSString *)identity {
    NSDictionary *all = [NSUserDefaults.standardUserDefaults dictionaryForKey:OpenTabsKey];
    [NSUserDefaults.standardUserDefaults setObject:TBSavedTabsWith(all, identity, tabs) forKey:OpenTabsKey];
}

@end
