#import <Foundation/Foundation.h>

/// 「林健说了多少句 你小子」这类问题：直接查微信本地聊天库数，不靠模型记忆。
/// 记忆里存的是摘要，长度和条数都是压缩后的信息，问「说了多少次」只能扫原文。
@interface InsStat : NSObject

/// 解析自然语言的统计意图，不是统计问题返回 nil。
/// 返回 @{ @"who": NSString（空＝当前会话对方）, @"keyword": NSString,
///        @"from": @"partner" / @"me" / @"both" }
+ (NSDictionary *)parseCountQuestion:(NSString *)payload;

/// 显式命令：@insomnia 数 林健 你小子 / 数 你小子
+ (NSDictionary *)parseExplicitCount:(NSString *)payload;

/// 人名 → 会话候选：先扫记忆索引（有备注名），再查通讯录。
/// 每项 @{ @"wxid", @"name", @"scanned" }
+ (NSArray<NSDictionary *> *)candidatesForName:(NSString *)name;

/// 生成统计回执；不是统计问题返回 nil（调用方回落到普通提问）
+ (NSString *)reportForQuestion:(NSString *)payload talker:(NSString *)talker;

/// 通讯录里读到的人数（用于报错时说清楚「是没这个人，还是压根没读到」）
+ (NSUInteger)knownContactCount;

/// 通讯录数据从哪来：微信通讯录 / 本地通讯录库 / 两者合并
+ (NSString *)contactSource;

/// 按名字找人：列出备注名/昵称 + wxid，供授权、代发时指定
+ (NSString *)searchReport:(NSString *)keyword;

/// 记一笔「这个名字 = 这个 wxid」。通讯录枚举接口在多数版本上读不到，
/// 只能靠平时见到的名字积累；代发/授权时按名字找人就用这本簿子。
+ (void)learnName:(NSString *)name forWxid:(NSString *)wxid;

@end
