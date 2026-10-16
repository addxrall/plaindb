#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Pure list update for recent files: replaces the entry with the same path; `top` moves it to the front. At most 20.
NSArray<NSDictionary *> *DBRecentFilesWith(NSArray<NSDictionary *> *list, NSDictionary *file, BOOL top);

// Tabs: which connection a window belongs to ("file:<path>" or "<id>/<database>"), whether a connection is still used
// by another window, and the saved tab lists (each tab @[schema, table, @(Data / Structure / SQL tab)]).
NSString *TBConnectionIdentity(NSDictionary *info);
// An SQLite database: a local file (kind "sqlite") or a file on a server reached over ssh (kind "sqlite-ssh",
// a saved connection with sshHost and path).
BOOL TBIsSQLite(NSDictionary *info);
BOOL TBConnectionStillUsed(NSArray *connectionsOfOtherWindows, id connection);
NSDictionary *TBSavedTabsWith(NSDictionary *all, NSString *identity, NSArray<NSArray *> *tabs);

// Saved connections: a plist in ~/Library/Application Support/PlainDB, passwords in the Keychain.
// Data saved under the old name (Tabula) is read as a fallback and moved over on the next save.
// Dictionary keys: id, name, host, port, user, database, sshHost, production (NSNumber); SQLite on a server adds
// kind = "sqlite-ssh" and path (database is set to the path too).
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
// SQLite files, as connection dictionaries (kind "sqlite", path, name, production = read-only, frame), newest first.
+ (NSArray<NSDictionary *> *)recentFiles;
+ (void)rememberFile:(NSDictionary *)file moveToTop:(BOOL)top;
+ (void)forgetFile:(NSString *)path;
// The remembered entry for `path`, or a new one.
+ (NSDictionary *)fileConnectionForPath:(NSString *)path;
// The tabs a connection had open last time, in tab order.
+ (NSArray<NSArray *> *)savedTabsFor:(NSString *)identity;
+ (void)saveTabs:(NSArray<NSArray *> *)tabs for:(NSString *)identity;
@end

NS_ASSUME_NONNULL_END
