#import <Foundation/Foundation.h>

@interface InsHistory : NSObject

/// 按时间升序返回该会话的文本消息：@{ @"t": NSNumber(createTime), @"me": @(0/1), @"text": NSString }
+ (NSArray<NSDictionary *> *)textMessagesForTalker:(NSString *)wxid
                                         afterTime:(uint32_t)afterTime
                                          maxCount:(NSInteger)maxCount;

+ (NSArray<NSDictionary *> *)latestTextMessagesForTalker:(NSString *)wxid count:(NSInteger)count;

+ (NSUInteger)totalTextMessageCountForTalker:(NSString *)wxid;

/// 关键词统计：在该会话可读文本里数 keyword 出现过的消息条数，按说话人拆分。
/// 返回 @{ @"total", @"fromMe", @"fromPartner", @"first", @"last",
///        @"textTotal", @"compressed", @"samples": @[ @{@"t",@"me",@"text"} ] }
+ (NSDictionary *)keywordStatsForTalker:(NSString *)wxid
                               keyword:(NSString *)keyword
                               samples:(NSInteger)samples;

/// 这个版本库里 Des 等于几才表示「账号主人发出的」（用文件传输助手单向特性校准）
+ (NSInteger)meDesValue;

/// filehelper / 微信团队 这类只会被单向写入的账号
+ (BOOL)isOneWayAccount:(NSString *)wxid;

/// 按服务器消息 id（引用消息 refermsg 里的 svrid）反查本地 MesLocalID。
/// 引用图片取图要靠它：图片消息的本地文件名就是 MesLocalID，而引用里只带了 svrid。
/// 表里没有 MesSvrID 列或查不到时返回 0。
+ (NSUInteger)localIDForSvrID:(NSString *)svrid talker:(NSString *)wxid;

@end
