#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Tunnel through the system /usr/bin/ssh, so ~/.ssh/config, keys, the agent and ProxyJump all work.
// If ssh dies after the tunnel was established, it is restarted on the same local port.
@interface SSHTunnel : NSObject
@property (nonatomic, readonly) uint16_t localPort;
// Called on the main thread when the state changes: YES = connected, NO = dropped, reconnecting.
@property (nonatomic, copy, nullable) void (^onStatus)(BOOL connected);

- (instancetype)initWithSSHHost:(NSString *)sshHost remoteHost:(NSString *)host remotePort:(NSString *)port;
// Blocks until the local port accepts connections or ssh fails. Don't call on the main thread.
- (BOOL)start:(NSError **)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
