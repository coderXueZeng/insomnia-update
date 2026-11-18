#import <Foundation/Foundation.h>

@interface InsGen : NSObject

/// 驱动手机上的 ChatGPT 生成图片，成功后返回图片字节和设备上的源文件路径。
/// continuation=YES 时不点「新聊天」，而是接着上一张图的会话继续问（优化/修改类需求）
+ (void)generateImage:(NSString *)prompt
         continuation:(BOOL)continuation
           completion:(void (^)(NSData *image, NSString *devicePath, NSError *error))done;

/// 上一次成功发出去的提示词；本次进程还没生过图则为 nil
+ (NSString *)lastPrompt;

/// 进程被杀后重启的恢复路径：提示词早已发出，不驱动 ChatGPT，直接等缓存里出现
/// mtime 晚于 since 的新图（通常是上次没来得及取走的图）
+ (void)resumeImage:(NSString *)prompt
              since:(long long)startedAt
         completion:(void (^)(NSData *image, NSString *devicePath, NSError *error))done;

/// 探测 MCP 通道是否可用
+ (BOOL)available;

/// 是否正有一条生图任务在跑（并发请求会互相踩 ChatGPT 的输入框，需要先挡住）
+ (BOOL)isGenerating;

/// 结束后台保活（图片发完之后调用）
+ (void)stopAlive;

@end
