#import "InsMemory.h"
#import "InsConfig.h"
#import "InsHistory.h"
#import "InsLLM.h"
#import "InsSend.h"

static NSMutableSet<NSString *> *gSyncing = nil;
static NSObject *gMemoryLock = nil;
static dispatch_queue_t InsMemoryQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.xuezeng.insomnia.memory", DISPATCH_QUEUE_SERIAL);
        gSyncing = [NSMutableSet set];
        gMemoryLock = [NSObject new];
    });
    return q;
}

/// 同步单独一条队列：长同步不再占内存队列，也不占命令队列
static dispatch_queue_t InsSyncQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.xuezeng.insomnia.sync", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static NSString *InsSafeName(NSString *wxid) {
    NSMutableCharacterSet *allowed = [[NSMutableCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"_-"];
    return [[wxid componentsSeparatedByCharactersInSet:[allowed invertedSet]] componentsJoinedByString:@"_"] ?: @"unknown";
}

/// 记忆也做一份 Library/Caches 备份：Documents 被重建或锁屏读不到时，进度不会归零
static NSString *InsMBackupDir(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [caches stringByAppendingPathComponent:@"InsomniaMemory"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *InsMBackupPathFor(NSString *wxid) {
    return [[InsMBackupDir() stringByAppendingPathComponent:InsSafeName(wxid)]
            stringByAppendingString:@".json"];
}

static NSDictionary *InsMRead(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) return nil;
    NSDictionary *d = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [d isKindOfClass:[NSDictionary class]] ? d : nil;
}

static void InsMUnprotect(NSString *path) {
    [[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone}
                                     ofItemAtPath:path error:nil];
}

static NSString *InsStamp(uint32_t t) {
    static NSDateFormatter *fmt;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm";
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    });
    // 回填是并发跑的，NSDateFormatter 不是线程安全的
    @synchronized (fmt) {
        return [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]];
    }
}

static NSDictionary *InsEmpty(NSString *wxid) {
    return @{
        @"wxid": wxid ?: @"",
        @"name": @"",
        @"updatedAt": @0,
        @"cursor": @0,
        @"summary": @"",
        @"facts": @[],
        @"recent": @[],
        @"stats": @{@"scanned": @0, @"chunks": @0},
    };
}

@implementation InsMemory

#pragma mark - 人称口径

+ (NSString *)selfLabel {
    NSString *alias = [InsConfig shared].selfAlias;
    return alias.length ? alias : @"你";
}

+ (NSString *)partnerLabelForTalker:(NSString *)wxid {
    NSString *name = nil;
    NSDictionary *memory = [self load:wxid];
    if ([memory[@"name"] isKindOfClass:[NSString class]]) name = memory[@"name"];
    if (!name.length) name = [InsSend displayNameForTalker:wxid];
    if ([name isEqualToString:wxid] || [name hasPrefix:@"wxid_"] || [name hasSuffix:@"@chatroom"]) name = nil;
    if (!name.length) return [wxid hasSuffix:@"@chatroom"] ? @"群里其他人" : @"对方";
    return name;
}

+ (NSString *)roleRulesForTalker:(NSString *)wxid {
    NSString *me = [self selfLabel];
    NSString *other = [self partnerLabelForTalker:wxid];
    return [NSString stringWithFormat:
        @"【人物称谓 · 最高优先级，覆盖下面任何与它冲突的描述】\n"
        @"1. 你是第三方助手，只负责叙述和分析，不是聊天里的任何一方；一律用第三人称叙述聊天内容，"
        @"不要用「我」指代聊天中的任何人，也不要把自己代入其中一方。\n"
        @"2. 记录里的「%@」＝微信账号主人，也就是正在向你提问、让你整理记忆的那个人；"
        @"这是说话人标签，不是指你模型自己。\n"
        @"3. 记录里的「%@」＝另一方的备注/姓名；提到这一方时一律用这个名字，"
        @"不要写成「对方」「他」「她」「某人」「用户」这类含混称呼。\n"
        @"4. 谁说的就归谁：「%@」说过的话、喜欢的东西、做过的事归「%@」；"
        @"「%@」说过的话、喜欢的东西、做过的事归「%@」。严禁对调，也不要合并成「两人」「双方」「他们」。\n"
        @"5. 不臆测身份、不编造没出现的人名和事件；合并转发记录里的人名按原文使用。",
        me, other, me, me, other, other];
}

+ (NSString *)speakerLabelForMe:(BOOL)me talker:(NSString *)wxid speakerName:(NSString *)speakerName {
    if (me) return [self selfLabel];
    if (speakerName.length) return speakerName;      // 群聊里逐条记下的发言人
    return [self partnerLabelForTalker:wxid];
}

+ (NSString *)pathFor:(NSString *)wxid {
    NSString *dir = [[InsConfig rootDir] stringByAppendingPathComponent:@"memory"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:[InsSafeName(wxid) stringByAppendingString:@".json"]];
}

