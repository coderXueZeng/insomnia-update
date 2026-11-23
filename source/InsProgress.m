#import "InsProgress.h"
#import "InsConfig.h"
#import "InsMemory.h"
#import "InsSticker.h"

static void (^gReply)(NSString *, NSString *) = nil;

#pragma mark - 状态读写

static NSString *InsPStatePath(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [caches stringByAppendingPathComponent:@"Insomnia"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"progress.json"];
}

static NSDictionary *InsPRead(NSString *path) {
    NSData *raw = [NSData dataWithContentsOfFile:path];
    if (!raw.length) return nil;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
    return [d isKindOfClass:[NSDictionary class]] ? d : nil;
}

static void InsPSave(NSDictionary *state) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
    if (!data.length) return;
    NSString *path = InsPStatePath();
    if ([data writeToFile:path atomically:YES]) {
        [[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone}
                                         ofItemAtPath:path error:nil];
    }
}

static NSDictionary *InsPDefaults(void) {
    // 2026-11-23：默认彻底关闭自动汇报。用户要求只有主动触发（进度 现在）才发送。
    // 保留 target=filehelper 仅作为手动触发时的收件目标。
    return @{@"enabled": @NO,
             @"intervalMin": @60,
             @"talker": @"filehelper",
             @"chatName": @"文件传输助手",
             @"lastReportAt": @0,
             @"lastScanned": @0,
             @"lastChunks": @0,
             @"reportsSent": @0};
}

static NSMutableDictionary *InsPState(void) {
    NSMutableDictionary *s = [InsPRead(InsPStatePath()) mutableCopy];
    if (!s) s = [InsPDefaults() mutableCopy];
    NSDictionary *def = InsPDefaults();
    for (NSString *k in def) if (!s[k]) s[k] = def[k];
    NSInteger interval = [s[@"intervalMin"] integerValue];
    if (interval < 5 || interval > 1440) s[@"intervalMin"] = @60;
    NSString *t = [s[@"talker"] isKindOfClass:[NSString class]] ? s[@"talker"] : @"";
    if (!t.length) s[@"talker"] = @"filehelper";
    // 一次性迁移（2026-11-23）：老版本把 enabled 默认写成 YES，光改默认值覆盖不了
    // 手机上已有的 progress.json。打这个标记后强制关一次，之后尊重用户主动设置。
    if (![s[@"manualOnlyV1"] boolValue]) {
        s[@"enabled"] = @NO;
        s[@"manualOnlyV1"] = @YES;
        InsPSave(s);
    }
    return s;
}

static NSString *InsPTime(void) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"MM-dd HH:mm";
    f.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    return [f stringFromDate:[NSDate date]];
}

static NSString *InsPStamp(uint32_t t) {
    if (!t) return @"尚未同步";
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"yyyy-MM-dd HH:mm";
    f.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    return [f stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]];
}

static NSString *InsPVersion(void) {
    for (NSString *path in @[@"/var/jb/var/lib/dpkg/status", @"/var/lib/dpkg/status"]) {
        NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        NSRange hit = [s rangeOfString:@"Package: com.xuezeng.insomnia"];
        if (!s.length || hit.location == NSNotFound) continue;
        NSString *tail = [s substringFromIndex:NSMaxRange(hit)];
        NSRange v = [tail rangeOfString:@"Version: "];
        if (v.location == NSNotFound || v.location > 400) continue;
        NSString *line = [[tail substringFromIndex:NSMaxRange(v)]
                          componentsSeparatedByString:@"\n"].firstObject;
        return line.length ? line : @"未知";
    }
    return @"未知";
}

#pragma mark - 汇报内容

/// 生成汇报文本，并顺手把本次快照写进 state（供下次算增量）
static NSString *InsPBuildReport(NSMutableDictionary *s) {
    InsConfig *cfg = [InsConfig shared];
    NSArray *all = [InsMemory allSummaries];
    NSUInteger scanned = 0, chunks = 0;
    for (NSDictionary *d in all) {
        scanned += [d[@"scanned"] unsignedIntegerValue];
        chunks += [d[@"chunks"] unsignedIntegerValue];
    }
    NSInteger dScanned = (NSInteger)scanned - (NSInteger)[s[@"lastScanned"] unsignedIntegerValue];
    NSInteger dChunks = (NSInteger)chunks - (NSInteger)[s[@"lastChunks"] unsignedIntegerValue];
    s[@"lastScanned"] = @(scanned);
    s[@"lastChunks"] = @(chunks);
    NSNumber *prevReports = [s[@"reportsSent"] isKindOfClass:[NSNumber class]] ? s[@"reportsSent"] : @0;
    s[@"reportsSent"] = @([prevReports unsignedIntegerValue] + 1);

    NSMutableString *t = [NSMutableString string];
    [t appendFormat:@"【Insomnia 同步进度 · %@】\n", InsPTime()];
    if (cfg.apiKey.length) {
        [t appendFormat:@"聊天 Key 已配置 · 模型 %@\n", cfg.chatModel];
    } else {
        [t appendFormat:@"注意：聊天 Key 未配置，同步与问答已暂停。发 %@ key <Key> 或 %@ setup <串> 恢复。\n",
            cfg.trigger, cfg.trigger];
    }
    [t appendFormat:@"版本 %@ · 斗图 %@ · 表情库 %lu 张\n",
        InsPVersion(), [InsSticker battleEnabled] ? @"开" : @"关",
        (unsigned long)[InsSticker library].count];
    [t appendFormat:@"记忆会话 %lu 个：合计已同步 %lu 条 / 摘要 %lu 次（较上次 %+ld 条 / %+ld 次）\n",
        (unsigned long)all.count, (unsigned long)scanned, (unsigned long)chunks,
        (long)dScanned, (long)dChunks];
    NSUInteger shown = MIN(all.count, 5);
    for (NSUInteger i = 0; i < shown; i++) {
        NSDictionary *d = all[i];
        NSString *name = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : @"(未命名)";
        if (name.length > 16) name = [name substringToIndex:16];
        [t appendFormat:@"· %@：已同步 %lu 条 / 摘要 %lu 次，到 %@\n",
            name, (unsigned long)[d[@"scanned"] unsignedIntegerValue],
            (unsigned long)[d[@"chunks"] unsignedIntegerValue],
            InsPStamp([d[@"cursor"] unsignedIntValue])];
    }
    if (!all.count) {
        [t appendFormat:@"· 还没有同步过任何会话，在目标聊天里发 %@ sync 开始\n", cfg.trigger];
    }
    if (all.count > shown) [t appendFormat:@"· 另有 %lu 个会话未列出\n", (unsigned long)(all.count - shown)];
    [t appendFormat:@"正在同步 %lu 个会话\n", (unsigned long)[InsMemory syncingCount]];
    [t appendFormat:@"自动推送已停用，仅在你主动发「%@ 进度 现在」时发送这一份。", cfg.trigger];
    return t;
}

