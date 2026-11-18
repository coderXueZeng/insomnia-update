#import "InsHot.h"
#import "InsConfig.h"

#pragma mark - 小工具

static NSString *InsHotUA(void) {
    return @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 "
           @"(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
}

static NSString *InsHotEncode(NSString *text) {
    static NSCharacterSet *allowed = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:
                   @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    });
    return [text stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: text;
}

static NSString *InsHotNumber(id value) {
    double n = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0;
    if (n <= 0) return nil;
    if (n >= 100000000) return [NSString stringWithFormat:@"%.1f亿", n / 100000000.0];
    if (n >= 10000) return [NSString stringWithFormat:@"%.1f万", n / 10000.0];
    return [NSString stringWithFormat:@"%.0f", n];
}

static NSString *InsHotTrim(NSString *s) {
    static NSCharacterSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSCharacterSet characterSetWithCharactersInString:
               @" \t\n，。、,.:：;；!！?？~～·\"'“”‘’「」『』【】（）()<>《》-—"];
    });
    return [s stringByTrimmingCharactersInSet:set];
}

static NSData *InsHotGet(NSString *url, NSString *referer, NSError **outError) {
    if (!url.length) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.timeoutInterval = 12;
    [req setValue:InsHotUA() forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"application/json, text/plain, */*" forHTTPHeaderField:@"Accept"];
    [req setValue:@"zh-CN,zh;q=0.9" forHTTPHeaderField:@"Accept-Language"];
    if (referer.length) [req setValue:referer forHTTPHeaderField:@"Referer"];

    __block NSData *body = nil;
    __block NSError *error = nil;
    __block NSInteger status = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        body = d;
        error = e;
        status = [(NSHTTPURLResponse *)r statusCode];
        dispatch_semaphore_signal(sem);
    }] resume];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)))) {
        if (outError) *outError = [NSError errorWithDomain:@"InsHot" code:-1
                                                  userInfo:@{NSLocalizedDescriptionKey: @"请求超时"}];
        return nil;
    }
    if (error) {
        if (outError) *outError = error;
        return nil;
    }
    if (status < 200 || status >= 300) {
        if (outError) *outError = [NSError errorWithDomain:@"InsHot" code:status
                                                  userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"HTTP %ld", (long)status]}];
        return nil;
    }
    return body;
}

static id InsHotJSON(NSData *data, NSError **outError) {
    if (!data.length) {
        if (outError) *outError = [NSError errorWithDomain:@"InsHot" code:-2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"空响应"}];
        return nil;
    }
    NSError *err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!obj) {
        if (outError) *outError = [NSError errorWithDomain:@"InsHot" code:-3
                                                  userInfo:@{NSLocalizedDescriptionKey:
            @"返回的不是 JSON（可能被拦截了）"}];
        return nil;
    }
    return obj;
}

#pragma mark - 平台表

static NSArray<NSDictionary *> *InsHotPlatforms(void) {
    static NSArray *list = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @{@"id": @"weibo", @"name": @"微博热搜",
              @"aliases": @[@"微博", @"新浪微博", @"weibo", @"wb"]},
            @{@"id": @"douyin", @"name": @"抖音热榜",
              @"aliases": @[@"抖音", @"douyin", @"dy"]},
            @{@"id": @"zhihu", @"name": @"知乎热榜",
              @"aliases": @[@"知乎", @"zhihu"]},
            @{@"id": @"baidu", @"name": @"百度热搜",
              @"aliases": @[@"百度", @"baidu"]},
            @{@"id": @"toutiao", @"name": @"头条热榜",
              @"aliases": @[@"今日头条", @"头条", @"toutiao"]},
            @{@"id": @"bili", @"name": @"B站热门",
              @"aliases": @[@"哔哩哔哩", @"哔哩", @"bilibili", @"b站", @"bili"]},
        ];
    });
    return list;
}

static NSDictionary *InsHotPlatformNamed(NSString *lower) {
    for (NSDictionary *p in InsHotPlatforms()) {
        for (NSString *alias in p[@"aliases"]) {
            if ([lower rangeOfString:alias.lowercaseString].location != NSNotFound) return p;
        }
    }
    return nil;
}

#pragma mark - 各平台抓取