+ (NSDictionary *)load:(NSString *)wxid {
    if (!wxid.length) return InsEmpty(wxid);
    NSDictionary *dict = InsMRead([self pathFor:wxid]);
    if (!dict) {
        NSDictionary *bk = InsMRead(InsMBackupPathFor(wxid));
        if (bk) {
            dict = bk;
            [InsConfig log:@"记忆主文件读不到，已从 Caches 备份恢复该会话进度"];
            [self save:bk for:wxid];
        }
    }
    if (![dict isKindOfClass:[NSDictionary class]]) return InsEmpty(wxid);
    return dict;
}

+ (void)save:(NSDictionary *)memory for:(NSString *)wxid {
    NSMutableDictionary *out = [memory mutableCopy];
    NSString *path = [self pathFor:wxid];
    NSDictionary *disk = InsMRead(path) ?: InsMRead(InsMBackupPathFor(wxid));
    // 防归零：本次写入会把进度清空、而磁盘/备份上明明有进度，说明只是文件暂时读不到
    BOOL diskHasProgress = [disk[@"cursor"] unsignedIntValue] > 0 ||
        [disk[@"stats"][@"scanned"] unsignedIntegerValue] > 0 ||
        ([disk[@"summary"] isKindOfClass:[NSString class]] && [disk[@"summary"] length] > 0);
    BOOL incomingEmpty = [out[@"cursor"] unsignedIntValue] == 0 &&
        [out[@"stats"][@"scanned"] unsignedIntegerValue] == 0 &&
        !([out[@"summary"] isKindOfClass:[NSString class]] && [out[@"summary"] length] > 0);
    if (diskHasProgress && incomingEmpty) {
        for (NSString *k in @[@"cursor", @"summary", @"facts", @"stats", @"name", @"updatedAt"]) {
            if (disk[k]) out[k] = disk[k];
        }
        [InsConfig log:@"记忆文件已有进度，本次写入保留磁盘上的长期字段，避免归零"];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingPrettyPrinted error:nil];
    if (!data.length) return;
    if ([data writeToFile:path atomically:YES]) {
        InsMUnprotect(path);
        NSString *bk = InsMBackupPathFor(wxid);
        if ([data writeToFile:bk atomically:YES]) InsMUnprotect(bk);
    }
}

+ (NSUInteger)syncingCount {
    InsMemoryQueue();
    @synchronized (gSyncing) { return gSyncing.count; }
}

/// 遍历所有会话的记忆文件，给定时进度汇报用（按已同步条数倒序）
+ (NSArray<NSDictionary *> *)allSummaries {
    NSString *dir = [[InsConfig rootDir] stringByAppendingPathComponent:@"memory"];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *f in files) {
        if (![f hasSuffix:@".json"]) continue;
        NSDictionary *d = InsMRead([dir stringByAppendingPathComponent:f])
                          ?: InsMRead([InsMBackupDir() stringByAppendingPathComponent:f]);
        if (!d) continue;
        NSString *name = ([d[@"name"] isKindOfClass:[NSString class]] && [d[@"name"] length])
                         ? d[@"name"] : [f stringByDeletingPathExtension];
        [out addObject:@{@"name": name,
                         @"scanned": @([d[@"stats"][@"scanned"] unsignedIntegerValue]),
                         @"chunks": @([d[@"stats"][@"chunks"] unsignedIntegerValue]),
                         @"total": @([d[@"stats"][@"total"] unsignedIntegerValue]),
                         @"cursor": @([d[@"cursor"] unsignedIntValue]),
                         @"summary": ([d[@"summary"] isKindOfClass:[NSString class]] ? d[@"summary"] : @"")}];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSUInteger sa = [a[@"scanned"] unsignedIntegerValue], sb = [b[@"scanned"] unsignedIntegerValue];
        return sa > sb ? NSOrderedAscending : (sa < sb ? NSOrderedDescending : NSOrderedSame);
    }];
    return out;
}

+ (NSArray<NSDictionary *> *)nameIndex {
    NSString *dir = [[InsConfig rootDir] stringByAppendingPathComponent:@"memory"];
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *f in files) {
        if (![f hasSuffix:@".json"]) continue;
        NSDictionary *d = InsMRead([dir stringByAppendingPathComponent:f])
                          ?: InsMRead([InsMBackupDir() stringByAppendingPathComponent:f]);
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSString *wxid = [d[@"wxid"] isKindOfClass:[NSString class]] ? d[@"wxid"] : nil;
        if (!wxid.length) wxid = [[f stringByDeletingPathExtension] stringByReplacingOccurrencesOfString:@"_" withString:@""];
        if (!wxid.length || [seen containsObject:wxid]) continue;
        NSString *name = [d[@"name"] isKindOfClass:[NSString class]] ? d[@"name"] : nil;
        if (!name.length) name = [InsSend displayNameForTalker:wxid];
        if (!name.length || [name hasPrefix:@"wxid_"]) continue;   // 没备注名的会话按名字找不到
        [seen addObject:wxid];
        [out addObject:@{@"wxid": wxid,
                         @"name": name,
                         @"scanned": @([d[@"stats"][@"scanned"] unsignedIntegerValue])}];
    }
    return out;
}