static void InsPSend(NSMutableDictionary *s) {
    NSString *text = InsPBuildReport(s);
    NSString *talker = [s[@"talker"] isKindOfClass:[NSString class]] ? s[@"talker"] : @"filehelper";
    if (!talker.length) talker = @"filehelper";
    InsPSave(s);   // 先落盘再发，重复触发时不会又发一遍
    void (^handler)(NSString *, NSString *) = gReply;
    if (handler) handler(talker, text);
    else [InsConfig log:@"进度汇报：回复通道未注册，本次未发送"];
    [InsConfig log:[NSString stringWithFormat:@"进度汇报已发往 %@（%lu 字）",
                    talker, (unsigned long)text.length]];
}

// 2026-11-23：自动汇报逻辑（定时器 / 消息补检）已整体移除。
// 用户要求「只有主动触发才发送」，现在唯一发送入口是 +reportNow -> InsPSend。

@implementation InsProgress

+ (void)setReplyHandler:(void (^)(NSString *, NSString *))handler {
    gReply = [handler copy];
}

+ (void)start {
    // 2026-11-23：不再启动定时汇报。用户要求只有主动触发才发送。
    // 保留一次性迁移（关掉老配置），但不创建定时器。
    (void)InsPState();
    [InsConfig log:@"进度汇报：自动推送已停用，仅主动触发（进度 现在）发送"];
}

+ (void)noteActivity {
    // 2026-11-23：消息不再触发自动汇报。留空以兼容 Tweak.x 的调用点。
}

+ (BOOL)enabled { return [InsPState()[@"enabled"] boolValue]; }
+ (NSInteger)intervalMinutes { return [InsPState()[@"intervalMin"] integerValue]; }
+ (NSString *)targetTalker { return InsPState()[@"talker"] ?: @"filehelper"; }

+ (NSString *)targetLabel {
    NSDictionary *s = InsPState();
    NSString *t = [s[@"talker"] isKindOfClass:[NSString class]] ? s[@"talker"] : @"";
    if ([t isEqualToString:@"filehelper"]) return @"文件传输助手";
    NSString *name = [s[@"chatName"] isKindOfClass:[NSString class]] ? s[@"chatName"] : @"";
    return name.length ? name : (t.length ? t : @"文件传输助手");
}

+ (NSString *)statusLine {
    return @"进度汇报：仅手动（自动推送已停用；发「进度 现在」才发一份）";
}

+ (void)setEnabled:(BOOL)on {
    [self setEnabled:on target:nil chatName:nil];
}

+ (void)setEnabled:(BOOL)on target:(NSString *)talker chatName:(NSString *)chatName {
    NSMutableDictionary *s = InsPState();
    s[@"enabled"] = @(on);
    if (talker.length) {
        s[@"talker"] = talker;
        s[@"chatName"] = chatName ?: @"";
    }
    if (on) s[@"lastReportAt"] = @([[NSDate date] timeIntervalSince1970]);
    InsPSave(s);
}

+ (void)setTarget:(NSString *)talker chatName:(NSString *)chatName {
    if (!talker.length) return;
    NSMutableDictionary *s = InsPState();
    s[@"talker"] = talker;
    s[@"chatName"] = chatName ?: @"";
    InsPSave(s);
}

+ (void)setIntervalMinutes:(NSInteger)minutes {
    NSInteger m = minutes;
    if (m < 5) m = 5;
    if (m > 1440) m = 1440;
    NSMutableDictionary *s = InsPState();
    s[@"intervalMin"] = @(m);
    s[@"lastReportAt"] = @([[NSDate date] timeIntervalSince1970]);
    InsPSave(s);
}

+ (NSString *)reportNow {
    NSMutableDictionary *s = InsPState();
    s[@"lastReportAt"] = @([[NSDate date] timeIntervalSince1970]);
    InsPSend(s);
    return [self targetLabel];
}

@end