/// B站/抖音这类搜索页链接也能直接点开，用户要的是「点一下能看到」
static NSArray<NSDictionary *> *InsHotWeibo(NSError **err) {
    NSData *data = InsHotGet(@"https://weibo.com/ajax/side/hotSearch",
                             @"https://weibo.com/", err);
    NSDictionary *json = InsHotJSON(data, err);
    NSArray *rows = json[@"data"][@"realtime"];
    if (![rows isKindOfClass:[NSArray class]]) {
        if (err && !*err) *err = [NSError errorWithDomain:@"InsHot" code:-4
                                                 userInfo:@{NSLocalizedDescriptionKey: @"微博返回结构变了"}];
        return nil;
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        if (![row isKindOfClass:[NSDictionary class]]) continue;
        if ([row[@"is_ad"] boolValue] || [row[@"promotion"] boolValue]) continue;
        NSString *title = [row[@"note"] isKindOfClass:[NSString class]] ? row[@"note"] : row[@"word"];
        if (![title isKindOfClass:[NSString class]] || !title.length) continue;
        NSString *query = [row[@"word_scheme"] isKindOfClass:[NSString class]] ? row[@"word_scheme"] : title;
        [out addObject:@{
            @"title": title,
            @"hot": InsHotNumber(row[@"num"]) ?: @"",
            @"tag": [row[@"icon_desc"] isKindOfClass:[NSString class]] ? row[@"icon_desc"] : @"",
            @"url": [@"https://s.weibo.com/weibo?q=" stringByAppendingString:InsHotEncode(query)],
        }];
    }
    return out;
}

static NSArray<NSDictionary *> *InsHotDouyin(NSError **err) {
    NSData *data = InsHotGet(@"https://www.iesdouyin.com/web/api/v2/hotsearch/billboard/word/",
                             @"https://www.douyin.com/", err);
    NSDictionary *json = InsHotJSON(data, err);
    NSArray *rows = json[@"word_list"];
    if (![rows isKindOfClass:[NSArray class]]) {
        if (err && !*err) *err = [NSError errorWithDomain:@"InsHot" code:-4
                                                 userInfo:@{NSLocalizedDescriptionKey: @"抖音返回结构变了"}];
        return nil;
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSString *title = [row[@"word"] isKindOfClass:[NSString class]] ? row[@"word"] : nil;
        if (!title.length) continue;
        [out addObject:@{
            @"title": title,
            @"hot": InsHotNumber(row[@"hot_value"]) ?: @"",
            @"tag": @"",
            @"url": [@"https://www.douyin.com/search/" stringByAppendingString:InsHotEncode(title)],
        }];
    }
    return out;
}

static NSArray<NSDictionary *> *InsHotZhihu(NSError **err) {
    NSData *data = InsHotGet(@"https://api.zhihu.com/topstory/hot-list?limit=30",
                             @"https://www.zhihu.com/hot", err);
    NSDictionary *json = InsHotJSON(data, err);
    NSArray *rows = json[@"data"];
    if (![rows isKindOfClass:[NSArray class]]) {
        if (err && !*err) *err = [NSError errorWithDomain:@"InsHot" code:-4
                                                 userInfo:@{NSLocalizedDescriptionKey: @"知乎返回结构变了"}];
        return nil;
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSDictionary *target = [row[@"target"] isKindOfClass:[NSDictionary class]] ? row[@"target"] : row;
        NSString *title = [target[@"title"] isKindOfClass:[NSString class]] ? target[@"title"] : nil;
        if (!title.length) continue;
        id qid = target[@"id"];
        NSString *url = nil;
        if (qid) {
            url = [NSString stringWithFormat:@"https://www.zhihu.com/question/%@", qid];
        } else if ([target[@"url"] isKindOfClass:[NSString class]]) {
            url = [target[@"url"] stringByReplacingOccurrencesOfString:@"api.zhihu.com/questions"
                                                            withString:@"www.zhihu.com/question"];
        }
        if (!url.length) continue;
        [out addObject:@{
            @"title": title,
            @"hot": [row[@"detail_text"] isKindOfClass:[NSString class]] ? row[@"detail_text"] : @"",
            @"tag": @"",
            @"url": url,
        }];
    }
    return out;
}