+ (NSString *)crossMemoryForQuestion:(NSString *)text excludeTalker:(NSString *)talker {
    if (text.length < 2) return @"";
    NSDictionary *best = nil;
    for (NSDictionary *entry in [self nameIndex]) {
        NSString *name = entry[@"name"];
        if (![name isKindOfClass:[NSString class]] || name.length < 2) continue;
        if ([talker isEqualToString:entry[@"wxid"]]) continue;     // 本会话已经单独拼过记忆
        if ([text rangeOfString:name].location == NSNotFound) continue;
        // 名字更长的优先：「林健」不该被「林」类短名抢走
        if (!best || name.length > [best[@"name"] length]) best = entry;
    }
    if (!best) return @"";
    NSString *wxid = best[@"wxid"];
    NSMutableString *chunk = [NSMutableString string];
    NSString *block = [self contextBlockForTalker:wxid];
    if (block.length) {
        if (block.length > 1200) block = [[block substringToIndex:1200] stringByAppendingString:@"\n…（记忆过长，已截断）"];
        [chunk appendString:block];
    }
    // 摘要里往往没有具体句子；再补最近几条原文，问「他说了啥」才答得出来
    NSArray *recent = [InsHistory latestTextMessagesForTalker:wxid count:8];
    if (recent.count) {
        [chunk appendString:@"\n【最近的原文】"];
        for (NSDictionary *row in [recent reverseObjectEnumerator]) {
            NSString *text = row[@"text"];
            if (text.length > 60) text = [[text substringToIndex:60] stringByAppendingString:@"…"];
            [chunk appendFormat:@"\n%@: %@",
             [self speakerLabelForMe:[row[@"me"] boolValue] talker:wxid speakerName:nil], text];
        }
    }
    if (!chunk.length) return @"";
    return [NSString stringWithFormat:@"\n\n【另一个会话的记忆：%@】\n%@", best[@"name"], chunk];
}

+ (void)reset:(NSString *)wxid {
    NSString *path = [self pathFor:wxid];
    // 必须排在 recordMessage 的写入后面，否则那条待写的旧记录会把文件又建回来
    dispatch_sync(InsMemoryQueue(), ^{
        @synchronized (gMemoryLock) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        }
    });
}

+ (void)recordMessage:(NSString *)wxid text:(NSString *)text me:(BOOL)me time:(uint32_t)time name:(NSString *)name {
    if (!wxid.length || !text.length) return;
    BOOL isRoom = [wxid hasSuffix:@"@chatroom"];
    dispatch_async(InsMemoryQueue(), ^{
        @synchronized (gMemoryLock) {
            NSMutableDictionary *memory = [[self load:wxid] mutableCopy];
            NSMutableArray *recent = [([memory[@"recent"] isKindOfClass:[NSArray class]] ? memory[@"recent"] : @[]) mutableCopy];
            NSMutableDictionary *row = [@{@"t": @(time), @"me": @(me), @"text": text} mutableCopy];
            if (name.length) row[@"n"] = name;   // 群聊里每条消息的发言人各不相同，只能逐条记
            [recent addObject:row];
            while (recent.count > 60) [recent removeObjectAtIndex:0];
            memory[@"recent"] = recent;
            memory[@"updatedAt"] = @((uint32_t)[[NSDate date] timeIntervalSince1970]);
            if (name.length && !isRoom) memory[@"name"] = name;
            [self save:memory for:wxid];
        }
    });
}

+ (NSString *)contextBlockForTalker:(NSString *)wxid {
    NSDictionary *memory = [self load:wxid];
    NSMutableArray *lines = [NSMutableArray array];
    NSString *summary = [memory[@"summary"] isKindOfClass:[NSString class]] ? memory[@"summary"] : @"";
    NSArray *facts = [memory[@"facts"] isKindOfClass:[NSArray class]] ? memory[@"facts"] : @[];
    NSArray *recent = [memory[@"recent"] isKindOfClass:[NSArray class]] ? memory[@"recent"] : @[];
    if (!summary.length && !facts.count && !recent.count) return @"";

    if (summary.length) [lines addObjectsFromArray:@[@"【长期记忆】", summary]];
    if (facts.count) {
        [lines addObject:@"【要点】"];
        for (id f in facts) {
            if ([f isKindOfClass:[NSString class]] && [f length]) [lines addObject:[NSString stringWithFormat:@"- %@", f]];
        }
    }
    if (recent.count) {
        [lines addObject:@"【最近记录】"];
        for (NSDictionary *m in recent) {
            if (![m isKindOfClass:[NSDictionary class]]) continue;
            // 「我」会让模型把用户本人误认成助手自己，统一换成 selfLabel；群聊优先逐条发言人
            NSString *who = [self speakerLabelForMe:[m[@"me"] boolValue] talker:wxid
                                       speakerName:([m[@"n"] isKindOfClass:[NSString class]] ? m[@"n"] : nil)];
            [lines addObject:[NSString stringWithFormat:@"%@ %@: %@",
                              InsStamp([m[@"t"] unsignedIntValue]), who, m[@"text"]]];
        }
    }
    uint32_t cursor = [memory[@"cursor"] unsignedIntValue];
    NSUInteger scanned = [memory[@"stats"][@"scanned"] unsignedIntegerValue];
    [lines insertObject:[NSString stringWithFormat:
                         @"【称谓】「%@」＝微信账号主人，「%@」＝对方；以下每行开头都是说话人标签。",
                         [self selfLabel], [self partnerLabelForTalker:wxid]] atIndex:0];
    [lines insertObject:[NSString stringWithFormat:@"【同步进度】已扫描 %lu 条历史，同步到 %@",
                         (unsigned long)scanned, cursor ? InsStamp(cursor) : @"尚未同步"] atIndex:0];
    return [lines componentsJoinedByString:@"\n"];
}

