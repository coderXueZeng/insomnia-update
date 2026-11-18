#import "InsConfig.h"
#import <os/log.h>

static InsConfig *gInsConfig = nil;

/// 公开的版本清单入口：不是秘密，写死在代码里，config.json 被清空后 update 仍能用
static NSString * const kInsDefaultManifest =
    @"https://github.com/coderXueZeng/insomnia-update/releases/latest/download/latest.json";

/// 配置备份放 Library/Caches，与 Documents/Insomnia 分离：
/// 即使 Documents 整个被重建（微信重装、沙箱迁移、锁屏时文件被覆盖），备份还在。
static NSString *InsCBackupPath(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [caches stringByAppendingPathComponent:@"Insomnia"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"config.backup.json"];
}

/// 锁屏时带 Complete 保护的文件读不到。写成 None，后台冷启动也能读到配置。
static void InsCUnprotect(NSString *path) {
    if (!path.length) return;
    [[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone}
                                     ofItemAtPath:path error:nil];
}

static NSDictionary *InsCRead(NSString *path) {
    NSData *raw = [NSData dataWithContentsOfFile:path];
    if (!raw.length) return nil;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
    return [d isKindOfClass:[NSDictionary class]] ? d : nil;
}

static BOOL InsCWrite(NSDictionary *dict, NSString *path) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:nil];
    if (!data.length) return NO;
    BOOL ok = [data writeToFile:path atomically:YES];
    if (ok) InsCUnprotect(path);
    return ok;
}

@interface InsConfig ()
- (BOOL)setConfigKey:(NSString *)key value:(id)value;
@end

@implementation InsConfig

+ (InsConfig *)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gInsConfig = [[InsConfig alloc] init];
        [gInsConfig reload];
    });
    return gInsConfig;
}

+ (NSString *)rootDir {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *root = [docs stringByAppendingPathComponent:@"Insomnia"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:root]) {
        [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"memory"]
      withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return root;
}

+ (NSString *)configPath {
    return [[self rootDir] stringByAppendingPathComponent:@"config.json"];
}

+ (NSString *)backupPath {
    return InsCBackupPath();
}

+ (NSString *)logPath {
    return [[self rootDir] stringByAppendingPathComponent:@"log.txt"];
}

