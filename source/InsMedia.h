#import <Foundation/Foundation.h>

@interface InsMedia : NSObject

/// 记下会话里最近一条图片(type 3)/链接(type 49)消息，落盘以便重启后还能看
+ (void)remember:(NSString *)talker
            type:(NSUInteger)type
             xml:(NSString *)xml
         localID:(NSUInteger)localID
            time:(uint32_t)time;

/// kind = image / link / record；没有记到返回 nil
+ (NSDictionary *)lastForTalker:(NSString *)talker kind:(NSString *)kind;

/// 本会话最近记到的图片（新 → 旧）；兼容只存了单条的旧数据。
/// limit = 0 表示不限条数
+ (NSArray<NSDictionary *> *)imagesForTalker:(NSString *)talker limit:(NSUInteger)limit;

/// 本会话最近记到的链接（新 → 旧，最多 8 条）；兼容只存了单条的旧数据
+ (NSArray<NSDictionary *> *)linksForTalker:(NSString *)talker;

/// 本会话最近记到的「合并转发聊天记录」（新 → 旧，最多 3 条）
+ (NSArray<NSDictionary *> *)recordsForTalker:(NSString *)talker;

/// 微信「合并转发聊天记录」(appmsg type 19) 解析成带序号的可读文本；不是聊天记录返回 nil
+ (NSString *)chatRecordTextFrom:(NSString *)xml;

/// 取图片字节：本地全图 → CDN 下载(必要时 AES 解密) → 本地缩略图 → 时间窗兜底
+ (NSData *)imageDataFor:(NSDictionary *)media talker:(NSString *)talker error:(NSError **)error;

/// 链接消息里的标题/摘要/URL
+ (NSDictionary *)linkInfoFor:(NSDictionary *)media;

/// 从任意文本里找链接：微信分享 XML（<url> 或 url="..."）、被引用消息、纯文本里的 http(s) 地址。
/// 找不到 URL 返回 nil；返回 @{@"title", @"des", @"url"}，URL 已做实体解码。
+ (NSDictionary *)linkInfoFromText:(NSString *)text;

/// 文件消息（appmsg type 6 / <appattach>）里能拿到的东西：文件名、大小、md5、attachid。
/// 不是文件消息返回 nil。
+ (NSDictionary *)fileInfoFromXML:(NSString *)xml;

/// 一站式取文件正文：先找手机上已下载的副本，没有就调微信内部接口下载再等，
/// 最后按 UTF-8 / GB18030 / UTF-16 读成文本（超过 20000 字截断）。
/// 读不到返回 nil，reason 说明卡在哪一步（没下载、下载失败、是二进制等）。
+ (NSString *)fileTextFor:(NSDictionary *)info talker:(NSString *)talker reason:(NSString **)reason;

/// 解析微信「引用回复」消息（appmsg type 57 / <refermsg>，或 "原文\n------\n回复" 纯文本格式）。
/// 返回 @{@"reply": 回复文字, @"quoted": 被引用的原文, @"link": 被引用内容里的链接(可能为空字典),
///        @"kind": @"link" / @"image" / @"record" / @""}；不是引用消息返回 nil。
+ (NSDictionary *)parseQuote:(NSString *)content;

/// 抓链接正文并粗清洗成纯文本，抓不到返回 nil
+ (NSString *)fetchLinkText:(NSString *)url error:(NSError **)error;

/// 抓「可用」正文：归一化 URL、带微信浏览器 UA 直连、剔除验证页/空壳页。
/// 成功返回正文且 reason 为 nil；失败返回 nil 并通过 reason 说明原因。
+ (NSString *)fetchLinkArticle:(NSString *)url reason:(NSString **)reason;

/// 抓不到正文时走「屏幕读」：优先在微信里点开链接卡片用内置浏览器看，兜底 open_url 到 Safari，
/// 等页面加载后 OCR + 读界面元素，最后把微信拉回前台。force=NO 时同一网址 10 分钟内只自动试一次。
/// 成功返回屏幕上读到的文字；失败返回 nil 并通过 reason 说明原因。
+ (NSString *)readLinkOnScreen:(NSString *)url title:(NSString *)title force:(BOOL)force
                        reason:(NSString **)reason;

@end