+ (BOOL)isSyncing:(NSString *)wxid {
    // 只查集合，绝不 dispatch_sync 进队列——同步任务独占队列时会把调用方一起冻住
    @synchronized (gSyncing) {
        return [gSyncing containsObject:wxid];
    }
}

static NSDictionary *InsParseJSONLenient(NSString *text) {
    if (!text.length) return nil;
    NSRange first = [text rangeOfString:@"{"];
    NSRange last = [text rangeOfString:@"}" options:NSBackwardsSearch];
    if (first.location == NSNotFound || last.location == NSNotFound || last.location <= first.location) return nil;
    NSString *slice = [text substringWithRange:NSMakeRange(first.location, last.location + last.length - first.location)];
    NSData *data = [slice dataUsingEncoding:NSUTF8StringEncoding];
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

/// 没有信息量的短回复：留着只会把 token 烧光，对记忆没有任何贡献
static NSSet *InsNoiseWords(void) {
    static NSSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"嗯", @"嗯嗯", @"哦", @"哦哦", @"啊", @"哈", @"哈哈", @"哈哈哈",
                                    @"好", @"好的", @"行", @"行吧", @"呃", @"唉", @"在", @"在吗",
                                    @"ok", @"okay", @"？", @"?", @"。", @".", @"1", @"+1",
                                    @"[表情]", @"[动画表情]", @"[图片]", @"[语音]"]];
    });
    return set;
}

