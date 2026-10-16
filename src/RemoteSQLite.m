#import "RemoteSQLite.h"
#import "DBConnection.h"
#import <signal.h>

static const NSUInteger StderrKept = 4096;  // the end of ssh's messages, for errors
static const NSUInteger LinesBeforeHello = 100; // e.g. a banner printed by the remote shell

@implementation RemoteSQLite {
    NSArray<NSString *> *_command;
    NSString *_helper, *_path;
    BOOL _readOnly, _started;
    NSTask *_task;
    NSFileHandle *_input, *_output;
    NSMutableData *_buffer;  // stdout read but not yet split into lines
    NSMutableData *_stderr;
    NSInteger _lastId;
}

+ (void)initialize {
    signal(SIGPIPE, SIG_IGN); // writing to a helper that died must be an error, not the end of the app
}

- (instancetype)initWithCommand:(NSArray<NSString *> *)command helper:(NSString *)helper {
    if ((self = [super init])) {
        _command = [command copy];
        _helper = [helper copy];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

- (NSString *)stderrTail {
    NSData *data;
    @synchronized (self) { data = [_stderr copy]; }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

- (BOOL)startWithPath:(NSString *)path readOnly:(BOOL)readOnly error:(NSError **)error {
    [self endProcess];
    _path = [path copy];
    _readOnly = readOnly;
    _started = YES;
    _buffer = [NSMutableData new];
    _stderr = [NSMutableData new];
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:_command.firstObject];
    task.arguments = [_command subarrayWithRange:NSMakeRange(1, _command.count - 1)];
    NSPipe *input = [NSPipe pipe], *output = [NSPipe pipe], *errors = [NSPipe pipe];
    task.standardInput = input;
    task.standardOutput = output;
    task.standardError = errors;
    __weak RemoteSQLite *weakSelf = self;
    errors.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        RemoteSQLite *strongSelf = weakSelf;
        if (!data.length) handle.readabilityHandler = nil;
        if (!strongSelf || !data.length) return;
        @synchronized (strongSelf) {
            [strongSelf->_stderr appendData:data];
            if (strongSelf->_stderr.length > StderrKept)
                [strongSelf->_stderr replaceBytesInRange:NSMakeRange(0, strongSelf->_stderr.length - StderrKept) withBytes:NULL length:0];
        }
    };
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (error) *error = DBError(launchError.localizedDescription, nil);
        return NO;
    }
    _task = task;
    _input = input.fileHandleForWriting;
    _output = output.fileHandleForReading;

    // the helper's source and config travel on stdin, so nothing from the user reaches the remote shell
    NSData *config = [NSJSONSerialization dataWithJSONObject:@{@"path": _path, @"readonly": @(_readOnly)} options:0 error:NULL];
    NSMutableData *intro = [[[_helper dataUsingEncoding:NSUTF8StringEncoding] base64EncodedDataWithOptions:0] mutableCopy] ?: [NSMutableData new];
    [intro appendBytes:"\n" length:1];
    [intro appendData:config];
    [intro appendBytes:"\n" length:1];
    [_input writeData:intro error:NULL]; // a failure shows up as the missing hello below

    for (NSUInteger i = 0; i < LinesBeforeHello; i++) {
        NSData *line = [self readLine];
        if (!line) break;
        NSDictionary *message = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
        if (![message isKindOfClass:NSDictionary.class] || message[@"id"]) continue; // not the helper speaking yet
        if ([message[@"hello"] isEqual:@"plaindb"]) return YES;
        if ([message[@"error"] isKindOfClass:NSString.class]) {
            if (error) *error = DBError(message[@"error"], nil);
            [self endProcess];
            return NO;
        }
    }
    if (_task.running) [_task terminate]; // talked a lot, never said hello
    if (error) *error = [self exitError];
    [self endProcess];
    return NO;
}

// Why the process ended (or is about to): ssh's message, or a missing python3.
- (NSError *)exitError {
    [_input closeFile];
    [_task waitUntilExit];
    usleep(50000); // the last of stderr
    NSString *tail = [self stderrTail];
    if (_task.terminationStatus == 127)
        return DBError([NSString stringWithFormat:L(@"python3 wasn't found on the server. %@"), tail], nil);
    return DBError(tail.length ? tail : L(@"The connection to the server ended."), nil);
}

// The next line of stdout without its newline, or nil at the end.
- (NSData *)readLine {
    NSUInteger scanned = 0;
    while (YES) {
        const char *bytes = _buffer.bytes;
        for (NSUInteger i = scanned; i < _buffer.length; i++) {
            if (bytes[i] != '\n') continue;
            NSData *line = [_buffer subdataWithRange:NSMakeRange(0, i)];
            [_buffer replaceBytesInRange:NSMakeRange(0, i + 1) withBytes:NULL length:0];
            return line;
        }
        scanned = _buffer.length;
        NSData *more = nil;
        @try { more = _output.availableData; } @catch (NSException *e) { more = nil; }
        if (!more.length) return nil;
        [_buffer appendData:more];
    }
}

- (NSDictionary *)send:(NSDictionary *)request error:(NSError **)error {
    if (!_started) {
        if (error) *error = DBError(L(@"Not connected to the database."), nil);
        return nil;
    }
    if (!_task.running && ![self startWithPath:_path readOnly:_readOnly error:error]) return nil;
    NSMutableDictionary *message = [request mutableCopy];
    message[@"id"] = @(++_lastId);
    NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:message options:0 error:NULL] mutableCopy];
    [data appendBytes:"\n" length:1];
    NSData *line = [_input writeData:data error:NULL] ? [self readLine] : nil;
    if (!line) {
        NSError *ended = [self exitError];
        if (error) *error = DBError([NSString stringWithFormat:L(@"Lost the connection to the server: %@"), ended.localizedDescription], nil);
        [self endProcess]; // the next request starts it again
        return nil;
    }
    NSDictionary *answer = [NSJSONSerialization JSONObjectWithData:line options:0 error:NULL];
    if (![answer isKindOfClass:NSDictionary.class] || ![answer[@"id"] isEqual:message[@"id"]]) {
        // never guess what an unexpected line means: drop the session
        if (error) *error = DBError(L(@"The server sent an unexpected answer, so the connection was closed."), nil);
        [self endProcess];
        return nil;
    }
    return answer;
}

- (void)stop {
    _started = NO;
    [self endProcess];
}

// Ends the process but not the connection: the next request starts a new one.
- (void)endProcess {
    NSTask *task = _task;
    _task = nil;
    if (!task) return;
    [_input closeFile]; // the helper ends when its input does
    _input = nil;
    _output = nil;
    if (task.running)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (task.running) [task terminate];
        });
}

@end
