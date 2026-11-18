#import "InsProgress.h"
#import "InsConfig.h"
#import "InsMemory.h"
#import "InsSticker.h"

static void (^gReply)(NSString *, NSString *) = nil;
static NSTimeInterval gLastCheck = 0;
static dispatch_source_t gTimer = nil;

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
    // 默认开：升级后用户不用再下命令就能定时收到进度。
    // 默认发到「文件传输助手」，绝不会把进度发到别人的聊天里。
    return @{@"enabled": @YES,
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
    return s;
}

static NSObject *InsPLock(void) {
    static NSObject *o = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ o = [NSObject new]; });
    return o;
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
    [t appendFormat:@"下次汇报 %ld 分钟后；%@ 进度关 可停，%@ 进度 30 改间隔",
        (long)[s[@"intervalMin"] integerValue], cfg.trigger, cfg.trigger];
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

/// 只有抢到「该汇报了」这一次的调用会真的发，定时器与消息驱动不会重复
static void InsPMaybeReport(void) {
    NSMutableDictionary *s = InsPState();
    if (![s[@"enabled"] boolValue]) return;
    NSInteger interval = [s[@"intervalMin"] integerValue];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - [s[@"lastReportAt"] doubleValue] < interval * 60) return;
    @synchronized (InsPLock()) {
        s = InsPState();
        if (![s[@"enabled"] boolValue]) return;
        now = [[NSDate date] timeIntervalSince1970];
        if (now - [s[@"lastReportAt"] doubleValue] < interval * 60) return;
        s[@"lastReportAt"] = @(now);
        InsPSave(s);   // 先占位，防止 30 秒定时器与消息驱动各发一次
    }
    InsPSend(s);
}

@implementation InsProgress

+ (void)setReplyHandler:(void (^)(NSString *, NSString *))handler {
    gReply = [handler copy];
}

+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(gTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                                  30 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(gTimer, ^{ InsPMaybeReport(); });
        dispatch_resume(gTimer);
        [InsConfig log:[NSString stringWithFormat:@"进度汇报已启动：%@", [self statusLine]]];
    });
}

+ (void)noteActivity {
    // 后台挂起后定时器不跑，靠每条消息补检；20 秒最多查一次，避免频繁读盘
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    @synchronized (InsPLock()) {
        if (now - gLastCheck < 20) return;
        gLastCheck = now;
    }
    InsPMaybeReport();
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
    NSDictionary *s = InsPState();
    return [NSString stringWithFormat:@"进度汇报：%@（每 %ld 分钟 → %@）",
            [s[@"enabled"] boolValue] ? @"开" : @"关",
            (long)[s[@"intervalMin"] integerValue], [self targetLabel]];
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
