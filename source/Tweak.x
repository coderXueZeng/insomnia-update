#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#import "InsConfig.h"
#import "InsLLM.h"
#import "InsHistory.h"
#import "InsMemory.h"
#import "InsGen.h"
#import "InsSend.h"
#import "InsMedia.h"
#import "InsUpdate.h"
#import "InsSticker.h"
#import "InsProgress.h"
#import "InsOutbox.h"
#import "InsAutoLink.h"
#import "InsStat.h"
#import "InsHot.h"
#import "InsRelay.h"
#import "InsVoice.h"
#import <substrate.h>

static NSString *InsSelfWxid(void);
static void InsHandleWrap(id wrap, NSString *source);
static void InsRunCommand(NSString *payload, NSString *talker, NSString *displayName,
                          NSDictionary *linkOverride, NSDictionary *imageOverride,
                          NSString *recordOverride, NSDictionary *fileOverride,
                          BOOL owner, NSString *quoteNote, uint32_t msgTime);
static BOOL InsWantsLink(NSString *payload);
static BOOL InsWantsImage(NSString *payload, InsConfig *cfg);
static BOOL InsWantsRecord(NSString *payload);
static BOOL InsWantsScreenOpen(NSString *payload);
static NSInteger InsRecordIndex(NSString *payload);
static NSInteger InsLinkIndex(NSString *payload);
static BOOL InsSendLocal(NSString *talker, NSString *text);
static BOOL InsSendVia(NSString *talker, NSString *text);
static void InsReply(NSString *talker, NSString *text);
static void InsReplyNoQueue(NSString *talker, NSString *text);
static NSInteger InsImageCount(NSString *payload);
static NSString *InsKV(id object, NSString *key);
static NSString *InsImagePrompt(NSString *payload, InsConfig *cfg);
static BOOL InsImageContinuation(NSString *text, InsConfig *cfg);
static void InsWritePending(NSString *prompt, NSString *talker, NSString *chatName);
static void InsClearPending(void);
static BOOL InsReminderParse(NSString *payload, NSTimeInterval *outDelay, NSString **outContent, NSString **outWhen);
static void InsNote(NSString *line);
static BOOL InsCmdIs(NSString *lower, NSString *word);
static void InsFlushOutboxIfDue(void);
static NSString *InsLocalVersion(void);
static NSString *InsScrub(NSString *text);
static NSString *InsTailLines(NSInteger count);

static id gMessageMgr = nil;
static NSMutableSet *gSeen = nil;
static NSMutableArray *gOwnTexts = nil;

// 成语接龙会话：开局后同一会话里不带前缀的消息也进游戏；10 分钟无动静自动收摊。
static NSString *gGameTalker = nil;
static NSDate *gGameLast = nil;
static BOOL InsGameActive(NSString *talker) {
    if (![InsConfig shared].gameEnabled) return NO;
    if (!gGameTalker || !gGameLast) return NO;
    if (![talker isEqualToString:gGameTalker]) return NO;
    return (-[gGameLast timeIntervalSinceNow] < 600);
}
static void InsGameStart(NSString *talker) {
    gGameTalker = talker;
    gGameLast = [NSDate date];
    InsNote([NSString stringWithFormat:@"接龙会话开始：%@", talker]);
}
static void InsGameTouch(NSString *talker) {
    gGameTalker = talker;
    gGameLast = [NSDate date];
}
static void InsGameEnd(void) {
    if (gGameTalker) InsNote([NSString stringWithFormat:@"接龙会话结束：%@", gGameTalker]);
    gGameTalker = nil;
    gGameLast = nil;
}
static dispatch_queue_t gWork = nil;
static dispatch_queue_t gFast = nil;
static dispatch_queue_t gCover = nil;                     // 翻唱专用：6~8 分钟轮询不占工作队列
static NSUInteger gCoverDepth = 0;                        // 翻唱队列里排队/在处理的任务数（gPending 锁保护）
static NSMutableArray<NSDictionary *> *gPending = nil;   // 待执行命令，按 (消息时间, 到达序号) 升序
static _Atomic BOOL gQueueOn = true;                      // 排队（默认开）
static BOOL gDraining = NO;
static uint64_t gJobSeq = 0;
static NSString *gRunningLabel = nil;                     // 正在处理的那条（会话 + 摘要）
static NSTimeInterval gRunningAt = 0;                     // 开始处理的时刻
static _Atomic BOOL gImageClaimed = false;

static id InsMessageMgr(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class center = NSClassFromString(@"MMServiceCenter");
        Class mgr = NSClassFromString(@"CMessageMgr");
        if (center && mgr) {
            id defaultCenter = [center performSelector:@selector(defaultCenter)];
            if (defaultCenter && [defaultCenter respondsToSelector:@selector(getService:)]) {
                gMessageMgr = [defaultCenter performSelector:@selector(getService:) withObject:mgr];
            }
        }
        gSeen = [NSMutableSet set];
        gOwnTexts = [NSMutableArray array];
        gPending = [NSMutableArray array];
        // 命令改成「按消息时间排队、逐条执行」：多人同时 @ 时不会再并发，
        // 回答顺序 = 消息先后顺序。要恢复并发（一条慢请求不挡后面的）用「排队 关」。
        gWork = dispatch_queue_create("com.xuezeng.insomnia.work", DISPATCH_QUEUE_SERIAL);
        gFast = dispatch_queue_create("com.xuezeng.insomnia.fast", DISPATCH_QUEUE_CONCURRENT);
        // 翻唱单独一条串行队列：翻唱之间仍按顺序来，但不挡普通命令
        gCover = dispatch_queue_create("com.xuezeng.insomnia.cover", DISPATCH_QUEUE_SERIAL);
    });
    return gMessageMgr;
}

static void InsDrainWork(void);
static NSUInteger InsQueueDepth(void);

/// 入队一条命令。msgTime 是微信给的消息创建时间（秒），排序优先用它，
/// 取不到（0）时才用到达时刻，免得漏时间的消息插到最前面。
/// label 只用于日志和「排队」状态显示，不参与排序。
static void InsEnqueueWork(uint32_t msgTime, NSString *label, dispatch_block_t block) {
    if (!block) return;
    if (!atomic_load(&gQueueOn)) {       // 关掉排队：退回并发，先问完先回
        dispatch_async(gFast, block);
        return;
    }
    uint32_t t = msgTime ? msgTime : (uint32_t)[[NSDate date] timeIntervalSince1970];
    NSUInteger pos = 0;
    BOOL running = NO;
    @synchronized (gPending) {
        uint64_t seq = ++gJobSeq;
        NSDictionary *job = @{ @"t": @(t), @"s": @(seq), @"b": block, @"l": label ?: @"" };
        pos = gPending.count;
        for (NSUInteger i = 0; i < gPending.count; i++) {
            uint32_t xt = [gPending[i][@"t"] unsignedIntValue];
            // 同一秒的消息按到达先后排，别让后到的抢到前面
            if (xt > t || (xt == t && [gPending[i][@"s"] unsignedLongLongValue] > seq)) {
                pos = i;
                break;
            }
        }
        [gPending insertObject:job atIndex:pos];
        running = gDraining;
        if (!running) gDraining = YES;
    }
    // 日志放在锁外面写，别让文件 IO 拖住入队
    if (running) {
        NSDateFormatter *hm = [[NSDateFormatter alloc] init];
        hm.dateFormat = @"HH:mm:ss";
        NSString *when = [hm stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]];
        if (pos > 0) {
            InsNote([NSString stringWithFormat:@"排队：%@ 的消息排在第 %lu 位（前面 %lu 条）",
                     when, (unsigned long)pos + 1, (unsigned long)pos]);
        } else {
            InsNote([NSString stringWithFormat:@"排队：%@ 的消息要等正在处理的那条做完（%lu 条在等）",
                     when, (unsigned long)InsQueueDepth()]);
        }
        return;
    }
    dispatch_async(gWork, ^{ InsDrainWork(); });
}

/// 翻唱是「下单 → 轮询 6~8 分钟 → 取成品上传」，全程同步阻塞。
/// 它绝不能进 gWork：那条是普通命令的串行队列，一旦被翻唱占住，
/// 唱歌期间其他 @insomnia 命令（问答/语音/查东西）会一直排队等出片。
/// 这里单开一条串行队列：翻唱之间仍按顺序，普通命令不受影响。
static void InsEnqueueCover(NSString *label, dispatch_block_t block) {
    if (!block) return;
    NSUInteger depth = 0;
    @synchronized (gPending) {
        gCoverDepth += 1;
        depth = gCoverDepth;
    }
    InsNote([NSString stringWithFormat:@"翻唱队列：接入「%@」（第 %lu 条）",
             label ?: @"", (unsigned long)depth]);
    dispatch_async(gCover, ^{
        @try {
            block();
        } @finally {
            @synchronized (gPending) {
                if (gCoverDepth > 0) gCoverDepth -= 1;
            }
        }
    });
}

static NSUInteger InsCoverDepth(void) {
    @synchronized (gPending) { return gCoverDepth; }
}

/// 串行队列上逐条取出执行；每取出一条就放掉锁，长时间任务（LLM/语音）不影响入队。
static void InsDrainWork(void) {
    for (;;) {
        NSDictionary *job = nil;
        NSUInteger left = 0;
        @synchronized (gPending) {
            if (!gPending.count) { gDraining = NO; return; }
            job = gPending[0];
            [gPending removeObjectAtIndex:0];
            left = gPending.count;
        }
        dispatch_block_t work = job[@"b"];
        NSString *label = job[@"l"] ?: @"";
        @synchronized (gPending) {
            gRunningLabel = label;
            gRunningAt = [[NSDate date] timeIntervalSince1970];
        }
        if (left) {
            InsNote([NSString stringWithFormat:@"排队：开始处理「%@」，还剩 %lu 条待办",
                     label, (unsigned long)left]);
        }
        if (work) work();
        @synchronized (gPending) { gRunningLabel = nil; gRunningAt = 0; }
    }
}

static NSUInteger InsQueueDepth(void) {
    @synchronized (gPending) { return gPending.count; }
}

/// 「排队」命令的状态行：正在处理什么、处理了多久、后面还压着几条
static NSString *InsQueueStatus(void) {
    NSString *label = nil;
    NSTimeInterval at = 0;
    NSUInteger depth = 0;
    @synchronized (gPending) {
        label = [gRunningLabel copy];
        at = gRunningAt;
        depth = gPending.count;
    }
    NSMutableString *out = [NSMutableString stringWithFormat:@"排队：%@，待处理 %lu 条",
                            atomic_load(&gQueueOn) ? @"开" : @"关", (unsigned long)depth];
    if (label.length) {
        double secs = at > 0 ? [[NSDate date] timeIntervalSince1970] - at : 0;
        [out appendFormat:@"；正在处理「%@」，已 %.0f 秒", label, secs];
    } else {
        [out appendString:@"；当前空闲"];
    }
    return out;
}

/// 「给我画…」「帮我生成一张…」这类前言会把生图动词挤到第二位，
/// 先剥掉礼貌用语再判断，否则整段会被当成普通提问丢给文本模型，得到「我没有绘图能力」的回复。
static NSString *InsStripImageLeadIns(NSString *text) {
    static NSArray *leads = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 长词在前，避免「能不能」被「能」截断
        leads = @[@"能不能帮我", @"可不可以帮我", @"能不能给我", @"能不能", @"可不可以",
                  @"可以帮我", @"帮我", @"给我", @"帮忙", @"麻烦", @"请", @"可以", @"能", @"你"];
    });
    NSCharacterSet *wrap = [NSCharacterSet characterSetWithCharactersInString:@"「『“‘\"'【（("];
    NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *s = [text stringByTrimmingCharactersInSet:space];
    for (NSInteger round = 0; round < 4; round++) {
        s = [s stringByTrimmingCharactersInSet:wrap];
        BOOL stripped = NO;
        for (NSString *lead in leads) {
            if (s.length > lead.length && [s hasPrefix:lead]) {
                s = [[s substringFromIndex:lead.length] stringByTrimmingCharactersInSet:space];
                stripped = YES;
                break;
            }
        }
        if (!stripped) break;
    }
    return s;
}

static NSString *InsImagePrompt(NSString *payload, InsConfig *cfg) {
    NSString *text = [payload stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *body = InsStripImageLeadIns(text);
    for (NSString *keyword in cfg.imageKeywords) {
        if (![keyword length]) continue;
        // 原文和去掉前言后的说法都试一遍
        for (NSString *candidate in (body.length && ![body isEqualToString:text]) ? @[text, body] : @[text]) {
            if (![candidate hasPrefix:keyword]) continue;
            NSString *rest = [[candidate substringFromIndex:keyword.length]
                              stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (rest.length) return rest;
        }
    }
    // 「给我画一把…」「帮我生成一张…」：前言剥掉后以生图动词开头，整段交给 ChatGPT（前言不丢，描述更完整）
    if (body.length && ![body isEqualToString:text]) {
        for (NSString *verb in @[@"画", @"绘", @"生成", @"出图", @"做图", @"生成图", @"画一"]) {
            if ([body hasPrefix:verb] && body.length > verb.length) return text;
        }
    }
    // 「截止到今天生成一张…」这类带前缀的说法：只要包含这些短语就当生图，短语前的废话去掉
    for (NSString *phrase in cfg.imagePhrases) {
        if (![phrase length]) continue;
        NSRange hit = [text rangeOfString:phrase];
        if (hit.location == NSNotFound) continue;
        NSString *prompt = [[text substringFromIndex:hit.location]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (prompt.length > phrase.length) return prompt;
    }
    // 「把刚才的猫改成红色」「优化一下」这类没有生图前缀，但生过图后就是对上一张图的修改
    if (text.length && [InsGen lastPrompt].length && InsImageContinuation(text, cfg)) return text;
    return nil;
}

/// 优化/修改类说法：命中这些短语的请求会接着上一张图的 ChatGPT 会话继续问，而不是开新会话
static BOOL InsImageContinuation(NSString *text, InsConfig *cfg) {
    for (NSString *phrase in cfg.continuePhrases) {
        if (phrase.length && [text rangeOfString:phrase].location != NSNotFound) return YES;
    }
    return NO;
}

static NSString *InsKV(id object, NSString *key) {
    if (!object) return nil;
    @try {
        id value = [object valueForKey:key];
        if ([value isKindOfClass:[NSString class]]) return value;
        if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    } @catch (__unused NSException *e) {}
    return nil;
}

static NSUInteger InsUInt(id object, NSString *key) {
    if (!object) return 0;
    @try {
        id value = [object valueForKey:key];
        if ([value isKindOfClass:[NSNumber class]]) return (NSUInteger)[value unsignedIntegerValue];
    } @catch (__unused NSException *e) {}
    return 0;
}

static NSString *InsSelfWxid(void) {
    InsConfig *cfg = [InsConfig shared];
    if (cfg.selfWxid.length) return cfg.selfWxid;
    static NSString *cached = nil;
    if (cached.length) return cached;
    Class center = NSClassFromString(@"MMServiceCenter");
    Class contactMgr = NSClassFromString(@"CContactMgr");
    if (center && contactMgr) {
        id defaultCenter = [center performSelector:@selector(defaultCenter)];
        id mgr = defaultCenter && [defaultCenter respondsToSelector:@selector(getService:)]
            ? [defaultCenter performSelector:@selector(getService:) withObject:contactMgr] : nil;
        if (mgr && [mgr respondsToSelector:@selector(getSelfContact)]) {
            id contact = [mgr performSelector:@selector(getSelfContact)];
            for (NSString *key in @[@"m_nsUsrName", @"m_nsNickName", @"userName"]) {
                NSString *value = InsKV(contact, key);
                if (value.length) { cached = value; return value; }
            }
        }
    }
    return nil;
}

/// 给语音模块用：开会话录音时需要自己的 wxid
NSString *InsSelfWxidShared(void) {
    return InsSelfWxid();
}

static NSString *InsTalkerFor(id wrap, BOOL *fromMe) {
    NSString *from = InsKV(wrap, @"m_nsFromUsr");
    NSString *to = InsKV(wrap, @"m_nsToUsr");
    NSString *selfWxid = InsSelfWxid();
    if (fromMe) *fromMe = selfWxid.length && [from isEqualToString:selfWxid];
    NSString *talker = nil;
    if ([to hasSuffix:@"@chatroom"]) talker = to;
    else if ([from hasSuffix:@"@chatroom"]) talker = from;
    else if (selfWxid.length && [from isEqualToString:selfWxid]) talker = to;
    else talker = from;
    if ([talker isEqualToString:selfWxid]) talker = to;
    return talker;
}

/// 联系人里能代表这个人的名字：备注优先（getContactDisplayName 已做回退），再补昵称
static NSArray *InsContactNames(NSString *wxid) {
    if (!wxid.length) return @[];
    // 这些特殊会话在通讯录里没有条目，getContactDisplayName 会退回原始 id，搜不到
    static NSDictionary *special = nil;
    static dispatch_once_t onceSpecial;
    dispatch_once(&onceSpecial, ^{
        special = @{@"filehelper": @"文件传输助手", @"weixin": @"微信团队",
                   @"mphelper": @"公众平台安全助手", @"floatbottle": @"朋友圈",
                   @"medianote": @"语音记事本", @"qqmail": @"邮件提醒"};
    });
    NSString *known = special[wxid];
    if (known) return @[known];

    static NSMutableDictionary *gNameCache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gNameCache = [NSMutableDictionary dictionary]; });
    @synchronized (gNameCache) {
        NSArray *cached = gNameCache[wxid];
        if (cached) return cached;
    }

    NSMutableArray *names = [NSMutableArray array];
    Class center = NSClassFromString(@"MMServiceCenter");
    Class contactMgr = NSClassFromString(@"CContactMgr");
    if (center && contactMgr) {
        id defaultCenter = [center performSelector:@selector(defaultCenter)];
        id mgr = defaultCenter && [defaultCenter respondsToSelector:@selector(getService:)]
            ? [defaultCenter performSelector:@selector(getService:) withObject:contactMgr] : nil;
        if (mgr && [mgr respondsToSelector:@selector(getContactByName:)]) {
            id contact = [mgr performSelector:@selector(getContactByName:) withObject:wxid];
            if (contact) {
                if ([contact respondsToSelector:@selector(getContactDisplayName)]) {
                    @try {
                        id value = [contact performSelector:@selector(getContactDisplayName)];
                        if ([value isKindOfClass:[NSString class]] && [value length]) [names addObject:value];
                    } @catch (__unused NSException *e) {}
                }
                NSString *nick = InsKV(contact, @"m_nsNickName");
                if (nick.length && ![names containsObject:nick]) [names addObject:nick];
            }
        }
    }
    NSArray *result = [names copy];
    @synchronized (gNameCache) {
        // 后台线程查联系人会返回 nil，空结果不缓存，避免污染后续的名字匹配
        if (result.count) gNameCache[wxid] = result;
    }
    return result;
}

/// 真实发送人：群聊在 m_nsRealChatUsr；单聊里这个字段是空串而不是 nil，所以要用非空判断取 m_nsFromUsr
static NSString *InsSenderOf(id wrap) {
    NSString *sender = InsKV(wrap, @"m_nsRealChatUsr");
    if (sender.length) return sender;
    return InsKV(wrap, @"m_nsFromUsr");
}

/// 默认只有我自己能下命令；allowTriggersFrom 里列出的 wxid 或 备注/昵称 也可以，"*" 表示放开所有人
static BOOL InsSenderAllowed(id wrap, NSString *selfWxid) {
    NSArray *list = [InsConfig shared].allowTriggersFrom;
    if (!list.count) return NO;
    NSString *sender = InsSenderOf(wrap);
    if (!sender.length || [sender isEqualToString:selfWxid]) return NO;
    if ([list containsObject:@"*"]) return YES;
    if ([list containsObject:sender]) return YES;
    for (NSString *name in InsContactNames(sender)) {
        if ([list containsObject:name]) return YES;
    }
    // 通讯录读不出来时（这个版本偶发「读到 0 个联系人」），退回消息自带的昵称/备注名，
    // 否则「放行 某某」写进名单也匹配不上，表现还是「没反应」
    NSString *nick = InsKV(wrap, @"m_nsNickName");
    if (nick.length && [list containsObject:nick]) return YES;
    return NO;
}

static void InsNote(NSString *line) {
    [InsConfig log:line];
}

/// 不在放行名单的人 @ 了我。以前这里直接 return，一行日志都不留，现象就是「别人 @ 了没反应」。
/// 现在两件事：① 日志留痕（同会话 8 秒节流）② 记进待报队列，主人下条命令时在回复里附带一句。
/// 不再往文件传输助手硬发：那要切会话，实测会连着「当前界面不是目标 filehelper / 找不到返回入口」
/// 失败好几次，既发不出去又把日志刷满。
static NSMutableArray *gBlockedPending = nil;

static void InsBlockedInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gBlockedPending = [NSMutableArray array]; });
}