+ (void)log:(NSString *)line {
    NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                     dateStyle:NSDateFormatterShortStyle
                                                     timeStyle:NSDateFormatterMediumStyle];
    // 一条日志压成一行：以前 help 这类含换行的回复会把 log.txt 拆成多行、还丢掉时间戳
    NSString *flat = [[line componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
                      componentsJoinedByString:@" | "];
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", stamp, flat];
    os_log(OS_LOG_DEFAULT, "Insomnia: %{public}@", flat);
    NSString *path = [self logPath];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [entry writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
    NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if ([attr fileSize] > 1024 * 1024) {
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        // 只留最后 4000 字会把半小时前的记录全裁掉：回头查「别人 @ 了为什么没反应」
        // 时日志里啥都没有，只能靠猜。留 60000 字（约 500 行）够覆盖一段时间。
        if (text.length > 60000) {
            NSString *tail = [text substringFromIndex:text.length - 60000];
            [tail writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        }
    }
}

- (instancetype)init {
    if ((self = [super init])) {
        _enabled = YES;
        _baseURL = @"https://api.api2cn.com/v1";
        _apiKey = @"";
        _baseURL2 = @"";
        _apiKey2 = @"";
        _chatModel2 = @"";
        _voiceApiKey = @"";
        _voiceApiKey2 = @"";
        _voiceBaseURL = @"https://api.breeze.blue";
        _voiceId = @"voc_u3nxkd5578wc";
        _voiceModel = @"breeze-tts-2";
        _voiceInstructions = @"";
        _singInstructions = @"";
        _coverURL = @"";
        _voiceMaxSeconds = 45;
        _voiceAuto = NO;
        _chatModel = @"deepseek-v4.1-flash-1017";
        _persona = @"你是微信账号主人的聊天助手，以第三人称叙述聊天内容，用自然口语回复，简短、贴合上下文。";
        _trigger = @"@insomnia";
        _selfWxid = @"";
        _selfAlias = @"";
        _allowTriggersFrom = @[];
        _sendSelectors = @[];
        _allowLocalEcho = NO;
        // 自动看链接：点进对方会话时顺手把最近没看过的链接读一遍，结果只存本地，不打扰聊天
        _autoLinkEnabled = YES;
        _autoLinkMode = @"quiet";
        _autoLinkOnReceive = NO;
        _autoLinkMaxPerOpen = 2;
        _autoLinkMaxPerHour = 20;
        _autoLinkWindowHours = 72;
        _contextMessages = 20;
        _chunkSize = 120;
        _maxChunkCalls = 40;
        _syncChunkSize = 500;
        _syncConcurrency = 3;
        _syncBulkThreshold = 2000;
        _syncBulkRounds = 60;
        _imageEnabled = YES;
        _mcpURL = @"http://127.0.0.1:8090/mcp";
        _chatgptBundle = @"com.openai.chat";
        _chatGptInputHint = @"询问 ChatGPT";
        _kfCacheSubpath = @"Library/Caches/com.onevcat.Kingfisher.ImageCache.default";
        _genTimeout = 120;
        _minImageBytes = 200000;
        _imageKeywords = @[@"img", @"画", @"生图", @"生成图", @"出图"];
        _imagePhrases = @[@"生成一张", @"画一张", @"来一张", @"做一张", @"画个", @"生成个"];
        _continuePhrases = @[@"优化", @"修改", @"调整", @"改成", @"换成", @"变成", @"重新", @"重画", @"再画", @"加上", @"去掉", @"删掉", @"换掉", @"改一下", @"变一下"];
        _imageAck = @"收到，开始生图：%@";
        _visionBaseURL = @"https://api.xiaomimimo.com/v1";
        _visionApiKey = @"";
        _visionModel = @"mimo-v2.6-flash";
        _visionImageWords = @[@"看图", @"看图片", @"看看图", @"分析图", @"这张图"];
        _visionLinkWords = @[@"看链接", @"看看链接", @"分析链接", @"总结链接", @"这链接"];
        // 斗图默认关，必须显式开，避免刚升级就自己给别人发表情
        _stickerBattleEnabled = NO;
        _gameEnabled = YES;
        _stickerBattleMode = @"auto";
        _stickerBattleCooldown = 8;
        _stickerBattleMaxPerMinute = 4;
        // 清单地址属于公开信息，内置默认值：config.json 被清空后 update 也不会失灵
        _updateManifest = kInsDefaultManifest;
        _sudoPassword = @"";
    }
    return self;
}

- (void)reload {
    NSString *path = [[self class] configPath];
    NSString *backup = [[self class] backupPath];
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    NSDictionary *dict = InsCRead(path);

    // 主文件读不到/损坏时先从备份恢复，而不是直接写一份默认配置
    if (!dict) {
        NSDictionary *bk = InsCRead(backup);
        if (bk) {
            dict = bk;
            if (InsCWrite(bk, path))
                [[self class] log:@"config.json 缺失/损坏，已从 Library/Caches 备份恢复"];
            else
                [[self class] log:@"已从备份读取配置，但写回 config.json 失败；本次内存仍用备份值"];
        }
    }
    if (!dict) {
        if (exists) {
            // 锁屏 + 数据保护：文件明明还在，只是这一刻读不到。
            // 老版本在这里会用默认值 save() 覆盖，把 apiKey/密码/清单全部清空 —— 正是「Key 未配置」的根因。
            [[self class] log:@"config.json 存在但暂时不可读且无备份：本次用内存默认值，绝不覆盖磁盘"];
        } else {
            [[self class] log:@"config.json 不存在，写入默认配置（清单地址已内置）"];
            [self save];
        }
        return;
    }
#define INS_STR(key, prop) if ([dict[key] isKindOfClass:[NSString class]]) self.prop = dict[key];
#define INS_NUM(key, prop) if ([dict[key] isKindOfClass:[NSNumber class]]) self.prop = [dict[key] integerValue];
    INS_NUM(@"enabled", enabled)
    INS_STR(@"baseURL", baseURL)
    INS_STR(@"apiKey", apiKey)
    INS_STR(@"baseURL2", baseURL2)
    INS_STR(@"apiKey2", apiKey2)
    INS_STR(@"chatModel2", chatModel2)
    INS_STR(@"voiceApiKey", voiceApiKey)
    INS_STR(@"voiceApiKey2", voiceApiKey2)
    INS_STR(@"voiceBaseURL", voiceBaseURL)
    INS_STR(@"voiceId", voiceId)
    INS_STR(@"voiceModel", voiceModel)
    INS_STR(@"voiceInstructions", voiceInstructions)
    INS_STR(@"singInstructions", singInstructions)
    INS_STR(@"coverURL", coverURL)
    INS_NUM(@"voiceMaxSeconds", voiceMaxSeconds)
    if ([dict[@"voiceAuto"] isKindOfClass:[NSNumber class]]) self.voiceAuto = [dict[@"voiceAuto"] boolValue];
    INS_STR(@"chatModel", chatModel)
    INS_STR(@"persona", persona)
    INS_STR(@"trigger", trigger)
    INS_STR(@"selfWxid", selfWxid)
    INS_STR(@"selfAlias", selfAlias)
    if ([dict[@"allowTriggersFrom"] isKindOfClass:[NSArray class]]) self.allowTriggersFrom = dict[@"allowTriggersFrom"];
    INS_NUM(@"contextMessages", contextMessages)
    INS_NUM(@"chunkSize", chunkSize)
    INS_NUM(@"maxChunkCalls", maxChunkCalls)
    INS_NUM(@"syncChunkSize", syncChunkSize)
    INS_NUM(@"syncConcurrency", syncConcurrency)
    INS_NUM(@"syncBulkThreshold", syncBulkThreshold)
    INS_NUM(@"syncBulkRounds", syncBulkRounds)
    if ([dict[@"sendSelectors"] isKindOfClass:[NSArray class]]) self.sendSelectors = dict[@"sendSelectors"];
    INS_NUM(@"imageEnabled", imageEnabled)
    INS_STR(@"mcpURL", mcpURL)
    INS_STR(@"chatgptBundle", chatgptBundle)
    INS_STR(@"chatGptInputHint", chatGptInputHint)
    INS_STR(@"kfCacheSubpath", kfCacheSubpath)
    INS_NUM(@"genTimeout", genTimeout)
    INS_NUM(@"minImageBytes", minImageBytes)
    if ([dict[@"imageKeywords"] isKindOfClass:[NSArray class]]) self.imageKeywords = dict[@"imageKeywords"];
    if ([dict[@"imagePhrases"] isKindOfClass:[NSArray class]]) self.imagePhrases = dict[@"imagePhrases"];
    if ([dict[@"continuePhrases"] isKindOfClass:[NSArray class]]) self.continuePhrases = dict[@"continuePhrases"];
    INS_STR(@"imageAck", imageAck)
    INS_STR(@"visionBaseURL", visionBaseURL)
    INS_STR(@"visionApiKey", visionApiKey)
    INS_STR(@"visionModel", visionModel)
    if ([dict[@"visionImageWords"] isKindOfClass:[NSArray class]]) self.visionImageWords = dict[@"visionImageWords"];
    if ([dict[@"visionLinkWords"] isKindOfClass:[NSArray class]]) self.visionLinkWords = dict[@"visionLinkWords"];
    // 布尔值在 JSON 里可能是 true/false，也可能是 0/1，两种都认
    if ([dict[@"stickerBattleEnabled"] isKindOfClass:[NSNumber class]]) self.stickerBattleEnabled = [dict[@"stickerBattleEnabled"] boolValue];
    if ([dict[@"gameEnabled"] isKindOfClass:[NSNumber class]]) self.gameEnabled = [dict[@"gameEnabled"] boolValue];
    if ([dict[@"allowLocalEcho"] isKindOfClass:[NSNumber class]]) self.allowLocalEcho = [dict[@"allowLocalEcho"] boolValue];
    INS_STR(@"stickerBattleMode", stickerBattleMode)
    INS_NUM(@"stickerBattleCooldown", stickerBattleCooldown)
    INS_NUM(@"stickerBattleMaxPerMinute", stickerBattleMaxPerMinute)
    INS_NUM(@"autoLinkEnabled", autoLinkEnabled)
    INS_STR(@"autoLinkMode", autoLinkMode)
    INS_NUM(@"autoLinkOnReceive", autoLinkOnReceive)
    INS_NUM(@"autoLinkMaxPerOpen", autoLinkMaxPerOpen)
    INS_NUM(@"autoLinkMaxPerHour", autoLinkMaxPerHour)
    INS_NUM(@"autoLinkWindowHours", autoLinkWindowHours)
    INS_STR(@"updateManifest", updateManifest)
    INS_STR(@"sudoPassword", sudoPassword)
#undef INS_STR
#undef INS_NUM

    // 关键字段自愈：主文件里被清空的凭据，只要备份还在就补回来
    NSDictionary *bk = InsCRead(backup);
    NSMutableDictionary *heal = [NSMutableDictionary dictionary];
    NSArray *guarded = @[@"apiKey", @"apiKey2", @"visionApiKey", @"voiceApiKey", @"voiceApiKey2", @"sudoPassword", @"updateManifest",
                         @"voiceBaseURL", @"voiceId", @"voiceModel",
                         @"baseURL", @"baseURL2", @"chatModel", @"chatModel2",
                         @"visionBaseURL", @"visionModel", @"selfAlias"];
    for (NSString *k in guarded) {
        NSString *cur = [self valueForKey:k];
        if (![cur isKindOfClass:[NSString class]]) cur = @"";
        NSString *saved = [bk[k] isKindOfClass:[NSString class]] ? bk[k] : @"";
        if (!cur.length && saved.length) {
            heal[k] = saved;
            [self setValue:saved forKey:k];
        }
    }
    // 清单地址是公开的，即使没有备份也要补回，否则「@insomnia update」彻底断掉
    NSString *onDiskManifest = [dict[@"updateManifest"] isKindOfClass:[NSString class]] ? dict[@"updateManifest"] : @"";
    if (!onDiskManifest.length) {
        heal[@"updateManifest"] = kInsDefaultManifest;
        self.updateManifest = kInsDefaultManifest;
    }
    if (heal.count) {
        [self setConfigKeysPersisted:heal];
        [[self class] log:[NSString stringWithFormat:@"配置自愈：补回 %@",
                           [heal.allKeys componentsJoinedByString:@", "]]];
    }
    // 每次成功加载都刷新备份（只写备份，不动主文件）
    InsCWrite(dict, backup);
}

/// 手机端一键恢复：把 setup 字典合并进现有配置，返回写入的字段数
- (NSUInteger)applySetupDictionary:(NSDictionary *)pairs {
    if (![pairs isKindOfClass:[NSDictionary class]] || !pairs.count) return 0;
    NSArray *allowed = @[@"apiKey", @"apiKey2", @"baseURL2", @"chatModel2",
                         @"voiceApiKey", @"voiceApiKey2", @"voiceBaseURL", @"voiceId", @"voiceModel", @"voiceInstructions",
                         @"visionApiKey", @"visionBaseURL", @"visionModel",
                         @"baseURL", @"chatModel", @"persona", @"trigger", @"selfAlias",
                         @"sudoPassword", @"updateManifest", @"mcpURL"];
    NSMutableDictionary *clean = [NSMutableDictionary dictionary];
    for (NSString *k in pairs) {
        if (![allowed containsObject:k]) continue;
        id v = pairs[k];
        if ([v isKindOfClass:[NSString class]] && [v length]) clean[k] = v;
    }
    if (!clean.count) return 0;
    [self setConfigKeysPersisted:clean];
    [self reload];
    [[self class] log:[NSString stringWithFormat:@"setup 导入 %lu 个配置字段（不含明文值）",
                       (unsigned long)clean.count]];
    return clean.count;
}

/// 只动一个键：config.json 里还有 apiKey / sudoPassword / updateManifest 等。
/// 关键：主文件读不到时必须从备份续写，绝不能拿空字典写回去 —— 那会把整份配置清空。
- (BOOL)setConfigKey:(NSString *)key value:(id)value {
    NSString *path = [[self class] configPath];
    NSString *backup = [[self class] backupPath];
    NSMutableDictionary *dict = [InsCRead(path) mutableCopy];
    if (![dict isKindOfClass:[NSMutableDictionary class]]) {
        NSDictionary *bk = InsCRead(backup);
        if ([bk isKindOfClass:[NSDictionary class]]) {
            dict = [bk mutableCopy];
            [[self class] log:@"config.json 不可读，单键写入改从备份续写"];
        }
    }
    if (![dict isKindOfClass:[NSMutableDictionary class]]) {
        [[self class] log:@"拒绝写入配置：主文件与备份都不可读，避免把 Key/密码/清单清空"];
        return NO;
    }
    // 最后一道防线：备份里有、当前字典里没有的凭据，先并回来再写
    NSDictionary *bk = InsCRead(backup);
    for (NSString *k in @[@"apiKey", @"visionApiKey", @"sudoPassword", @"updateManifest"]) {
        NSString *saved = [bk[k] isKindOfClass:[NSString class]] ? bk[k] : @"";
        NSString *cur = [dict[k] isKindOfClass:[NSString class]] ? dict[k] : @"";
        if (saved.length && !cur.length) dict[k] = saved;
    }
    dict[key] = value ?: @"";
    if (!InsCWrite(dict, path)) {
        [[self class] log:@"config.json 写入失败"];
        return NO;
    }
    InsCWrite(dict, backup);
    return YES;
}

- (void)setConfigKeysPersisted:(NSDictionary *)pairs {
    for (NSString *k in pairs) [self setConfigKey:k value:pairs[k]];
}

- (void)setSelfAliasPersisted:(NSString *)alias {
    NSString *value = [alias isKindOfClass:[NSString class]] ? alias : @"";
    self.selfAlias = value;
    [self setConfigKey:@"selfAlias" value:value];
    [[self class] log:[NSString stringWithFormat:@"叙述口径：账号主人=%@", value.length ? value : @"你"]];
}

- (void)setStickerBattleEnabledPersisted:(BOOL)on {
    self.stickerBattleEnabled = on;
    [self setConfigKey:@"stickerBattleEnabled" value:@(on)];
    [[self class] log:[NSString stringWithFormat:@"斗图开关：%@", on ? @"开" : @"关"]];
}

- (void)setGameEnabledPersisted:(BOOL)on {
    self.gameEnabled = on;
    [self setConfigKey:@"gameEnabled" value:@(on)];
    [[self class] log:[NSString stringWithFormat:@"成语接龙开关：%@", on ? @"开" : @"关"]];
}

- (void)setStickerBattleModePersisted:(NSString *)mode {
    NSString *value = [[mode lowercaseString] stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (![@[@"auto", @"board", @"image"] containsObject:value]) value = @"auto";
    self.stickerBattleMode = value;
    [self setConfigKey:@"stickerBattleMode" value:value];
    [[self class] log:[NSString stringWithFormat:@"斗图模式：%@", value]];
}

- (void)setApiKeyPersisted:(NSString *)key {
    NSString *value = [[key stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
    self.apiKey = value;
    BOOL ok = [self setConfigKey:@"apiKey" value:value];
    // 绝不把 Key 明文写进日志/交接包
    [[self class] log:[NSString stringWithFormat:@"聊天 Key %@（长度 %lu，写入 %@）",
                       value.length ? @"已设置" : @"已清空",
                       (unsigned long)value.length, ok ? @"成功" : @"失败"]];
}

/// 从备份把缺失的关键字段补回主文件；返回是否真的补了东西
- (BOOL)restoreFromBackup {
    NSDictionary *bk = InsCRead([[self class] backupPath]);
    if (!bk) return NO;
    NSMutableDictionary *heal = [NSMutableDictionary dictionary];
    NSArray *keys = @[@"apiKey", @"visionApiKey", @"sudoPassword", @"updateManifest",
                      @"baseURL", @"chatModel", @"visionBaseURL", @"visionModel", @"selfAlias", @"trigger"];
    for (NSString *k in keys) {
        NSString *cur = [self valueForKey:k];
        if (![cur isKindOfClass:[NSString class]]) cur = @"";
        NSString *saved = [bk[k] isKindOfClass:[NSString class]] ? bk[k] : @"";
        if (!cur.length && saved.length) heal[k] = saved;
    }
    if (!heal.count) return NO;
    [self setConfigKeysPersisted:heal];
    [self reload];
    [[self class] log:[NSString stringWithFormat:@"从备份恢复：%@",
                       [heal.allKeys componentsJoinedByString:@", "]]];
    return YES;
}

+ (NSString *)diagnostics {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = [self configPath];
    NSString *backup = [self backupPath];
    NSDictionary *d = InsCRead(path);
    NSDictionary *b = InsCRead(backup);
    NSString * (^desc)(NSString *) = ^NSString * (NSString *p) {
        NSDictionary *a = [fm attributesOfItemAtPath:p error:nil];
        return a ? [NSString stringWithFormat:@"存在 %lldB", (long long)[a fileSize]] : @"不存在";
    };
    NSString *memDir = [[self rootDir] stringByAppendingPathComponent:@"memory"];
    NSUInteger memCount = 0;
    for (NSString *f in [fm contentsOfDirectoryAtPath:memDir error:nil] ?: @[]) {
        if ([f hasSuffix:@".json"]) memCount++;
    }
    InsConfig *c = [self shared];
    return [NSString stringWithFormat:
        @"===== 配置诊断 =====\n"
        @"主文件 %@\n  %@ / 字段 %lu / 解析 %@\n"
        @"备份 %@\n  %@ / 字段 %lu\n"
        @"聊天 Key %@（备份 %@）/ 视觉 Key %@ / sudoPassword %@ / 清单 %@\n"
        @"接口 %@ / 模型 %@ / 触发词 %@\n"
        @"记忆文件 %lu 个\n"
        @"修法：恢复配置 从备份补；key <Key> 重设聊天 Key；setup <串> 一次补齐",
        path, desc(path), (unsigned long)d.count, d ? @"成功" : @"失败",
        backup, desc(backup), (unsigned long)b.count,
        c.apiKey.length ? @"有" : @"无",
        ([b[@"apiKey"] isKindOfClass:[NSString class]] && [b[@"apiKey"] length]) ? @"有" : @"无",
        c.visionApiKey.length ? @"有" : @"无",
        c.sudoPassword.length ? @"有" : @"无",
        c.updateManifest.length ? @"有" : @"无",
        c.baseURL, c.chatModel, c.trigger,
        (unsigned long)memCount];
}

- (void)save {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"enabled"] = @(self.enabled);
    dict[@"baseURL"] = self.baseURL;
    dict[@"apiKey"] = self.apiKey;
    dict[@"baseURL2"] = self.baseURL2 ?: @"";
    dict[@"apiKey2"] = self.apiKey2 ?: @"";
    dict[@"chatModel2"] = self.chatModel2 ?: @"";
    dict[@"voiceApiKey"] = self.voiceApiKey ?: @"";
    dict[@"voiceApiKey2"] = self.voiceApiKey2 ?: @"";
    dict[@"voiceBaseURL"] = self.voiceBaseURL ?: @"";
    dict[@"voiceId"] = self.voiceId ?: @"";
    dict[@"voiceModel"] = self.voiceModel ?: @"";
    dict[@"voiceInstructions"] = self.voiceInstructions ?: @"";
    dict[@"singInstructions"] = self.singInstructions ?: @"";
    dict[@"coverURL"] = self.coverURL ?: @"";
    dict[@"voiceMaxSeconds"] = @(self.voiceMaxSeconds);
    dict[@"voiceAuto"] = @(self.voiceAuto);
    dict[@"chatModel"] = self.chatModel;
    dict[@"persona"] = self.persona;
    dict[@"trigger"] = self.trigger;
    dict[@"selfWxid"] = self.selfWxid;
    dict[@"selfAlias"] = self.selfAlias ?: @"";
    dict[@"allowTriggersFrom"] = self.allowTriggersFrom;
    dict[@"sendSelectors"] = self.sendSelectors;
    dict[@"allowLocalEcho"] = @(self.allowLocalEcho);
    dict[@"contextMessages"] = @(self.contextMessages);
    dict[@"chunkSize"] = @(self.chunkSize);
    dict[@"maxChunkCalls"] = @(self.maxChunkCalls);
    dict[@"syncChunkSize"] = @(self.syncChunkSize);
    dict[@"syncConcurrency"] = @(self.syncConcurrency);
    dict[@"syncBulkThreshold"] = @(self.syncBulkThreshold);
    dict[@"syncBulkRounds"] = @(self.syncBulkRounds);
    dict[@"imageEnabled"] = @(self.imageEnabled);
    dict[@"mcpURL"] = self.mcpURL;
    dict[@"chatgptBundle"] = self.chatgptBundle;
    dict[@"chatGptInputHint"] = self.chatGptInputHint;
    dict[@"kfCacheSubpath"] = self.kfCacheSubpath;
    dict[@"genTimeout"] = @(self.genTimeout);
    dict[@"minImageBytes"] = @(self.minImageBytes);
    dict[@"imageKeywords"] = self.imageKeywords;
    dict[@"imagePhrases"] = self.imagePhrases;
    dict[@"continuePhrases"] = self.continuePhrases;
    dict[@"imageAck"] = self.imageAck;
    dict[@"visionBaseURL"] = self.visionBaseURL;
    dict[@"visionApiKey"] = self.visionApiKey;
    dict[@"visionModel"] = self.visionModel;
    dict[@"visionImageWords"] = self.visionImageWords;
    dict[@"visionLinkWords"] = self.visionLinkWords;
    dict[@"stickerBattleEnabled"] = @(self.stickerBattleEnabled);
    dict[@"gameEnabled"] = @(self.gameEnabled);
    dict[@"stickerBattleMode"] = self.stickerBattleMode ?: @"auto";
    dict[@"stickerBattleCooldown"] = @(self.stickerBattleCooldown);
    dict[@"stickerBattleMaxPerMinute"] = @(self.stickerBattleMaxPerMinute);
    dict[@"autoLinkEnabled"] = @(self.autoLinkEnabled);
    dict[@"autoLinkMode"] = self.autoLinkMode ?: @"quiet";
    dict[@"autoLinkOnReceive"] = @(self.autoLinkOnReceive);
    dict[@"autoLinkMaxPerOpen"] = @(self.autoLinkMaxPerOpen);
    dict[@"autoLinkMaxPerHour"] = @(self.autoLinkMaxPerHour);
    dict[@"autoLinkWindowHours"] = @(self.autoLinkWindowHours);
    dict[@"updateManifest"] = self.updateManifest.length ? self.updateManifest : kInsDefaultManifest;
    dict[@"sudoPassword"] = self.sudoPassword;
    // 最后一道防线：磁盘/备份上已有的凭据，绝不会因为内存里是空值而被写空
    NSString *path = [[self class] configPath];
    NSDictionary *existing = InsCRead(path) ?: InsCRead([[self class] backupPath]);
    for (NSString *k in @[@"apiKey", @"visionApiKey", @"sudoPassword", @"updateManifest",
                          @"baseURL", @"chatModel", @"visionBaseURL", @"visionModel",
                          @"selfAlias", @"trigger", @"persona"]) {
        NSString *cur = [dict[k] isKindOfClass:[NSString class]] ? dict[k] : @"";
        NSString *old = [existing[k] isKindOfClass:[NSString class]] ? existing[k] : @"";
        if (!cur.length && old.length) dict[k] = old;
    }
    if (InsCWrite(dict, path)) InsCWrite(dict, [[self class] backupPath]);
}

@end