static NSArray<NSDictionary *> *InsHotBaidu(NSError **err) {
    NSData *data = InsHotGet(@"https://top.baidu.com/api/board?platform=wise&tab=realtime",
                             @"https://top.baidu.com/board", err);
    NSDictionary *json = InsHotJSON(data, err);
    NSArray *cards = json[@"data"][@"cards"];
    if (![cards isKindOfClass:[NSArray class]]) {
        if (err && !*err) *err = [NSError errorWithDomain:@"InsHot" code:-4
                                                 userInfo:@{NSLocalizedDescriptionKey: @"百度返回结构变了"}];
        return nil;
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *card in cards) {
        NSArray *groups = card[@"content"];
        if (![groups isKindOfClass:[NSArray class]]) continue;
        for (NSDictionary *group in groups) {
            NSArray *items = group[@"content"];
            if (![items isKindOfClass:[NSArray class]]) continue;
            for (NSDictionary *item in items) {
                if ([item[@"isTop"] boolValue]) continue;      // 置顶位多是专题推广，不算热搜
                NSString *title = [item[@"word"] isKindOfClass:[NSString class]] ? item[@"word"] : item[@"query"];
                if (![title isKindOfClass:[NSString class]] || !title.length) continue;
                NSString *url = [item[@"url"] isKindOfClass:[NSString class]]
                    ? item[@"url"]
                    : [@"https://m.baidu.com/s?word=" stringByAppendingString:InsHotEncode(title)];
                [out addObject:@{
                    @"title": title,
                    @"hot": InsHotNumber(item[@"hotScore"]) ?: @"",
                    @"tag": @"",
                    @"url": url,
                }];
            }
        }
    }
    return out;
}

static NSArray<NSDictionary *> *InsHotToutiao(NSError **err) {
    NSData *data = InsHotGet(@"https://www.toutiao.com/hot-event/hot-board/?origin=toutiao_pc",
                             @"https://www.toutiao.com/", err);
    NSDictionary *json = InsHotJSON(data, err);
    NSArray *rows = json[@"data"];
    if (![rows isKindOfClass:[NSArray class]]) {
        if (err && !*err) *err = [NSError errorWithDomain:@"InsHot" code:-4
                                                 userInfo:@{NSLocalizedDescriptionKey: @"头条返回结构变了"}];
        return nil;
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSString *title = [row[@"Title"] isKindOfClass:[NSString class]] ? row[@"Title"] : nil;
        if (!title.length) continue;
        NSString *url = [row[@"Url"] isKindOfClass:[NSString class]] ? row[@"Url"] : nil;
        if (!url.length) continue;
        [out addObject:@{
            @"title": title,
            @"hot": InsHotNumber(row[@"HotValue"]) ?: @"",
            @"tag": @"",
            @"url": url,
        }];
    }
    return out;
}

/// 网页版 ranking 接口有风控（-352），改走 app 端榜单接口
static NSArray<NSDictionary *> *InsHotBili(NSError **err) {
    NSData *data = InsHotGet(@"https://app.bilibili.com/x/v2/search/trending/ranking?limit=30",
                             @"https://www.bilibili.com/", err);
    NSDictionary *json = InsHotJSON(data, err);
    NSArray *rows = json[@"data"][@"list"];
    if (![rows isKindOfClass:[NSArray class]]) {
        if (err && !*err) *err = [NSError errorWithDomain:@"InsHot" code:-4
                                                 userInfo:@{NSLocalizedDescriptionKey: @"B站返回结构变了"}];
        return nil;
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *row in rows) {
        NSString *title = [row[@"show_name"] isKindOfClass:[NSString class]] ? row[@"show_name"] : row[@"keyword"];
        if (![title isKindOfClass:[NSString class]] || !title.length) continue;
        [out addObject:@{
            @"title": title,
            @"hot": @"",
            @"tag": @"",
            @"url": [@"https://search.bilibili.com/all?keyword=" stringByAppendingString:InsHotEncode(title)],
        }];
    }
    return out;
}

#pragma mark - 缓存

static NSMutableDictionary *gHotCache = nil;
static NSObject *gHotLock = nil;

static NSArray<NSDictionary *> *InsHotCached(NSString *pid, BOOL *fresh) {
    @synchronized ([InsHot class]) {
        if (!gHotCache) { gHotCache = [NSMutableDictionary dictionary]; gHotLock = [NSObject new]; }
    }
    @synchronized (gHotLock) {
        NSDictionary *entry = gHotCache[pid];
        if (!entry) return nil;
        NSTimeInterval age = -[entry[@"t"] timeIntervalSinceNow];
        if (age > 300) return nil;      // 5 分钟内复用，免得连发几条被风控
        if (fresh) *fresh = YES;
        return entry[@"items"];
    }
}

static void InsHotStore(NSString *pid, NSArray *items) {
    @synchronized ([InsHot class]) {
        if (!gHotCache) { gHotCache = [NSMutableDictionary dictionary]; gHotLock = [NSObject new]; }
    }
    @synchronized (gHotLock) {
        gHotCache[pid] = @{@"t": [NSDate date], @"items": items ?: @[]};
    }
}

@implementation InsHot