static void InsBlockedRecord(NSString *talker, NSString *name, NSString *brief) {
    InsBlockedInit();
    @synchronized (gBlockedPending) {
        NSMutableDictionary *hit = nil;
        for (NSMutableDictionary *row in gBlockedPending) {
            if ([row[@"talker"] isEqualToString:(talker ?: @"")]) { hit = row; break; }
        }
        if (hit) {
            hit[@"count"] = @([hit[@"count"] integerValue] + 1);
            hit[@"brief"] = brief ?: @"";
            hit[@"t"] = @([[NSDate date] timeIntervalSince1970]);
        } else {
            [gBlockedPending addObject:[@{@"talker": talker ?: @"",
                                          @"name": name ?: @"",
                                          @"brief": brief ?: @"",
                                          @"count": @1,
                                          @"t": @([[NSDate date] timeIntervalSince1970])} mutableCopy]];
            while (gBlockedPending.count > 8) [gBlockedPending removeObjectAtIndex:0];
        }
    }
}

/// 取走待报的拦截记录（取完即清空，不重复唠叨）。当前会话自身跳过，免得自己提醒自己。
static NSString *InsBlockedTakeReport(NSString *currentTalker) {
    InsBlockedInit();
    NSMutableArray *taken = nil;
    @synchronized (gBlockedPending) {
        if (!gBlockedPending.count) return nil;
        taken = [gBlockedPending mutableCopy];
        [gBlockedPending removeAllObjects];
    }
    NSString *trigger = [InsConfig shared].trigger.length ? [InsConfig shared].trigger : @"@insomnia";
    NSMutableArray *lines = [NSMutableArray array];
    NSString *firstWho = nil;
    for (NSDictionary *row in taken) {
        NSString *t = row[@"talker"] ?: @"";
        if (currentTalker.length && [t isEqualToString:currentTalker]) continue;
        NSString *who = [row[@"name"] length] ? row[@"name"] : t;
        if (!firstWho) firstWho = who;
        [lines addObject:[NSString stringWithFormat:@"· %@（%@）被挡 %ld 次，最后一条：%@",
                          who, t, (long)[row[@"count"] integerValue], row[@"brief"] ?: @"（无文本）"]];
    }
    if (!lines.count) return nil;
    return [NSString stringWithFormat:
        @"顺带一提，有人 @ 了你但不在放行名单，命令没执行：\n%@\n"
        @"要放行：%@ 放行 %@；看名单：%@ 放行列表",
        [lines componentsJoinedByString:@"\n"], trigger, firstWho ?: @"<名字>", trigger];
}

static void InsNoteBlockedSender(NSString *talker, NSString *name, NSString *brief) {
    // 待报队列每次都记（这是主人唯一的线索），日志才按会话节流
    InsBlockedRecord(talker, name, brief);
    static NSMutableDictionary *gBlockedLog = nil;
    static dispatch_once_t onceBlocked;
    dispatch_once(&onceBlocked, ^{ gBlockedLog = [NSMutableDictionary dictionary]; });
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSString *key = talker.length ? talker : @"?";
    @synchronized (gBlockedLog) {
        if (now - [gBlockedLog[key] doubleValue] < 8) return;
        gBlockedLog[key] = @(now);
        if (gBlockedLog.count > 300) [gBlockedLog removeAllObjects];
    }
    InsNote([NSString stringWithFormat:@"拦下（不在 allowTriggersFrom）：%@（%@）%@",
             key, name.length ? name : key, brief ?: @""]);

    // 单聊里被挡的人完全没有反馈，只会觉得「插件坏了」。
    // 12 小时最多回一句「怎么被放行」；而且只在这条会话已经打开时才回，
    // 否则 InsReply 会跳会话，把人正在看的界面跳走。
    if (![key hasSuffix:@"@chatroom"] && [InsSend isChatOpen:key]) {
        static NSMutableDictionary *gBlockedTold = nil;
        static dispatch_once_t onceTold;
        dispatch_once(&onceTold, ^{ gBlockedTold = [NSMutableDictionary dictionary]; });
        BOOL tell = NO;
        @synchronized (gBlockedTold) {
            if (now - [gBlockedTold[key] doubleValue] > 12 * 3600) {
                gBlockedTold[key] = @(now);
                tell = YES;
            }
        }
        if (tell) {
            NSString *trigger = [InsConfig shared].trigger ?: @"@insomnia";
            InsReplyNoQueue(key, [NSString stringWithFormat:
                @"我还没被授权回应你。让账号主人发一句「%@ 放行 %@」，之后你 @ 我就能用了。",
                trigger, name.length ? name : key]);
        }
    }
}

static void InsHandleWrap(id wrap, NSString *source) {
    InsConfig *cfg = [InsConfig shared];
    if (!cfg.enabled || !wrap) return;
    // 定时器在微信后台可能被挂起，收到消息时补检一次是否该发进度汇报
    [InsProgress noteActivity];
    // 顺手把没送达的回复补发掉（内部 10 分钟节流，队列空时直接返回）
    InsFlushOutboxIfDue();

    NSString *content = InsKV(wrap, @"m_nsContent");
    NSUInteger type = InsUInt(wrap, @"m_uiMessageType");
    // 47 = 微信自定义/商城表情，斗图要认它；其余非文本/图片/appmsg 一律不处理
    if (type != 1 && type != 3 && type != 49 && type != 47) return;
    if (!content.length && type != 47) return;

    @synchronized (gOwnTexts) {
        if ([gOwnTexts containsObject:content]) return;
    }

    BOOL fromMe = NO;
    NSString *talker = InsTalkerFor(wrap, &fromMe);
    if (!talker.length) return;
    // 文件传输助手/微信团队这类账号不会回话，里面的消息一定是账号主人发的。
    // 少数字段在某些机型上取不到自己的 wxid，会让 fromMe 判成 0，这里兜住。
    if ([InsHistory isOneWayAccount:talker]) fromMe = YES;

    NSUInteger localID = InsUInt(wrap, @"m_uiMesLocalID");
    NSUInteger createTime = InsUInt(wrap, @"m_uiCreateTime");
    NSString *dedupe = [NSString stringWithFormat:@"%@-%lu-%lu", talker, (unsigned long)localID, (unsigned long)createTime];
    @synchronized (gSeen) {
        if ([gSeen containsObject:dedupe]) return;
        [gSeen addObject:dedupe];
        if (gSeen.count > 4000) [gSeen removeAllObjects];
    }

    // 通讯录枚举接口在这台机器上读不到（getAllFriendContact 返回空），
    // 所以「按名字找人」全靠平时积累：谁发来消息，就把显示名记进人名簿。
    // 代发「给林健发消息说…」、授权、查人都靠这本簿子把人名换成 wxid。
    if (!fromMe) {
        NSString *senderWxid = InsSenderOf(wrap);
        if (senderWxid.length) {
            [InsStat learnName:InsKV(wrap, @"m_nsNickName") forWxid:senderWxid];
            for (NSString *n in InsContactNames(senderWxid)) [InsStat learnName:n forWxid:senderWxid];
        }
    }

    // 微信表情消息：内容是 <msg><emoji ... md5="..."/></msg>，不进文本记忆。
    // 开关打开 + 对方在放行范围时自动回一张「我的已有表情包」；我发的只入库不回。
    if (type == 47) {
        BOOL stickerAllowed = NO;
        if (!fromMe) {
            NSArray *list = cfg.allowTriggersFrom;
            // 配了白名单就按白名单（群聊按发言人匹配）；没配则单聊默认放行、群聊不自动斗图
            stickerAllowed = list.count ? InsSenderAllowed(wrap, InsSelfWxid())
                                        : ![talker hasSuffix:@"@chatroom"];
        }
        [InsSticker handleMessage:(content ?: @"") talker:talker
                           fromMe:fromMe allowed:stickerAllowed];
        return;
    }

    // 微信「引用回复」是 appmsg type 57，旧逻辑会在 type!=1 处直接丢掉，命令根本不会跑。
    // 这里把「回复的文字」当作命令文本，「被引用的链接/图片」当作本次要读的媒体。
    BOOL isQuote = NO;
    NSDictionary *quoteLink = nil;
    NSDictionary *quoteImage = nil;
    NSString *quoteRecord = nil;
    // 引用的是文件（.txt/.pdf 这类）：把附件信息带下去，由读文件分支取正文
    NSDictionary *quoteFile = nil;
    // 文字引用时给模型的一句话说明：谁、什么时候、说了什么。否则上下文里同一句话
    // 出现两次，模型会当成对方又问了一遍（实测：主人引用姜世谊的「分泌物是啥」追问，
    // 回答里变成「姜世谊连着问了两次」）。
    NSString *quoteNote = nil;
    if (type == 49 || [content rangeOfString:@"<refermsg"].location != NSNotFound) {
        NSDictionary *q = [InsMedia parseQuote:content];
        if (q) {
            isQuote = YES;
            content = q[@"reply"] ?: @"";
            NSDictionary *li = q[@"link"];
            if ([li count]) quoteLink = li;
            if ([q[@"kind"] isEqualToString:@"record"]) quoteRecord = q[@"record"] ?: @"";
            // 引用的是文件消息：文件名 + svrid，读正文时按 svrid 找本地下载副本
            if ([q[@"kind"] isEqualToString:@"file"] && [q[@"file"] count]) quoteFile = q[@"file"];
            // 引用的是图片：把被引用的 XML 交给看图分支。time 置 0 是故意的——
            // 让 imageDataFor: 的「按时间窗找缩略图」兜底失效，避免拿错成别的图；
            // 引用内容拿不到图时会回落到本会话已记下的那张（localID 准确，可读本地 .pic）。
            if ([q[@"kind"] isEqualToString:@"image"]) {
                // 以前这里把「当前这条命令消息」的 localID 塞进来，图片文件名根本对不上，
                // 只能退回本会话最近一张（于是答错图）。现在只带 svrid/createtime，
                // 由看图分支去反查真正的 MesLocalID。
                quoteImage = @{ @"xml": q[@"quoted"] ?: @"",
                                @"localID": @0,
                                @"time": q[@"time"] ?: @0,
                                @"svrid": q[@"svrid"] ?: @"" };
            }
            NSString *brief = content.length > 40 ? [content substringToIndex:40] : content;
            InsNote([NSString stringWithFormat:
                     @"识别引用消息：回复=%@ 类型=%@ 引用链接=%@ 记录条数=%ld 引用长度=%lu svrid=%@ 引用文件=%@",
                     brief, q[@"kind"] ?: @"未知", quoteLink[@"url"] ?: @"无",
                     (long)(quoteRecord.length ? [quoteRecord componentsSeparatedByString:@"\n"].count - 1 : 0),
                     (unsigned long)[q[@"quoted"] length], [q[@"svrid"] length] ? q[@"svrid"] : @"无",
                     quoteFile[@"name"] ?: @"无"]);
            // 引用的是纯文本：给出「谁 · 什么时候 · 说了什么」，让模型明白这是主人在
            // 指着对方那句原话追问，而不是对方又发了一次
            NSString *quoted = q[@"quoted"] ?: @"";
            if (quoted.length && !quoteImage && !quoteLink && !quoteRecord.length && !quoteFile.count) {
                NSString *who = q[@"quoterName"];
                NSString *qwxid = q[@"quoter"];
                if (qwxid.length && [qwxid isEqualToString:InsSelfWxid()]) who = @"账号主人";
                else if (!who.length && qwxid.length) who = InsContactNames(qwxid).firstObject;
                // 有些版本 refermsg 不给 chatusr/displayname，单聊里被引用的只可能是
                // 主人或对方，用会话备注兜底，别写成「对方」这种含糊称呼
                if (!who.length && talker.length) who = [InsMemory partnerLabelForTalker:talker];
                if (!who.length) who = @"对方";
                uint32_t qt = [q[@"time"] unsignedIntValue];
                NSString *when = nil;
                if (qt) {
                    NSDateFormatter *hm = [[NSDateFormatter alloc] init];
                    hm.dateFormat = @"HH:mm";
                    when = [hm stringFromDate:[NSDate dateWithTimeIntervalSince1970:qt]];
                }
                NSString *body = quoted.length > 60 ? [quoted substringToIndex:60] : quoted;
                quoteNote = [NSString stringWithFormat:@"账号主人引用了%@%@说的「%@」，然后向你追问。"
                             @"这是聊天里原来那一句，主人指着它再问一次，不是%@又发了一遍。",
                             who,
                             when.length ? [NSString stringWithFormat:@"在 %@ ", when] : @"之前",
                             body, who];
                InsNote([NSString stringWithFormat:@"文字引用：%@ %@「%@」", who, when ?: @"", body]);
            }
        }
    }

    // 图片/链接先记下来（不管谁发的），之后「看图/看链接」才有得分析
    if (type != 1 && !isQuote) {
        [InsMedia remember:talker type:type xml:content localID:localID time:(uint32_t)createTime];
        // 对方发来的链接卡片：开了「收链接即看」就先在后台读一遍，等你点进会话时摘要已经好了
        if (type == 49 && !fromMe) {
            [InsAutoLink noteIncomingXML:content talker:talker fromMe:fromMe];
        }
        return;
    }

    NSString *displayName = InsKV(wrap, @"m_nsNickName") ?: @"";
    if (!displayName.length) {
        displayName = fromMe ? @"我" : (InsContactNames(InsSenderOf(wrap)).firstObject ?: @"");
    }
    // key / setup 这类命令消息里带凭据：既不写进记忆，也不在日志里留明文
    NSString *lowContent = [content lowercaseString];
    BOOL secretCmd = [lowContent containsString:@"sk-"] ||
                     [lowContent containsString:@"setup "] ||
                     [lowContent containsString:@"key "];
    if (content.length && !secretCmd) {
        [InsMemory recordMessage:talker text:content me:fromMe time:(uint32_t)createTime
                            name:fromMe ? @"" : displayName];
    }
    NSString *brief = secretCmd ? @"<含凭据，已隐藏>" :
                      InsScrub([content substringToIndex:MIN(content.length, 40)]);
    InsNote([NSString stringWithFormat:@"消息 %@ fromMe=%d talker=%@(%@) %@",
             source, fromMe, talker, displayName, brief]);

    NSString *trigger = cfg.trigger.length ? cfg.trigger : @"@insomnia";
    NSRange range = [content rangeOfString:trigger];
    // 接龙会话放行：开局后不带前缀的消息也当游戏指令处理（对方连着接龙不用每次 @）
    BOOL gameChat = InsGameActive(talker);
    if (range.location == NSNotFound) {
        if (!gameChat) return;
        if (!fromMe && !InsSenderAllowed(wrap, InsSelfWxid())) return;  // 陌生人不享受免前缀
        InsNote([NSString stringWithFormat:@"接龙会话放行（无前缀）：%@",
                 InsScrub([content substringToIndex:MIN(content.length, 40)])]);
        InsRunCommand(content, talker, displayName, quoteLink, quoteImage, quoteRecord, quoteFile,
                      fromMe, quoteNote, (uint32_t)createTime);
        return;
    }

    NSString *payload = [[content substringFromIndex:NSMaxRange(range)]
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!fromMe) {
        BOOL allowed = InsSenderAllowed(wrap, InsSelfWxid());
        // 代发命令单独放行：能不能发由 InsRelay 按授权表判断，
        // 不要求对方同时进 allowTriggersFrom（那是「允许用全部命令」的白名单）
        if (!allowed && ![InsRelay isRelayPayload:payload]) {
            // 不能静默丢弃：至少留一条日志 + 提醒主人怎么放行，否则现象就是「别人 @ 了没反应」
            InsNoteBlockedSender(talker, displayName, brief);
            return;
        }
        if (allowed) {
            InsNote([NSString stringWithFormat:@"allowTriggersFrom 放行：%@（%@）", talker, displayName]);
        }
    }
    // 成语接龙总开关与开局判定（只看带前缀的 payload）
    if ([payload containsString:@"关闭接龙"] || [payload containsString:@"关闭成语接龙"]) {
        InsGameEnd();
        [[InsConfig shared] setGameEnabledPersisted:NO];
        InsReply(talker, @"成语接龙已关闭，以后 @ 我也不玩了。想再玩发「开启接龙」。");
        return;
    }
    if ([payload containsString:@"开启接龙"] || [payload containsString:@"开启成语接龙"] ||
        [payload containsString:@"打开接龙"] || [payload containsString:@"打开成语接龙"]) {
        [[InsConfig shared] setGameEnabledPersisted:YES];
        InsReply(talker, @"成语接龙已开启～发「成语接龙」开局。");
        return;
    }
    if (([payload containsString:@"成语接龙"] || [payload containsString:@"玩接龙"]) &&
        ![InsConfig shared].gameEnabled) {
        InsReply(talker, @"成语接龙功能现在是关闭状态，发「开启接龙」可重新打开。");
        return;
    }
    if (([payload containsString:@"成语接龙"] || [payload containsString:@"玩接龙"])) {
        InsGameStart(talker);
    } else if (InsGameActive(talker)) {
        if ([payload containsString:@"不玩了"] || [payload containsString:@"结束接龙"] ||
            [payload containsString:@"退出接龙"]) {
            InsGameEnd();
        } else {
            InsGameTouch(talker);
        }
    }
    InsRunCommand(payload, talker, displayName, quoteLink, quoteImage, quoteRecord, quoteFile,
                  fromMe, quoteNote, (uint32_t)createTime);
}

/// 回复的三档送达：会话通道 → 跳转会话再发 → 重发队列。
/// 只有前两档是真的上服务器，对方能看到；第三档不再往本地库塞假消息（除非 allowLocalEcho=YES）。
static void InsReplyCore(NSString *talker, NSString *text, BOOL queueOnFailure) {
    @synchronized (gOwnTexts) {
        [gOwnTexts addObject:text];
        if (gOwnTexts.count > 50) [gOwnTexts removeObjectAtIndex:0];
    }
    InsNote([NSString stringWithFormat:@"→ 回复 %@：%@…〔共 %lu 字〕", talker,
            [text substringToIndex:MIN(text.length, 60)], (unsigned long)text.length]);
    [InsSend sendText:text toTalker:talker completion:^(BOOL ok) {
        if (ok) {
            [InsOutbox noteDeliveryVia:@"当前会话" talker:talker];
            return;
        }
        // 目标会话没开着：跳到该会话再发一次，这一档也是真发送
        NSString *chatName = [InsSend displayNameForTalker:talker];
        [InsSend sendTextAfterNavigating:text toTalker:talker chatName:chatName completion:^(BOOL ok2) {
            if (ok2) {
                [InsOutbox noteDeliveryVia:@"跳转会话后发送" talker:talker];
                return;
            }
            if (InsSendVia(talker, text)) {
                [InsOutbox noteDeliveryVia:@"config 自定义选择器" talker:talker];
                return;
            }
            BOOL echo = [InsConfig shared].allowLocalEcho;
            if (echo && InsSendLocal(talker, text)) {
                InsNote(@"以上回复只在本地插入，对方收不到（本地回显已开）");
                return;
            }
            if (!queueOnFailure) {
                InsNote(@"这条回复没有送达，且不允许入队（避免自我循环）");
                return;
            }
            [InsOutbox enqueueText:text toTalker:talker chatName:chatName error:@"会话通道与跳转都失败"];
        }];
    }];
}

static void InsReply(NSString *talker, NSString *text) {
    InsReplyCore(talker, text, YES);
}

/// 补发结果、队列明细这类回复失败时不能再入队，否则会自己喂自己
static void InsReplyNoQueue(NSString *talker, NSString *text) {
    InsReplyCore(talker, text, NO);
}

/// 代发专用送达：只走真发送链路（会话通道 → 跳转会话 → 自定义选择器）。
/// 不插本地假消息、也不入重发队列——代发必须当场知道成没成功。
/// 代发用：优先当前会话，其次用微信内部接口打开目标会话，最后才退回屏幕模拟点击。
/// how 回传成功/失败走的是哪一步，用来给用户一个说得清的结论。
static void InsDeliverText(NSString *talker, NSString *text, BOOL allowNavigate,
                           void (^done)(BOOL ok, NSString *how)) {
    if (!talker.length || !text.length) { if (done) done(NO, @"会话或内容为空"); return; }
    NSMutableArray *tried = [NSMutableArray array];

    void (^finishFail)(void) = ^{
        if (done) done(NO, [tried componentsJoinedByString:@"、"]);
    };

    void (^navigateSend)(void) = ^{
        if (!allowNavigate) {
            [tried addObject:@"跳转开关关着"];
            finishFail();
            return;
        }
        NSString *chatName = [InsSend displayNameForTalker:talker];
        [InsSend sendTextAfterNavigating:text toTalker:talker chatName:chatName completion:^(BOOL ok) {
            if (ok) {
                [InsOutbox noteDeliveryVia:@"代发·屏幕跳转" talker:talker];
                if (done) done(YES, @"屏幕模拟跳转");
                return;
            }
            [tried addObject:@"屏幕模拟跳转"];
            if (InsSendVia(talker, text)) {
                [InsOutbox noteDeliveryVia:@"代发·config 选择器" talker:talker];
                if (done) done(YES, @"config 选择器");
                return;
            }
            [tried addObject:@"config 选择器"];
            finishFail();
        }];
    };

    void (^inProcessSend)(void) = ^{
        if (![InsSend openChatInProcess:talker]) {
            [tried addObject:@"内部接口开会话"];
            navigateSend();
            return;
        }
        [InsSend sendText:text toTalker:talker completion:^(BOOL ok) {
            if (ok) {
                [InsOutbox noteDeliveryVia:@"代发·内部开会话" talker:talker];
                if (done) done(YES, @"内部接口打开会话");
                return;
            }
            [tried addObject:@"内部开会话后发送失败"];
            navigateSend();
        }];
    };

    [InsSend sendText:text toTalker:talker completion:^(BOOL ok) {
        if (ok) {
            [InsOutbox noteDeliveryVia:@"代发·当前会话" talker:talker];
            if (done) done(YES, @"会话已经开着");
            return;
        }
        [tried addObject:@"当前会话没开着"];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), inProcessSend);
    }];
}

