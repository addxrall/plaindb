#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Saved connections: a plist in ~/Library/Application Support/PlainDB, passwords in the Keychain.
// Data saved under the old name (Tabula) is read as a fallback and moved over on the next save.
// Dictionary keys: id, name, host, port, user, database, sshHost, production (NSNumber).
@interface ConnectionStore : NSObject
+ (NSMutableArray<NSMutableDictionary *> *)load;
+ (void)save:(NSArray<NSDictionary *> *)connections;
+ (nullable NSString *)passwordFor:(NSString *)connectionId;
// Window frame colour as "#rrggbb", or "" for none. Production connections always get one (red by default).
// Stored under "frame"; older entries only had "color", which was meant for production connections only.
+ (NSString *)frameColorFor:(NSDictionary *)connection;
// Frame colours of databases opened from the Local tab, by database name.
+ (NSString *)localFrameColorFor:(NSString *)database;
+ (void)setLocalFrameColor:(NSString *)hex for:(NSString *)database;
+ (void)setPassword:(nullable NSString *)password for:(NSString *)connectionId;
@end

NS_ASSUME_NONNULL_END
