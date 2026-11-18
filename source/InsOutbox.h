#import <Foundation/Foundation.h>

/// 回复重发队列。
/// 微信的「发送」只有走会话控制器/SendTextMessage 才会真正上服务器；
/// 会话没开着又跳不过去时，旧版会往本地库里插一条假消息——气泡照常显示、
/// 还带「已送达」，但对方永远收不到。v64 起默认改成排队重试，不再造假记录。
@interface InsOutbox : NSObject

/// 存一条没发出去的回复（超过上限丢最旧的，最多留 20 条）
+ (void)enqueueText:(NSString *)text
           toTalker:(NSString *)talker
           chatName:(NSString *)chatName
              error:(NSString *)error;

+ (NSUInteger)count;

/// 一行摘要，给 status / help 用
+ (NSString *)statusLine;

/// 队列明细：谁、什么时候、失败原因
+ (NSString *)detail;

/// 后台按顺序重发，成功一条删一条；report 是给人看的结果
+ (void)flushWithCompletion:(void (^)(NSString *report))done;

/// 记下最近一次真实送达走的哪条通道（会话通道 / 跳转后发送），给「送达」命令看
+ (void)noteDeliveryVia:(NSString *)channel talker:(NSString *)talker;

+ (NSString *)lastDeliveryLine;

@end