/// 收到新消息 / 刚启动时顺手补发一次，10 分钟内不重复触发
static void InsFlushOutboxIfDue(void) {
    static time_t last = 0;
    if ([InsOutbox count] == 0) return;
    time_t now = time(NULL);
    if (last && now - last < 600) return;
    last = now;
    [InsOutbox flushWithCompletion:nil];
}

/// 命令词必须整体匹配，别让 "logic" 之类被 log 抢走
static BOOL InsCmdIs(NSString *lower, NSString *word) {
    if (![lower hasPrefix:word]) return NO;
    if (lower.length == word.length) return YES;
    return [[NSCharacterSet whitespaceAndNewlineCharacterSet]
            characterIsMember:[lower characterAtIndex:word.length]];
}

static BOOL InsHasWord(NSString *text, NSString *word) {
    return text.length && word.length && [text rangeOfString:word].location != NSNotFound;
}

/// 取命令前缀之后的参数；中文前缀按 UTF-16 长度算，payload 与 lower 等长
static NSString *InsArgAfter(NSString *payload, NSString *prefix) {
    if (!payload.length || !prefix.length) return @"";
    NSUInteger n = MIN(prefix.length, payload.length);
    return [[payload substringFromIndex:n]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/// 只读 dpkg status 文件拿版本，不依赖 MCP/守护进程（数据线拔掉时也能用）
static NSString *InsLocalVersion(void) {
    for (NSString *path in @[@"/var/jb/var/lib/dpkg/status", @"/var/lib/dpkg/status"]) {
        NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        NSRange hit = [s rangeOfString:@"Package: com.xuezeng.insomnia"];
        if (!s.length || hit.location == NSNotFound) continue;
        NSString *tail = [s substringFromIndex:NSMaxRange(hit)];
        NSRange end = [tail rangeOfString:@"\n\n"];
        if (end.location != NSNotFound) tail = [tail substringToIndex:end.location];
        for (NSString *line in [tail componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@"Version:"]) {
                return [[line substringFromIndex:8]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
        }
    }
    return @"未知";
}

/// 转发给 WorkBuddy 之前脱敏：API Key、wxid、手机号
static NSString *InsScrub(NSString *text) {
    NSString *out = text ?: @"";
    NSArray *rules = @[@[@"sk-[A-Za-z0-9_-]{16,}", @"<api-key>"],
                       @[@"wxid_[A-Za-z0-9]{6,}", @"<wxid>"],
                       @[@"1[3-9][0-9]{9}", @"<phone>"]];
    for (NSArray *rule in rules) {
        out = [out stringByReplacingOccurrencesOfString:rule[0]
                                             withString:rule[1]
                                                  options:NSRegularExpressionSearch
                                                    range:NSMakeRange(0, out.length)];
    }
    return out;
}

/// 取日志末尾 N 行（日志本身会被裁剪到 4KB，整段读不会撑爆内存）
static NSString *InsTailLines(NSInteger count) {
    NSString *text = [NSString stringWithContentsOfFile:[InsConfig logPath]
                                              encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    NSInteger start = (NSInteger)lines.count - count;
    if (start < 0) start = 0;
    NSMutableArray *keep = [NSMutableArray array];
    for (NSInteger i = start; i < (NSInteger)lines.count; i++) {
        if ([lines[i] length]) [keep addObject:lines[i]];
    }
    return [keep componentsJoinedByString:@"\n"];
}

static double InsCNNumber(NSString *s) {
    if (!s.length) return 0;
    if ([s isEqualToString:@"半"]) return 0.5;
    if ([s rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound) {
        return [s doubleValue];
    }
    static NSDictionary *digits;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        digits = @{@"一": @1, @"二": @2, @"两": @2, @"三": @3, @"四": @4,
                   @"五": @5, @"六": @6, @"七": @7, @"八": @8, @"九": @9};
    });
    NSRange shi = [s rangeOfString:@"十"];
    if (shi.location == NSNotFound) return [digits[s] doubleValue];
    double tens = shi.location == 0 ? 1 : [digits[[s substringToIndex:shi.location]] doubleValue];
    NSString *tail = [s substringFromIndex:shi.location + shi.length];
    return tens * 10 + (tail.length ? [digits[tail] doubleValue] : 0);
}

/// 口语化「看链接」识别。设备上的 config.json 已经写死了 visionLinkWords，
/// 改 InsConfig.m 的默认值对现网不生效，所以这里内置一组判断，不依赖配置。
static BOOL InsWantsLink(NSString *payload) {
    NSString *s = [payload lowercaseString];
    if (!s.length) return NO;
    // 「写一篇文章」「来个稿子」是让我创作，不是让我读上方链接。
    // 光看「文章」这个词会误判（实测「写一篇 800 字的文章」被回成「这个会话上方没找到链接」）。
    for (NSString *w in @[@"写一篇", @"写篇", @"写一段", @"写段", @"写个", @"写点",
                          @"生成一篇", @"来一篇", @"作一篇", @"起草", @"作文", @"稿子", @"短文"]) {
        if ([s rangeOfString:w].location != NSNotFound) return NO;
    }
    BOOL hasTarget = NO;
    for (NSString *w in @[@"链接", @"网址", @"link", @"url", @"文章", @"这条", @"上面",
                          @"上一条", @"刚发", @"他发", @"她发", @"刚才", @"分享的"]) {
        if ([s rangeOfString:w].location != NSNotFound) { hasTarget = YES; break; }
    }
    if (!hasTarget) return NO;
    // 「链接发我一下」「把链接转发给他」是要地址，不是要分析，别抢走
    for (NSString *w in @[@"发我", @"发一下", @"发过来", @"发来", @"给我", @"转发", @"复制", @"贴给"]) {
        if ([s rangeOfString:w].location != NSNotFound) return NO;
    }
    for (NSString *w in @[@"看", @"读", @"分析", @"总结", @"讲", @"说", @"啥", @"什么",
                          @"打开", @"点开", @"解读", @"介绍", @"内容", @"意思"]) {
        if ([s rangeOfString:w].location != NSNotFound) return YES;
    }
    return s.length <= 8;  // 只写「链接」「看下这个」这类短句也算
}

/// 口语化「看图」识别，同样不依赖设备上写死的 visionImageWords。
/// 关键是要让开生图命令：vision 分支在生图之前，抢走就变成「分析旧图」了。
static BOOL InsWantsImage(NSString *payload, InsConfig *cfg) {
    NSString *s = [payload lowercaseString];
    if (!s.length) return NO;
    for (NSString *word in cfg.imageKeywords) {
        if (word.length && [s hasPrefix:word]) return NO;
    }
    for (NSString *phrase in cfg.imagePhrases) {
        if (phrase.length && [s rangeOfString:phrase].location != NSNotFound) return NO;
    }
    for (NSString *w in @[@"发我", @"发一下", @"发过来", @"发来", @"给我", @"转发", @"复制", @"贴给"]) {
        if ([s rangeOfString:w].location != NSNotFound) return NO;
    }
    BOOL hasTarget = NO;
    for (NSString *w in @[@"图", @"图片", @"照片", @"截图", @"这张", @"上面",
                          @"刚发", @"他发", @"她发", @"刚才", @"表情包"]) {
        if ([s rangeOfString:w].location != NSNotFound) { hasTarget = YES; break; }
    }
    if (!hasTarget) return NO;
    for (NSString *w in @[@"看", @"读", @"分析", @"总结", @"讲", @"说", @"啥", @"什么",
                          @"识别", @"描述", @"内容", @"里面", @"文字", @"ocr", @"意思"]) {
        if ([s rangeOfString:w].location != NSNotFound) return YES;
    }
    return NO;
}

/// 「这两张」「上面 3 张图」→ 张数；没提到数量返回 0（按最近 1 张处理）。
/// 「分析上面两张图片」是常见说法，只取最后一张会让模型答「只有一张图」。
static NSInteger InsImageCount(NSString *payload) {
    if (!payload.length) return 0;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"([0-9]+|[一二两三四五六七八九十]+)\\s*张" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:payload options:0 range:NSMakeRange(0, payload.length)];
    if (m) {
        double n = InsCNNumber([payload substringWithRange:[m rangeAtIndex:1]]);
        if (n >= 1) return (NSInteger)MIN(n, 6.0);
    }
    for (NSString *w in @[@"这几张", @"这些图", @"上面的图", @"所有图", @"全部图", @"刚才的图"]) {
        if ([payload rangeOfString:w].location != NSNotFound) return 3;
    }
    return 0;
}

/// 「看下聊天记录」「总结转发记录」「这聊天记录讲了啥」——旧版会掉进普通问答让模型编瞎话
static BOOL InsWantsRecord(NSString *payload) {
    NSString *s = [payload lowercaseString];
    if (!s.length) return NO;
    BOOL hasTarget = NO;
    for (NSString *w in @[@"聊天记录", @"转发记录", @"转发的记录", @"聊天内容",
                          @"转发的内容", @"这些记录", @"那份记录", @"记录"]) {
        if ([s rangeOfString:w].location != NSNotFound) { hasTarget = YES; break; }
    }
    if (!hasTarget) return NO;
    for (NSString *w in @[@"发我", @"发一下", @"发过来", @"转发给我", @"复制", @"贴给"]) {
        if ([s rangeOfString:w].location != NSNotFound) return NO;
    }
    for (NSString *w in @[@"看", @"读", @"分析", @"总结", @"讲", @"说", @"啥", @"什么",
                          @"内容", @"意思", @"梳理", @"概括", @"提炼"]) {
        if ([s rangeOfString:w].location != NSNotFound) return YES;
    }
    return s.length <= 10;
}

/// 明确要求「点进去看」：跳过 HTTP 直抓，直接走屏幕读取
static BOOL InsWantsScreenOpen(NSString *payload) {
    NSString *s = payload ?: @"";
    for (NSString *w in @[@"点开", @"点进去", @"点一下", @"进网页", @"屏幕读",
                          @"用浏览器", @"打开网页", @"模拟点击"]) {
        if ([s rangeOfString:w].location != NSNotFound) return YES;
    }
    return NO;
}

/// 「第 2 份聊天记录」「上一条聊天记录」→ recordsForTalker 的下标（0 = 最新一份）
static NSInteger InsRecordIndex(NSString *payload) {
    NSString *s = payload ?: @"";
    for (NSString *w in @[@"上一条", @"上一个", @"前一条", @"上条", @"上一份"]) {
        if ([s rangeOfString:w].location != NSNotFound) return 1;
    }
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"第\\s*([0-9]+|[一二两三四五六七八九十]+)\\s*[条份个]" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m) return 0;
    double n = InsCNNumber([s substringWithRange:[m rangeAtIndex:1]]);
    return n > 0 ? (NSInteger)n - 1 : 0;
}

/// 「第 2 条链接」「上一条」「倒数第 2 条」→ linksForTalker 的下标（0 = 最新一条）
static NSInteger InsLinkIndex(NSString *payload) {
    NSString *s = payload ?: @"";
    for (NSString *w in @[@"上一条", @"上一个", @"前一条", @"上条"]) {
        if ([s rangeOfString:w].location != NSNotFound) return 1;
    }
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"(倒数)?第\\s*([0-9]+|[一二两三四五六七八九十]+)\\s*[条个张篇]" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m) return 0;
    double n = InsCNNumber([s substringWithRange:[m rangeAtIndex:2]]);
    return n > 0 ? (NSInteger)n - 1 : 0;
}

// 「一分钟后提醒我去吃饭」「明天8点半提醒我开会」→ 延迟秒数 + 要做的事；识别不了返回 NO 走普通聊天
static BOOL InsReminderParse(NSString *payload, NSTimeInterval *outDelay, NSString **outContent, NSString **outWhen) {
    if ([payload rangeOfString:@"提醒"].location == NSNotFound) return NO;

    NSRegularExpression *rel = [NSRegularExpression regularExpressionWithPattern:
        @"(半|[一二两三四五六七八九十]+|[0-9]+)\\s*(分钟|小时|钟头|秒|分)(后|之后)?" options:0 error:nil];
    NSRegularExpression *abs = [NSRegularExpression regularExpressionWithPattern:
        @"(今天|明天|晚上|下午|早上|中午)?\\s*([0-9]{1,2}|[一二两三四五六七八九十]+)\\s*[点:：]\\s*([0-9]{1,2}|半)?\\s*分?" options:0 error:nil];

    NSTimeInterval delay = 0;
    NSString *when = nil;
    NSRange timeRange = NSMakeRange(NSNotFound, 0);

    NSTextCheckingResult *m = [rel firstMatchInString:payload options:0 range:NSMakeRange(0, payload.length)];
    if (m) {
        double n = InsCNNumber([payload substringWithRange:[m rangeAtIndex:1]]);
        NSString *unit = [payload substringWithRange:[m rangeAtIndex:2]];
        double sec = [unit isEqualToString:@"秒"] ? 1
                   : ([unit isEqualToString:@"小时"] || [unit isEqualToString:@"钟头"]) ? 3600 : 60;
        delay = n * sec;
        when = [payload substringWithRange:m.range];
        timeRange = m.range;
    } else {
        m = [abs firstMatchInString:payload options:0 range:NSMakeRange(0, payload.length)];
        if (!m) return NO;
        NSString *daypart = [m rangeAtIndex:1].location != NSNotFound
            ? [payload substringWithRange:[m rangeAtIndex:1]] : @"";
        NSInteger hour = (NSInteger)InsCNNumber([payload substringWithRange:[m rangeAtIndex:2]]);
        NSInteger minute = 0;
        if ([m rangeAtIndex:3].location != NSNotFound) {
            NSString *mm = [payload substringWithRange:[m rangeAtIndex:3]];
            minute = [mm isEqualToString:@"半"] ? 30 : (NSInteger)[mm integerValue];
        }
        if (([daypart isEqualToString:@"晚上"] || [daypart isEqualToString:@"下午"] || [daypart isEqualToString:@"中午"]) && hour < 12) hour += 12;
        if (hour > 23 || minute > 59) return NO;
        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDateComponents *dc = [cal components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:[NSDate date]];
        dc.hour = hour; dc.minute = minute; dc.second = 0;
        NSDate *target = [cal dateFromComponents:dc];
        if ([daypart isEqualToString:@"明天"]) target = [target dateByAddingTimeInterval:86400];
        if ([target timeIntervalSinceNow] <= 0) target = [target dateByAddingTimeInterval:86400];
        delay = [target timeIntervalSinceNow];
        NSDateFormatter *fmt = [NSDateFormatter new];
        fmt.dateFormat = @"HH:mm";
        when = [NSString stringWithFormat:@"%@ %@", [cal isDateInToday:target] ? @"今天" : @"明天", [fmt stringFromDate:target]];
        timeRange = m.range;
    }
    if (delay <= 0 || delay > 7 * 86400) return NO;

    NSString *rest = nil;
    for (NSString *anchor in @[@"提醒我去", @"提醒我", @"提醒"]) {
        NSRange r = [payload rangeOfString:anchor];
        if (r.location != NSNotFound) {
            rest = [payload substringFromIndex:r.location + r.length];
            break;
        }
    }
    if (!rest) rest = payload;
    // 时间词可能在「提醒我」前也可能在后，统一抠掉
    rest = [rest stringByReplacingOccurrencesOfString:[payload substringWithRange:timeRange] withString:@""];
    NSCharacterSet *punct = [NSCharacterSet characterSetWithCharactersInString:@"，。、,.:：;； \t\n"];
    rest = [rest stringByTrimmingCharactersInSet:punct];

    *outDelay = delay;
    *outContent = rest;
    *outWhen = when;
    return YES;
}

