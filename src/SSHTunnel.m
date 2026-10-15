#import "SSHTunnel.h"
#import "DBConnection.h"
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

static uint16_t FreeLocalPort(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t len = sizeof addr;
    bind(fd, (struct sockaddr *)&addr, len);
    getsockname(fd, (struct sockaddr *)&addr, &len);
    close(fd);
    return ntohs(addr.sin_port);
}

static BOOL PortAccepts(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    BOOL ok = connect(fd, (struct sockaddr *)&addr, sizeof addr) == 0;
    close(fd);
    return ok;
}

@implementation SSHTunnel {
    NSString *_sshHost, *_host, *_port;
    NSTask *_task;
    BOOL _stopped, _established;
}

- (instancetype)initWithSSHHost:(NSString *)sshHost remoteHost:(NSString *)host remotePort:(NSString *)port {
    if ((self = [super init])) {
        _sshHost = sshHost;
        _host = host;
        _port = port;
        _localPort = FreeLocalPort();
    }
    return self;
}

- (BOOL)start:(NSError **)error {
    NSString *message = [self launchAndWait];
    if (!message) {
        @synchronized (self) { _established = YES; }
        return YES;
    }
    [self stop];
    if (error) *error = DBError([NSString stringWithFormat:L(@"SSH tunnel: %@"), message], nil);
    return NO;
}

// Returns nil when the tunnel is up, otherwise an error message.
- (NSString *)launchAndWait {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ssh"];
    task.arguments = @[
        @"-N",
        @"-L", [NSString stringWithFormat:@"127.0.0.1:%u:%@:%@", _localPort, _host, _port],
        @"-o", @"ExitOnForwardFailure=yes",
        @"-o", @"ServerAliveInterval=30",
        @"-o", @"ServerAliveCountMax=3",
        @"-o", @"ConnectTimeout=10",
        @"-o", @"BatchMode=yes", // no password prompts: the app has no terminal
        @"--", _sshHost,
    ];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardError = stderrPipe;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    __weak SSHTunnel *weakSelf = self;
    task.terminationHandler = ^(NSTask *t) { [weakSelf taskDidExit:t]; };

    @synchronized (self) {
        if (_stopped) return L(@"stopped");
        _task = task;
    }
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) return launchError.localizedDescription;

    for (int i = 0; i < 100; i++) { // up to ~20 s: ConnectTimeout plus login
        if (!task.running) {
            NSData *data = [stderrPipe.fileHandleForReading readDataToEndOfFile];
            NSString *err = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            err = [err stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            return err.length ? err : [NSString stringWithFormat:L(@"ssh exited with code %d"), task.terminationStatus];
        }
        if (PortAccepts(_localPort)) return nil;
        usleep(200 * 1000);
    }
    [task terminate];
    return L(@"timed out waiting for the connection");
}

- (void)taskDidExit:(NSTask *)task {
    @synchronized (self) {
        if (_stopped || !_established || task != _task) return;
    }
    [self report:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        // If this fails, ssh exits again and taskDidExit retries.
        if (![self launchAndWait]) [self report:YES];
    });
}

- (void)report:(BOOL)connected {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.onStatus) self.onStatus(connected);
    });
}

- (void)stop {
    NSTask *task;
    @synchronized (self) {
        _stopped = YES;
        task = _task;
    }
    if (task.running) [task terminate];
}

- (void)dealloc {
    [self stop];
}

@end
