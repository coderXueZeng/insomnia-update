#import <Foundation/Foundation.h>

@interface InsConfig : NSObject

@property (class, readonly, nonatomic) InsConfig *shared;

@property (nonatomic, assign) BOOL enabled;
@property (nonatomic, copy) NSString *baseURL;
@property (nonatomic, copy) NSString *apiKey;
/// 备用通道：主 Key 失效（401/402/403、分组被删）时自动顶上；留空则不启用
@property (nonatomic, copy) NSString *baseURL2;
@property (nonatomic, copy) NSString *apiKey2;
/// 备用通道的模型名；留空则沿用 chatModel
@property (nonatomic, copy) NSString *chatModel2;
@property (nonatomic, copy) NSString *chatModel;
@property (nonatomic, copy) NSString *persona;
@property (nonatomic, copy) NSString *trigger;
@property (nonatomic, copy) NSString *selfWxid;
/// 叙述里怎么称呼微信账号主人（可填对方对自己的称呼）；留空＝「你」
@property (nonatomic, copy) NSString *selfAlias;
/// 除自己之外还允许谁用 @insomnia 下命令：填联系人的备注/昵称或 wxid（群聊按发言人的备注/昵称匹配），填 "*" 表示所有人
@property (nonatomic, copy) NSArray<NSString *> *allowTriggersFrom;
@property (nonatomic, copy) NSArray<NSString *> *sendSelectors;
@property (nonatomic, assign) NSInteger contextMessages;
@property (nonatomic, assign) NSInteger chunkSize;
@property (nonatomic, assign) NSInteger maxChunkCalls;
/// 大体量回填：每个分段的条数与并发路数（默认 500 条 × 3 路）
@property (nonatomic, assign) NSInteger syncChunkSize;
@property (nonatomic, assign) NSInteger syncConcurrency;
/// 历史条数超过这个值就走「先抽要点、再少量合并」的回填模式（默认 2000）
@property (nonatomic, assign) NSInteger syncBulkThreshold;
/// 回填模式一次 sync 最多跑多少轮（每轮 = 并发路数 × 分段条数）
@property (nonatomic, assign) NSInteger syncBulkRounds;

// 文生图（驱动本机 ChatGPT App）
@property (nonatomic, assign) BOOL imageEnabled;
@property (nonatomic, copy) NSString *mcpURL;
@property (nonatomic, copy) NSString *chatgptBundle;
@property (nonatomic, copy) NSString *chatGptInputHint;
@property (nonatomic, copy) NSString *kfCacheSubpath;
@property (nonatomic, assign) NSInteger genTimeout;
@property (nonatomic, assign) long long minImageBytes;
@property (nonatomic, copy) NSArray<NSString *> *imageKeywords;
/// 命中这些短语的请求会接着上一张图的 ChatGPT 会话继续问（优化/修改类），而不是开新会话
@property (nonatomic, copy) NSArray<NSString *> *continuePhrases;
/// 只要消息里包含这些短语就按生图处理（如「生成一张」「画一张」），并把短语之前的前缀去掉
@property (nonatomic, copy) NSArray<NSString *> *imagePhrases;
/// 开始生图时回执的那句话，%@ 处填图片描述；留空则不发提示，静默生图
@property (nonatomic, copy) NSString *imageAck;

// 语音（Breeze TTS：文字转语音，再走微信自己的录音通道发成语音条）
/// Breeze 的 API Key（xi-api-key），只放在设备 config.json 里
/// 可以在一个字段里用逗号/空格写多个 Key，会按顺序当备用池用
@property (nonatomic, copy) NSString *voiceApiKey;
/// 备用语音 Key：voiceApiKey 不通（401/402/403/429）时自动顶上，可同样写多个；留空不启用
@property (nonatomic, copy) NSString *voiceApiKey2;
@property (nonatomic, copy) NSString *voiceBaseURL;
@property (nonatomic, copy) NSString *voiceId;
@property (nonatomic, copy) NSString *voiceModel;
/// 语气/演绎指令（例如「说话懒散一点，尾音上扬」）
@property (nonatomic, copy) NSString *voiceInstructions;
/// 唱歌演绎指令（「唱歌 <…>」合成时用；例如「温柔的民谣唱腔，节奏舒缓」）
@property (nonatomic, copy) NSString *singInstructions;
/// Mac 翻唱服务地址（http://192.168.x.x:8777），空则点歌走 TTS 直唱
@property (nonatomic, copy) NSString *coverURL;
/// 单条语音最长秒数（微信上限 60）
@property (nonatomic, assign) NSInteger voiceMaxSeconds;
/// YES = 问答回复自动转成语音条发出去
@property (nonatomic, assign) BOOL voiceAuto;