/// 放行名单管理：默认只有账号主人能下命令，这里把别人加进 allowTriggersFrom。
/// 用法：「放行 林健」「放行 *」「放行列表」「取消放行 林健」「取消放行 *」
static void InsHandleAllow(NSString *payload, NSString *talker) {
    InsConfig *cfg = [InsConfig shared];
    NSString *trigger = cfg.trigger.length ? cfg.trigger : @"@insomnia";
    NSString *rest = payload;
    BOOL remove = NO;
    for (NSString *w in @[@"取消放行", @"不放行", @"放行", @"允许", @"allow"]) {
        if ([payload hasPrefix:w]) {
            remove = [w hasPrefix:@"取消"] || [w hasPrefix:@"不"];
            rest = [payload substringFromIndex:w.length];
            break;
        }
    }
    rest = [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // 原地改这个数组，下面所有回复都读同一份
    NSMutableArray *list = [(cfg.allowTriggersFrom ?: @[]) mutableCopy];

    if (remove) {
        if (!rest.length) {
            InsReply(talker, [NSString stringWithFormat:@"用法：%@ 取消放行 <名字>；%@ 取消放行 * 清空整个名单",
                              trigger, trigger]);
            return;
        }
        if ([rest isEqualToString:@"*"] || [rest isEqualToString:@"全部"] || [rest isEqualToString:@"所有人"]) {
            [list removeAllObjects];
            cfg.allowTriggersFrom = list;
            [cfg save];
            InsReply(talker, @"放行名单已清空，现在只有你自己能用。");
            return;
        }
        NSMutableArray *drop = [NSMutableArray array];
        for (NSString *item in list) {
            if ([item caseInsensitiveCompare:rest] == NSOrderedSame) [drop addObject:item];
        }
        if (!drop.count) {
            InsReply(talker, [NSString stringWithFormat:@"名单里没有「%@」。当前放行：%@",
                              rest, list.count ? [list componentsJoinedByString:@"、"] : @"（空）"]);
            return;
        }
        [list removeObjectsInArray:drop];
        cfg.allowTriggersFrom = list;
        [cfg save];
        InsReply(talker, [NSString stringWithFormat:@"已取消放行「%@」。当前放行：%@",
                          rest, list.count ? [list componentsJoinedByString:@"、"] : @"（空，只有你自己能用）"]);
        return;
    }

    // 「放行」「放行列表」「放行 list」都当查询
    if (!rest.length || [rest isEqualToString:@"列表"] || [rest isEqualToString:@"list"] ||
        [rest isEqualToString:@"谁"] || [rest isEqualToString:@"查看"]) {
        if (!list.count) {
            InsReply(talker, [NSString stringWithFormat:
                @"当前只有你自己能用（名单为空）。\n"
                @"让别人也能用：%@ 放行 <备注名或 wxid>，或 %@ 放行 * 放开所有人。\n"
                @"注意：放行后对方能问问题、能让你代发，但 Key、安装、配置、放行名单这些仍然只有你能改。",
                trigger, trigger]);
            return;
        }
        NSMutableArray *shown = [NSMutableArray array];
        for (NSString *item in list) {
            [shown addObject:[item isEqualToString:@"*"] ? @"*（所有人）" : item];
        }
        InsReply(talker, [NSString stringWithFormat:@"当前放行：%@\n（按联系人的备注名、昵称或 wxid 匹配；"
                          @"名字对不上不生效，可用「%@ 查人 <名字>」看准确写法）",
                          [shown componentsJoinedByString:@"、"], trigger]);
        return;
    }

    if ([rest isEqualToString:@"*"]) {
        [list setArray:@[@"*"]];
        cfg.allowTriggersFrom = list;
        [cfg save];
        InsReply(talker, [NSString stringWithFormat:
            @"已放开所有人：任何人在单聊或群里 @ 你都能问问题。\n"
            @"Key、安装、配置、放行名单这类命令仍然只有你能用。\n"
            @"想收回：%@ 取消放行 *", trigger]);
        return;
    }

    BOOL already = NO;
    for (NSString *item in list) {
        if ([item caseInsensitiveCompare:rest] == NSOrderedSame) { already = YES; break; }
    }
    if (!already) [list addObject:rest];
    cfg.allowTriggersFrom = list;
    [cfg save];
    if (!already && ![rest containsString:@"@"]) {
        // 名字写错是最常见的失败原因，顺手把匹配结果告一声，别让人对着「还是没反应」猜
        NSArray *list2 = cfg.allowTriggersFrom;
        InsReply(talker, [NSString stringWithFormat:
            @"已放行「%@」。当前放行：%@\n"
            @"提示：名字要和微信里的备注名或昵称完全一致才生效；对方再发还是没反应的话，"
            @"用「%@ 查人 %@」看准确写法（也可以直接放行 wxid）。\n"
            @"日志里会记一条「拦下（不在 allowTriggersFrom）」，方便确认到底挡没挡住。",
            rest, [list2 componentsJoinedByString:@"、"], trigger, rest]);
    } else {
        InsReply(talker, [NSString stringWithFormat:@"已放行「%@」。当前放行：%@",
                          rest, [list componentsJoinedByString:@"、"]]);
    }
}

static void InsRunCommand(NSString *payload, NSString *talker, NSString *displayName,
                          NSDictionary *linkOverride, NSDictionary *imageOverride,
                          NSString *recordOverride, NSDictionary *fileOverride,
                          BOOL owner, NSString *quoteNote, uint32_t msgTime) {
    InsConfig *cfg = [InsConfig shared];
    // 手动补发/引用时 payload 可能自带触发词，先剥掉再解析
    if (cfg.trigger.length && [payload hasPrefix:cfg.trigger]) {
        payload = [[payload substringFromIndex:cfg.trigger.length]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    // 「补成品 <jobid> [给 <名字/wxid>]」：云端已做好的翻唱成品当时没发出去（息屏/后台），
    // 主人重发一次，不重新下单、不用等 6~8 分钟。默认发当前会话，带「给 X」发指定人。
    NSString *cmdLower = [payload lowercaseString];
    if (owner && InsCmdIs(cmdLower, @"补成品")) {
        NSString *arg = InsArgAfter(payload, @"补成品");
        NSArray *bits = [arg componentsSeparatedByCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSMutableArray *words = [NSMutableArray array];
        for (NSString *b in bits) if (b.length) [words addObject:b];
        NSString *jobid = words.firstObject;
        NSString *destTalker = talker;   // 默认发当前会话
        NSString *destName = @"";
        NSUInteger idx = [words indexOfObject:@"给"];
        if (idx == NSNotFound) idx = [words indexOfObject:@"to"];
        if (idx != NSNotFound && idx + 1 < words.count) {
            destName = words[idx + 1];
            NSString *q = destName;
            if ([q hasPrefix:@"wxid_"]) {
                destTalker = q;
            } else {
                NSArray *cands = [InsStat candidatesForName:q];
                NSArray *exact = [cands filteredArrayUsingPredicate:
                                  [NSPredicate predicateWithFormat:@"name ==[c] %@", q]];
                if (exact.count == 1) {
                    destTalker = exact.firstObject[@"wxid"];
                } else if (cands.count == 1) {
                    destTalker = cands.firstObject[@"wxid"];
                } else if (cands.count > 1) {
                    InsReply(talker, [NSString stringWithFormat:
                        @"「%@」匹配到多个人，请用 wxid 指定：补成品 %@ 给 wxid_xxx", q, jobid ?: @"?"]);
                    return;
                } else {
                    InsReply(talker, [NSString stringWithFormat:@"没找到「%@」这个人。", q]);
                    return;
                }
            }
        }
        if (!jobid.length || !cfg.coverURL.length) {
            InsReply(talker, @"用法：补成品 <任务id> [给 <名字/wxid>]（翻唱服务未配置时不可用）");
            return;
        }
        InsNote([NSString stringWithFormat:@"补成品：job %@ → %@", jobid, destTalker]);
        InsReply(talker, [NSString stringWithFormat:@"补发成品 %@…", jobid]);
        [InsVoice resendCoverJob:jobid url:cfg.coverURL talker:destTalker reply:^(NSString *text) {
            InsReply(talker, text);
        }];
        return;
    }
    // 「唱歌 <歌名/要求>」/「语音 唱 <…>」：现场编词开唱。先让大模型把题目写成歌词，
    // 回答出来后用唱歌腔（Breeze 演唱指令）合成语音条，而不是照着念。
    // 这个检查必须放在语音问答之前：「语音 唱xxx」不能被当成普通语音提问。
    BOOL singOnce = NO;
    {
        NSString *singTopic = nil;
        if ([InsVoice singRequestForPayload:payload topic:&singTopic]) {
            singOnce = YES;
            // 配置了 Mac 翻唱服务：点具体的歌直接走「找原曲→分离→换音色→合成」，
            // 旋律是原曲的；没配才走下面的编词 TTS 直唱。
                if (cfg.coverURL.length) {
                    NSString *song = singTopic.length ? singTopic : payload;
                    BOOL wantFull = [InsVoice singFullRequested:payload];
                    InsNote([NSString stringWithFormat:@"唱歌：翻唱服务处理「%@」%@",
                             song, wantFull ? @"（完整版）" : @""]);
                // 翻唱是「下单 → 轮询几分钟 → 取成品」，每一步都是同步阻塞调用。
                // 这里绝对不能就地执行：消息钩子跑在微信主线程上，阻塞超过几秒
                // 微信就整片卡死（发完消息界面点不动就是这么来的）。一律丢进排队队列，
                // 让主线程马上返回。
                NSString *coverURL = cfg.coverURL;
                NSString *who = displayName.length ? displayName : talker;
                NSUInteger depth = InsCoverDepth();
                if (depth >= 3) {   // 一首约 6~8 分钟，压太多没意义
                    InsNote([NSString stringWithFormat:@"翻唱队列已满（%lu 条），丢弃：%@",
                             (unsigned long)depth, song]);
                    InsReply(talker, [NSString stringWithFormat:
                        @"前面还压着 %lu 首歌没做完，这条先不接了，过一会儿再发。",
                        (unsigned long)depth]);
                    return;
                }
                // 链接点歌（抖音等）：song 是完整 URL，绝不能把它塞进接单文案——
                // 微信内部 SendTextMessage 遇到含长链接+特殊字符(%&?=)的文本会解析成
                // 「检测到分享链接」，把消息丢进输入框等人确认，结果卡在输入框发不出去。
                // 所以这里对链接源只回一句简短文案，不出现 URL。
                BOOL isLinkSong = [song hasPrefix:@"http://"] || [song hasPrefix:@"https://"];
                NSString *queueLabel = isLinkSong ? @"链接里的歌" : song;
                InsEnqueueCover([NSString stringWithFormat:@"%@: 唱《%@》%@", who, queueLabel,
                                 wantFull ? @"（完整版）" : @""], ^{
                    // 先回一句接单，中间没有反馈会让人以为卡死了。文案里不出现任何链接。
                    NSString *ack;
                    if (isLinkSong) {
                        ack = @"收到，开始做这个链接里的歌：取原声 → 换成我的音色 → 合成，"
                              @"这种快，一般 1~2 分钟，好了直接把语音发给你。";
                    } else {
                        ack = [NSString stringWithFormat:
                               @"收到，开始做《%@》：找原曲 → 拆人声 → 换成我的音色 → 合成，"
                               @"%@好了直接把语音发给你。", song,
                               wantFull ? @"这是完整版，要 10 分钟以上、分几条语音发。\n" : @"一般 6~8 分钟，"];
                    }
                    InsReply(talker, ack);
                    [InsVoice singCoverWithSong:song url:coverURL talker:talker full:wantFull reply:^(NSString *text) {
                        if ([text hasPrefix:@"已发语音"]) {
                            InsNote(text);
                            return;
                        }
                        InsReply(talker, text);
                    }];
                });
                return;
            }
            if (singTopic.length) {
                // 点了具体的歌（「唱首周杰伦的花海」）：让模型先认歌——是真歌就按原歌词
                // 节选演唱并给出这首歌的唱法；不认识就如实说，绝不编歌词。
                payload = [NSString stringWithFormat:
                    @"题目「%@」。先判断这是不是一首真实存在的歌：\n"
                    @"① 是真歌：第一行输出「唱法：<一句话描述这首歌的演唱风格>」，"
                    @"然后按原歌词输出（只输出你确定记得的部分，节选最经典的段落，8 句以内）；"
                    @"歌词没把握就直接输出「不认识这首歌」，不要编造。\n"
                    @"② 不是真歌（泛泛的要求）：自己编一段能唱的歌词，4~8 句，第一行同样输出「唱法：<适合的风格>」。\n"
                    @"除第一行唱法外只输出歌词正文，不要歌名、段落标记、括号注释、表情和任何解释。",
                    singTopic];
            } else {
                payload = @"直接输出一段能唱的中文歌词：第一行输出「唱法：<适合的演唱风格>」，"
                          @"然后给 4~8 句轻松愉快、口语化、有韵脚的歌词；"
                          @"除第一行唱法外不要歌名、段落标记、括号注释、表情和任何解释。";
            }
            InsNote([NSString stringWithFormat:@"唱歌：要唱「%@」，先认歌编词",
                     singTopic.length ? singTopic : @"（自由发挥）"]);
        }
    }
    // 「语音 背一首李白的古诗」不是让我照读这句话，而是「理解我的话，再把回答念出来」。
    // 所以这里把「语音」剥掉，payload 改成要问的话，走正常问答，回答出来再合成语音条。
    // 真要照读原文：语音 原文 <话> / 语音 说<话>（这条路径会返回 AskNone 交给 InsVoice 接管）
    BOOL voiceOnce = NO;
    {
        NSString *voiceAsk = nil;
        InsVoiceAskMode vmode = [InsVoice askModeForPayload:payload text:&voiceAsk];
        if (vmode != InsVoiceAskNone && voiceAsk.length) {
            InsNote([NSString stringWithFormat:@"语音：先理解「%@」再念回答（%ld）",
                     voiceAsk, (long)vmode]);
            payload = voiceAsk;
            voiceOnce = (vmode == InsVoiceAskSpeak);
        }
    }
    // 排队自身的开关必须能立刻生效：留在队列里的话，前面一条长任务卡住时
    // 连「排队 关」都执行不了。这组命令直接在当前线程处理，不进队列。
    {
        NSString *qLower = [payload lowercaseString];
        BOOL isQueueCmd = InsCmdIs(qLower, @"排队") || InsCmdIs(qLower, @"queue");
        if (isQueueCmd) {
            NSString *arg = InsArgAfter(payload, InsCmdIs(qLower, @"排队") ? @"排队" : @"queue");
            NSString *a = [arg lowercaseString];
            if ([a hasPrefix:@"开"] || [a isEqualToString:@"on"]) {
                atomic_store(&gQueueOn, true);
                InsReply(talker, @"排队已打开：多人同时 @ 我时，按每条消息的发送时间先后逐条回答。");
            } else if ([a hasPrefix:@"关"] || [a isEqualToString:@"off"]) {
                atomic_store(&gQueueOn, false);
                InsReply(talker, @"排队已关闭：命令回到并发执行，谁先问完谁先回。");
            } else if ([a hasPrefix:@"清"] || [a hasPrefix:@"clear"]) {
                NSUInteger n = 0;
                @synchronized (gPending) {
                    n = gPending.count;
                    [gPending removeAllObjects];
                }
                InsNote([NSString stringWithFormat:@"排队：清空了 %lu 条待办", (unsigned long)n]);
                InsReply(talker, [NSString stringWithFormat:@"已丢弃 %lu 条还没开始处理的命令。", (unsigned long)n]);
            } else {
                InsReply(talker, [NSString stringWithFormat:
                                  @"%@。\n%@ 排队 开 / 关 切换；%@ 排队 清空 丢弃待办",
                                  InsQueueStatus(), cfg.trigger, cfg.trigger]);
            }
            return;
        }
    }
    // 排队状态里显示的是谁问的、问的什么，方便多会话时看出先后
    NSString *queueWho = [InsMemory partnerLabelForTalker:talker];
    if (!queueWho.length) queueWho = displayName.length ? displayName : talker;
    NSString *queueBrief = payload.length > 20 ? [[payload substringToIndex:20] stringByAppendingString:@"…"] : (payload ?: @"");
    NSString *queueLabel = [NSString stringWithFormat:@"%@: %@", queueWho, queueBrief];
    // 上限 20 条：有人连刷时宁可拒掉新消息，也别把队伍堵到几十分钟
    NSUInteger depthNow = InsQueueDepth();
    if (depthNow >= 20) {
        InsNote([NSString stringWithFormat:@"排队已满（%lu 条），丢弃：%@", (unsigned long)depthNow, queueBrief]);
        InsReply(talker, [NSString stringWithFormat:@"前面还压着 %lu 条没答完，这条先不接了，过一会儿再发。",
                          (unsigned long)depthNow]);
        return;
    }
    InsEnqueueWork(msgTime, queueLabel, ^{
        // 代发：已授权的人让我把某句话转给另一个联系人（授权 + 内容检查 + 频控 + 审计）
        if ([InsRelay handlePayload:payload talker:talker senderName:displayName owner:owner
                              reply:^(NSString *text) { InsReply(talker, text); }
                            deliver:^(NSString *text, NSString *targetTalker, BOOL allowNavigate,
                                      void (^done)(BOOL ok, NSString *how)) {
                                InsDeliverText(targetTalker, text, allowNavigate, done);
                            }]) {
            return;
        }
        NSString *lower = [payload lowercaseString];
        // 主人一发命令，就把「刚才有人 @ 但被放行名单挡住」的记录带出来，不用去翻日志
        if (owner) {
            NSString *blocked = InsBlockedTakeReport(talker);
            if (blocked.length) InsReply(talker, blocked);
        }
        // 别人（allowTriggersFrom 放行的人）只能用问答和代发；Key、安装、记忆导出这些只有主人能动
        if (!owner) {
            for (NSString *w in @[@"key", @"视觉key", @"密码", @"清单", @"setup", @"恢复配置", @"恢复key",
                                  @"导入配置", @"update", @"装", @"重启", @"mem", @"reset", @"记忆",
                                  @"配置", @"config", @"log", @"wb", @"link", @"方向", @"本地回显",
                                  @"允许", @"放行", @"取消放行", @"allow", @"进度", @"查人", @"找人", @"联系人",
                                  @"key2", @"备用key", @"base2", @"接口2", @"model2", @"模型2",
                                  @"测key", @"keycheck", @"语音key", @"语音体检",
                                  @"排队", @"queue", @"直发能力", @"sendapi",
                                  @"读文件", @"readfile"]) {
                if (InsCmdIs(lower, w)) {
                    InsNote([NSString stringWithFormat:@"拒绝非主人命令：%@（%@）", w, talker]);
                    InsReply(talker, @"这类命令只有账号主人能用。");
                    return;
                }
            }
        }
        // 引用了链接/图片/聊天记录、只发了触发词时（payload 为空）也要去读那条，而不是回帮助
        if ([lower hasPrefix:@"help"] ||
            (!payload.length && !linkOverride.count && !imageOverride.count &&
             !recordOverride.length && !fileOverride.count)) {
            InsReply(talker, [NSString stringWithFormat:
                @"Insomnia 用法：\n%1$@ <问题> 直接提问\n"
                @"%1$@ 看看链接 / 看下他发的链接 自动读本会话上方最近一条链接\n"
                @"%1$@ links 列出最近几条链接；%1$@ 看第2条链接 可指定\n"
                @"%1$@ 自动看链接 开/关 点进会话就自动分析对方发来的链接（默认开，静默存本地）\n"
                @"%1$@ 自动看链接 静默/转发/回复 切换结果去向；%1$@ 链接摘要 看已分析结果\n"
                @"%1$@ 看下这张图 / 看看他发的图 自动读本会话最近的图片\n"
                @"引用链接、图片或聊天记录再 %1$@ 直接分析被引用的那条\n"
                @"%1$@ 看聊天记录 / 总结转发记录 自动读本会话最近的合并转发记录\n"
                @"%1$@ 点开 / 点开链接 抓不到正文时让我在屏幕上点开读一遍\n"
                @"%1$@ 语音 <话> 先理解你的话，再把回答念成语音条（背诗/讲笑话也认）\n"
                @"%1$@ 唱歌 <歌名/要求> 现场编词开唱，发语音条；%1$@ 语音 唱腔 <描述> 定演唱风格\n"
                @"%1$@ 语音 原文 <话> / %1$@ 语音 说<话> 照读这句话本身；%1$@ 语音 试 <话> 只试听不发\n"
                @"%1$@ 语音体检 查 Key/合成/录音通道；%1$@ 语音 通道 / 语音 格式 切换注入通道\n"
                @"%1$@ 语音 声 list 选音色；%1$@ 语音 语气 <描述>；%1$@ 语音 模式 开/关 问答自动发语音\n"
                @"%1$@ 语音key <Key> 写主 Key；%1$@ 语音key2 <Key> 写备用 Key（主 Key 401/402/403/429 自动换）\n"
                @"%1$@ 语音key 列表 看 Key 池；%1$@ 语音key 测 逐把实测；一个字段可用逗号写多把\n"
                @"%1$@ 微博热点 / 抖音热点 / 知乎热点 / 百度热点 / 头条热点 / B站热点 抓热榜，附可点开的链接\n"
                @"%1$@ 热点 全网热点 一次看微博+抖音+知乎；%1$@ 微博热点 汽车 只看含关键词的；加数字限条数如 微博热点 5\n"
                @"%1$@ 林健说了多少句 你小子 直接扫聊天库数条数（也认「说了几次」「出现了多少回」）\n"
                @"%1$@ 数 林健 你小子 指定人和词统计；%1$@ 数 你小子 只数当前会话\n"
                @"%1$@ 放行 林健 / %1$@ 放行 * 让别人也能 @ 你问问题（默认只有你能用；Key/安装/配置仍只限你）\n"
                @"%1$@ 放行列表 看名单；%1$@ 取消放行 林健 收回权限\n"
                @"%1$@ 授权 林健 张鹏 允许林健让我给张鹏发消息（单聊生效，发送前查内容）\n"
                @"%1$@ 查人 张鹏 按名字查联系人和 wxid（授权对不上名字时先用这个）\n"
                @"%1$@ 授权列表 / %1$@ 取消授权 林健 [张鹏] / %1$@ 代发记录\n"
                @"%1$@ 代发体检 张鹏 代发发不出去时逐段体检：联系人 / 内部接口 / 开会话 / 8090\n"
                @"%1$@ 排队 看多人同时 @ 时的排队状态；%1$@ 排队 开/关 切换；%1$@ 排队 清空 丢弃待办\n"
                @"%1$@ 测key 主/备通道各发一句最小请求，报可用性与服务端原话\n"
                @"%1$@ key2 <Key> 配备用 Key（主 Key 被停用/分组被删/欠费时自动顶上）\n"
                @"%1$@ 兜底 直接把视觉通道当备用聊天通道；%1$@ base2 / %1$@ model2 单独改地址和模型\n"
                @"%1$@ 代发 开/关、代发 跳转 开/关、代发 署名 开/关\n"
                @"%1$@ sync 同步此人全部历史进记忆\n"
                @"%1$@ 同步速度 4 调并发路数（历史量大时会自动走并发回填）\n"
                @"%1$@ mem 查看当前记忆\n%1$@ reset 清空本会话记忆\n%1$@ status 查看状态\n"
                @"%1$@ 斗图开 / 斗图关 对方发表情包时自动回一张我的表情包\n"
                @"%1$@ 来一张 立刻回一张；%1$@ 表情包 查看/刷新我的表情库\n"
                @"%1$@ 叫我 <称呼> 改叙述里对你的叫法；%1$@ 重述 把旧摘要改成新口径\n"
                @"%1$@ 进度 看同步进度；%1$@ 进度开/关、进度 30、进度 现在、进度 这里\n"
                @"%1$@ 送达 看有没有只在本地显示、对方收不到的回复；%1$@ 补发 立刻重试\n"
                @"%1$@ 配置 体检配置；%1$@ 恢复配置 从备份补；%1$@ key <Key> 重设聊天 Key\n"
                @"%1$@ 方向 检查历史消息的发言人标注是否正确\n"
                @"%1$@ 视觉key <Key> 重设视觉 Key；%1$@ 密码 <sudo密码>；%1$@ 清单 <地址>\n"
                @"%1$@ 一分钟后提醒我去吃饭 定时提醒（支持 X分钟/小时后、几点几分）\n"
                @"%1$@ update 检查并安装最新版（自动重启微信）\n"
                @"%1$@ 装 <deb直链> 手动装包兜底（清单地址丢了也能升）\n"
                @"%1$@ log [行数] 取最近日志发回本会话，长按复制给 WorkBuddy\n"
                @"%1$@ wb [问题] 生成交接包（版本+配置+日志），复制给 WorkBuddy\n"
                @"%1$@ link 回显最近一条链接的 URL，可复制给 WorkBuddy 代抓\n"
                @"%1$@ 画<描述> 用本机 ChatGPT 生图并自动发回本会话",
                cfg.trigger]);
            return;
        }
        // 放行名单：别人想用 @insomnia，得先把人加进来（只有主人能改）
        if ([lower hasPrefix:@"放行"] || [lower hasPrefix:@"取消放行"] ||
            [lower hasPrefix:@"允许"] || [lower hasPrefix:@"allow"]) {
            InsHandleAllow(payload, talker);
            return;
        }
        // 找人：授权/代发时如果名字对不上，先用这个看备注名和 wxid
        if (InsCmdIs(lower, @"查人") || InsCmdIs(lower, @"找人")) {
            NSString *word = [lower hasPrefix:@"查人"] ? @"查人" : @"找人";
            InsReply(talker, [InsStat searchReport:InsArgAfter(payload, word)]);
            return;
        }
        if ([lower hasPrefix:@"status"]) {
            NSDictionary *memory = [InsMemory load:talker];
            NSUInteger total = [InsHistory totalTextMessageCountForTalker:talker];
            uint32_t cursor = [memory[@"cursor"] unsignedIntValue];
            NSString *syncedTo = cursor
                ? [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSince1970:cursor]
                                                 dateStyle:NSDateFormatterMediumStyle
                                                 timeStyle:NSDateFormatterShortStyle]
                : @"尚未同步";
            NSMutableString *out = [NSMutableString string];
            [out appendFormat:@"版本 %@\n", InsLocalVersion()];
            [out appendFormat:@"模型 %@ / 接口 %@\n", cfg.chatModel, cfg.baseURL];
            if (cfg.apiKey.length) {
                [out appendString:@"聊天 Key 已配置\n"];
                if (cfg.apiKey2.length) {
                    [out appendFormat:@"  备用 Key 已配置（%@），主 Key 失效时自动顶上\n",
                        cfg.chatModel2.length ? cfg.chatModel2 : cfg.chatModel];
                }
            } else {
                [out appendFormat:@"聊天 Key 未配置：同步与问答已暂停\n"
                    @"  先 %@ 恢复配置；不行就 %@ setup <串> 或 %@ key <Key>\n"
                    @"  不确定 Key 好不好用：%@ 测key\n",
                    cfg.trigger, cfg.trigger, cfg.trigger, cfg.trigger];
            }
            [out appendFormat:@"斗图 %@ / 模式 %@ / 表情库 %lu 张\n",
                [InsSticker battleEnabled] ? @"开" : @"关", [InsSticker battleMode],
                (unsigned long)[InsSticker library].count];
            [out appendFormat:@"%@\n", [InsProgress statusLine]];
            [out appendFormat:@"%@\n", [InsOutbox statusLine]];
            [out appendFormat:@"%@\n", [InsRelay statusLine]];
            [out appendFormat:@"%@\n", [InsAutoLink statusLine]];
            [out appendFormat:@"%@\n", [InsVoice statusLine]];
            [out appendFormat:@"叙述口径：你发的=「%@」／对方发的=「%@」\n",
                [InsMemory selfLabel], [InsMemory partnerLabelForTalker:talker]];
            [out appendFormat:@"本会话文本消息 %lu 条（分会话统计，换个聊天窗口就是它自己的进度）\n",
                (unsigned long)total];
            [out appendFormat:@"已同步 %lu 条 / 摘要 %lu 次\n",
                (unsigned long)[memory[@"stats"][@"scanned"] unsignedIntegerValue],
                (unsigned long)[memory[@"stats"][@"chunks"] unsignedIntegerValue]];
            [out appendFormat:@"同步到 %@\n", syncedTo];
            [out appendFormat:@"记忆摘要：%@",
                [memory[@"summary"] isKindOfClass:[NSString class]] ? memory[@"summary"] : @"(空)"];
            InsReply(talker, out);
            return;
        }

        // ---- 配置自救：体检 / 从备份恢复 / 重设 Key / 一键导入 ----
        if (InsCmdIs(lower, @"配置") || InsCmdIs(lower, @"config") || InsCmdIs(lower, @"配置体检")) {
            InsReply(talker, [InsConfig diagnostics]);
            return;
        }
        if (InsCmdIs(lower, @"恢复配置") || InsCmdIs(lower, @"恢复") || InsCmdIs(lower, @"restore")) {
            BOOL ok = [cfg restoreFromBackup];
            InsReply(talker, ok ? @"已从备份补回配置，发 status 确认聊天 Key。" :
                @"备份里没有可补的字段（旧版本没留过备份）。改发 setup <串> 或 key <Key> 直接设置。");
            return;
        }
        if (InsCmdIs(lower, @"setup") || InsCmdIs(lower, @"导入配置") || InsCmdIs(lower, @"恢复key")) {
            NSString *word = [lower hasPrefix:@"setup"] ? @"setup"
                            : ([lower hasPrefix:@"导入配置"] ? @"导入配置" : @"恢复key");
            NSString *arg = InsArgAfter(payload, word);
            if (!arg.length) {
                InsReply(talker, @"用法：把恢复串（很长那串字母数字）接在 setup 后面整条发过来。");
                return;
            }
            NSData *decoded = [[NSData alloc] initWithBase64EncodedString:arg
                                                                  options:NSDataBase64DecodingIgnoreUnknownCharacters];
            NSDictionary *pairs = decoded ? [NSJSONSerialization JSONObjectWithData:decoded options:0 error:nil] : nil;
            if (![pairs isKindOfClass:[NSDictionary class]]) {
                pairs = [NSJSONSerialization JSONObjectWithData:[arg dataUsingEncoding:NSUTF8StringEncoding]
                                                       options:0 error:nil];
            }
            if (![pairs isKindOfClass:[NSDictionary class]]) {
                // 报清楚是「解不开」还是「字段为空」，用户才能判断是复制漏了还是串本身不对
                InsReply(talker, [NSString stringWithFormat:
                    @"这串没解开（长度 %lu，%@）。常见原因：复制时被微信截断、末尾少了 =、\
                     或者中间混进了空格/表情。可以改用 @insomnia key <聊天Key> 和 @insomnia 视觉key <视觉Key> 分两次发。",
                    (unsigned long)arg.length,
                    decoded ? @"不是合法 JSON" : @"不是合法 base64"]);
                return;
            }
            NSUInteger n = [cfg applySetupDictionary:pairs];
            NSMutableArray *imported = [NSMutableArray array];
            for (NSString *k in @[@"apiKey", @"visionApiKey", @"sudoPassword", @"updateManifest", @"baseURL", @"chatModel"]) {
                if ([pairs[k] isKindOfClass:[NSString class]] && [pairs[k] length]) [imported addObject:k];
            }
            InsReply(talker, n ? [NSString stringWithFormat:
                @"已导入 %lu 个字段（%@），这串不会写进日志。\n发 %@ status 确认「聊天 Key 已配置」；有 Key 后 %@ sync 就能继续同步。",
                (unsigned long)n, [imported componentsJoinedByString:@"/"], cfg.trigger, cfg.trigger] :
                @"这串解析出来了但没一个字段能用（值都是空的）。改用 @insomnia key <Key> 单独写聊天 Key。");
            return;
        }
        if (InsCmdIs(lower, @"视觉key") || InsCmdIs(lower, @"visionkey")) {
            NSString *k = InsArgAfter(payload, [lower hasPrefix:@"视觉key"] ? @"视觉key" : @"visionkey");
            if (!k.length) { InsReply(talker, @"用法：@insomnia 视觉key <Key>"); return; }
            [cfg setConfigKeysPersisted:@{@"visionApiKey": k}];
            cfg.visionApiKey = k;
            InsReply(talker, [NSString stringWithFormat:@"视觉 Key 已写入（长度 %lu）。", (unsigned long)k.length]);
            return;
        }
        if (InsCmdIs(lower, @"聊天key") || InsCmdIs(lower, @"key")) {
            NSString *k = InsArgAfter(payload, [lower hasPrefix:@"聊天key"] ? @"聊天key" : @"key");
            if (!k.length) { InsReply(talker, @"用法：@insomnia key <API Key>"); return; }
            [cfg setApiKeyPersisted:k];
            InsReply(talker, [NSString stringWithFormat:
                @"聊天 Key 已写入（长度 %lu）。Key 不会出现在日志和交接包里；发 status 确认。",
                (unsigned long)k.length]);
            return;
        }
        // 备用通道：主 Key 被停用/分组被删/欠费时自动顶上，不至于整个助手哑掉
        if (InsCmdIs(lower, @"key2") || InsCmdIs(lower, @"备用key")) {
            NSString *prefix = [lower hasPrefix:@"key2"] ? @"key2" : @"备用key";
            NSString *k = InsArgAfter(payload, prefix);
            if (!k.length) { InsReply(talker, @"用法：@insomnia key2 <备用 Key>（主 Key 报 401/403 时自动切到它）"); return; }
            [cfg setConfigKeysPersisted:@{ @"apiKey2": k }];
            cfg.apiKey2 = k;
            InsReply(talker, [NSString stringWithFormat:
                @"备用 Key 已写入（长度 %lu）。主 Key 失效时会自动切过去；发「%@ 测key」当场验证两条通道。",
                (unsigned long)k.length, cfg.trigger]);
            return;
        }
        if (InsCmdIs(lower, @"base2") || InsCmdIs(lower, @"接口2")) {
            NSString *v = InsArgAfter(payload, [lower hasPrefix:@"base2"] ? @"base2" : @"接口2");
            if (!v.length) { InsReply(talker, @"用法：@insomnia base2 https://xxx/v1（备用通道地址，留空沿用主地址）"); return; }
            [cfg setConfigKeysPersisted:@{ @"baseURL2": v }];
            cfg.baseURL2 = v;
            InsReply(talker, [NSString stringWithFormat:@"备用接口已写入：%@", v]);
            return;
        }
        if (InsCmdIs(lower, @"model2") || InsCmdIs(lower, @"模型2")) {
            NSString *v = InsArgAfter(payload, [lower hasPrefix:@"model2"] ? @"model2" : @"模型2");
            if (!v.length) { InsReply(talker, @"用法：@insomnia model2 <备用模型名>（留空沿用主模型）"); return; }
            [cfg setConfigKeysPersisted:@{ @"chatModel2": v }];
            cfg.chatModel2 = v;
            InsReply(talker, [NSString stringWithFormat:@"备用模型已写入：%@", v]);
            return;
        }
        if (InsCmdIs(lower, @"测key") || InsCmdIs(lower, @"keycheck") || InsCmdIs(lower, @"测 key")) {
            InsReply(talker, @"正在测通道（聊天主备 + 视觉 + 语音），约 15 秒…");
            InsReply(talker, [InsLLM probeKeyReport]);
            InsReply(talker, [InsVoice keyProbeReport]);
            return;
        }
        // 一键兜底：把已在用的视觉通道直接当聊天备用通道，主 Key 报废时不必先去找新 Key
        if (InsCmdIs(lower, @"兜底") || InsCmdIs(lower, @"用视觉通道") || InsCmdIs(lower, @"视觉兜底")) {
            if (!cfg.visionApiKey.length || !cfg.visionBaseURL.length) {
                InsReply(talker, [NSString stringWithFormat:
                    @"视觉通道还没配 Key：先发「%@ 视觉key <Key>」，再发「%@ 兜底」。", cfg.trigger, cfg.trigger]);
                return;
            }
            NSString *model = cfg.visionModel.length ? cfg.visionModel : cfg.chatModel;
            [cfg setConfigKeysPersisted:@{ @"baseURL2": cfg.visionBaseURL,
                                           @"apiKey2": cfg.visionApiKey,
                                           @"chatModel2": model }];
            cfg.baseURL2 = cfg.visionBaseURL;
            cfg.apiKey2 = cfg.visionApiKey;
            cfg.chatModel2 = model;
            InsReply(talker, [NSString stringWithFormat:
                @"已把视觉通道设为备用：%@ · 模型 %@。\n发「%@ 测key」验证；能通的话，主 Key 再挂问答会自动切过去。",
                cfg.visionBaseURL, model, cfg.trigger]);
            return;
        }
        // 单键补写：长 base64 恢复串容易被微信截断，这几个短命令随时能单独补回
        if (InsCmdIs(lower, @"密码") || InsCmdIs(lower, @"sudo密码")) {
            NSString *p = InsArgAfter(payload, [lower hasPrefix:@"sudo密码"] ? @"sudo密码" : @"密码");
            if (!p.length) { InsReply(talker, @"用法：@insomnia 密码 <sudo 密码>"); return; }
            [cfg setConfigKeysPersisted:@{@"sudoPassword": p}];
            cfg.sudoPassword = p;
            InsReply(talker, @"sudo 密码已写入（只存在本机 config.json，不进日志/仓库）。");
            return;
        }
        if (InsCmdIs(lower, @"清单") || InsCmdIs(lower, @"manifest")) {
            NSString *u = InsArgAfter(payload, [lower hasPrefix:@"manifest"] ? @"manifest" : @"清单");
            if (!u.length) { InsReply(talker, @"用法：@insomnia 清单 <latest.json 地址>"); return; }
            [cfg setConfigKeysPersisted:@{@"updateManifest": u}];
            cfg.updateManifest = u;
            InsReply(talker, @"更新清单地址已写入，发 update 试试。");
            return;
        }

        // ---- 定时同步进度汇报 ----
        if ([lower hasPrefix:@"进度"] || [lower hasPrefix:@"progress"]) {
            NSString *arg = InsArgAfter(payload, [lower hasPrefix:@"progress"] ? @"progress" : @"进度");
            NSString *a = [arg lowercaseString];
            if ([a isEqualToString:@"开"] || [a isEqualToString:@"on"]) {
                [InsProgress setEnabled:YES];
                InsReply(talker, [NSString stringWithFormat:@"已开启：%@。默认发到「文件传输助手」，不会打扰别人。",
                                  [InsProgress statusLine]]);
                return;
            }
            if ([a isEqualToString:@"关"] || [a isEqualToString:@"off"] || [a isEqualToString:@"停"]) {
                [InsProgress setEnabled:NO];
                InsReply(talker, @"已关闭定时进度汇报。想看时发「进度 现在」即可。");
                return;
            }
            if ([a isEqualToString:@"这里"] || [a isEqualToString:@"本会话"] || [a isEqualToString:@"here"]) {
                [InsProgress setEnabled:YES target:talker chatName:displayName];
                InsReply(talker, @"进度改发到本会话。注意：这个会话里的对方也能看到这些进度消息。");
                return;
            }
            if ([a isEqualToString:@"发给我"] || [a isEqualToString:@"文件传输助手"] || [a isEqualToString:@"me"]) {
                [InsProgress setEnabled:YES target:@"filehelper" chatName:@"文件传输助手"];
                InsReply(talker, @"进度改发到「文件传输助手」，只有你自己能看到。");
                return;
            }
            if ([a isEqualToString:@"现在"] || [a isEqualToString:@"now"] || [a isEqualToString:@"发一次"]) {
                NSString *target = [InsProgress reportNow];
                InsReply(talker, [NSString stringWithFormat:@"已立刻发一份同步进度到「%@」。", target]);
                return;
            }
            NSInteger minutes = [arg integerValue];
            if (minutes > 0) {
                [InsProgress setIntervalMinutes:minutes];
                InsReply(talker, [NSString stringWithFormat:@"%@（间隔范围 5~1440 分钟）",
                                  [InsProgress statusLine]]);
                return;
            }
            InsReply(talker, [NSString stringWithFormat:
                @"%@\n发「%@ 进度 现在」立刻收一份；「%@ 进度 30」改成每 30 分钟；"
                @"「%@ 进度 这里」改发到本会话；「%@ 进度关」停掉。",
                [InsProgress statusLine], cfg.trigger, cfg.trigger, cfg.trigger, cfg.trigger]);
            return;
        }

        // ---- 送达：为什么有的回复对方看不到 / 补发 ----
        if (InsCmdIs(lower, @"补发") || InsCmdIs(lower, @"重发") || InsCmdIs(lower, @"outbox")) {
            if (![InsOutbox count]) {
                InsReplyNoQueue(talker, @"重发队列是空的，最近没有漏送的回复。");
                return;
            }
            InsReplyNoQueue(talker, [NSString stringWithFormat:@"开始补发 %lu 条…（会切到目标会话真发送）",
                                     (unsigned long)[InsOutbox count]]);
            [InsOutbox flushWithCompletion:^(NSString *report) {
                InsReplyNoQueue(talker, report);
            }];
            return;
        }
        if (InsCmdIs(lower, @"送达") || InsCmdIs(lower, @"发送体检")) {
            InsReplyNoQueue(talker, [InsOutbox detail]);
            return;
        }
        // 排查「跨会话发不出去」：列出微信内部带 Send 的方法，找能绕开界面的直发接口
        if (InsCmdIs(lower, @"直发能力") || InsCmdIs(lower, @"sendapi")) {
            InsReplyNoQueue(talker, [InsSend capabilityReport]);
            return;
        }
        // 排查「引用文件读不出正文」：按 svrid 走一遍定位/下载/读文本，把每步结果摊开
        if (owner && (InsCmdIs(lower, @"读文件") || InsCmdIs(lower, @"readfile"))) {
            NSString *rest = InsArgAfter(payload, InsCmdIs(lower, @"读文件") ? @"读文件" : @"readfile");
            NSMutableArray *bits = [NSMutableArray array];
            for (NSString *b in [rest componentsSeparatedByCharactersInSet:
                                 [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
                if (b.length) [bits addObject:b];
            }
            if (!bits.count) {
                InsReply(talker, [NSString stringWithFormat:
                    @"用法：%@ 读文件 <svrid> [会话名或 wxid]\nsvrid 是那条文件消息的服务端 ID，"
                    @"引用文件时日志里会打出来。", cfg.trigger]);
                return;
            }
            NSString *svrid = bits.firstObject;
            NSString *who = bits.count > 1 ? bits[1] : talker;
            NSString *target = who;
            if (![who hasPrefix:@"wxid_"] && ![who containsString:@"@"]) {
                NSArray *cands = [InsStat candidatesForName:who];
                target = cands.count ? cands.firstObject[@"wxid"] : @"";
                if (!target.length) {
                    InsReply(talker, [NSString stringWithFormat:@"没找到「%@」这个人。", who]);
                    return;
                }
            }
            NSString *why = nil;
            NSString *body = [InsMedia fileTextFor:@{ @"svrid": svrid } talker:target reason:&why];
            if (!body.length) {
                InsReplyNoQueue(talker, [NSString stringWithFormat:@"读不到：%@", why ?: @"未知原因"]);
                return;
            }
            NSString *head = body.length > 200 ? [body substringToIndex:200] : body;
            InsReplyNoQueue(talker, [NSString stringWithFormat:@"读到了 %lu 字，开头：\n%@",
                                     (unsigned long)body.length, head]);
            return;
        }
        if (InsCmdIs(lower, @"本地回显")) {
            NSString *arg = [InsArgAfter(payload, @"本地回显") lowercaseString];
            BOOL on = [arg isEqualToString:@"开"] || [arg isEqualToString:@"on"] || [arg isEqualToString:@"1"];
            BOOL off = [arg isEqualToString:@"关"] || [arg isEqualToString:@"off"] || [arg isEqualToString:@"0"];
            if (!on && !off) {
                InsReply(talker, [NSString stringWithFormat:
                    @"本地回显目前是「%@」。\n开着时，回复真发不出去会在本地插一条：你这边有气泡、对方收不到；\n关着（推荐）时，发不出去就进重发队列，不会再造假记录。\n发「%@ 本地回显 开/关」切换。",
                    cfg.allowLocalEcho ? @"开" : @"关", cfg.trigger]);
                return;
            }
            [cfg setConfigKeysPersisted:@{@"allowLocalEcho": @(on)}];
            cfg.allowLocalEcho = on;
            InsReply(talker, on ? @"已打开本地回显：发不出去时本地插一条（对方收不到，但你能看到）。"
                                : @"已关闭本地回显：发不出去就进重发队列，不会再出现「你这儿有、对方那儿没有」。");
            return;
        }

        // ---- 表情包斗图：开关 / 模式 / 立刻来一张 / 表情库诊断 ----
        // 放在看图分支之前，避免「看看表情包」被误判成分析图片
        BOOL stickerCmd = InsHasWord(payload, @"斗图") || InsHasWord(payload, @"表情包") ||
                          InsHasWord(payload, @"来一张") || InsHasWord(payload, @"发个表情") ||
                          InsHasWord(lower, @"battle") || InsHasWord(lower, @"sticker");
        // 「看下他发的表情包」「识别一下表情包」是看图，不是斗图命令，让给视觉分支
        BOOL stickerQuestion = (InsHasWord(payload, @"看") || InsHasWord(payload, @"分析") ||
                                InsHasWord(payload, @"识别") || InsHasWord(payload, @"总结") ||
                                InsHasWord(payload, @"啥") || InsHasWord(payload, @"什么")) &&
                               !InsHasWord(payload, @"斗图");
        if (stickerCmd && !stickerQuestion) {
            BOOL hasOpen = InsHasWord(payload, @"开");
            BOOL hasClose = InsHasWord(payload, @"关") || InsHasWord(payload, @"停") ||
                            InsHasWord(payload, @"别") || InsHasWord(payload, @"不要");
            // 「开关」「关闭斗图」这类词要分清；同时含开和关时按状态查询处理
            BOOL wantOff = (hasClose && !hasOpen) || InsHasWord(lower, @"off") ||
                           InsHasWord(lower, @"disable");
            BOOL wantOn = (hasOpen && !hasClose) || InsHasWord(lower, @"enable") ||
                          [lower isEqualToString:@"on"] || InsHasWord(lower, @" on");
            NSString *modeWord = nil;
            if (InsHasWord(payload, @"面板") || InsHasWord(lower, @"board")) modeWord = @"board";
            else if (InsHasWord(payload, @"图片") || InsHasWord(payload, @"相册") ||
                     InsHasWord(lower, @"image")) modeWord = @"image";
            else if (InsHasWord(payload, @"自动") || InsHasWord(lower, @"auto")) modeWord = @"auto";
            BOOL wantRefresh = InsHasWord(payload, @"刷新") || InsHasWord(payload, @"重建") ||
                               InsHasWord(lower, @"refresh");
            BOOL wantSend = InsHasWord(payload, @"来一张") || InsHasWord(payload, @"发一张") ||
                            InsHasWord(payload, @"回一张") || InsHasWord(payload, @"发个表情") ||
                            InsHasWord(payload, @"测试") || InsHasWord(lower, @"now");

            if (wantOff) {
                [InsSticker setEnabled:NO];
                InsReply(talker, [NSString stringWithFormat:
                    @"表情包斗图已关闭。对方再发表情包不会自动回；发「%@ 斗图开」可重新打开。", cfg.trigger]);
                return;
            }
            if (wantOn) {
                [InsSticker setEnabled:YES];
                InsReply(talker, [NSString stringWithFormat:
                    @"表情包斗图已打开：对方发来表情包时，自动从我的已有表情包里回一张。\n"
                    @"同一会话间隔 %ld 秒、每分钟最多 %ld 张，避免刷屏。\n%@\n"
                    @"发「%@ 斗图关」关闭，「%@ 来一张」立刻试一张。",
                    (long)(cfg.stickerBattleCooldown > 0 ? cfg.stickerBattleCooldown : 8),
                    (long)(cfg.stickerBattleMaxPerMinute > 0 ? cfg.stickerBattleMaxPerMinute : 4),
                    [InsSticker debugInfo], cfg.trigger, cfg.trigger]);
                return;
            }
            if (modeWord.length) {
                [InsSticker setMode:modeWord];
                InsReply(talker, [NSString stringWithFormat:
                    @"斗图发送方式已设为「%@」：%@\n%@",
                    modeWord,
                    [modeWord isEqualToString:@"board"] ? @"只走微信表情面板（真正的表情消息）"
                    : ([modeWord isEqualToString:@"image"] ? @"只从表情库里挑图片发（图片消息，会进相册）"
                                                           : @"优先表情面板，打不开再用表情库图片兜底"),
                    [InsSticker debugInfo]]);
                return;
            }
            if (wantRefresh || (!wantSend && InsHasWord(payload, @"表情包") && !InsHasWord(payload, @"斗图"))) {
                NSUInteger n = [InsSticker refreshLibrary];
                InsReply(talker, [NSString stringWithFormat:
                    @"表情库已重新扫描，本地可用图片 %lu 张。\n%@\n"
                    @"也可以把自己喜欢的图片放到 Insomnia/stickers/ 目录，重启微信后会被收进库里。",
                    (unsigned long)n, [InsSticker debugInfo]]);
                return;
            }
            if (wantSend) {
                [InsSticker sendOneTo:talker reply:^(NSString *result) {
                    InsReply(talker, result);
                }];
                return;
            }
            InsReply(talker, [NSString stringWithFormat:
                @"%@\n\n用法：\n"
                @"%@ 斗图开 / 斗图关 开关自动斗图\n"
                @"%@ 来一张 立刻回一张试试\n"
                @"%@ 斗图 面板 / 图片 / 自动 切换发送方式\n"
                @"%@ 表情包 刷新 重新扫描我的表情包\n"
                @"开关打开后，对方发来表情包会自动回一张；我发的表情不会触发。",
                [InsSticker debugInfo], cfg.trigger, cfg.trigger, cfg.trigger, cfg.trigger]);
            return;
        }

        // 叙述里怎么称呼账号主人：默认「你」，也可以填对方平时对自己的叫法
        if ([lower hasPrefix:@"叫我"] || [lower hasPrefix:@"称呼"]) {
            NSString *alias = nil;
            if ([payload hasPrefix:@"叫我"]) alias = [payload substringFromIndex:2];
            else if ([payload hasPrefix:@"称呼我"]) alias = [payload substringFromIndex:3];
            else if ([payload hasPrefix:@"称呼"]) alias = [payload substringFromIndex:2];
            alias = [alias stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!alias.length || [alias isEqualToString:@"你"] || [alias isEqualToString:@"默认"]
                || [alias isEqualToString:@"清空"]) alias = @"";
            if (alias.length > 12) alias = [alias substringToIndex:12];
            [cfg setSelfAliasPersisted:alias];
            InsReply(talker, [NSString stringWithFormat:
                @"好。以后叙述里把你称作「%@」，把对方称作「%@」；一律第三人称，不会再用「我」代指聊天里的任何一方。\n"
                @"发「%@ 重述」可以把旧摘要也改成这个口径。",
                [InsMemory selfLabel], [InsMemory partnerLabelForTalker:talker], cfg.trigger]);
            return;
        }

        // 旧摘要（「两人聊天…」）按新称谓重写，不重跑十几万条历史
        if ([lower hasPrefix:@"重述"] || [lower hasPrefix:@"resummary"] || [lower hasPrefix:@"重写摘要"]) {
            InsReply(talker, @"我按新称谓口径把这份记忆重写一遍…");
            [InsMemory rewriteSummaryForTalker:talker completion:^(NSString *text, NSError *err) {
                InsReply(talker, err ? [NSString stringWithFormat:@"重述失败：%@", err.localizedDescription]
                                     : [NSString stringWithFormat:@"摘要已按新口径重写：\n%@", text]);
            }];
            return;
        }

        if ([lower hasPrefix:@"mem"]) {
            NSString *block = [InsMemory contextBlockForTalker:talker];
            InsReply(talker, block.length ? block : @"本会话还没有记忆，先执行 sync 或继续聊天。");
            return;
        }
        if ([lower hasPrefix:@"reset"]) {
            [InsMemory reset:talker];
            InsReply(talker, @"已清空本会话记忆。");
            return;
        }
        // 同步档位：历史量大时插件会自动切「并发抽要点」的回填模式，这里只调并发路数
        if (InsCmdIs(lower, @"同步速度") || InsCmdIs(lower, @"并发")) {
            NSString *word = InsCmdIs(lower, @"并发") ? @"并发" : @"同步速度";
            NSString *arg = InsArgAfter(payload, word);
            NSInteger n = [arg integerValue];
            if (n <= 0) {
                InsReply(talker, [NSString stringWithFormat:
                    @"当前 %ld 路并发、每段 %ld 条；历史超过 %ld 条自动走回填模式（抽要点 + 合并）。\n"
                    @"发「%@ 同步速度 4」可调到 4 路（1~4，默认 3）。",
                    (long)cfg.syncConcurrency, (long)cfg.syncChunkSize, (long)cfg.syncBulkThreshold, cfg.trigger]);
                return;
            }
            n = MAX(1, MIN(4, n));
            [cfg setConfigKeysPersisted:@{@"syncConcurrency": @(n)}];
            cfg.syncConcurrency = n;
            InsReply(talker, [NSString stringWithFormat:@"已改成 %ld 路并发（下次 sync 生效）。", (long)n]);
            return;
        }
        if ([lower hasPrefix:@"sync"]) {
            if (!cfg.apiKey.length) {
                // 没 Key 直接说清楚，别等 LLM 回 401 让用户以为网络/模型坏了
                InsReply(talker, [NSString stringWithFormat:
                    @"聊天 Key 未配置，同步会直接失败。先发 %@ setup <恢复串>（或 %@ key <sk-...>），再发 status 确认。",
                    cfg.trigger, cfg.trigger]);
                return;
            }
            if ([InsMemory isSyncing:talker]) {
                InsReply(talker, @"该会话正在同步中。");
                return;
            }
            InsReply(talker, @"开始同步本会话历史，完成后会通知你。");
            // 同步要用会话本身的名字（群名/对方备注），而不是最后发言人的名字
            NSString *sessionName = [InsSend displayNameForTalker:talker] ?: displayName;
            [InsMemory syncTalker:talker name:sessionName
                         progress:^(NSString *line) { InsNote(line); }
                       completion:^(NSString *result, NSError *error) {
                InsReply(talker, error ? [NSString stringWithFormat:@"同步中断：%@", error.localizedDescription] : result);
            }];
            return;
        }

        if ([lower hasPrefix:@"diag"]) {
            [InsSend diagnoseForTalker:talker completion:^(NSString *report) {
                InsNote([NSString stringWithFormat:@"诊断 %@:\n%@", talker, report]);
                InsReply(talker, report);
            }];
            return;
        }

        if ([lower hasPrefix:@"imgcheck"]) {
            InsReply(talker, [InsGen available] ? @"MCP 通道正常，可以生图。" : @"MCP 通道不通，检查 iproxy/守护进程是否在跑。");
            return;
        }

        // 方向体检：历史回填最容易错的就是「谁说的」，这里把原始 Des 和最终标签一起摊开
        if (InsCmdIs(lower, @"方向") || InsCmdIs(lower, @"方向检查")) {
            NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
            fmt.dateFormat = @"MM-dd HH:mm";
            NSMutableString *out = [NSMutableString stringWithFormat:
                @"Des 校准：Des=%ld 表示账号主人发出\n本会话%@单向账号（文件传输助手/微信团队这类）\n",
                (long)[InsHistory meDesValue],
                [InsHistory isOneWayAccount:talker] ? @"属于" : @"不是"];
            NSArray *rows = [InsHistory latestTextMessagesForTalker:talker count:6];
            [out appendString:@"最近 6 条（时间 des 标注 内容）：\n"];
            for (NSDictionary *row in [rows reverseObjectEnumerator]) {
                NSString *text = [row[@"text"] isKindOfClass:[NSString class]] ? row[@"text"] : @"";
                BOOL me = [row[@"me"] boolValue];
                [out appendFormat:@"%@ des=%@ %@：%@\n",
                    [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:[row[@"t"] unsignedIntValue]]],
                    row[@"des"] ?: @"?",
                    me ? [InsMemory selfLabel] : [InsMemory partnerLabelForTalker:talker],
                    [text substringToIndex:MIN(text.length, 16)]];
            }
            InsReply(talker, out);
            return;
        }

        // 兜底安装：清单地址被清掉、自更新链路整个断掉时，一条命令把新包装回去
        if (InsCmdIs(lower, @"装") || InsCmdIs(lower, @"安装") || InsCmdIs(lower, @"install")) {
            NSUInteger wl = InsCmdIs(lower, @"装") ? 1 : (InsCmdIs(lower, @"安装") ? 2 : 7);
            NSString *arg = InsArgAfter(payload, [payload substringToIndex:MIN(wl, payload.length)]);
            if (!arg.length || [arg isEqualToString:@"最新"]) {
                InsReply(talker, [NSString stringWithFormat:
                    @"用法：%@ 装 <deb 直链>\n例：%@ 装 https://github.com/coderXueZeng/insomnia-update/releases/download/v58/insomnia.deb",
                    cfg.trigger, cfg.trigger]);
                return;
            }
            [InsUpdate installFromURL:arg
                             progress:^(NSString *line) { InsReply(talker, line); }
                           completion:^(NSString *result, NSError *error) {
                InsReply(talker, error ? [@"安装失败：" stringByAppendingString:error.localizedDescription] : result);
            }];
            return;
        }

        if ([lower hasPrefix:@"update"]) {
            [InsUpdate runWithProgress:^(NSString *line) { InsReply(talker, line); }
                            completion:^(NSString *result, NSError *error) {
                InsReply(talker, error ? [@"更新失败：" stringByAppendingString:error.localizedDescription] : result);
            }];
            return;
        }

        // 人不在电脑旁边时：这两个命令把手机沙箱里的日志/上下文取出来，
        // 长按需复制的那条消息粘贴到 WorkBuddy 对话即可，不依赖数据线和 Mac。
        if (InsCmdIs(lower, @"log")) {
            NSString *arg = [[payload substringFromIndex:3]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSInteger n = [arg integerValue];
            if (n <= 0) n = 25;
            if (n > 80) n = 80;
            NSString *tail = InsScrub(InsTailLines(n));
            InsReply(talker, [NSString stringWithFormat:
                @"最近 %ld 行日志（已脱敏，长按复制可发给 WorkBuddy）：\n%@",
                (long)n, tail.length ? tail : @"(日志为空)"]);
            return;
        }

        if (InsCmdIs(lower, @"wb")) {
            NSString *question = [[payload substringFromIndex:2]
                                  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            InsConfig *c = [InsConfig shared];
            NSString *stamp = [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                             dateStyle:NSDateFormatterShortStyle
                                                             timeStyle:NSDateFormatterMediumStyle];
            NSString *tail = InsScrub(InsTailLines(35));
            NSString *block = [NSString stringWithFormat:
                @"我在手机上，电脑不在身边，请帮我排查 Insomnia 插件。\n"
                @"项目：/Users/xuezeng/Documents/Qoder/2026-10-29/73ff2e4b\n"
                @"仓库：coderXueZeng/insomnia-update\n"
                @"===== 交接包 =====\n"
                @"时间：%@\n"
                @"插件版本：%@\n"
                @"更新清单：%@\n"
                @"配置：聊天 Key %@ / 视觉 Key %@ / updateManifest %@ / sudoPassword %@\n"
                @"%@\n"
                @"%@\n"
                @"%@\n"
                @"斗图：%@（模式 %@，表情库 %lu 张）\n"
                @"叙述口径：账号主人=%@ / 对方=%@\n"
                @"我的问题：%@\n"
                @"----- 配置体检 -----\n%@\n"
                @"----- 最近日志（已脱敏）-----\n%@\n"
                @"===== 长按复制以上全部内容，粘贴到 WorkBuddy 对话 =====",
                stamp,
                InsLocalVersion(),
                c.updateManifest.length ? c.updateManifest : @"未配置",
                c.apiKey.length ? @"有" : @"无",
                c.visionApiKey.length ? @"有" : @"无",
                c.updateManifest.length ? @"有" : @"无",
                c.sudoPassword.length ? @"有" : @"无",
                [InsProgress statusLine],
                [InsOutbox statusLine],
                [InsAutoLink statusLine],
                [InsSticker battleEnabled] ? @"开" : @"关", [InsSticker battleMode],
                (unsigned long)[InsSticker library].count,
                [InsMemory selfLabel], [InsMemory partnerLabelForTalker:talker],
                question.length ? question : @"(没写问题，请帮我看日志有没有异常)",
                [InsConfig diagnostics],
                tail.length ? tail : @"(日志为空)"];
            InsReply(talker, block);
            return;
        }

        // 列出本会话最近记到的链接，配合「看第N条链接」挑一条
        if (InsCmdIs(lower, @"links")) {
            NSArray *items = [InsMedia linksForTalker:talker];
            if (!items.count) {
                InsReply(talker, @"这个会话还没记到链接，先发/收一条链接卡片。");
                return;
            }
            NSMutableString *list = [NSMutableString stringWithString:@"本会话最近的链接（1 = 最新）：\n"];
            NSInteger n = 1;
            for (NSDictionary *m in items) {
                NSDictionary *li = [InsMedia linkInfoFor:m];
                NSString *title = [li[@"title"] length] ? li[@"title"] : @"(无标题)";
                if (title.length > 40) title = [title substringToIndex:40];
                [list appendFormat:@"%ld. %@\n   %@\n", (long)n++, title, li[@"url"]];
            }
            [list appendFormat:@"发「%1$@ 看第2条链接」指定某条；也可以引用那条链接消息再 %1$@。", cfg.trigger];
            InsReply(talker, list);
            return;
        }

        // 回显最近记到的链接，便于确认抓的是哪个地址、或复制给 WorkBuddy 代抓
        if (InsCmdIs(lower, @"link")) {
            NSDictionary *m = [InsMedia lastForTalker:talker kind:@"link"];
            if (!m) {
                InsReply(talker, @"这个会话最近没记到链接，先发一条链接消息再来查。");
                return;
            }
            NSDictionary *i = [InsMedia linkInfoFor:m];
            InsReply(talker, [NSString stringWithFormat:
                @"最近一条链接：\n标题：%@\n摘要：%@\nURL：%@\n（长按复制 URL 可发给 WorkBuddy 代抓）",
                i[@"title"], i[@"des"], i[@"url"]]);
            return;
        }

        // 自动看链接：点进会话就分析对方发来的链接，结果按模式静默/转发/回复
        NSString *autoLinkWord = [lower hasPrefix:@"自动看链接"] ? @"自动看链接"
            : ([lower hasPrefix:@"autolink"] ? @"autolink"
               : (InsCmdIs(lower, @"自动看") ? @"自动看" : nil));
        if (autoLinkWord.length) {
            NSString *word = autoLinkWord;
            NSString *arg = [[InsArgAfter(payload, [payload substringToIndex:MIN(word.length, payload.length)])
                              lowercaseString]
                             stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!arg.length) {
                InsReply(talker, [NSString stringWithFormat:@"%@\n用法：%@ 自动看链接 开 / 关 / 静默 / 转发 / 回复 / 收链接即看 / 关收链接\n"
                    @"静默＝只存本地（%@ 链接摘要 看）；转发＝发到文件传输助手；回复＝直接回在当前会话。",
                    [InsAutoLink statusLine], cfg.trigger, cfg.trigger]);
                return;
            }
            if ([arg hasPrefix:@"收链接"] || [arg hasPrefix:@"来就"] || [arg hasPrefix:@"receive"]) {
                BOOL on = ![arg containsString:@"关"];
                [InsAutoLink setAnalyzeOnReceive:on];
                InsReply(talker, [NSString stringWithFormat:@"收到链接就自动看：%@。", on ? @"开" : @"关"]);
                return;
            }
            if ([arg containsString:@"关"] || [arg isEqualToString:@"off"]) {
                [InsAutoLink setEnabled:NO];
                InsReply(talker, @"已关闭自动看链接。手动看还是发「看链接」或引用那条链接再叫我。");
                return;
            }
            if ([arg containsString:@"开"] || [arg isEqualToString:@"on"]) {
                [InsAutoLink setEnabled:YES];
                InsReply(talker, [NSString stringWithFormat:@"已开启自动看链接：点进对方会话就会看最近没看过的链接（每次最多 %ld 条）。\n%@",
                                  (long)cfg.autoLinkMaxPerOpen, [InsAutoLink statusLine]]);
                return;
            }
            if ([arg hasPrefix:@"静默"] || [arg hasPrefix:@"quiet"]) {
                [InsAutoLink setMode:@"quiet"];
                InsReply(talker, @"模式已改为静默：只在后台存摘要，用「链接摘要」查。");
                return;
            }
            if ([arg hasPrefix:@"转发"] || [arg hasPrefix:@"forward"] || [arg hasPrefix:@"文件"]) {
                [InsAutoLink setMode:@"forward"];
                InsReply(talker, @"模式已改为转发：分析完把摘要发到文件传输助手，聊天里不会多出消息。");
                return;
            }
            if ([arg hasPrefix:@"回复"] || [arg hasPrefix:@"reply"]) {
                [InsAutoLink setMode:@"reply"];
                InsReply(talker, @"模式已改为回复：分析完直接在当前会话回一条摘要（注意对方也看得到）。");
                return;
            }
            InsReply(talker, @"没听懂这个参数。可用：开 / 关 / 静默 / 转发 / 回复 / 收链接即看 / 关收链接。");
            return;
        }

        // 看自动分析出来的摘要；默认列本会话，带「全部」列所有会话
        if (InsCmdIs(lower, @"链接摘要") || InsCmdIs(lower, @"看过的链接") || InsCmdIs(lower, @"摘要列表")) {
            BOOL all = [lower containsString:@"全部"] || [lower containsString:@"all"];
            NSString *list = [InsAutoLink digestListForTalker:all ? @"" : talker limit:5];
            NSUInteger pending = [InsAutoLink pendingCountForTalker:talker];
            NSString *tail = pending
                ? [NSString stringWithFormat:@"\n本会话还有 %lu 条链接没看过，发「%@ 自动看链接 开」或直接等一下我来分析。",
                   (unsigned long)pending, cfg.trigger]
                : @"";
            InsReply(talker, [list stringByAppendingString:tail]);
            return;
        }

        // 列出本会话最近记到的合并转发聊天记录
        if (InsCmdIs(lower, @"records")) {
            NSArray *items = [InsMedia recordsForTalker:talker];
            if (!items.count) {
                InsReply(talker, @"这个会话还没记到合并转发的聊天记录。收到「聊天记录」卡片后我就会记下来。");
                return;
            }
            NSMutableString *list = [NSMutableString stringWithString:@"本会话最近的聊天记录（1 = 最新）：\n"];
            NSInteger n = 1;
            for (NSDictionary *m in items) {
                NSString *text = [InsMedia chatRecordTextFrom:m[@"xml"]] ?: @"";
                NSString *title = [InsMedia linkInfoFor:m][@"title"] ?: @"";
                if (title.length > 36) title = [title substringToIndex:36];
                NSInteger lines = [text componentsSeparatedByString:@"\n"].count - 1;
                [list appendFormat:@"%ld. %@（%ld 条）\n", (long)n++,
                 title.length ? title : @"(无标题)", (long)lines];
            }
            [list appendFormat:@"发「%1$@ 看第2条聊天记录」指定某份；也可以引用那条记录再 %1$@。", cfg.trigger];
            InsReply(talker, list);
            return;
        }

        // 引用的是文件（.txt/.md/.json/.csv 这类）：先把正文读出来再回答。
        // 以前这里整条 XML 被当成「被引用的原话」喂给模型，模型只能回「没看到内容」——
        // 林健 15:14 引用 qq 文件问「分析一下具体内容」得到的就是这么一句空话。
        if (fileOverride.count) {
            NSString *fname = fileOverride[@"name"] ?: @"文件";
            NSString *why = nil;
            NSString *body = [InsMedia fileTextFor:fileOverride talker:talker reason:&why];
            if (!body.length) {
                InsNote([NSString stringWithFormat:@"读文件失败：%@（%@）", fname, why ?: @"未知"]);
                InsReply(talker, [NSString stringWithFormat:@"「%@」我打不开：%@", fname, why ?: @"内容读不出来"]);
                return;
            }
            NSString *lead = payload.length ? payload : @"说说这份文件讲了什么，用简短口语讲重点";
            InsNote([NSString stringWithFormat:@"读文件：%@ %lu 字，问「%@」", fname,
                     (unsigned long)body.length, lead]);
            InsReply(talker, [NSString stringWithFormat:@"我读一下「%@」（%lu 字）…", fname,
                              (unsigned long)body.length]);
            NSError *fileErr = nil;
            NSString *fileSystem = [NSString stringWithFormat:
                @"%@\n\n你正在替微信账号主人读一份对方发来的文件，文件名是「%@」。"
                @"只依据文件内容回答，不要臆测文件名之外的东西；读不懂或内容不全就直说。"
                @"用简短口语化中文，别写成报告体。",
                [InsMemory roleRulesForTalker:talker], fname];
            NSString *answer = [InsLLM askSystem:fileSystem
                user:[NSString stringWithFormat:@"%@\n\n以下是文件全文：\n%@", lead, body]
                error:&fileErr];
            InsReply(talker, answer.length
                ? [NSString stringWithFormat:@"[读了「%@」]\n%@", fname, answer]
                : [NSString stringWithFormat:@"分析失败：%@", fileErr.localizedDescription]);
            return;
        }

        // 别人合并转发的聊天记录：引用那条消息、说「看下聊天记录」，或指定第 N 份都能读
        if (InsWantsRecord(payload) || recordOverride.length) {
            NSString *recordText = recordOverride.length ? recordOverride : nil;
            NSString *from = recordOverride.length ? @"你引用的那条消息" : @"本会话最近一份聊天记录";
            if (!recordText.length) {
                NSArray *items = [InsMedia recordsForTalker:talker];
                NSInteger idx = InsRecordIndex(payload);
                NSDictionary *item = (idx >= 0 && idx < (NSInteger)items.count)
                    ? items[idx] : items.firstObject;
                if ([item isKindOfClass:[NSDictionary class]]) {
                    recordText = [InsMedia chatRecordTextFrom:item[@"xml"]];
                    if (idx > 0 && idx < (NSInteger)items.count) {
                        from = [NSString stringWithFormat:@"本会话第 %ld 份聊天记录", (long)idx + 1];
                    }
                }
            }
            if (!recordText.length) {
                InsReply(talker, @"这个会话里没记到合并转发的聊天记录。先让对方发一份「聊天记录」卡片，"
                                @"或者长按引用那条记录再问我。");
                return;
            }
            NSInteger lines = [recordText componentsSeparatedByString:@"\n"].count - 1;
            InsNote([NSString stringWithFormat:@"看聊天记录：%ld 条，来自%@", (long)lines, from]);
            InsReply(talker, [NSString stringWithFormat:@"我看看%@（%ld 条）…", from, (long)lines]);
            NSString *lead = payload.length ? payload : @"总结这份聊天记录讲了什么，简短口语化，点出关键结论";
            NSError *recErr = nil;
            NSString *recSystem = [NSString stringWithFormat:
                @"%@\n\n你正在替微信账号主人阅读别人合并转发过来的聊天记录，用第三人称叙述。"
                @"只依据给出的记录回答，不要臆测、不要编造没出现的人名/时间/事件；"
                @"记录里没有就直说没看到。用简短口语化中文。",
                [InsMemory roleRulesForTalker:talker]];
            NSString *answer = [InsLLM askSystem:recSystem
                user:[NSString stringWithFormat:@"%@\n\n以下是聊天记录（每行开头是发言人）：\n%@", lead, recordText]
                error:&recErr];
            InsReply(talker, answer.length
                ? [NSString stringWithFormat:@"[读了 %ld 条转发记录]\n%@", (long)lines, answer]
                : [NSString stringWithFormat:@"分析失败：%@", recErr.localizedDescription]);
            return;
        }

        // 定时提醒：到点自动在本会话发提醒（微信被杀掉则提醒失效）
        NSTimeInterval reminderDelay = 0;
        NSString *reminderContent = nil;
        NSString *reminderWhen = nil;
        if (InsReminderParse(payload, &reminderDelay, &reminderContent, &reminderWhen)) {
            // 「吃饭去」这类已经带「去」的别再拼成「去吃饭去」
            NSString *fire = reminderContent.length
                ? (([reminderContent hasPrefix:@"去"] || [reminderContent hasSuffix:@"去"])
                   ? reminderContent : [@"去" stringByAppendingString:reminderContent])
                : @"时间到了";
            InsReply(talker, [NSString stringWithFormat:@"好，%@提醒你：%@。", reminderWhen, fire]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(reminderDelay * NSEC_PER_SEC)), gFast, ^{
                InsReply(talker, fire);
            });
            return;
        }

        // 看图/看链接：用视觉模型分析该会话最近一条图片/链接
        NSString *visionKind = nil;
        NSString *visionQuestion = nil;
        for (NSString *word in cfg.visionImageWords) {
            if ([payload hasPrefix:word]) {
                visionKind = @"image";
                visionQuestion = [[payload substringFromIndex:word.length]
                                  stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                break;
            }
        }
        if (!visionKind) {
            for (NSString *word in cfg.visionLinkWords) {
                if ([payload hasPrefix:word]) {
                    visionKind = @"link";
                    visionQuestion = [[payload substringFromIndex:word.length]
                                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    break;
                }
            }
        }
        // 「看下他发的链接」「看看链接」「这个链接讲了啥」等口语说法，配置里没列全也能识别
        if (!visionKind && (InsWantsLink(payload) || InsWantsScreenOpen(payload) || linkOverride.count)) {
            visionKind = @"link";
            visionQuestion = payload.length ? payload : @"总结这个链接讲了什么";
        }
        // 直接把网址贴在命令里
        if (!visionKind && [InsMedia linkInfoFromText:payload].count) {
            visionKind = @"link";
            visionQuestion = payload;
        }
        // 「看下这张图」「看看他发的图」等口语说法；引用图片时只发触发词也直接看图
        if (!visionKind && (InsWantsImage(payload, cfg) || imageOverride.count)) {
            visionKind = @"image";
            visionQuestion = payload;
        }
        if (visionKind) {
            BOOL isImage = [visionKind isEqual:@"image"];
            NSError *visionError = nil;
            NSString *answer = nil;
            if (isImage) {
                NSMutableArray<NSData *> *pics = [NSMutableArray array];
                NSInteger want = InsImageCount(payload);
                // 先看被引用消息里有没有可直接用的图，拿不到再回落到本会话最近记下的那几张
                if (imageOverride.count) {
                    NSDictionary *ov = imageOverride;
                    NSData *one = nil;
                    // ① svrid → MesLocalID：引用图的正解，图片在磁盘上就叫 <MesLocalID>.pic
                    NSString *svr = [ov[@"svrid"] isKindOfClass:[NSString class]] ? ov[@"svrid"] : @"";
                    NSUInteger lid = 0;
                    if (svr.length) {
                        lid = [InsHistory localIDForSvrID:svr talker:talker];
                        InsNote([NSString stringWithFormat:@"看图：引用 svrid=%@ → localID=%lu",
                                 svr, (unsigned long)lid]);
                    }
                    if (lid) {
                        one = [InsMedia imageDataFor:@{ @"xml": ov[@"xml"] ?: @"",
                                                        @"localID": @(lid),
                                                        @"time": ov[@"time"] ?: @0 }
                                            talker:talker error:&visionError];
                    }
                    // ② 原样再试一次（xml 里的 CDN 直链、或历史版本留下的 localID 恰好是对的）
                    if (!one.length) one = [InsMedia imageDataFor:ov talker:talker error:&visionError];
                    // ③ 按 xml 认亲：这张图如果是刚收到的，本会话最近图片里有它
                    if (!one.length) {
                        NSString *quotedXML = ov[@"xml"] ?: @"";
                        if (quotedXML.length) {
                            for (NSDictionary *m in [InsMedia imagesForTalker:talker limit:0]) {
                                if (![m[@"xml"] isEqual:quotedXML]) continue;
                                one = [InsMedia imageDataFor:m talker:talker error:&visionError];
                                if (one.length) {
                                    InsNote(@"看图：引用图按 xml 匹配到本会话记录，用本地文件");
                                    break;
                                }
                            }
                        }
                    }
                    if (one.length) {
                        [pics addObject:one];
                        InsNote(@"看图：用引用消息里的图片");
                    } else {
                        // 引用的图取不到就到此为止，绝不悄悄换成会话里别的图——
                        // 那种「答得像模像样但答的是另一张」比直接报错糟糕得多
                        InsNote([NSString stringWithFormat:@"看图：引用图取不到（%@），按失败处理",
                                 visionError.localizedDescription ?: @"未知原因"]);
                        InsReply(talker, [NSString stringWithFormat:
                            @"你引用的那张图我取不到：%@\n"
                            @"（引用的图只能在微信 CDN 上拿，旧图或已清理的会失效。）\n"
                            @"可以直接发一张图再问，或者不带引用说「看下这张图」让我读本会话最近那张。",
                            visionError.localizedDescription ?: @"本地和 CDN 都没拿到"]);
                        return;
                    }
                }
                if (!pics.count) {
                    NSUInteger limit = want > 0 ? (NSUInteger)want : 1;
                    NSArray<NSDictionary *> *recent = [InsMedia imagesForTalker:talker limit:limit];
                    // imagesForTalker 是「新 → 旧」，多图要按发送顺序喂给模型（先发的算第 1 张）
                    NSArray *ordered = recent.count > 1
                        ? [[recent reverseObjectEnumerator] allObjects] : recent;
                    for (NSDictionary *media in ordered) {
                        if (![media isKindOfClass:[NSDictionary class]]) continue;
                        NSError *oneErr = nil;
                        NSData *one = [InsMedia imageDataFor:media talker:talker error:&oneErr];
                        if (one.length) [pics addObject:one];
                        else visionError = oneErr;
                    }
                    if (pics.count) {
                        InsNote([NSString stringWithFormat:@"看图：用本会话最近 %lu 张%@",
                                 (unsigned long)pics.count,
                                 want > 0 ? [NSString stringWithFormat:@"（你说了 %ld 张）", (long)want] : @""]);
                    }
                }
                if (!pics.count) {
                    InsReply(talker, [NSString stringWithFormat:@"图片取不到：%@",
                                      visionError.localizedDescription ?: @"本会话没有可用图片，先收/发一张再让我看"]);
                    return;
                }
                InsReply(talker, pics.count > 1
                        ? [NSString stringWithFormat:@"我看看这 %lu 张图…", (unsigned long)pics.count]
                        : @"我看看这张图…");
                NSString *imgQuestion = visionQuestion.length ? visionQuestion : @"说说这张图里有什么，有意思的地方点出来";
                imgQuestion = [NSString stringWithFormat:
                    @"【称谓】提到微信账号主人用「%@」，提到对方用「%@」；第三人称叙述，不要用「我」代指他们。\n%@",
                    [InsMemory selfLabel], [InsMemory partnerLabelForTalker:talker], imgQuestion];
                answer = [InsLLM askVisionImages:imgQuestion images:pics error:&visionError];
            } else {
                // 链接来源优先级：① 引用消息里那条 ② 命令里直接贴的网址
                // ③ 本会话最近记到的链接（可指定第 N 条） ④ 上方聊天记录里的纯文本网址
                NSDictionary *info = nil;
                NSString *from = @"";
                if (linkOverride.count) {
                    info = linkOverride;
                    from = @"你引用的那条消息";
                }
                if (!info.count) {
                    NSDictionary *inlineLink = [InsMedia linkInfoFromText:payload];
                    if (inlineLink.count) { info = inlineLink; from = @"这条消息里的网址"; }
                }
                if (!info.count) {
                    NSArray *links = [InsMedia linksForTalker:talker];
                    NSInteger idx = InsLinkIndex(payload);
                    if (idx >= 0 && idx < (NSInteger)links.count) {
                        info = [InsMedia linkInfoFor:links[idx]];
                        from = links.count > 1
                            ? [NSString stringWithFormat:@"本会话第 %ld 条链接", (long)idx + 1]
                            : @"本会话最近一条链接";
                    }
                }
                if (!info.count) {
                    for (NSDictionary *row in [[InsHistory latestTextMessagesForTalker:talker count:30] reverseObjectEnumerator]) {
                        NSDictionary *li = [InsMedia linkInfoFromText:row[@"text"]];
                        if (li.count) { info = li; from = @"上方聊天记录里的网址"; break; }
                    }
                }
                if (!info.count || ![info[@"url"] length]) {
                    InsReply(talker, @"这个会话上方没找到链接。发一条链接卡片，或者长按引用那条链接消息再问我。");
                    return;
                }
                NSString *url = info[@"url"] ?: @"";
                BOOL forceScreen = InsWantsScreenOpen(payload);
                InsNote([NSString stringWithFormat:@"看链接：来源=%@ url=%@ 强制屏幕读=%d",
                         from, url, forceScreen]);
                InsReply(talker, forceScreen
                    ? [NSString stringWithFormat:@"我在屏幕上点开%@…", from]
                    : [NSString stringWithFormat:@"我看看%@…", from]);
                NSString *reason = nil;
                NSString *body = forceScreen ? nil : [InsMedia fetchLinkArticle:url reason:&reason];
                BOOL fromScreen = NO;
                if (!body.length) {
                    // 直连抓不到（反爬/JS 渲染），就真的在屏幕上把网页点开读一遍；
                    // 自动兜底有 10 分钟同网址节流，「点开」命令则强制重试。
                    if (!forceScreen) InsReply(talker, @"网页抓不到正文，我试着在屏幕上点开读一遍（手机可能会短暂跳到网页）…");
                    NSString *screenReason = nil;
                    NSString *screen = [InsMedia readLinkOnScreen:url title:info[@"title"]
                                                            force:forceScreen reason:&screenReason];
                    if (screen.length) {
                        body = screen;
                        fromScreen = YES;
                        reason = nil;
                        InsNote([NSString stringWithFormat:@"看链接：屏幕读到 %lu 字", (unsigned long)body.length]);
                    } else {
                        reason = [NSString stringWithFormat:@"%@；屏幕读取：%@",
                                  reason ?: @"网页没返回内容", screenReason ?: @"没成功"];
                    }
                }
                NSString *roleHint = [NSString stringWithFormat:
                    @"【称谓】提到微信账号主人用「%@」，提到对方用「%@」；第三人称叙述，不要用「我」代指他们。\n",
                    [InsMemory selfLabel], [InsMemory partnerLabelForTalker:talker]];
                NSString *lead = visionQuestion.length
                    ? [NSString stringWithFormat:@"%@ 想问：%@。请据此总结这个链接讲了什么，简短口语化",
                       [InsMemory selfLabel], visionQuestion]
                    : @"总结这个链接讲了什么，简短口语化";
                NSString *question = body.length
                    ? [NSString stringWithFormat:
                        @"%@%@\n标题：%@\n摘要：%@\n以下是%@，请只依据这些内容回答，不要臆测：\n%@",
                        roleHint, lead, info[@"title"], info[@"des"],
                        fromScreen ? @"在手机屏幕上读到的文字（OCR 可能有错漏）" : @"从网页抓取到的正文",
                        body]
                    : [NSString stringWithFormat:
                        @"%@%@\n标题：%@\n摘要：%@\n链接：%@\n网页正文读取失败（%@）。"
                        @"请先明确说明「没能读到网页正文，只能根据标题和摘要推测」，"
                        @"再给出简短推测，不要编造文章细节。",
                        roleHint, lead, info[@"title"], info[@"des"], url, reason ?: @"未知原因"];
                answer = [InsLLM askVision:question image:nil error:&visionError];
                // 抓不到就把原因和链接一起回出来，方便长按复制给 WorkBuddy 代抓
                if (!body.length) {
                    NSString *notice = [NSString stringWithFormat:
                        @"[没读到网页正文：%@]\n来自：%@\n链接：%@\n把链接贴给 WorkBuddy 可以代抓。\n\n",
                        reason ?: @"未知原因", from, url];
                    answer = [notice stringByAppendingString:(answer ?: @"")];
                }
            }
            InsReply(talker, answer.length ? answer
                     : [NSString stringWithFormat:@"分析失败：%@", visionError.localizedDescription]);
            return;
        }

        NSString *imagePrompt = InsImagePrompt(payload, cfg);
        if (imagePrompt.length && cfg.imageEnabled) {
            // 两条请求同时驱动 ChatGPT 会互相踩输入框；原子占坑，并发进来也只有一个能拿到生图权
            if ([InsGen isGenerating] ||
                atomic_exchange_explicit(&gImageClaimed, true, memory_order_relaxed)) {
                InsReply(talker, @"正在给上一条请求生图，大约还要 1 分钟，这条我没接，等它忙完再发一次。");
                return;
            }
            // ack 和最后的图都要落在这个会话里，先把界面跳过去
            NSString *chatName = [InsSend displayNameForTalker:talker];
            if (chatName.length && ![InsSend isChatOpen:talker]) {
                if ([InsSend openChatNamed:chatName]) {
                    InsNote([NSString stringWithFormat:@"已跳到「%@」准备生图", chatName]);
                } else {
                    atomic_store_explicit(&gImageClaimed, false, memory_order_relaxed);
                    InsReply(talker, [NSString stringWithFormat:@"找不到会话「%@」，图片没法发出去。", chatName]);
                    return;
                }
            }
            if (cfg.imageAck.length) {
                InsReply(talker, [NSString stringWithFormat:cfg.imageAck, imagePrompt]);
            }
            BOOL continuation = InsImageContinuation(imagePrompt, cfg) && [InsGen lastPrompt].length;
            InsWritePending(imagePrompt, talker, chatName);
            [InsGen generateImage:imagePrompt continuation:continuation completion:^(NSData *image, NSString *devicePath, NSError *error) {
                atomic_store_explicit(&gImageClaimed, false, memory_order_relaxed);
                InsClearPending();
                if (!image.length) {
                    [InsGen stopAlive];
                    InsReply(talker, [NSString stringWithFormat:@"生图失败：%@", error.localizedDescription ?: @"未知错误"]);
                    return;
                }
                [InsSend sendImageData:image toTalker:talker chatName:chatName completion:^(NSString *failure) {
                    [InsGen stopAlive];
                    if (failure) {
                        InsReply(talker, [NSString stringWithFormat:@"图已生成但发送失败：%@", failure]);
                        return;
                    }
                    InsNote([NSString stringWithFormat:@"图片已发到会话，源文件 %@", devicePath]);
                }];
            }];
            return;
        }

        // 语音：Breeze 合成 PCM → 顶替微信录音器的麦克风数据 → 微信自己编码上传成语音条
        if ([InsVoice handlesPayload:payload]) {
            if ([InsVoice handlePayload:payload talker:talker owner:owner
                                  reply:^(NSString *text) {
                                      // 「已发语音（x 秒）：…」只是回执，语音条已经发出去了，
                                      // 再补一条文字会把会话刷成「已发语音…」，像在念原文
                                      if ([text hasPrefix:@"已发语音"]) {
                                          InsNote(text);
                                          // 超长被截断时提一句，别让人以为整段都念了
                                          if ([text rangeOfString:@"没念"].location != NSNotFound) {
                                              InsReply(talker, @"这条太长，超出时长的部分没念。");
                                          }
                                          return;
                                      }
                                      InsReply(talker, text);
                                  }]) {
                return;
            }
        }

        // 微博/抖音/知乎…热榜：直连各家官方接口，取不到就如实说，不让大模型编新闻
        NSString *hotReport = [InsHot reportForPayload:payload];
        if (hotReport.length) {
            InsNote(@"热点命令：已抓到榜单，正在回复");
            InsReply(talker, hotReport);
            return;
        }

        // 「林健说了多少句 你小子」这类问题：记忆里存的是摘要，数不出条数，
        // 必须直接扫本地聊天库。走确定性统计，不交给模型去猜。
        NSString *statReport = [InsStat reportForQuestion:payload talker:talker];
        if (statReport.length) {
            InsReply(talker, statReport);
            return;
        }

        NSString *memoryBlock = [InsMemory contextBlockForTalker:talker];
        NSString *selfLabel = [InsMemory selfLabel];
        NSString *partnerLabel = [InsMemory partnerLabelForTalker:talker];
        NSMutableArray *history = [NSMutableArray array];
        NSUInteger skippedCmds = 0;
        // 「@insomnia xxx」是主人的操作指令，不是聊天内容。混进上下文会出两种错：
        // 同一句话被算成两条（主人漏打 @ 补一次就多一条），以及模型把主人的问话
        // 归到对方头上（实测把「分泌物是啥」说成对方问了两次）。
        NSString *trig = cfg.trigger.length ? cfg.trigger : @"@insomnia";
        NSString *trigBare = [[trig stringByReplacingOccurrencesOfString:@"@" withString:@""]
                              lowercaseString];
        NSDateFormatter *hmFmt = [[NSDateFormatter alloc] init];
        hmFmt.dateFormat = @"HH:mm";
        for (NSDictionary *row in [InsHistory latestTextMessagesForTalker:talker count:cfg.contextMessages]) {
            NSString *text = [row[@"text"] isKindOfClass:[NSString class]] ? row[@"text"] : @"";
            if (!text.length) continue;
            NSString *lowText = [text lowercaseString];
            if ([lowText rangeOfString:trig.lowercaseString].location != NSNotFound) { skippedCmds++; continue; }
            if (trigBare.length && [lowText hasPrefix:trigBare]) { skippedCmds++; continue; }
            uint32_t t = [row[@"t"] unsignedIntValue];
            NSString *when = t ? [hmFmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]] : nil;
            [history addObject:[NSString stringWithFormat:@"%@%@: %@",
                                when.length ? [when stringByAppendingString:@" "] : @"",
                                [InsMemory speakerLabelForMe:[row[@"me"] boolValue] talker:talker speakerName:nil],
                                text]];
        }
        NSMutableString *system = [NSMutableString stringWithString:[InsMemory roleRulesForTalker:talker]];
        // 设备 config.json 里 persona 写死了「你是我的聊天助手」：那个「我」会把模型带偏，这里归一化
        NSString *persona = [(cfg.persona ?: @"") stringByReplacingOccurrencesOfString:@"我的"
                                                                          withString:@"账号主人的"];
        if (persona.length) [system appendFormat:@"\n\n%@", persona];
        [system appendString:@"\n\n你是替微信账号主人回复微信消息的第三方助手，用简短口语化的中文回答，不要说自己是 AI，除非对方明确询问。"];
        [system appendFormat:@"\n回答里提到聊天双方时：账号主人一律叫「%@」，对方一律叫「%@」；叙述他们说过的话用第三人称，不要用「我」代指其中任何一方。",
         selfLabel, partnerLabel];
        [system appendString:@"\n被问到同步进度、记忆覆盖到哪天、某件事的日期时，按记忆里的【同步进度】和带日期的记录直接回答；记忆里没有就说没记到，不要编日期、不要打哈哈。"];
        [system appendFormat:@"\n记录都在账号主人手机的本地聊天库里，禁止回答「我没有对方的台词/视频/文字记录」「没法统计」这类话。"
                              @"问某人说了多少次某个词时，如果上下文里没有【统计】结果，就直说「这个得按原文数，发 %@ 数 <名字> <词>」，不要凭摘要估数字。",
         cfg.trigger];
        if (memoryBlock.length) {
            [system appendString:@"\n\n以下是账号主人与该联系人往来的记忆，请据此保持前后一致：\n"];
            [system appendString:memoryBlock];
        }
        // 问的人可能是别的会话里的联系人（比如在文件传输助手里问「林健说了啥」）：
        // 只带本会话记忆时模型会说「我这边没有这个人的记录」，这里把另一段记忆补上。
        NSString *crossBlock = [InsMemory crossMemoryForQuestion:payload excludeTalker:talker];
        if (crossBlock.length) {
            [system appendString:@"\n\n以下是账号主人与另一个人（另一个会话）的记忆，只在问题确实问到这个人时使用；"
                                  @"不要把两段会话混成同一段对话，也不要把那段的说话人当成当前会话的对方。"];
            [system appendString:crossBlock];
        }
        if (history.count) {
            [system appendString:@"\n\n最近对话（每行是「时间 说话人: 内容」）：\n"];
            [system appendString:[history componentsJoinedByString:@"\n"]];
        }
        InsNote([NSString stringWithFormat:@"上下文：%lu 条对话，剔除 %lu 条指令",
                 (unsigned long)history.count, (unsigned long)skippedCmds]);
        if (quoteNote.length) {
            [system appendFormat:@"\n\n【本次提问引用了哪句】%@", quoteNote];
        }
        [system appendString:@"\n\n【别数次数、别猜动机】判断谁说过什么只认行首的说话人标签，"
                              @"不要统计「谁问了几次」「说了几遍」——同一句话在聊天里出现多次很常见"
                              @"（对方说过，主人又引用它追问一次），不能因此说成某一方重复发问；"
                              @"也不要揣测对方动机（比如「在试探你」「想考你」），对方没明说就别加这种评论。"];
        // 回答要直接被念出来时，模型别给 Markdown，也别复述要求，直接给内容
        if (singOnce) {
            [system appendString:@"\n\n【这条回答会被唱成歌】严格按题目要求的格式输出：第一行「唱法：<风格>」，"
                                  @"其余只给歌词正文——不要段落标记、表情、链接、解释或开场白；"
                                  @"句子要短、口语化、有韵脚，适合传唱。"];
        } else if (voiceOnce || [InsVoice autoEnabled]) {
            [system appendString:@"\n\n【这条回答会被念成语音】只输出要念的正文：不要 Markdown、列表编号、表情、链接、括号注释、英文缩写；"
                                  @"对方让我背诗、讲笑话、说一段时，直接给出完整内容本身，不要复述我的要求，"
                                  @"也不要说「好的，我来背一首」这类开场话。"];
        }
        // 本次这句是谁发的，必须显式告诉模型：user 里传的是裸 payload，不带说话人标签，
        // 而主人标签默认是「你」，模型会把「你」误当成它自己、把提问归给对方
        // （实测：主人发「@insomnia 退下吧」，模型回「姜世谊说了句退下吧」）。
        // 注意此处不要复用 selfLabel（默认是「你」，有歧义），用无歧义的「账号主人本人」。
        // owner=YES 表示是微信账号主人本人发的；否则是会话对方（partnerLabel）。
        NSString *asker = owner ? @"微信账号主人本人" : partnerLabel;
        NSString *otherSide = owner ? partnerLabel : @"微信账号主人本人（称呼规则里的「你」）";
        [system appendFormat:@"\n\n【本次提问是谁说的 · 最高优先级】你收到的这条用户提问，是%@当面说的，"
                              @"不是另一方说的。回答里若要提到这句话的出处，必须归给%@，"
                              @"绝不能写成另一方（尤其不要写成「%@」）说的。",
                              asker, asker, otherSide];
        NSError *error = nil;
        NSString *answer = [InsLLM askSystem:system user:payload error:&error];
        // 文本模型偶尔会替自己解释「我没有绘图能力」，用户会以为插件不会画。
        // 这里补一句引导，真正的出图入口是 imageKeywords（画/生图/出图…）。
        if (answer.length && cfg.imageEnabled) {
            for (NSString *mark in @[@"没有绘图能力", @"没法直接画", @"无法直接画",
                                     @"不能生成图片", @"不能画图", @"不具备绘图", @"无法生成图片"]) {
                if ([answer rangeOfString:mark].location == NSNotFound) continue;
                answer = [answer stringByAppendingString:
                    [NSString stringWithFormat:@"\n\n—— 直接出图请发：%@ 画 <上面的描述>，我会用手机上的 ChatGPT 画完直接发回来。", cfg.trigger]];
                break;
            }
        }
        // 已经翻译成人话的错误（带换行/较长）直接原样回，不再套「调用失败：」
        NSString *failure = error.localizedDescription ?: @"未知错误";
        BOOL explained = [failure rangeOfString:@"\n"].location != NSNotFound || failure.length > 40;
        if (answer.length && singOnce) {
            // 模型自己说这首歌没把握：如实回文字，不硬唱编造的歌词
            if ([answer rangeOfString:@"不认识这首歌"].location != NSNotFound) {
                InsReply(talker, [NSString stringWithFormat:
                    @"这首歌的歌词我没有把握，不硬唱了，免得唱错。%@",
                    [answer stringByReplacingOccurrencesOfString:@"不认识这首歌" withString:@""]]);
                return;
            }
            // 「唱法：<描述>」行 = 这首歌的专属演绎风格，摘出来传给合成指令
            NSString *style = nil;
            NSString *lyrics = [answer stringByTrimmingCharactersInSet:
                                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSRange nl = [lyrics rangeOfString:@"\n"];
            if (nl.location != NSNotFound) {
                NSString *firstLine = [[lyrics substringToIndex:nl.location]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([firstLine hasPrefix:@"唱法"] || [firstLine hasPrefix:@"【唱法"] ||
                    [firstLine hasPrefix:@"（唱法"] || [firstLine hasPrefix:@"(唱法"]) {
                    NSRange colon = [firstLine rangeOfString:@"："].location != NSNotFound
                        ? [firstLine rangeOfString:@"："]
                        : [firstLine rangeOfString:@":"];
                    if (colon.location != NSNotFound && colon.location + 1 < firstLine.length) {
                        style = [[firstLine substringFromIndex:colon.location + 1]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    }
                    lyrics = [[lyrics substringFromIndex:nl.location + 1]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    InsNote([NSString stringWithFormat:@"唱歌：专属唱法「%@」", style ?: @""]);
                }
            }
            if (!lyrics.length) lyrics = answer;
            [InsVoice singLyrics:lyrics instructions:style talker:talker reply:^(NSString *text) {
                // 「已发语音（x 秒）…」只是回执，不打扰会话；失败才回文字
                if ([text hasPrefix:@"已发语音"]) {
                    InsNote(text);
                    return;
                }
                InsReply(talker, text);
            }];
            return;
        }
        if (answer.length && ([InsVoice autoEnabled] || voiceOnce)) {
            [InsVoice sayAnswer:answer talker:talker fallback:^(NSString *text) {
                InsReply(talker, text);
            }];
            return;
        }
        InsReply(talker, answer ?: (explained ? failure
                                             : [NSString stringWithFormat:@"调用失败：%@", failure]));
    });
}

/// 优先使用 config 里配置的发送选择器（"类名 选择器" 形式，签名为 (text, talker)）
static BOOL InsSendVia(NSString *talker, NSString *text) {
    InsConfig *cfg = [InsConfig shared];
    for (NSString *entry in cfg.sendSelectors) {
        NSArray *parts = [entry componentsSeparatedByString:@" "];
        if (parts.count != 2) continue;
        Class cls = NSClassFromString(parts[0]);
        SEL sel = NSSelectorFromString(parts[1]);
        id mgr = InsMessageMgr();
        id target = [cls isEqual:object_getClass(mgr)] ? mgr : [[cls alloc] init];
        if (!target || ![target respondsToSelector:sel]) continue;
        @try {
            NSMethodSignature *sig = [target methodSignatureForSelector:sel];
            if (sig.numberOfArguments != 4) continue;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = target;
            inv.selector = sel;
            [inv setArgument:&text atIndex:2];
            [inv setArgument:&talker atIndex:3];
            [inv invoke];
            InsNote([NSString stringWithFormat:@"通过 %@ 发送成功", entry]);
            return YES;
        } @catch (NSException *e) {
            InsNote([NSString stringWithFormat:@"%@ 发送异常: %@", entry, e.reason]);
        }
    }
    return NO;
}

/// 回退方案：本地插入一条自己发出的文本消息（不经过网络）
static BOOL InsSendLocal(NSString *talker, NSString *text) {
    id mgr = InsMessageMgr();
    Class wrapClass = NSClassFromString(@"CMessageWrap");
    if (!mgr || !wrapClass) return NO;
    SEL insert = NSSelectorFromString(@"AddMsg:MsgWrap:");
    if (![mgr respondsToSelector:insert]) return NO;

    id wrap = [[wrapClass alloc] init];
    @try {
        [wrap setValue:@1 forKey:@"m_uiMessageType"];
        [wrap setValue:InsSelfWxid() forKey:@"m_nsFromUsr"];
        [wrap setValue:talker forKey:@"m_nsToUsr"];
        [wrap setValue:text forKey:@"m_nsContent"];
        [wrap setValue:@((uint32_t)[[NSDate date] timeIntervalSince1970]) forKey:@"m_uiCreateTime"];
        [wrap setValue:@5 forKey:@"m_uiStatus"];
    } @catch (NSException *e) {
        InsNote([NSString stringWithFormat:@"构造消息失败: %@", e.reason]);
        return NO;
    }
    void (*send)(id, SEL, id, id) = (void (*)(id, SEL, id, id))[mgr methodForSelector:insert];
    send(mgr, insert, talker, wrap);
    InsNote([NSString stringWithFormat:@"本地插入回复给 %@", talker]);
    return YES;
}

/// 生图任务落盘：微信进程被杀后重启时靠它把没送完的图继续送完
static NSString *InsPendingPath(void) {
    return [[InsConfig rootDir] stringByAppendingPathComponent:@"pending.json"];
}

static void InsWritePending(NSString *prompt, NSString *talker, NSString *chatName) {
    NSDictionary *dict = @{@"prompt": prompt ?: @"", @"talker": talker ?: @"",
                           @"chatName": chatName ?: @"",
                           @"startedAt": @((long long)[[NSDate date] timeIntervalSince1970])};
    [[NSJSONSerialization dataWithJSONObject:dict options:0 error:nil]
     writeToFile:InsPendingPath() atomically:YES];
}

static NSDictionary *InsReadPending(void) {
    NSData *raw = [NSData dataWithContentsOfFile:InsPendingPath()];
    NSDictionary *dict = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : nil;
    return [dict isKindOfClass:[NSDictionary class]] ? dict : nil;
}

static void InsClearPending(void) {
    [[NSFileManager defaultManager] removeItemAtPath:InsPendingPath() error:nil];
}

/// 启动时检查有没有没送完的生图任务：等图出现后发回原会话，把链路补完
static void InsResumePendingIfAny(void) {
    NSDictionary *pending = InsReadPending();
    if (!pending) return;
    NSString *prompt = pending[@"prompt"];
    NSString *talker = pending[@"talker"];
    NSString *chatName = pending[@"chatName"];
    long long startedAt = [pending[@"startedAt"] longLongValue];
    if (!prompt.length || !talker.length) { InsClearPending(); return; }
    if ((long long)[[NSDate date] timeIntervalSince1970] - startedAt > 20 * 60) {
        InsNote(@"待恢复任务已超过 20 分钟，放弃");
        InsClearPending();
        return;
    }
    InsNote([NSString stringWithFormat:@"恢复生图任务：%@ → %@", prompt, talker]);
    [InsGen resumeImage:prompt since:startedAt completion:^(NSData *image, NSString *devicePath, NSError *error) {
        InsClearPending();
        if (!image.length) {
            [InsGen stopAlive];
            InsReply(talker, [NSString stringWithFormat:@"生图失败：%@", error.localizedDescription ?: @"未知错误"]);
            return;
        }
        [InsSend sendImageData:image toTalker:talker chatName:chatName.length ? chatName : nil
                    completion:^(NSString *failure) {
            [InsGen stopAlive];
            if (failure) {
                InsReply(talker, [NSString stringWithFormat:@"图已生成但发送失败：%@", failure]);
                return;
            }
            InsNote([NSString stringWithFormat:@"恢复任务完成，图片已发到会话，源文件 %@", devicePath]);
        }];
    }];
}

static void InsDumpSignatures(NSString *className, NSString *prefix) {
    Class cls = NSClassFromString(className);
    if (!cls) {
        InsNote([NSString stringWithFormat:@"%@ 不存在", className]);
        return;
    }
    unsigned count = 0;
    Method *methods = class_copyMethodList(object_getClass(cls), &count);
    NSMutableArray *lines = [NSMutableArray array];
    for (unsigned i = 0; i < count; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        if (prefix.length && ![name hasPrefix:prefix]) continue;
        [lines addObject:[NSString stringWithFormat:@"%@ %@", name,
                          [NSString stringWithUTF8String:method_getTypeEncoding(methods[i])]]];
    }
    free(methods);
    InsNote([NSString stringWithFormat:@"%@ 类方法: %@", className, [lines componentsJoinedByString:@" | "]]);
}

/// 「点进聊天」= 聊天界面出现，这是微信里最可靠的进会话信号（点输入框、点会话列表都算）
static void (*InsOrigChatViewDidAppear)(id, SEL, BOOL) = NULL;
static void InsChatViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (InsOrigChatViewDidAppear) InsOrigChatViewDidAppear(self, _cmd, animated);
    // 内部延迟 1.5 秒再取当前会话，避开界面切换过程中的空窗，并在后台队列分析
    [InsAutoLink noteChatOpened];
}

static void InsInstallChatHook(void) {
    Class cls = NSClassFromString(@"BaseMsgContentViewController");
    if (!cls) {
        InsNote(@"自动看链接：没有 BaseMsgContentViewController，进会话触发不可用");
        return;
    }
    SEL sel = @selector(viewDidAppear:);
    if (!class_getInstanceMethod(cls, sel)) {
        InsNote(@"自动看链接：BaseMsgContentViewController 没有 viewDidAppear:，触发不可用");
        return;
    }
    MSHookMessageEx(cls, sel, (IMP)&InsChatViewDidAppear, (IMP *)&InsOrigChatViewDidAppear);
    InsNote(@"自动看链接：已挂上聊天界面出现事件");
}

%ctor {
    @autoreleasepool {
        [InsConfig shared];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            InsNote([NSString stringWithFormat:@"插件已加载，self=%@ model=%@",
                     InsSelfWxid() ?: @"未知", [InsConfig shared].chatModel]);
            InsMessageMgr();
            // 进度汇报是周期性消息：发不出去就丢掉，不能塞满重发队列
            [InsProgress setReplyHandler:^(NSString *t, NSString *text) { InsReplyNoQueue(t, text); }];
            [InsProgress start];      // 默认每 60 分钟把同步进度发到文件传输助手
            [InsVoice installHook];   // 语音条：hook 微信录音器的 PCM 通道
            [InsSticker bootstrap];   // 启动时先扫一次「我的已有表情包」
            [InsAutoLink bootstrap];  // 装载自动链接分析缓存
            InsInstallChatHook();     // 点进聊天 → 自动分析对方发来的链接
            InsDumpSignatures(@"ZstdUtil", @"");
            InsDumpSignatures(@"CMessageMgr", @"GetMsgByCreateTime");
            // 微信被杀重启后，把上次没送完的图接着送完
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                InsResumePendingIfAny();
            });
            // 微信从后台回到前台也检查一次没送完的生图：生图等待线程若被系统冻结，
            // 图生成了也发不出去；用户/系统把微信切回前台时补上这条链路。
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if ([InsGen isGenerating]) return;   // 正在跑的生图任务自己会取图，别重复驱动
                    InsResumePendingIfAny();
                });
            }];
            // 上次没送达的回复（进程被杀/会话没开着）也补发一次
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                InsFlushOutboxIfDue();
            });
        });
    }
}

%hook CMessageMgr

- (void)AsyncOnAddMsgForSession:(id)session MsgWrap:(id)wrap NewMsgArriveNotify:(BOOL)notify {
    %orig;
    InsHandleWrap(wrap, @"AsyncForSession");
}

- (void)AsyncOnAddMsg:(id)arg1 MsgWrap:(id)wrap {
    %orig;
    InsHandleWrap(wrap, @"AsyncOnAddMsg");
}

- (void)AddMsg:(id)arg1 MsgWrap:(id)wrap {
    %orig;
    InsHandleWrap(wrap, @"AddMsg");
}

%end
