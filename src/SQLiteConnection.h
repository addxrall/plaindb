#import "DBConnection.h"

NS_ASSUME_NONNULL_BEGIN

// SQLite database file, local or on a server. The schema is always "main".
// readOnly sets PRAGMA query_only, so the session refuses writes (sqlstate 25006) except in inWriteTransaction.
@interface SQLiteConnection : NSObject <DBConnection>
- (instancetype)initWithPath:(NSString *)path readOnly:(BOOL)readOnly;
// A file on a server, through PlainDB's helper (Resources/sqlite_remote.py) started over ssh: keys or the agent
// only (BatchMode), python3 on the server. A read-only connection is also guarded by the helper itself.
- (instancetype)initWithSSHHost:(NSString *)sshHost path:(NSString *)path readOnly:(BOOL)readOnly;
// The same with any command starting the helper (tests run it with the local python3).
- (instancetype)initWithCommand:(NSArray<NSString *> *)command helper:(NSString *)helper path:(NSString *)path readOnly:(BOOL)readOnly;
@end

// Python code that reads the helper from the first line of stdin and runs it; the remote command is
// `python3 -I -u -c '<this>'`, the same for every connection, with nothing from the user in it.
extern NSString *const SQLiteRemoteBootstrap;

NS_ASSUME_NONNULL_END