// 多模态理解（看图/看链接，独立于聊天模型）
@property (nonatomic, copy) NSString *visionBaseURL;
@property (nonatomic, copy) NSString *visionApiKey;
@property (nonatomic, copy) NSString *visionModel;
@property (nonatomic, copy) NSArray<NSString *> *visionImageWords;
@property (nonatomic, copy) NSArray<NSString *> *visionLinkWords;

// 自动链接分析（点进会话就分析对方发来的链接）
/// 总开关：默认开，点进会话时最多分析 autoLinkMaxPerOpen 条没看过的链接
@property (nonatomic, assign) BOOL autoLinkEnabled;
/// quiet = 只存本地（默认）；forward = 发到文件传输助手；reply = 直接回在当前会话
@property (nonatomic, copy) NSString *autoLinkMode;
/// YES = 收到对方链接卡片就立刻后台分析，不等你点进去
@property (nonatomic, assign) BOOL autoLinkOnReceive;
/// 每次进会话最多分析几条（默认 2）
@property (nonatomic, assign) NSInteger autoLinkMaxPerOpen;
/// 全局每小时最多分析几条，防额度被刷（默认 20）
@property (nonatomic, assign) NSInteger autoLinkMaxPerHour;
/// 只分析最近多少小时内收到的链接（默认 72 小时）
@property (nonatomic, assign) NSInteger autoLinkWindowHours;

// 表情包斗图（对方发来表情包时自动回一张我的收藏表情）
@property (nonatomic, assign) BOOL stickerBattleEnabled;
/// 成语接龙游戏总开关：YES = 允许开局（默认），NO = 发「成语接龙」也不开局
@property (nonatomic, assign) BOOL gameEnabled;
/// auto = 先走微信表情面板，失败再用表情库图片兜底；board = 只走面板；image = 只发图片
@property (nonatomic, copy) NSString *stickerBattleMode;
/// 同一会话两次自动斗图的最小间隔（秒）
@property (nonatomic, assign) NSInteger stickerBattleCooldown;
/// 同一会话一分钟内最多自动回几张，防止对方连发表情时刷屏
@property (nonatomic, assign) NSInteger stickerBattleMaxPerMinute;

// 回复送达：真发不出去时怎么处理
/// YES = 允许在本地插一条假消息（只有你这边能看到，对方永远收不到）；默认 NO，只进重发队列
@property (nonatomic, assign) BOOL allowLocalEcho;

// 自更新（@insomnia update）
@property (nonatomic, copy) NSString *updateManifest;
/// 只放在设备 config.json 里，源码/仓库中永远为空
@property (nonatomic, copy) NSString *sudoPassword;

- (void)reload;
- (void)save;
/// 只改 config.json 里的单个键，避免 save() 覆盖部署脚本/用户注入的其他字段
/// 返回 NO 表示主文件与备份都不可读，调用方必须放弃写入（否则会把 Key/密码清空）
- (BOOL)setConfigKey:(NSString *)key value:(id)value;
- (void)setConfigKeysPersisted:(NSDictionary *)pairs;
- (void)setSelfAliasPersisted:(NSString *)alias;
- (void)setStickerBattleEnabledPersisted:(BOOL)on;
- (void)setGameEnabledPersisted:(BOOL)on;
- (void)setStickerBattleModePersisted:(NSString *)mode;
/// 手机端自救：设置聊天 Key、从备份恢复、一键导入配置、查看诊断
- (void)setApiKeyPersisted:(NSString *)key;
- (BOOL)restoreFromBackup;
- (NSUInteger)applySetupDictionary:(NSDictionary *)pairs;
+ (NSString *)rootDir;
+ (NSString *)backupPath;
+ (NSString *)logPath;
+ (NSString *)diagnostics;
+ (void)log:(NSString *)line;

@end
