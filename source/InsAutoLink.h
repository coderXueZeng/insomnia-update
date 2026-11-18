#import <Foundation/Foundation.h>

/// 点进聊天就自动分析对方发来的链接：
///  - 进入/切换会话时，取该会话最近几条还没分析过的链接卡片，后台抓正文 + 模型总结
///  - 收到对方发来的链接卡片时可选择立刻分析（省得等你看的时候再跑）
///  - 结果按 URL 去重落盘；quiet 只存本地，forward 发到文件传输助手，reply 就地回一条
@interface InsAutoLink : NSObject

/// 启动时装载缓存（顺带清理过期条目），不会主动分析
+ (void)bootstrap;

/// 收到 type 49 的 appmsg：只有链接卡片会被处理，fromMe 的跳过
+ (void)noteIncomingXML:(NSString *)xml talker:(NSString *)talker fromMe:(BOOL)fromMe;

/// 进入/点击聊天框时调用（内部自己找当前会话，60 秒内同一会话只跑一次）
+ (void)noteChatOpened;

/// 当前打开会话的 talker，取不到返回 nil
+ (NSString *)currentTalker;

/// 一行状态，给 status / wb 用
+ (NSString *)statusLine;

/// 已分析过的链接列表（新 → 旧），talker 为空则列全部
+ (NSString *)digestListForTalker:(NSString *)talker limit:(NSInteger)limit;

/// 某个会话里还没分析过的链接数（供命令提示）
+ (NSUInteger)pendingCountForTalker:(NSString *)talker;

+ (BOOL)enabled;
+ (NSString *)mode;
+ (void)setEnabled:(BOOL)on;
+ (void)setMode:(NSString *)mode;
+ (void)setAnalyzeOnReceive:(BOOL)on;
+ (BOOL)analyzeOnReceive;

@end
