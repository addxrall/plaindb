#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Zapisane połączenia: plist w ~/Library/Application Support/Tabula, hasła w Keychain.
// Klucze słownika: id, name, host, port, user, database, sshHost, production (NSNumber).
@interface ConnectionStore : NSObject
+ (NSMutableArray<NSMutableDictionary *> *)load;
+ (void)save:(NSArray<NSDictionary *> *)connections;
+ (nullable NSString *)passwordFor:(NSString *)connectionId;
+ (void)setPassword:(nullable NSString *)password for:(NSString *)connectionId;
@end

NS_ASSUME_NONNULL_END
