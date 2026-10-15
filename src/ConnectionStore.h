#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Saved connections: a plist in ~/Library/Application Support/PlainDB, passwords in the Keychain.
// Data saved under the old name (Tabula) is read as a fallback and moved over on the next save.
// Dictionary keys: id, name, host, port, user, database, sshHost, production (NSNumber).
@interface ConnectionStore : NSObject
+ (NSMutableArray<NSMutableDictionary *> *)load;
+ (void)save:(NSArray<NSDictionary *> *)connections;
+ (nullable NSString *)passwordFor:(NSString *)connectionId;
+ (void)setPassword:(nullable NSString *)password for:(NSString *)connectionId;
@end

NS_ASSUME_NONNULL_END
