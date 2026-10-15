#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Tunel przez systemowy /usr/bin/ssh, więc działają ~/.ssh/config, klucze, agent i ProxyJump.
// Jeśli ssh padnie po zestawieniu tunelu, uruchamia go ponownie na tym samym porcie lokalnym.
@interface SSHTunnel : NSObject
@property (nonatomic, readonly) uint16_t localPort;
// Wołane na głównym wątku przy zmianie stanu („połączony”, „wznawiam…”).
@property (nonatomic, copy, nullable) void (^onStatus)(NSString *status);

- (instancetype)initWithSSHHost:(NSString *)sshHost remoteHost:(NSString *)host remotePort:(NSString *)port;
// Blokuje, dopóki port lokalny nie przyjmuje połączeń albo ssh się nie wyłoży. Nie wołaj z głównego wątku.
- (BOOL)start:(NSError **)error;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
