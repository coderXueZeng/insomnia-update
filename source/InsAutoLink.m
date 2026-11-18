#import "InsAutoLink.h"
#import "InsConfig.h"
#import "InsMedia.h"
#import "InsLLM.h"
#import "InsSend.h"
#import <objc/message.h>

// 自动链接分析：
//   进入会话（点聊天框）→ 找该会话最近几条还没分析过的链接 → 抓正文 → 模型总结 → 落盘
// 整个链路都在串行后台队列上跑，绝不拦 UI；抓不到正文时不做「屏幕点开」，
// 因为那会抢前台（用户正看着聊天），需要点开时用 @insomnia 点开 手动触发。

static NSString *const kInsALFile = @"linkdigest.json";
static NSUInteger const kInsALMaxItems = 200;
static NSUInteger const kInsALMaxURLCache = 600;

static NSMutableDictionary *gALStore = nil;      // items / urls / stats
static NSMutableDictionary *gALAnalyzing = nil;  // url -> @YES（同一条链接只跑一个任务）
static NSMutableDictionary *gALLastOpen = nil;   // talker -> ts
static NSMutableArray *gALHourStamps = nil;      // 最近一小时的分析时间戳
static dispatch_queue_t gALQueue = NULL;
static NSRecursiveLock *gALLock = nil;

static NSString *InsALPath(void) {
    return [[InsConfig rootDir] stringByAppendingPathComponent:kInsALFile];
}

static id InsALCall0(id obj, SEL sel) {
    if (!obj || ![obj respondsToSelector:sel]) return nil;
    @try {
        id (*fn)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        return fn(obj, sel);
    } @catch (NSException *e) {
        return nil;
    }
}

static id InsALService(NSString *className) {
    Class center = NSClassFromString(@"MMServiceCenter");
    Class service = NSClassFromString(className);
    if (!center || !service) return nil;
    id defaultCenter = InsALCall0((id)center, NSSelectorFromString(@"defaultCenter"));
    if (!defaultCenter) return nil;
    @try {
        id (*fn)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        return fn(defaultCenter, NSSelectorFromString(@"getService:"), (id)service);
    } @catch (NSException *e) {
        return nil;
    }
}

/// 归一化 URL：去掉 fragment、utm_* 等分享参数、末尾斜杠，避免同一条链接被算成多条
static NSString *InsALNormalize(NSString *url) {
    if (![url isKindOfClass:[NSString class]] || !url.length) return @"";
    NSString *clean = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSURLComponents *parts = [NSURLComponents componentsWithString:clean];
    if (!parts) return clean;
    NSMutableArray *kept = [NSMutableArray array];
    for (NSURLQueryItem *item in parts.queryItems) {
        NSString *name = item.name.lowercaseString ?: @"";
        if ([name hasPrefix:@"utm_"] || [name isEqualToString:@"from"] ||
            [name isEqualToString:@"spm"] || [name isEqualToString:@"share_token"] ||
            [name isEqualToString:@"scene"] || [name isEqualToString:@"sharer_sharetime"]) {
            continue;
        }
        [kept addObject:item];
    }
    parts.queryItems = kept.count ? kept : nil;
    parts.fragment = nil;
    NSString *out = parts.string ?: clean;
    while (out.length > 1 && [out hasSuffix:@"/"]) out = [out substringToIndex:out.length - 1];
    return out;
}

static NSString *InsALHost(NSString *url) {
    NSString *host = [NSURL URLWithString:url].host.lowercaseString ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    return host;
}

static void InsALSaveLocked(void) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:gALStore options:0 error:nil];
    if (data) [data writeToFile:InsALPath() atomically:YES];
}

static void InsALLoadIfNeeded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gALQueue = dispatch_queue_create("com.xuezeng.insomnia.autolink", DISPATCH_QUEUE_SERIAL);
        gALLock = [NSRecursiveLock new];
        gALAnalyzing = [NSMutableDictionary dictionary];
        gALLastOpen = [NSMutableDictionary dictionary];
        gALHourStamps = [NSMutableArray array];
        gALStore = [NSMutableDictionary dictionary];
        NSData *raw = [NSData dataWithContentsOfFile:InsALPath()];
        NSDictionary *dict = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : nil;
        if ([dict isKindOfClass:[NSDictionary class]]) {
            if ([dict[@"items"] isKindOfClass:[NSArray class]]) gALStore[@"items"] = [dict[@"items"] mutableCopy];
            if ([dict[@"urls"] isKindOfClass:[NSDictionary class]]) gALStore[@"urls"] = [dict[@"urls"] mutableCopy];
        }
        if (![gALStore[@"items"] isKindOfClass:[NSMutableArray class]]) gALStore[@"items"] = [NSMutableArray array];
        if (![gALStore[@"urls"] isKindOfClass:[NSMutableDictionary class]]) gALStore[@"urls"] = [NSMutableDictionary dictionary];
    });
}

