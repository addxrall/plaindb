#import "ConnectionStore.h"
#import <Security/Security.h>

static NSURL *FileURL(void) {
    NSURL *dir = [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject
                  URLByAppendingPathComponent:@"Tabula"];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"connections.plist"];
}

static NSDictionary *KeychainQuery(NSString *connectionId) {
    return @{(id)kSecClass: (id)kSecClassGenericPassword,
             (id)kSecAttrService: @"Tabula",
             (id)kSecAttrAccount: connectionId};
}

@implementation ConnectionStore

+ (NSMutableArray<NSMutableDictionary *> *)load {
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *c in [NSArray arrayWithContentsOfURL:FileURL()]) [result addObject:[c mutableCopy]];
    return result;
}

+ (void)save:(NSArray<NSDictionary *> *)connections {
    [connections writeToURL:FileURL() error:nil];
}

+ (NSString *)passwordFor:(NSString *)connectionId {
    NSMutableDictionary *q = [KeychainQuery(connectionId) mutableCopy];
    q[(id)kSecReturnData] = @YES;
    q[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
    CFTypeRef data = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &data) != errSecSuccess) return nil;
    return [[NSString alloc] initWithData:CFBridgingRelease(data) encoding:NSUTF8StringEncoding];
}

+ (void)setPassword:(NSString *)password for:(NSString *)connectionId {
    NSDictionary *q = KeychainQuery(connectionId);
    SecItemDelete((__bridge CFDictionaryRef)q);
    if (!password.length) return;
    NSMutableDictionary *add = [q mutableCopy];
    add[(id)kSecValueData] = [password dataUsingEncoding:NSUTF8StringEncoding];
    SecItemAdd((__bridge CFDictionaryRef)add, NULL);
}

@end