/// 单条消息瘦身：超长链接只留开头，超长文本截断，纯语气词直接丢掉
static NSString *InsSlimText(NSString *text) {
    NSString *t = [(text ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return nil;
    if (t.length <= 4 && [InsNoiseWords() containsObject:[t lowercaseString]]) return nil;
    if (t.length > 400) {
        t = [[t substringToIndex:400] stringByAppendingString:@"…"];
    } else if (t.length > 80) {
        NSRange http = [t rangeOfString:@"http"];
        if (http.location != NSNotFound && http.location < 12) {
            // 链接正文对长期记忆没意义，留个开头足够知道「他发过这么个东西」
            t = [[t substringToIndex:60] stringByAppendingString:@"…"];
        }
    }
    return t;
}

/// 把一批消息拼成「时间 说话人: 内容」的转录
+ (NSString *)transcriptForRows:(NSArray *)rows me:(NSString *)meLabel other:(NSString *)otherLabel {
    NSMutableString *out = [NSMutableString string];
    for (NSDictionary *row in rows) {
        NSString *text = InsSlimText([row[@"text"] isKindOfClass:[NSString class]] ? row[@"text"] : @"");
        if (!text) continue;
        [out appendFormat:@"%@ %@: %@\n", InsStamp([row[@"t"] unsignedIntValue]),
            [row[@"me"] boolValue] ? meLabel : otherLabel, text];
    }
    return out;
}

/// 把一批要点合并进记忆（summary 重写 + facts 覆盖）。失败时不动 memory，调用方保留要点下次再合。
+ (BOOL)mergeFacts:(NSArray *)facts
        intoMemory:(NSMutableDictionary *)memory
                me:(NSString *)meLabel
             other:(NSString *)otherLabel
             rules:(NSString *)rules {
    NSMutableString *list = [NSMutableString string];
    NSUInteger kept = 0;
    for (id item in facts) {
        if (![item isKindOfClass:[NSString class]] || ![item length]) continue;
        if (++kept > 300) break;
        [list appendFormat:@"- %@\n", item];
    }
    if (!list.length) return YES;
    NSString *system = [NSString stringWithFormat:
        @"%@\n\n"
        @"你是私人记忆整理器。把新要点合并进已有记忆，只输出 JSON，不要解释、不要代码块。"
        @"结构：{\"summary\":\"对该联系人的整体长期记忆，200字以内，写明覆盖的时间范围；第三人称要写清，"
        @"分别写清「%@」和「%@」各自说过什么、喜欢什么、做过什么，禁止用「两人」「双方」当主语；"
        @"若整段只有一方发言（文件传输助手这类单向会话），写成这一方单方面记录，绝不写反\","
        @"\"facts\":[\"最多40条，每条以人物标签开头，尽量带日期\"]}",
        rules, meLabel, otherLabel];
    NSString *user = [NSString stringWithFormat:
        @"已有记忆 summary：%@\n已有记忆 facts：%@\n\n新增要点（来自新读到的聊天记录）：\n%@",
        memory[@"summary"] ?: @"", memory[@"facts"] ?: @[], list];
    NSError *error = nil;
    NSString *answer = [InsLLM askSystem:system user:user error:&error];
    NSDictionary *parsed = InsParseJSONLenient(answer);
    if (!parsed) {
        [InsConfig log:[NSString stringWithFormat:@"要点合并失败：%@",
                        error.localizedDescription ?: @"返回无法解析"]];
        return NO;
    }
    if ([parsed[@"summary"] isKindOfClass:[NSString class]]) memory[@"summary"] = parsed[@"summary"];
    if ([parsed[@"facts"] isKindOfClass:[NSArray class]]) memory[@"facts"] = parsed[@"facts"];
    memory[@"updatedAt"] = @((uint32_t)[[NSDate date] timeIntervalSince1970]);
    return YES;
}

/// 从一段转录里抽要点（只输出短 facts，比让模型重写整段记忆快得多）
static NSArray *InsExtractFacts(NSString *transcript, NSString *rules,
                                NSString *meLabel, NSString *otherLabel, NSString **errText) {
    if (!transcript.length) return @[];
    NSString *system = [NSString stringWithFormat:
        @"%@\n\n"
        @"你是聊天记录的要点抽取器。只输出 JSON，不要解释、不要代码块。"
        @"结构：{\"facts\":[\"要点短句\"]}。每条必须以人物标签开头（「%@」或「%@」），"
        @"尽量带日期（如 2026-02-14，聊天里没写的不要编），只写明确出现过的事实，不评价，最多 10 条。",
        rules, meLabel, otherLabel];
    NSError *err = nil;
    NSString *answer = [InsLLM askSystem:system user:transcript error:&err];
    NSDictionary *parsed = InsParseJSONLenient(answer);
    NSArray *facts = [parsed[@"facts"] isKindOfClass:[NSArray class]] ? parsed[@"facts"] : nil;
    if (!facts && errText) *errText = err.localizedDescription ?: @"返回无法解析";
    return facts;
}

/// 大体量回填：并发「抽要点」+ 少量「合并」调用。
/// 老办法是每 120 条就让模型重写一遍完整记忆（输出重、串行），8 万条要跑十几轮；
/// 这里改成每段 500 条、3 路并发只抽要点（输出短），攒到 120 条要点再合并一次。
+ (NSError *)runBulkSyncFor:(NSString *)wxid
                       name:(NSString *)name
                     memory:(NSMutableDictionary *)memory
                      total:(NSUInteger)total
                         me:(NSString *)meLabel
                      other:(NSString *)otherLabel
                      rules:(NSString *)rules
                   progress:(void (^)(NSString *))progress {
    InsConfig *cfg = [InsConfig shared];
    NSUInteger chunk = (NSUInteger)MAX(200, cfg.syncChunkSize);
    NSUInteger lanes = (NSUInteger)MAX(1, MIN(4, cfg.syncConcurrency));
    NSUInteger rounds = (NSUInteger)MAX(1, cfg.syncBulkRounds);

    uint32_t cursor = (uint32_t)[memory[@"cursor"] unsignedIntValue];
    NSUInteger scanned = (NSUInteger)[memory[@"stats"][@"scanned"] unsignedIntegerValue];
    NSUInteger chunks = (NSUInteger)[memory[@"stats"][@"chunks"] unsignedIntegerValue];
    NSMutableArray *pool = [NSMutableArray array];
    if ([memory[@"bulkFacts"] isKindOfClass:[NSArray class]]) {
        [pool addObjectsFromArray:memory[@"bulkFacts"]];
    }

    time_t started = time(NULL);
    NSUInteger runScanned = 0;
    NSError *failure = nil;

    for (NSUInteger round = 0; round < rounds; round++) {
        // 1) 顺序切出 lanes 段（游标只在拿到结果后才前进，失败重跑也不会漏）
        NSMutableArray *batches = [NSMutableArray array];
        uint32_t probe = cursor;
        for (NSUInteger lane = 0; lane < lanes; lane++) {
            NSArray *rows = [InsHistory textMessagesForTalker:wxid afterTime:probe maxCount:(NSInteger)chunk];
            if (!rows.count) break;
            probe = [[rows lastObject][@"t"] unsignedIntValue];
            [batches addObject:rows];
        }
        if (!batches.count) break;

        // 2) 并发抽取要点
        NSMutableArray *results = [NSMutableArray array];
        dispatch_group_t group = dispatch_group_create();
        for (NSUInteger i = 0; i < batches.count; i++) {
            NSArray *rows = batches[i];
            uint32_t last = [[rows lastObject][@"t"] unsignedIntValue];
            NSString *transcript = [self transcriptForRows:rows me:meLabel other:otherLabel];
            if (!transcript.length) {
                @synchronized (results) {
                    [results addObject:@{@"i": @(i), @"facts": @[], @"cursor": @(last), @"count": @(rows.count)}];
                }
                continue;
            }
            dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSString *errText = nil;
                NSArray *facts = InsExtractFacts(transcript, rules, meLabel, otherLabel, &errText);
                @synchronized (results) {
                    [results addObject:@{@"i": @(i), @"facts": facts ?: @[], @"cursor": @(last),
                                         @"count": @(rows.count), @"ok": @(facts != nil),
                                         @"err": errText ?: @""}];
                }
            });
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        if (!results.count) break;

        // 2.5) 失败的段串行补跑一次：游标按时间推进，跳过一段就是 500 条永远丢掉
        for (NSUInteger i = 0; i < results.count; i++) {
            NSDictionary *r = results[i];
            if ([r[@"ok"] boolValue]) continue;
            NSUInteger idx = [r[@"i"] unsignedIntegerValue];
            if (idx >= batches.count) continue;
            NSString *transcript = [self transcriptForRows:batches[idx] me:meLabel other:otherLabel];
            NSString *errText = nil;
            NSArray *facts = InsExtractFacts(transcript, rules, meLabel, otherLabel, &errText);
            if (!facts) continue;
            NSMutableDictionary *fixed = [r mutableCopy];
            fixed[@"facts"] = facts;
            fixed[@"ok"] = @YES;
            results[i] = fixed;
        }

        // 3) 按时间顺序推进游标、收集要点
        [results sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"i"] compare:b[@"i"]];
        }];
        BOOL anyOK = NO;
        NSString *lastErr = nil;
        for (NSDictionary *r in results) {
            cursor = [r[@"cursor"] unsignedIntValue];
            scanned += [r[@"count"] unsignedIntegerValue];
            runScanned += [r[@"count"] unsignedIntegerValue];
            chunks++;
            if ([r[@"ok"] boolValue]) {
                anyOK = YES;
                for (id f in r[@"facts"]) {
                    if ([f isKindOfClass:[NSString class]] && [f length]) [pool addObject:f];
                }
            } else if ([r[@"err"] length]) {
                lastErr = r[@"err"];
            }
        }
        if (!anyOK) {
            failure = [NSError errorWithDomain:@"Insomnia" code:-13
                                      userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"回填中断：%@", lastErr ?: @"模型返回无法解析"]}];
            break;
        }

        // 4) 要点攒够就先合并一次，之后落盘（进程被杀也能接着跑）
        if (pool.count >= 120) {
            if ([self mergeFacts:pool intoMemory:memory me:meLabel other:otherLabel rules:rules]) {
                [pool removeAllObjects];
            } else if (pool.count > 400) {
                [pool removeObjectsInRange:NSMakeRange(0, pool.count - 400)];
            }
        }
        memory[@"cursor"] = @(cursor);
        memory[@"stats"] = @{@"scanned": @(scanned), @"chunks": @(chunks), @"total": @(total)};
        memory[@"bulkFacts"] = pool.count ? pool : @[];
        @synchronized (gMemoryLock) {
            NSDictionary *fresh = [self load:wxid];
            if ([fresh[@"recent"] isKindOfClass:[NSArray class]]) memory[@"recent"] = fresh[@"recent"];
            [self save:memory for:wxid];
        }

        if (progress) {
            NSTimeInterval elapsed = MAX(1.0, (double)(time(NULL) - started));
            double perMsg = elapsed / (double)MAX((NSUInteger)1, runScanned);
            NSUInteger left = total > scanned ? total - scanned : 0;
            if (left) {
                progress([NSString stringWithFormat:@"回填 %lu/%lu 条%@，预计还需 %lu 分钟",
                          (unsigned long)scanned, (unsigned long)total,
                          name.length ? [NSString stringWithFormat:@"（%@）", name] : @"",
                          (unsigned long)MAX((NSUInteger)1, (NSUInteger)(perMsg * left / 60.0 + 0.999))]);
            } else {
                progress([NSString stringWithFormat:@"回填 %lu/%lu 条%@，已到最新",
                          (unsigned long)scanned, (unsigned long)total,
                          name.length ? [NSString stringWithFormat:@"（%@）", name] : @""]);
            }
        }
    }

    // 5) 收尾：把剩下的要点合并掉，再清空缓存要点
    if (pool.count) {
        if ([self mergeFacts:pool intoMemory:memory me:meLabel other:otherLabel rules:rules]) {
            [pool removeAllObjects];
        }
    }
    memory[@"cursor"] = @(cursor);
    memory[@"stats"] = @{@"scanned": @(scanned), @"chunks": @(chunks), @"total": @(total)};
    memory[@"bulkFacts"] = pool;
    @synchronized (gMemoryLock) {
        NSDictionary *fresh = [self load:wxid];
        if ([fresh[@"recent"] isKindOfClass:[NSArray class]]) memory[@"recent"] = fresh[@"recent"];
        [self save:memory for:wxid];
    }
    return failure;
}

