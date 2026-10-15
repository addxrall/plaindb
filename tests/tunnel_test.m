// SSHTunnel's status reaches every window sharing the tunnel (tabs), and new windows can read the current state.
#import "SSHTunnel.h"
#import <assert.h>

@interface SSHTunnel (Testing)
- (void)report:(BOOL)connected;
@end

int main(void) {
    @autoreleasepool {
        SSHTunnel *tunnel = [[SSHTunnel alloc] initWithSSHHost:@"example" remoteHost:@"localhost" remotePort:@"5432"];
        assert(!tunnel.connected); // not started
        __block int heard = 0;
        __block BOOL last = YES;
        for (int i = 0; i < 2; i++) // two windows
            [NSNotificationCenter.defaultCenter addObserverForName:SSHTunnelStatusNotification object:tunnel queue:nil usingBlock:^(NSNotification *n) {
                heard++;
                last = ((SSHTunnel *)n.object).connected;
            }];
        [tunnel report:NO];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        assert(heard == 2 && !last && !tunnel.connected);
        [tunnel report:YES];
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        assert(heard == 4 && last && tunnel.connected);
        puts("tunnel_test: OK");
    }
    return 0;
}
