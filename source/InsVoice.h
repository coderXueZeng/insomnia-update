#import <Foundation/Foundation.h>

/// 语音条：Breeze TTS 合成 PCM → 顶替微信录音器的麦克风数据 → 由微信自己编码/上传，
/// 对方收到的是标准语音气泡（可按住听、可转文字），不是音频文件。
@interface InsVoice : NSObject

/// 「语音 <话>」怎么处理
typedef NS_ENUM(NSInteger, InsVoiceAskMode) {
    InsVoiceAskNone = 0,   ///< 不是这条路径（或是参数类命令：体检/声/语气/模式…）
    InsVoiceAskText = 1,   ///< 剥掉「语音」当普通提问，回答用文字
    InsVoiceAskSpeak = 2,  ///< 剥掉「语音」当普通提问，回答念成语音
};

/// 是不是语音命令（语音 <文本> / 语音 试 <文本> / 语音体检 …）
+ (BOOL)handlesPayload:(NSString *)payload;

/// 是不是唱歌请求（唱歌 <歌名/要求> / 唱首… / 语音 唱 <…>）；topicOut 带出要唱什么，可为空
+ (BOOL)singRequestForPayload:(NSString *)payload topic:(NSString *__autoreleasing *)topicOut;

/// 这条点歌是否明确要求「完整版/整首/不要片段」（用于翻唱不做 28 秒截断）
+ (BOOL)singFullRequested:(NSString *)payload;

/// 把歌词用唱歌腔合成语音条发出（复用说话管线，演绎指令换成「演唱」；成功时 reply 收「已发语音…」）
+ (void)singLyrics:(NSString *)lyrics
            talker:(NSString *)talker
            reply:(void (^)(NSString *text))reply;

/// 同上，但这首歌可以带专属唱法（如「周杰伦式的轻柔抒情，副歌渐强」）；style 为空时用全局唱腔
+ (void)singLyrics:(NSString *)lyrics
        instructions:(NSString *)style
              talker:(NSString *)talker
              reply:(void (^)(NSString *text))reply;

/// 把备好的 24k 单声道 int16 裸 PCM 直接发成语音条（翻唱音频等本地来源）
+ (void)sendPCMData:(NSData *)pcm talker:(NSString *)talker
              reply:(void (^)(NSString *text))reply;

/// 完整版长成品：切成多条 <=32 秒串行发（微信单条超 42 秒会崩）
+ (void)sendPCMFull:(NSData *)pcm talker:(NSString *)talker
              reply:(void (^)(NSString *text))reply;

/// 点歌翻唱：调 Mac 翻唱服务（找歌→分离→换音色→合成），拿回 wav 发成语音条。
/// 服务未就绪/失败时 reply 收到错误说明；全程可能需要几分钟
+ (void)singCoverWithSong:(NSString *)song
                      url:(NSString *)baseURL
                   talker:(NSString *)talker
                     full:(BOOL)full
                    reply:(void (^)(NSString *text))reply;

/// 按 job id 取回云端已做好的成品直接发语音（「补成品」命令）：不重新下单、不用等生成
+ (void)resendCoverJob:(NSString *)jobid
                   url:(NSString *)baseURL
                talker:(NSString *)talker
                 reply:(void (^)(NSString *text))reply;

/// 「语音 背一首李白的古诗」不该照读这句话，得先让大模型理解再念回答。
/// 返回 InsVoiceAskSpeak/InsVoiceAskText 时 textOut 是剥掉「语音」之后要问的话；
/// 返回 InsVoiceAskNone 表示照旧交给 handlePayload（照读或参数命令）。
+ (InsVoiceAskMode)askModeForPayload:(NSString *)payload text:(NSString *__autoreleasing *)textOut;

/// 处理语音命令，返回 YES 表示已接管（不会再走大模型）
+ (BOOL)handlePayload:(NSString *)payload
               talker:(NSString *)talker
                owner:(BOOL)owner
                reply:(void (^)(NSString *text))reply;

/// 装上录音器 hook（在 %ctor 里调一次即可，重复调用无副作用）
+ (void)installHook;

/// status 里的一行式状态：Key 池 / 录音 hook / 上次语音结果
+ (NSString *)statusLine;

/// 测key 用：逐把探测语音 Key + 真合成一次
+ (NSString *)keyProbeReport;

/// 问答回复自动转语音（cfg.voiceAuto 打开时用）；失败会回退成文字
+ (BOOL)autoEnabled;
+ (void)sayAnswer:(NSString *)answer talker:(NSString *)talker
          fallback:(void (^)(NSString *text))fallback;

@end