static NSArray *InsALSortedItems(void) {
    NSArray *items = gALStore[@"items"];
    return [items sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        long long ta = [a[@"t"] longLongValue];
        long long tb = [b[@"t"] longLongValue];
        if (ta == tb) return NSOrderedSame;
        return ta > tb ? NSOrderedAscending : NSOrderedDescending;
    }];
}

static NSDictionary *InsALItemForURL(NSString *url) {
    for (NSDictionary *item in gALStore[@"items"]) {
        if ([item[@"url"] isEqualToString:url]) return item;
    }
    return nil;
}

/// 已经分析过（且没失败）的链接不再跑；失败过的冷却一段时间再重试。
/// 之前失败一律压 6 小时，遇到「网络抖一下就断」的情况等于半天内都不会再试一次，
/// 现在临时失败 10 分钟就能重来，真正「网页没正文」也只要等这么久。
static BOOL InsALAlreadyDone(NSString *url, NSUInteger *pendingRetry) {
    NSDictionary *item = InsALItemForURL(url);
    if (!item) return NO;
    if ([item[@"ok"] boolValue]) return YES;
    NSTimeInterval t = [item[@"t"] doubleValue];
    if ([[NSDate date] timeIntervalSince1970] - t < 10 * 60) {
        if (pendingRetry) *pendingRetry += 1;
        return YES;
    }
    return NO;
}

static BOOL InsALRateOK(NSInteger limit) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSMutableIndexSet *old = [NSMutableIndexSet indexSet];
    [gALHourStamps enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if (now - [obj doubleValue] > 3600) [old addIndex:idx];
    }];
    [gALHourStamps removeObjectsAtIndexes:old];
    return (NSInteger)gALHourStamps.count < MAX(limit, 1);
}

static NSString *InsALTruncate(NSString *text, NSUInteger limit) {
    if (text.length <= limit) return text ?: @"";
    return [text substringToIndex:limit];
}

static void InsALDeliver(NSString *talker, NSString *title, NSString *host, NSString *summary, NSString *url) {
    NSString *mode = [InsAutoLink mode];
    if ([mode isEqualToString:@"quiet"] || !mode.length) return;
    NSString *text = [NSString stringWithFormat:@"【自动链接摘要】%@\n%@\n%@\n%@",
                      title.length ? title : @"(无标题)", host.length ? host : @"", summary ?: @"", url];
    NSString *target = [mode isEqualToString:@"forward"] ? @"filehelper" : talker;
    if (!target.length) return;
    [InsSend sendText:text toTalker:target completion:^(BOOL ok) {
        [InsConfig log:[NSString stringWithFormat:@"自动看链接：%@摘要%@", ok ? @"已推送" : @"推送失败",
                        [mode isEqualToString:@"forward"] ? @"到文件传输助手" : @"到当前会话"]];
    }];
}