+ (NSArray<NSDictionary *> *)itemsForPlatform:(NSString *)pid error:(NSError **)err {
    BOOL fresh = NO;
    NSArray *cached = InsHotCached(pid, &fresh);
    if (cached.count) return cached;
    NSArray *items = nil;
    if ([pid isEqualToString:@"weibo"]) items = InsHotWeibo(err);
    else if ([pid isEqualToString:@"douyin"]) items = InsHotDouyin(err);
    else if ([pid isEqualToString:@"zhihu"]) items = InsHotZhihu(err);
    else if ([pid isEqualToString:@"baidu"]) items = InsHotBaidu(err);
    else if ([pid isEqualToString:@"toutiao"]) items = InsHotToutiao(err);
    else if ([pid isEqualToString:@"bili"]) items = InsHotBili(err);
    if (items.count) InsHotStore(pid, items);
    return items;
}

+ (NSString *)nameForPlatform:(NSString *)pid {
    for (NSDictionary *p in InsHotPlatforms()) {
        if ([p[@"id"] isEqualToString:pid]) return p[@"name"];
    }
    return pid;
}

#pragma mark - 命令解析

/// 返回 @{ platform, limit, filter }；不是热点命令返回 nil
+ (NSDictionary *)parsePayload:(NSString *)payload {
    NSString *s = InsHotTrim(payload ?: @"");
    if (!s.length) return nil;
    NSString *lower = s.lowercaseString;

    // 「这首歌为什么热门」这类正常提问别抢
    for (NSString *bad in @[@"为什么", @"怎么", @"吗", @"？", @"?", @"你说"]) {
        if ([s rangeOfString:bad].location != NSNotFound) return nil;
    }

    static NSArray *triggers = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        triggers = @[@"全网热点", @"全网热搜", @"综合热点", @"热点", @"热搜", @"热榜", @"热门", @"trending"];
    });
    NSString *hit = nil;
    NSRange hitRange = NSMakeRange(NSNotFound, 0);
    for (NSString *w in triggers) {
        NSRange r = [lower rangeOfString:w.lowercaseString];
        if (r.location == NSNotFound) continue;
        if (hitRange.location == NSNotFound || r.location < hitRange.location) {
            hit = w;
            hitRange = r;
        }
    }
    if (!hit) return nil;

    NSDictionary *platform = InsHotPlatformNamed(lower);
    BOOL mixed = ([s rangeOfString:@"全网"].location != NSNotFound) ||
                 ([s rangeOfString:@"综合"].location != NSNotFound) ||
                 ([s rangeOfString:@"全平台"].location != NSNotFound);
    // 没有平台名时，必须是以热点词开头的短句（或「看热点」），长句子交给大模型
    if (!platform && !mixed) {
        NSString *head = [s substringToIndex:MIN(s.length, 3)];
        BOOL startsWithTrigger = [head hasPrefix:@"热点"] || [head hasPrefix:@"热搜"] ||
                                 [head hasPrefix:@"热榜"] || [head hasPrefix:@"热门"] ||
                                 [head hasPrefix:@"看热"] || [s hasPrefix:@"trending"];
        if (!startsWithTrigger) return nil;
        if (s.length > 14) return nil;
    }

    // 去掉触发词、平台名，剩下的当数量/过滤词
    NSMutableString *rest = [s mutableCopy];
    [rest replaceOccurrencesOfString:hit withString:@" " options:0 range:NSMakeRange(0, rest.length)];
    if (platform) {
        for (NSString *alias in platform[@"aliases"]) {
            [rest replaceOccurrencesOfString:alias withString:@" " options:NSCaseInsensitiveSearch
                                      range:NSMakeRange(0, rest.length)];
        }
    }
    for (NSString *w in @[@"全网", @"综合", @"全平台", @"一下", @"帮我", @"看看", @"看下", @"看",
                          @"最新的", @"最近的", @"新闻", @"热闻", @"排行", @"榜单", @"榜"]) {
        [rest replaceOccurrencesOfString:w withString:@" " options:0 range:NSMakeRange(0, rest.length)];
    }
    rest = [[rest stringByReplacingOccurrencesOfString:@"条" withString:@" "] mutableCopy];

    NSUInteger limit = 8;
    NSMutableString *filter = [NSMutableString string];
    for (NSString *token in [rest componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
        NSString *t = InsHotTrim(token);
        if (!t.length) continue;
        // 「前10」「第5」也算条数
        while (t.length && ([t hasPrefix:@"前"] || [t hasPrefix:@"第"] || [t hasPrefix:@"共"])) {
            t = [t substringFromIndex:1];
        }
        BOOL digits = t.length > 0;
        for (NSUInteger i = 0; i < t.length; i++) {
            unichar c = [t characterAtIndex:i];
            if (c < '0' || c > '9') { digits = NO; break; }
        }
        if (digits) {
            NSInteger n = t.integerValue;
            if (n >= 1 && n <= 30) limit = (NSUInteger)n;
            continue;
        }
        if (filter.length) [filter appendString:@" "];
        [filter appendString:t];
    }

    return @{@"platform": mixed ? @"all" : (platform[@"id"] ?: @"weibo"),
             @"limit": @(limit),
             @"filter": filter};
}

