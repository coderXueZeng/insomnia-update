#import <Foundation/Foundation.h>

@interface InsSend : NSObject

/// 逐步检查微信内部发送链路，结果通过回调返回
+ (void)diagnoseForTalker:(NSString *)talker completion:(void (^)(NSString *report))done;

/// 走微信自己的发送通道把文本送回指定会话
+ (void)sendText:(NSString *)text toTalker:(NSString *)talker completion:(void (^)(BOOL ok))done;

/// 直接发送失败（目标会话没开着）时，拉起微信、跳到该会话再发一次
+ (void)sendTextAfterNavigating:(NSString *)text
                       toTalker:(NSString *)talker
                       chatName:(NSString *)chatName
                     completion:(void (^)(BOOL ok))done;

/// 会话在通讯录里显示的名字（跳转搜索用），查不到返回 nil
+ (NSString *)displayNameForTalker:(NSString *)talker;

/// 目标会话当前是否已经打开（必须在非主线程调用）
+ (BOOL)isChatOpen:(NSString *)talker;

/// 会话没打开时，用会话列表或搜索点进去（必须在非主线程调用）
+ (BOOL)openChatNamed:(NSString *)chatName;

/// 用微信内部接口（MMMsgLogicManager）直接打开某个会话，不依赖屏幕模拟；
/// 任意线程可调用，内部会切到主线程并把界面等到就绪
+ (BOOL)openChatInProcess:(NSString *)talker;

/// 代发体检：把「联系人解析 / 内部接口是否存在 / 打开会话结果 / 8090 是否在听」逐项报出来
+ (NSString *)openDiagnosis:(NSString *)talker;

/// 列出微信内部带 Send 的方法（找「不用切界面也能发」的直发接口用）
+ (NSString *)capabilityReport;

/// 把图片存进相册并走微信自己的发图通道送回指定会话；会话没打开时先跳转
+ (void)sendImageData:(NSData *)image
             toTalker:(NSString *)talker
             chatName:(NSString *)chatName
           completion:(void (^)(NSString *failure))done;

@end