+ (void)syncTalker:(NSString *)wxid
              name:(NSString *)name
          progress:(void (^)(NSString *))progress
        completion:(void (^)(NSString *, NSError *))completion {
    if (!wxid.length) {
        if (completion) completion(nil, [NSError errorWithDomain:@"Insomnia" code:-10
                                                       userInfo:@{NSLocalizedDescriptionKey: @"无法确定会话对象"}]);
        return;
    }
    dispatch_async(InsSyncQueue(), ^{
        @synchronized (gSyncing) {
            if ([gSyncing containsObject:wxid]) {
                if (completion) completion(nil, [NSError errorWithDomain:@"Insomnia" code:-11
                                                                userInfo:@{NSLocalizedDescriptionKey: @"该对象正在同步中"}]);
                return;
            }
            [gSyncing addObject:wxid];
        }
        InsConfig *cfg = [InsConfig shared];
        // 摘要与问答共用同一套称谓：绝不能把用户本人标成「我」（模型会当成它自己）
        NSString *meLabel = [self selfLabel];
        NSString *otherLabel = name.length ? name : ([wxid hasSuffix:@"@chatroom"] ? @"群里其他人" : @"对方");
        NSString *rules = [self roleRulesForTalker:wxid];
        NSError *failure = nil;
        NSUInteger total = [InsHistory totalTextMessageCountForTalker:wxid];
        if (progress) progress([NSString stringWithFormat:@"开始同步 %@，共 %lu 条文本消息", name.length ? name : wxid, (unsigned long)total]);

        NSMutableDictionary *memory;
        @synchronized (gMemoryLock) {
            memory = [[self load:wxid] mutableCopy];
        }
        if (name.length) memory[@"name"] = name;
        uint32_t cursor = (uint32_t)[memory[@"cursor"] unsignedIntValue];
        NSUInteger chunks = (NSUInteger)[memory[@"stats"][@"chunks"] unsignedIntegerValue];
        NSUInteger scanned = (NSUInteger)[memory[@"stats"][@"scanned"] unsignedIntegerValue];

        // 历史量很大时先做并发回填：一段 500 条、3 路并行抽要点，攒够再合并，
        // 比「每 120 条重写一遍完整记忆」快一个数量级
        NSUInteger backlog = total > scanned ? total - scanned : 0;
        BOOL bulk = total > 0 && backlog > (NSUInteger)MAX(0, cfg.syncBulkThreshold);
        if (bulk) {
            failure = [self runBulkSyncFor:wxid name:name memory:memory total:total
                                        me:meLabel other:otherLabel rules:rules progress:progress];
        }

        for (NSUInteger call = 0; !bulk && call < (NSUInteger)cfg.maxChunkCalls; call++) {
            NSArray *rows = [InsHistory textMessagesForTalker:wxid afterTime:cursor maxCount:cfg.chunkSize];
            if (!rows.count) break;

            NSString *transcript = [self transcriptForRows:rows me:meLabel other:otherLabel];
            NSString *system = [NSString stringWithFormat:
                @"%@\n\n"
                @"你是私人记忆整理器。把新的聊天内容合并进已有记忆，只输出 JSON，不要解释、不要代码块。"
                @"JSON 结构：{\"summary\":\"对该联系人的整体长期记忆，200字以内，写明覆盖的时间范围；"
                @"第三人称叙述，分别写清「%@」和「%@」各自说过什么、喜欢什么、做过什么，"
                @"禁止用「两人」「双方」当主语；"
                @"若整段记录只有一方发言（文件传输助手这类单向会话就是这样），"
                @"必须写成这一方单方面记录/转发、另一方从未发言，绝不写反\","
                @"\"facts\":[\"要点短句，最多40条，每条开头带人物标签（%@ 或 %@），"
                @"尽量保留日期（如 2026-02-14 或 2月14日），聊天里没写的日期不要编\"]}",
                rules, meLabel, otherLabel, meLabel, otherLabel];
            NSString *user = [NSString stringWithFormat:
                @"%@\n\n已有记忆 summary：%@\n已有记忆 facts：%@\n\n新增聊天记录（每行开头是说话人标签）：\n%@",
                rules, memory[@"summary"] ?: @"", memory[@"facts"] ?: @[], transcript];

            NSError *error = nil;
            NSString *answer = [InsLLM askSystem:system user:user error:&error];
            if (!answer) {
                failure = error;
                break;
            }
            NSDictionary *parsed = InsParseJSONLenient(answer);
            if (!parsed) {
                // 多半是输出太长被截断：换紧凑格式重试一次，还不行才报错
                [InsConfig log:[NSString stringWithFormat:@"记忆返回解析失败，紧凑重试。原返回开头：%@",
                                [answer substringToIndex:MIN(answer.length, 200)]]];
                NSString *compact = [NSString stringWithFormat:
                    @"%@\n\n你是私人记忆整理器。只输出一个 JSON 对象，不要解释、不要代码块。"
                    @"结构：{\"summary\":\"长期记忆，120字以内，写明覆盖的时间范围，第三人称，"
                    @"分别写清「%@」和「%@」各自的事，禁止用「两人」「双方」\","
                    @"\"facts\":[\"要点短句，最多20条，每条带人物标签，尽量保留日期\"]}"
                    @"总输出控制在 600 字以内。", rules, meLabel, otherLabel];
                parsed = InsParseJSONLenient([InsLLM askSystem:compact user:user error:nil]);
            }
            if (!parsed) {
                NSString *head = [answer substringToIndex:MIN(answer.length, 200)];
                failure = [NSError errorWithDomain:@"Insomnia" code:-12
                                          userInfo:@{NSLocalizedDescriptionKey:
                                                      [NSString stringWithFormat:@"记忆返回无法解析：%@", head]}];
                break;
            }
            if ([parsed[@"summary"] isKindOfClass:[NSString class]]) memory[@"summary"] = parsed[@"summary"];
            if ([parsed[@"facts"] isKindOfClass:[NSArray class]]) memory[@"facts"] = parsed[@"facts"];
            cursor = (uint32_t)[rows.lastObject[@"t"] unsignedIntValue];
            chunks++;
            scanned += rows.count;
            memory[@"cursor"] = @(cursor);
            memory[@"updatedAt"] = @((uint32_t)[[NSDate date] timeIntervalSince1970]);
            memory[@"stats"] = @{@"scanned": @(scanned), @"chunks": @(chunks), @"total": @(total)};
            // 同步期间 recordMessage 也在写文件：保存前把磁盘上最新的 recent 并回来，别盖掉
            @synchronized (gMemoryLock) {
                NSDictionary *fresh = [self load:wxid];
                if ([fresh[@"recent"] isKindOfClass:[NSArray class]]) memory[@"recent"] = fresh[@"recent"];
                [self save:memory for:wxid];
            }
            if (progress) progress([NSString stringWithFormat:@"已处理 %lu/%lu 条", (unsigned long)scanned, (unsigned long)total]);
        }

        @synchronized (gSyncing) {
            [gSyncing removeObject:wxid];
        }
        if (completion) {
            if (failure) {
                completion(nil, failure);
                return;
            }
            // bulk 模式在方法内部推进游标，回读一次拿最终数字
            NSDictionary *finalMemory = [self load:wxid];
            NSUInteger doneCount = [finalMemory[@"stats"][@"scanned"] unsignedIntegerValue];
            NSUInteger doneChunks = [finalMemory[@"stats"][@"chunks"] unsignedIntegerValue];
            uint32_t finalCursor = (uint32_t)[finalMemory[@"cursor"] unsignedIntValue];
            NSUInteger left = total > doneCount ? total - doneCount : 0;
            completion([NSString stringWithFormat:
                @"%@ 记忆同步完成：已扫描 %lu 条，摘要调用 %lu 次，游标停在 %@%@",
                name.length ? name : wxid, (unsigned long)MAX(doneCount, scanned),
                (unsigned long)MAX(doneChunks, chunks), InsStamp(finalCursor),
                left ? [NSString stringWithFormat:@"；还剩 %lu 条，再发一次 sync 接着跑", (unsigned long)left]
                     : @"，已到最新"], nil);
        }
    });
}

