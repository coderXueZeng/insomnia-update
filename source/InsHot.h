#import <Foundation/Foundation.h>

/// 各平台热榜：微博 / 抖音 / 知乎 / 百度 / 头条 / B站。
/// 一律直连官方公开接口，取不到就如实说取不到，绝不交给大模型编热点。
@interface InsHot : NSObject

/// 是不是热点类命令（热点/热搜/热榜/热门）
+ (BOOL)handlesPayload:(NSString *)payload;

/// 生成回执；不是热点命令返回 nil
+ (NSString *)reportForPayload:(NSString *)payload;

@end
