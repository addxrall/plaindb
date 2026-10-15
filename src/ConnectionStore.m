#import "ConnectionStore.h"
#import <Security/Security.h>

static NSString *const Name = @"PlainDB";
static NSString *const OldName = @"Tabula"; // the app's previous name

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

+ (void)setPassword:(NSString *)password for:(NSString *)connectionId {
    SecItemDelete((__bridge CFDictionaryRef)KeychainQuery(OldName, connectionId));
    NSDictionary *q = KeychainQuery(Name, connectionId);
    SecItemDelete((__bridge CFDictionaryRef)q);
    if (!password.length) return;
    NSMutableDictionary *add = [q mutableCopy];
    add[(id)kSecValueData] = [password dataUsingEncoding:NSUTF8StringEncoding];
    SecItemAdd((__bridge CFDictionaryRef)add, NULL);
}

@end
