#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One process running PlainDB's SQLite helper (Resources/sqlite_remote.py), usually ssh starting it on a server:
// JSON lines over its stdin and stdout. Blocking; call it on the connection's queue.
@interface RemoteSQLite : NSObject
// command: what to launch (ssh … python3 …, or python3 itself in tests); helper: the helper's source.
- (instancetype)initWithCommand:(NSArray<NSString *> *)command helper:(NSString *)helper;
// Launches the command, sends the helper and its config, and waits for its hello.
- (BOOL)startWithPath:(NSString *)path readOnly:(BOOL)readOnly error:(NSError **)error;
// Sends one request and waits for the answer with its id (an "error" in the answer is the caller's business).
// A helper that died while idle is started again first; one that dies during the request fails it.
- (nullable NSDictionary *)send:(NSDictionary *)request error:(NSError **)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