/// 旧摘要（「两人聊天…」这种分不清谁是谁的写法）按新称谓口径重写，不重跑 16 万条历史
+ (void)rewriteSummaryForTalker:(NSString *)wxid
                     completion:(void (^)(NSString *summary, NSError *error))completion {
    dispatch_async(InsSyncQueue(), ^{
        NSDictionary *memory = [self load:wxid];
        NSString *old = [memory[@"summary"] isKindOfClass:[NSString class]] ? memory[@"summary"] : @"";
        if (!old.length) {
            if (completion) completion(nil, [NSError errorWithDomain:@"Insomnia" code:-20
                userInfo:@{NSLocalizedDescriptionKey: @"这个会话还没有摘要，先 sync 一次"}]);
            return;
        }
        NSArray *facts = [memory[@"facts"] isKindOfClass:[NSArray class]] ? memory[@"facts"] : @[];
        NSString *rules = [self roleRulesForTalker:wxid];
        NSString *system = [NSString stringWithFormat:
            @"%@\n\n你是记忆改写器。按上面的称谓口径重写下面这段旧记忆，只输出一个 JSON 对象，不要解释、不要代码块。"
            @"结构：{\"summary\":\"200字以内的长期记忆，写明覆盖的时间范围，第三人称，"
            @"把含混的「两人」「双方」「他/她」拆成具体人物，谁的事就归谁，不要用「我」\","
            @"\"facts\":[\"要点短句，最多40条，每条开头带上人物标签\"]}"
            @"只改措辞和人物归属，保留原有事实与时间范围，不新增任何没写过的信息。", rules];
        NSString *user = [NSString stringWithFormat:
            @"旧摘要：\n%@\n\n要点：\n%@", old, [facts componentsJoinedByString:@"\n"]];
        NSError *error = nil;
        NSString *fresh = [InsLLM askSystem:system user:user error:&error];
        if (!fresh.length) {
            if (completion) completion(nil, error ?: [NSError errorWithDomain:@"Insomnia" code:-21
                userInfo:@{NSLocalizedDescriptionKey: @"改写返回为空"}]);
            return;
        }
        NSDictionary *parsed = InsParseJSONLenient(fresh);
        NSMutableDictionary *updated = [memory mutableCopy];
        NSString *shown = nil;
        if ([parsed[@"summary"] isKindOfClass:[NSString class]] && [parsed[@"summary"] length]) {
            updated[@"summary"] = parsed[@"summary"];
            if ([parsed[@"facts"] isKindOfClass:[NSArray class]] && [parsed[@"facts"] count]) {
                updated[@"facts"] = parsed[@"facts"];
            }
            shown = parsed[@"summary"];
        } else {
            NSString *clean = [[fresh stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                               stringByReplacingOccurrencesOfString:@"```" withString:@""];
            updated[@"summary"] = clean;
            shown = clean;
        }
        updated[@"updatedAt"] = @((uint32_t)[[NSDate date] timeIntervalSince1970]);
        @synchronized (gMemoryLock) {
            // 改写期间新消息还在写 recent，保存前把磁盘上最新的并回来，别盖掉
            NSDictionary *onDisk = [self load:wxid];
            if ([onDisk[@"recent"] isKindOfClass:[NSArray class]]) updated[@"recent"] = onDisk[@"recent"];
            [self save:updated for:wxid];
        }
        [InsConfig log:[NSString stringWithFormat:@"摘要已按新称谓口径重写 %@", wxid]];
        if (completion) completion(shown, nil);
    });
}

@end
