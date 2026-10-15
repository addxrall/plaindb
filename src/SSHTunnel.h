#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Tunnel through the system /usr/bin/ssh, so ~/.ssh/config, keys, the agent and ProxyJump all work.
// If ssh dies after the tunnel was established, it is restarted on the same local port.
// Posted on the main thread (object: the tunnel) when the tunnel drops or comes back. Every window sharing the
// tunnel (tabs) observes it; `connected` has the new state.
extern NSNotificationName const SSHTunnelStatusNotification;

@interface SSHTunnel : NSObject
@property (nonatomic, readonly) uint16_t localPort;
// YES once started and while up; NO before start and while dropped and reconnecting. Main thread.
@property (nonatomic, readonly) BOOL connected;

- (instancetype)initWithSSHHost:(NSString *)sshHost remoteHost:(NSString *)host remotePort:(NSString *)port;
// Blocks until the local port accepts connections or ssh fails. Don't call on the main thread.
- (BOOL)start:(NSError **)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
