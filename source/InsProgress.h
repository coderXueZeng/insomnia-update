#import <Foundation/Foundation.h>

/// 定时把「当前同步进度」自动发到微信（默认文件传输助手）。
/// 微信在后台随时可能被挂起，所以定时器 + 收到消息时补检双保险。
@interface InsProgress : NSObject

/// 由 Tweak.x 在启动时注册，实际发消息走已经验证过的 InsReply 链路
+ (void)setReplyHandler:(void (^)(NSString *talker, NSString *text))handler;
+ (void)start;
/// 每条收到的消息都调一次，内部 20 秒节流；定时器被挂起时靠它补发
+ (void)noteActivity;

+ (BOOL)enabled;
+ (NSInteger)intervalMinutes;
+ (NSString *)targetLabel;
+ (NSString *)targetTalker;
+ (NSString *)statusLine;

+ (void)setEnabled:(BOOL)on;
+ (void)setEnabled:(BOOL)on target:(NSString *)talker chatName:(NSString *)chatName;
+ (void)setTarget:(NSString *)talker chatName:(NSString *)chatName;
+ (void)setIntervalMinutes:(NSInteger)minutes;
/// 立刻发一次（不管开关状态），返回发送目标名
+ (NSString *)reportNow;

@end