static void InsALAnalyze(NSString *talker, NSDictionary *info) {
    InsConfig *cfg = [InsConfig shared];
    NSString *url = InsALNormalize(info[@"url"]);
    if (!url.length) return;
    NSString *title = info[@"title"] ?: @"";
    NSString *des = info[@"des"] ?: @"";
    NSString *host = InsALHost(url);

    @synchronized (gALLock) {
        if (gALAnalyzing[url]) return;
        // 同一条链接只分析一次；失败过的 6 小时内也不重试，避免反复烧额度
        if (InsALAlreadyDone(url, NULL)) return;
        if (!InsALRateOK(cfg.autoLinkMaxPerHour)) {
            [InsConfig log:@"自动看链接：本小时额度已用完，跳过"];
            return;
        }
        gALAnalyzing[url] = @YES;
        gALStore[@"urls"][url] = @([[NSDate date] timeIntervalSince1970]);
        if ([gALStore[@"urls"] count] > kInsALMaxURLCache) {
            // 简单裁剪：按时间删掉最老的一半，避免文件无限长
            NSArray *keys = [gALStore[@"urls"] keysSortedByValueUsingComparator:^NSComparisonResult(id a, id b) {
                return [a compare:b];
            }];
            NSUInteger drop = keys.count / 2;
            for (NSUInteger i = 0; i < drop; i++) [gALStore[@"urls"] removeObjectForKey:keys[i]];
        }
    }

    dispatch_async(gALQueue, ^{
        NSString *reason = nil;
        NSString *body = [InsMedia fetchLinkArticle:url reason:&reason];
        NSString *summary = nil;
        BOOL ok = NO;
        if (body.length) {
            NSString *content = InsALTruncate(body, 6000);
            NSString *system = @"你是网页摘要器。用不超过 4 句中文说清：这页在讲什么、关键结论或数据、对普通人有什么用。"
                                "不要客套、不要复述标题、不要编造正文里没有的内容。";
            NSString *user = [NSString stringWithFormat:@"标题：%@\n来源：%@\n\n正文：\n%@", title, host, content];
            NSError *llmError = nil;
            summary = [InsLLM askSystem:system user:user error:&llmError];
            if (summary.length) {
                ok = YES;
            } else {
                reason = [NSString stringWithFormat:@"模型总结失败：%@", llmError.localizedDescription ?: @"未知错误"];
            }
        }
        if (!summary.length) {
            summary = [NSString stringWithFormat:@"没能读到正文（%@），只记下了标题和链接。", reason ?: @"未知原因"];
        }

        NSDictionary *item = @{ @"url": url,
                                @"title": title,
                                @"host": host,
                                @"des": InsALTruncate(des, 160),
                                @"summary": summary,
                                @"talker": talker ?: @"",
                                @"t": @([[NSDate date] timeIntervalSince1970]),
                                @"ok": @(ok) };
        @synchronized (gALLock) {
            NSMutableArray *items = gALStore[@"items"];
            NSMutableIndexSet *old = [NSMutableIndexSet indexSet];
            [items enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
                if ([obj[@"url"] isEqualToString:url]) [old addIndex:idx];
            }];
            if (old.count) [items removeObjectsAtIndexes:old];
            [items addObject:item];
            while (items.count > kInsALMaxItems) [items removeObjectAtIndex:0];
            [gALAnalyzing removeObjectForKey:url];
            [gALHourStamps addObject:@([[NSDate date] timeIntervalSince1970])];
            InsALSaveLocked();
        }
        [InsConfig log:[NSString stringWithFormat:@"自动看链接：%@ %@（%@，%lu 字%@）",
                        ok ? @"已分析" : @"分析失败", host, url,
                        (unsigned long)summary.length, ok ? @"" : @"，无正文"]];
        if (ok) InsALDeliver(talker, title, host, summary, url);
    });
}

static void InsALScanTalker(NSString *talker) {
    InsConfig *cfg = [InsConfig shared];
    if (!cfg.autoLinkEnabled || !talker.length) return;
    NSArray *links = [InsMedia linksForTalker:talker];
    if (!links.count) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval window = MAX(cfg.autoLinkWindowHours, 1) * 3600.0;
    NSInteger budget = MAX(cfg.autoLinkMaxPerOpen, 1);
    NSInteger picked = 0;
    for (NSDictionary *media in [links reverseObjectEnumerator]) {
        if (picked >= budget) break;
        NSDictionary *info = [InsMedia linkInfoFor:media];
        NSString *url = InsALNormalize(info[@"url"]);
        if (!url.length) continue;
        NSTimeInterval t = [media[@"time"] doubleValue];
        if (t > 0 && now - t > window) continue;
        NSUInteger retry = 0;
        if (InsALAlreadyDone(url, &retry)) continue;
        @synchronized (gALLock) {
            if (!InsALRateOK(cfg.autoLinkMaxPerHour)) {
                [InsConfig log:@"自动看链接：本小时额度用完，跳过"];
                return;
            }
        }
        InsALAnalyze(talker, info);
        picked++;
    }
    if (picked) {
        [InsConfig log:[NSString stringWithFormat:@"自动看链接：%@ 取了 %ld 条待分析链接",
                        talker, (long)picked]];
    }
}

@implementation InsAutoLink

+ (void)bootstrap {
    InsALLoadIfNeeded();
    // 只做装载；真正的分析等用户进会话或收到链接时再触发，避免启动就烧额度
    [InsConfig log:[NSString stringWithFormat:@"自动看链接：%@ / 模式 %@ / 已存 %lu 条摘要",
                    [self enabled] ? @"开" : @"关", [self mode],
                    (unsigned long)[gALStore[@"items"] count]]];
}

+ (BOOL)enabled {
    return [InsConfig shared].autoLinkEnabled;
}

+ (NSString *)mode {
    NSString *mode = [InsConfig shared].autoLinkMode;
    return mode.length ? mode : @"quiet";
}

+ (BOOL)analyzeOnReceive {
    return [InsConfig shared].autoLinkOnReceive;
}

+ (void)setEnabled:(BOOL)on {
    [[InsConfig shared] setConfigKey:@"autoLinkEnabled" value:@(on)];
}