#pragma mark - 回执

static NSString *InsHotClock(void) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        fmt.dateFormat = @"MM-dd HH:mm";
    });
    @synchronized (fmt) { return [fmt stringFromDate:[NSDate date]]; }
}

+ (NSString *)blockForPlatform:(NSString *)pid
                         limit:(NSUInteger)limit
                        filter:(NSString *)filter
                         title:(NSString *)title
                    showHeader:(BOOL)showHeader {
    NSError *error = nil;
    NSArray *items = [self itemsForPlatform:pid error:&error];
    if (!items.count) {
        NSString *reason = error.localizedDescription ?: @"没返回内容";
        [InsConfig log:[NSString stringWithFormat:@"热点：%@ 失败 %@", pid, reason]];
        return [NSString stringWithFormat:@"%@ 没抓到（%@）。换「抖音热点」试试，或过几分钟再发一次。",
                title, reason];
    }
    NSMutableArray *picked = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if (filter.length && [item[@"title"] rangeOfString:filter].location == NSNotFound) continue;
        [picked addObject:item];
        if (picked.count >= limit) break;
    }
    if (!picked.count) {
        return [NSString stringWithFormat:@"%@ 里没有含「%@」的条目。去掉关键词再发一次试试。", title, filter];
    }
    [InsConfig log:[NSString stringWithFormat:@"热点：%@ ok %lu 条（缓存可用 5 分钟）",
                    pid, (unsigned long)picked.count]];

    NSMutableString *out = [NSMutableString string];
    if (showHeader && title.length) {
        [out appendFormat:@"【%@】%@ · %lu 条", title, InsHotClock(), (unsigned long)picked.count];
    }
    NSInteger index = 1;
    for (NSDictionary *item in picked) {
        NSString *hot = item[@"hot"];
        NSString *tag = item[@"tag"];
        NSString *title = item[@"title"];
        if (title.length > 48) title = [[title substringToIndex:48] stringByAppendingString:@"…"];
        NSMutableString *line = [NSMutableString stringWithFormat:@"%ld. %@", (long)index++, title];
        if (tag.length) [line appendFormat:@" [%@]", tag];
        if (hot.length) [line appendFormat:@" · %@", hot];
        [out appendFormat:@"\n%@\n%@", line, item[@"url"]];
    }
    return out;
}

+ (NSString *)reportForPayload:(NSString *)payload {
    NSDictionary *req = [self parsePayload:payload];
    if (!req) return nil;
    NSString *pid = req[@"platform"];
    NSUInteger limit = [req[@"limit"] unsignedIntegerValue];
    NSString *filter = req[@"filter"];

    if ([pid isEqualToString:@"all"]) {
        NSMutableString *out = [NSMutableString stringWithFormat:@"【全网热点】%@", InsHotClock()];
        NSUInteger each = MAX(3, MIN(limit, 4));
        for (NSString *one in @[@"weibo", @"douyin", @"zhihu"]) {
            NSString *name = [self nameForPlatform:one];
            NSString *block = [self blockForPlatform:one limit:each filter:filter title:name showHeader:NO];
            [out appendFormat:@"\n\n— %@ —\n%@", name, block];
        }
        [out appendFormat:@"\n\n单独看某个平台：%@ 微博热点", [InsConfig shared].trigger];
        return out;
    }

    NSString *name = [self nameForPlatform:pid];
    NSString *block = [self blockForPlatform:pid limit:limit filter:filter title:name showHeader:YES];
    NSMutableString *out = [NSMutableString stringWithString:block];
    if ([block hasPrefix:@"【"]) {
        [out appendFormat:@"\n\n换平台：%@ 抖音热点 / 知乎热点 / 百度热点 / 头条热点 / B站热点；"
                          @"一次看三家：%@ 全网热点", [InsConfig shared].trigger, [InsConfig shared].trigger];
    }
    return out;
}

+ (BOOL)handlesPayload:(NSString *)payload {
    return [self parsePayload:payload] != nil;
}

@end
