#import "Connector.h"
#import "PGConnection.h"
#import "SSHTunnel.h"

void TBConnect(NSDictionary *info, NSString *password, void (^done)(id<DBConnection> connection, SSHTunnel *tunnel, NSError *error)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSString *host = info[@"host"], *port = [info[@"port"] length] ? info[@"port"] : @"5432";
        SSHTunnel *tunnel = nil;
        if ([info[@"sshHost"] length]) {
            tunnel = [[SSHTunnel alloc] initWithSSHHost:info[@"sshHost"] remoteHost:host.length ? host : @"localhost" remotePort:port];
            if (![tunnel start:&error]) tunnel = nil;
            host = @"127.0.0.1";
            port = @(tunnel.localPort).stringValue;
        }

        PGConnection *conn = nil;
        if (!error) {
            NSMutableDictionary *params = [@{@"port": port} mutableCopy];
            if (host.length) params[@"host"] = host; // empty host = local socket
            if ([info[@"user"] length]) params[@"user"] = info[@"user"];
            if (password.length) params[@"password"] = password;
            if ([info[@"database"] length]) params[@"dbname"] = info[@"database"];
            conn = [[PGConnection alloc] initWithParams:params readOnly:[info[@"production"] boolValue]];
            if (![conn open:&error]) {
                conn = nil;
                [tunnel stop];
                tunnel = nil;
            }
        }
        if (!conn && !error) error = DBError(L(@"Couldn't connect."), nil);
        dispatch_async(dispatch_get_main_queue(), ^{ done(conn, tunnel, error); });
    });
}