+ (void)setMode:(NSString *)mode {
    [[InsConfig shared] setConfigKey:@"autoLinkMode" value:mode ?: @"quiet"];
}

+ (void)setAnalyzeOnReceive:(BOOL)on {
    [[InsConfig shared] setConfigKey:@"autoLinkOnReceive" value:@(on)];
}

+ (NSString *)currentTalker {
    id manager = InsALService(@"MMMsgLogicManager");
    if (!manager) return nil;
    id logic = InsALCall0(manager, NSSelectorFromString(@"GetCurrentLogicController"));
    if (!logic) return nil;
    NSString *name = InsALCall0(logic, NSSelectorFromString(@"GetContactName"));
    return [name isKindOfClass:[NSString class]] && name.length ? name : nil;
}

+ (void)noteChatOpened {
    InsALLoadIfNeeded();
    if (![self enabled]) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSString *talker = [self currentTalker];
        if (!talker.length) return;
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        @synchronized (gALLock) {
            NSTimeInterval last = [gALLastOpen[talker] doubleValue];
            if (now - last < 60) return;
            gALLastOpen[talker] = @(now);
            if (gALLastOpen.count > 200) [gALLastOpen removeAllObjects];
        }
        dispatch_async(gALQueue, ^{
            InsALScanTalker(talker);
        });
    });
}

+ (void)noteIncomingXML:(NSString *)xml talker:(NSString *)talker fromMe:(BOOL)fromMe {
    InsALLoadIfNeeded();
    if (fromMe || ![self enabled] || ![self analyzeOnReceive]) return;
    // 只认真正的链接卡片（appmsg type 5）：小程序、音乐、文件这些也带 url，但不该当文章读
    if ([xml rangeOfString:@"<type>5</type>"].location == NSNotFound) return;
    NSDictionary *info = [InsMedia linkInfoFromText:xml];
    if (![info[@"url"] length]) return;
    dispatch_async(gALQueue, ^{
        InsALAnalyze(talker, info);
    });
}

+ (NSUInteger)pendingCountForTalker:(NSString *)talker {
    InsALLoadIfNeeded();
    NSUInteger n = 0;
    for (NSDictionary *media in [InsMedia linksForTalker:talker]) {
        NSString *url = InsALNormalize([InsMedia linkInfoFor:media][@"url"]);
        if (!url.length) continue;
        if (!InsALAlreadyDone(url, NULL)) n++;
    }
    return n;
}

+ (NSString *)statusLine {
    InsALLoadIfNeeded();
    NSArray *items = gALStore[@"items"];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSUInteger today = 0;
    NSDate *now = [NSDate date];
    for (NSDictionary *item in items) {
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:[item[@"t"] doubleValue]];
        if ([cal isDate:d inSameDayAsDate:now]) today++;
    }
    NSInteger okCount = 0;
    for (NSDictionary *item in items) if ([item[@"ok"] boolValue]) okCount++;
    return [NSString stringWithFormat:@"自动看链接：%@ / 模式 %@ / 收链接即看 %@ / 已存 %lu 条（成功 %ld，今日 %lu）",
            [self enabled] ? @"开" : @"关", [self mode],
            [self analyzeOnReceive] ? @"开" : @"关",
            (unsigned long)items.count, (long)okCount, (unsigned long)today];
}

+ (NSString *)digestListForTalker:(NSString *)talker limit:(NSInteger)limit {
    InsALLoadIfNeeded();
    NSArray *sorted = InsALSortedItems();
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSDictionary *item in sorted) {
        if (talker.length && ![item[@"talker"] isEqualToString:talker]) continue;
        [filtered addObject:item];
    }
    if (!filtered.count) {
        return [NSString stringWithFormat:@"还没有自动分析过的链接。%@ 自动看链接 开后，点进对方会话就会自动看。",
                [InsConfig shared].trigger];
    }
    if (limit <= 0) limit = 5;
    NSMutableString *out = [NSMutableString string];
    NSUInteger i = 1;
    for (NSDictionary *item in filtered) {
        if ((NSInteger)i > limit) break;
        NSString *title = item[@"title"] ?: @"";
        if (!title.length) title = item[@"url"] ?: @"";
        if (title.length > 40) title = [title substringToIndex:40];
        NSString *host = item[@"host"] ?: @"";
        NSString *summary = item[@"summary"] ?: @"";
        if (summary.length > 120) summary = [summary substringToIndex:120];
        [out appendFormat:@"%lu. %@（%@）\n   %@\n", (unsigned long)i++, title, host, summary];
    }
    return out;
}

@end
