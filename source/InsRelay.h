#import <Foundation/Foundation.h>

/// 代发（受控转达）：别人给我发「给张鹏发消息说你小子」，由我的账号替他把这句话发给张鹏。
///
/// 安全边界（默认全是收紧的）：
///  1. 必须我本人先授权，授权绑定 wxid。对方改备注、换个同名账号都顶不了位。
///  2. 只认单聊。群聊一律拒绝——群里认不出是谁在借我的号说话。
///  3. 发送前做内容检查：辱骂、威胁、要钱/验证码、链接、二维码、带触发词的，一条都不发。
///  4. 频控：每个授权人每小时 5 条、每天 20 条、两条间隔 ≥ 8 秒；全局每小时 20 条。
///  5. 每条都落审计（谁、发给谁、内容、结果），我可以随时 `代发记录` 查。
@interface InsRelay : NSObject

/// 是否是代发类命令。入口用它决定「没在 allowTriggersFrom 里的人」要不要放进来，
/// 真正的权限判断在 handlePayload: 里做。
+ (BOOL)isRelayPayload:(NSString *)payload;

/// 处理代发命令与授权命令。返回 YES 表示已接管（不会再走大模型）。
/// deliver 由调用方提供，用和普通回复同一条真实发送链路；done 回传是否送达。
+ (BOOL)handlePayload:(NSString *)payload
               talker:(NSString *)talker
           senderName:(NSString *)senderName
                owner:(BOOL)owner
                reply:(void (^)(NSString *text))reply
              deliver:(void (^)(NSString *text, NSString *targetTalker, BOOL allowNavigate,
                                void (^done)(BOOL ok, NSString *how)))deliver;

/// 是否允许为代发跳转会话（关掉后只发已打开的会话，不抢屏）
+ (BOOL)navigateEnabled;

/// 一行状态，给 status 用
+ (NSString *)statusLine;

/// 授权明细（给「授权列表」用）
+ (NSString *)listText;

@end
