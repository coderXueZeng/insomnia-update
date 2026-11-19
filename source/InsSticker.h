#import <Foundation/Foundation.h>

@interface InsSticker : NSObject

/// 总开关 / 发送模式（auto = 表情面板优先，失败用表情库图片兜底）
+ (BOOL)battleEnabled;
+ (NSString *)battleMode;
+ (void)setEnabled:(BOOL)on;
+ (void)setMode:(NSString *)mode;

/// 插件启动时异步扫一次「我的已有表情包」
+ (void)bootstrap;

/// 收到一条微信表情消息（type 47）时调用。
/// fromMe=YES 只把这张记进「我发过的表情」；allowed=NO 表示这个会话不在放行范围。
+ (void)handleMessage:(NSString *)xml
               talker:(NSString *)talker
               fromMe:(BOOL)fromMe
              allowed:(BOOL)allowed;

/// 立刻回一张表情（手动命令用），结果通过 reply 回执，传 nil 则只写日志
+ (void)sendOneTo:(NSString *)talker reply:(void (^)(NSString *result))reply;

/// 本地表情库（@{@"md5", @"path", @"kind", @"bytes"}）
+ (NSArray<NSDictionary *> *)library;
/// 重新扫一次微信自定义表情列表 + 沙箱里的表情图片，返回可用图片数
+ (NSUInteger)refreshLibrary;
/// 给 @insomnia 斗图状态 / wb 交接包用的诊断文字
+ (NSString *)debugInfo;

// ---- 解释表情包 ----

/// 记一条最近的表情消息（收发都记），供「表情包什么意思」取最近一张
+ (void)recordRecent:(NSString *)xml talker:(NSString *)talker fromMe:(BOOL)fromMe;
/// 本会话最近一条表情消息的信息（md5/cdnurl/aeskey/xml/fromMe），没有则 nil
+ (NSDictionary *)lastRecentForTalker:(NSString *)talker;
/// 把表情信息变成能喂给视觉模型的图片字节：本地缓存优先，再试 CDN 下载 + AES 解密
+ (NSData *)stickerImageData:(NSDictionary *)info error:(NSError **)error;

@end
