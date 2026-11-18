#import "InsRelay.h"
#import "InsConfig.h"
#import "InsStat.h"
#import "InsSend.h"

// 代发（受控转达）
//
//  林健（已授权）在单聊里发：@insomnia 给张鹏发消息说你小子
//  → 校验「林健确实被授权发给张鹏」→ 内容合规检查 → 频控 → 用我的号发给张鹏
//  → 回执告诉林健发没发出去；全程记审计，我随时能查。
//
// 默认不信任任何第三方：没授权就一条都不发；群聊不认；骂人/威胁/要钱/链接一律拒。
// 授权绑定 wxid，对方改备注或换个同名账号都顶不了位。

@interface InsRelay ()
+ (NSString *)auditText;
@end

static NSString *const kInsRelayFile = @"relay.json";
static NSUInteger const kInsRelayMaxAudit = 120;

static NSMutableDictionary *gRelay = nil;
static NSRecursiveLock *gRelayLock = nil;

#pragma mark - 基础设施

static NSString *InsRelayPath(void) {
    return [[InsConfig rootDir] stringByAppendingPathComponent:kInsRelayFile];
}

static NSRecursiveLock *InsRelayMutex(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gRelayLock = [NSRecursiveLock new]; });
    return gRelayLock;
}

static NSString *InsRelayTrim(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSCharacterSet characterSetWithCharactersInString:
               @" \t\n\r\u3000，。、,.:：;；!！?？~～…·\"'“”‘’「」『』【】（）()《》-—→"];
    });
    return [s stringByTrimmingCharactersInSet:set];
}

/// 只留一层「字段读取 + 兜底」，避免 JSON 里某个键类型不对就整份失效
static NSMutableDictionary *InsRelayStore(void) {
    @synchronized (InsRelayMutex()) {
        if (gRelay) return gRelay;
        NSData *raw = [NSData dataWithContentsOfFile:InsRelayPath()];
        NSDictionary *d = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : nil;
        if (![d isKindOfClass:[NSDictionary class]]) d = @{};
        NSMutableDictionary *store = [NSMutableDictionary dictionary];
        store[@"enabled"] = [d[@"enabled"] isKindOfClass:[NSNumber class]] ? d[@"enabled"] : @YES;
        store[@"navigate"] = [d[@"navigate"] isKindOfClass:[NSNumber class]] ? d[@"navigate"] : @YES;
        store[@"sign"] = [d[@"sign"] isKindOfClass:[NSNumber class]] ? d[@"sign"] : @NO;
        store[@"routes"] = [d[@"routes"] isKindOfClass:[NSDictionary class]]
            ? [d[@"routes"] mutableCopy] : [NSMutableDictionary dictionary];
        store[@"audit"] = [d[@"audit"] isKindOfClass:[NSArray class]]
            ? [d[@"audit"] mutableCopy] : [NSMutableArray array];
        store[@"globalStamps"] = [d[@"globalStamps"] isKindOfClass:[NSArray class]]
            ? [d[@"globalStamps"] mutableCopy] : [NSMutableArray array];
        gRelay = store;
        return gRelay;
    }
}

static void InsRelaySave(void) {
    @synchronized (InsRelayMutex()) {
        if (!gRelay) return;
        NSData *data = [NSJSONSerialization dataWithJSONObject:gRelay options:0 error:nil];
        if (data) [data writeToFile:InsRelayPath() atomically:YES];
    }
}

static void InsRelayNote(NSString *line) {
    [InsConfig log:[NSString stringWithFormat:@"代发：%@", line]];
}

static void InsRelayAudit(NSString *from, NSString *to, NSString *text,
                          BOOL ok, NSString *reason) {
    @synchronized (InsRelayMutex()) {
        NSMutableDictionary *store = InsRelayStore();
        NSMutableArray *list = store[@"audit"];
        if (![list isKindOfClass:[NSMutableArray class]]) {
            list = [NSMutableArray array];
            store[@"audit"] = list;
        }
        NSString *brief = text.length > 40 ? [[text substringToIndex:40] stringByAppendingString:@"…"] : text;
        [list insertObject:@{ @"t": @([[NSDate date] timeIntervalSince1970]),
                              @"from": from ?: @"?",
                              @"to": to ?: @"?",
                              @"text": brief ?: @"",
                              @"ok": @(ok),
                              @"reason": reason ?: @"" }
                   atIndex:0];
        while (list.count > kInsRelayMaxAudit) [list removeLastObject];
        InsRelaySave();
    }
    InsRelayNote([NSString stringWithFormat:@"%@ → %@ %@%@",
                  from ?: @"?", to ?: @"?", ok ? @"ok" : @"拒绝",
                  reason.length ? [NSString stringWithFormat:@"（%@）", reason] : @""]);
}

#pragma mark - 名字解析

static NSArray<NSDictionary *> *InsRelayCandidates(NSString *name) {
    NSString *q = InsRelayTrim(name);
    if (!q.length) return @[];
    if ([q hasPrefix:@"wxid_"]) {
        NSString *label = [InsSend displayNameForTalker:q] ?: q;
        return @[@{ @"wxid": q, @"name": label }];
    }
    // 老式微信号（自定义 wxid，如 zhangpeng123）直接按 id 查一次通讯录
    if (q.length >= 6 && [q rangeOfCharacterFromSet:
                          [NSCharacterSet characterSetWithCharactersInString:@"_0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"]].location == 0) {
        NSString *label = [InsSend displayNameForTalker:q];
        if (label.length) return @[@{ @"wxid": q, @"name": label }];
    }
    NSArray *all = [InsStat candidatesForName:q];
    return [all isKindOfClass:[NSArray class]] ? all : @[];
}

/// 唯一命中才算成功。同名多个人时**绝不猜**——发错人的代价比不发大得多。
static NSDictionary *InsRelayResolve(NSString *name) {
    NSString *q = InsRelayTrim(name);
    if (!q.length) return @{ @"error": @"名字是空的" };
    NSArray *all = InsRelayCandidates(q);
    if (!all.count) return @{ @"error": [NSString stringWithFormat:@"没找到「%@」这个人", q] };

    NSMutableArray *exact = [NSMutableArray array];
    for (NSDictionary *c in all) {
        if ([c[@"name"] isEqualToString:q]) [exact addObject:c];
    }
    if (exact.count == 1) return exact.firstObject;
    // 同名好几个人（通讯录里常有已删好友/群成员顶着同名）：
    // ① 之前已经授权过的那个 → ② 和你真有聊天记录的那个
    if (exact.count > 1) {
        NSDictionary *routes = InsRelayStore()[@"routes"];
        NSMutableArray *known = [NSMutableArray array];
        for (NSString *fromWxid in routes) {
            NSDictionary *targets = routes[fromWxid][@"targets"];
            if (![targets isKindOfClass:[NSDictionary class]]) continue;
            for (NSString *t in targets) {
                if (![targets[t][@"name"] isEqualToString:q]) continue;
                for (NSDictionary *c in exact) {
                    if ([c[@"wxid"] isEqualToString:t] && ![known containsObject:c]) [known addObject:c];
                }
            }
        }
        if (known.count == 1) return known.firstObject;
        NSMutableArray *talked = [NSMutableArray array];
        for (NSDictionary *c in exact) {
            if ([c[@"scanned"] unsignedIntegerValue] > 0) [talked addObject:c];
        }
        if (talked.count == 1) return talked.firstObject;
    }
    if (exact.count == 0 && all.count == 1) return all.firstObject;

    NSArray *pool = exact.count > 1 ? exact : all;
    NSMutableArray *labels = [NSMutableArray array];
    for (NSDictionary *c in pool) {
        if (labels.count >= 4) break;
        BOOL talked = [c[@"scanned"] unsignedIntegerValue] > 0;
        [labels addObject:[NSString stringWithFormat:@"%@（%@%@）", c[@"name"], c[@"wxid"],
                           talked ? @"，有聊天记录" : @""]];
    }
    return @{ @"error": [NSString stringWithFormat:@"「%@」对应 %lu 个人，我不猜：%@。请改发 wxid 版本",
                         q, (unsigned long)pool.count, [labels componentsJoinedByString:@"、"]],
              @"ambiguous": @YES };
}

static NSArray<NSString *> *InsRelayTokens(NSString *s) {
    static NSCharacterSet *sep;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sep = [NSCharacterSet characterSetWithCharactersInString:@" \t\n\r\u3000，,、;；→"];
    });
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *t in [s componentsSeparatedByCharactersInSet:sep]) {
        NSString *v = InsRelayTrim(t);
        if (v.length) [out addObject:v];
    }
    return out;
}

#pragma mark - 内容检查

static NSArray<NSString *> *InsRelayList(NSString *key) {
    NSDictionary *map = @{
        @"insult": @[@"傻逼", @"傻b", @"傻B", @"煞笔", @"沙比", @"智障", @"弱智", @"脑残", @"脑瘫", @"贱人",
                     @"婊子", @"杂种", @"畜生", @"王八蛋", @"狗东西", @"狗日", @"尼玛", @"妈逼", @"妈的",
                     @"他妈", @"操你", @"草你", @"草泥马", @"去死", @"死全家", @"滚蛋",
                     @"fuck", @"bitch", @"idiot", @"asshole", @"shit"],
        @"threat": @[@"杀了你", @"弄死你", @"打死你", @"砍死你", @"弄死", @"灭了你", @"报复你", @"砸了你家"],
        @"fraud":  @[@"转账", @"汇款", @"打钱", @"借钱", @"还钱", @"收款码", @"二维码", @"银行卡", @"验证码",
                     @"支付密码", @"身份证", @"网贷", @"贷款", @"刷单", @"返利", @"中奖", @"保证金"],
        @"sexual": @[@"约炮", @"裸照", @"色情", @"开房", @"一夜情", @"裸聊"],
    };
    return map[key] ?: @[];
}

/// 返回 nil 表示通过；否则返回给人看的原因
static NSString *InsRelayVeto(NSString *text, NSString *trigger) {
    if (!text.length) return @"内容是空的";
    if (text.length > 200) return @"太长了（上限 200 字）";

    NSString *low = text.lowercaseString;
    if ([low rangeOfString:@"http"].location != NSNotFound ||
        [low rangeOfString:@"www."].location != NSNotFound ||
        [low rangeOfString:@"t.cn"].location != NSNotFound ||
        [low rangeOfString:@".com/"].location != NSNotFound ||
        [low rangeOfString:@".cn/"].location != NSNotFound ||
        [low rangeOfString:@".net/"].location != NSNotFound) {
        return @"带链接的消息不支持代发";
    }
    if (trigger.length && [low rangeOfString:trigger.lowercaseString].location != NSNotFound) {
        return @"内容里不能带触发词（会被当成指令）";
    }
    if ([low rangeOfString:@"<msg"].location != NSNotFound ||
        [low rangeOfString:@"<?xml"].location != NSNotFound ||
        [low rangeOfString:@"<appmsg"].location != NSNotFound) {
        return @"内容里有类似微信消息结构的字段，拒绝发送";
    }

    NSArray *rules = @[@[@"insult", @"辱骂"], @[@"threat", @"威胁"], @[@"fraud", @"要钱/验证码"], @[@"sexual", @"色情"]];
    for (NSArray *rule in rules) {
        for (NSString *w in InsRelayList(rule[0])) {
            if ([low rangeOfString:w.lowercaseString].location == NSNotFound) continue;
            return [NSString stringWithFormat:@"含「%@」类内容（%@），不支持代发", w, rule[1]];
        }
    }

    // 只剩标点的内容也不发
    NSCharacterSet *keep = [NSCharacterSet alphanumericCharacterSet];
    BOOL hasWord = NO;
    for (NSUInteger i = 0; i < text.length && !hasWord; i++) {
        unichar c = [text characterAtIndex:i];
        // 汉字不在 alphanumeric 里，单独放行
        if ([keep characterIsMember:c] || (c >= 0x4E00 && c <= 0x9FFF)) hasWord = YES;
    }
    if (!hasWord) return @"只有标点/表情，没有实际内容";
    return nil;
}

#pragma mark - 命令解析

static NSDictionary *InsRelayParseSend(NSString *payload) {
    NSString *s = InsRelayTrim(payload);
    if (s.length < 4) return nil;

    for (NSString *lead in @[@"帮我", @"请帮我", @"麻烦你", @"麻烦", @"请"]) {
        if ([s hasPrefix:lead] && s.length > lead.length + 2) {
            s = InsRelayTrim([s substringFromIndex:lead.length]);
            break;
        }
    }

    NSString *rest = nil;
    BOOL tellStyle = NO;
    for (NSString *p in @[@"发给", @"给", @"向", @"跟", @"对", @"告诉", @"转告"]) {
        if (![s hasPrefix:p] || s.length <= p.length + 1) continue;
        rest = InsRelayTrim([s substringFromIndex:p.length]);
        tellStyle = [p isEqualToString:@"告诉"] || [p isEqualToString:@"转告"];
        break;
    }
    if (!rest.length) return nil;

    // 找最早出现的动作词；同位置取更长的（「发消息说」优于「发消息」优于「说」）
    NSArray *seps = @[@"发条消息说", @"发个消息说", @"发消息说", @"发条消息", @"发个消息",
                      @"发消息", @"带句话", @"说"];
    NSUInteger bestIdx = NSNotFound, bestLen = 0;
    for (NSString *sep in seps) {
        NSRange r = [rest rangeOfString:sep];
        if (r.location == NSNotFound) continue;
        if (bestIdx == NSNotFound || r.location < bestIdx ||
            (r.location == bestIdx && sep.length > bestLen)) {
            bestIdx = r.location;
            bestLen = sep.length;
        }
    }

    NSString *name = nil, *text = nil;
    if (bestIdx != NSNotFound) {
        name = InsRelayTrim([rest substringToIndex:bestIdx]);
        text = InsRelayTrim([rest substringFromIndex:bestIdx + bestLen]);
    } else if (tellStyle) {
        NSArray *toks = InsRelayTokens(rest);
        if (toks.count >= 2) {
            name = toks.firstObject;
            NSRange nr = [rest rangeOfString:name];
            text = nr.location == NSNotFound ? @"" : InsRelayTrim([rest substringFromIndex:NSMaxRange(nr)]);
        }
    }
    if (!name.length) return nil;

    // 「给我说说」「给他发消息」这类句子不是命令，别抢答
    NSArray *pronouns = @[@"我", @"你", @"他", @"她", @"它", @"咱", @"自己", @"我们", @"你们", @"他们", @"她们"];
    if ([pronouns containsObject:name]) return nil;
    if (name.length > 20) return nil;

    // 去掉正文前残留的说/冒号
    while (text.length && ([text hasPrefix:@"说"] || [text hasPrefix:@"："] ||
                           [text hasPrefix:@":" ] || [text hasPrefix:@"-"])) {
        text = InsRelayTrim([text substringFromIndex:1]);
    }

    BOOL strong = ([s rangeOfString:@"发消息"].location != NSNotFound) ||
                  ([s rangeOfString:@"发条消息"].location != NSNotFound) ||
                  ([s rangeOfString:@"转告"].location != NSNotFound) ||
                  ([s rangeOfString:@"告诉"].location != NSNotFound);
    return @{ @"name": name, @"text": text ?: @"", @"strong": @(strong) };
}

@implementation InsRelay

+ (BOOL)isRelayPayload:(NSString *)payload {
    NSString *s = InsRelayTrim(payload);
    if (!s.length) return NO;
    for (NSString *p in @[@"授权", @"取消授权", @"撤销授权", @"代发"]) {
        if ([s hasPrefix:p]) return YES;
    }
    return InsRelayParseSend(s) != nil;
}

#pragma mark - 频控

static NSUInteger InsRelayCountWithin(NSArray *stamps, NSTimeInterval now, NSTimeInterval window) {
    NSUInteger n = 0;
    for (NSNumber *v in stamps) {
        if (![v isKindOfClass:[NSNumber class]]) continue;
        if (now - v.doubleValue < window) n++;
    }
    return n;
}

static void InsRelayPruneStamps(NSMutableArray *stamps, NSTimeInterval now) {
    while (stamps.count && now - [stamps.firstObject doubleValue] > 7 * 86400) {
        [stamps removeObjectAtIndex:0];
    }
    while (stamps.count > 200) [stamps removeObjectAtIndex:0];
}

/// 返回 nil 表示放行；否则返回拒绝原因
static NSString *InsRelayQuotaError(NSMutableDictionary *route, NSTimeInterval now) {
    NSMutableArray *stamps = [route[@"stamps"] isKindOfClass:[NSArray class]]
        ? [route[@"stamps"] mutableCopy] : [NSMutableArray array];
    InsRelayPruneStamps(stamps, now);
    route[@"stamps"] = stamps;

    NSUInteger limit = [route[@"limit"] unsignedIntegerValue];
    if (!limit) limit = 5;
    if (InsRelayCountWithin(stamps, now, 3600) >= limit) {
        return [NSString stringWithFormat:@"你这一小时已经发满 %lu 条了，过会儿再来", (unsigned long)limit];
    }
    if (InsRelayCountWithin(stamps, now, 86400) >= 20) {
        return @"你今天的代发额度用完了（每天 20 条）";
    }
    NSTimeInterval last = [route[@"lastAt"] doubleValue];
    if (last > 0 && now - last < 8) {
        return @"发太快了，隔 8 秒再发";
    }
    return nil;
}

static NSString *InsRelayGlobalQuotaError(NSTimeInterval now) {
    NSMutableDictionary *store = InsRelayStore();
    NSMutableArray *stamps = [store[@"globalStamps"] isKindOfClass:[NSArray class]]
        ? [store[@"globalStamps"] mutableCopy] : [NSMutableArray array];
    InsRelayPruneStamps(stamps, now);
    store[@"globalStamps"] = stamps;
    if (InsRelayCountWithin(stamps, now, 3600) >= 20) {
        return @"代发总次数这一小时到上限了（全局 20 条）";
    }
    return nil;
}

static void InsRelayStamp(NSMutableDictionary *route, NSTimeInterval now) {
    NSMutableArray *stamps = [route[@"stamps"] isKindOfClass:[NSArray class]]
        ? [route[@"stamps"] mutableCopy] : [NSMutableArray array];
    [stamps addObject:@(now)];
    route[@"stamps"] = stamps;
    route[@"lastAt"] = @(now);

    NSMutableDictionary *store = InsRelayStore();
    NSMutableArray *global = [store[@"globalStamps"] isKindOfClass:[NSArray class]]
        ? [store[@"globalStamps"] mutableCopy] : [NSMutableArray array];
    [global addObject:@(now)];
    store[@"globalStamps"] = global;
}

#pragma mark - 主入口

+ (BOOL)handlePayload:(NSString *)payload
               talker:(NSString *)talker
           senderName:(NSString *)senderName
                owner:(BOOL)owner
                reply:(void (^)(NSString *text))reply
              deliver:(void (^)(NSString *text, NSString *targetTalker, BOOL allowNavigate,
                                void (^done)(BOOL ok, NSString *how)))deliver {
    if (!reply || !deliver) return NO;
    InsConfig *cfg = [InsConfig shared];
    NSString *trigger = cfg.trigger.length ? cfg.trigger : @"@insomnia";
    NSString *p = InsRelayTrim(payload);
    if ([p hasPrefix:trigger]) p = InsRelayTrim([p substringFromIndex:trigger.length]);
    if (!p.length) return NO;

    BOOL admin = NO;
    for (NSString *w in @[@"授权", @"取消授权", @"撤销授权", @"代发"]) {
        if ([p hasPrefix:w]) { admin = YES; break; }
    }

    // ---------- 管理命令：只有账号主人能执行 ----------
    if (admin) {
        // 不是主人发的「授权/代发…」不当命令处理，交回普通问答（不提示、不泄露能力）
        if (!owner) return NO;
        NSMutableDictionary *store = InsRelayStore();

        if ([p hasPrefix:@"授权列表"]) {
            reply([self listText]);
            return YES;
        }
        if ([p hasPrefix:@"代发记录"]) {
            reply([self auditText]);
            return YES;
        }
        // 代发体检：把「联系人解析→内部接口→打开会话→发送」逐段单独验一遍
        if ([p hasPrefix:@"代发体检"] || [p hasPrefix:@"体检"]) {
            NSString *arg = InsRelayTrim([p substringFromIndex:[p hasPrefix:@"代发体检"] ? 4 : 2]);
            // 只认第一个词：主人常把「代发体检 张鹏 看卡在哪一步，再发…」整段复制过来
            NSArray *toks = InsRelayTokens(arg);
            NSString *query = toks.count ? toks.firstObject : talker;
            NSDictionary *who = InsRelayResolve(query);
            if (who[@"error"] && arg.length && ![arg isEqualToString:query]) {
                NSDictionary *whole = InsRelayResolve(arg);   // 名字本身带空格时退回整句
                if (!whole[@"error"]) who = whole;
            }
            if (who[@"error"]) {
                reply([NSString stringWithFormat:@"体检对象没认出来：%@", who[@"error"]]);
                return YES;
            }
            reply([NSString stringWithFormat:@"开始体检「%@」，大概 10 秒…", who[@"name"]]);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSString *report = [InsSend openDiagnosis:who[@"wxid"]];
                reply(report);
            });
            return YES;
        }
        if ([p hasPrefix:@"代发"]) {
            NSString *arg = InsRelayTrim([p substringFromIndex:2]);
            NSArray *toks = InsRelayTokens(arg);
            if (!toks.count || [toks.firstObject isEqualToString:@"状态"]) {
                reply([self statusLine]);
                return YES;
            }
            NSString *what = toks.firstObject;
            NSString *val = toks.count > 1 ? toks[1] : @"";
            BOOL on = [val isEqualToString:@"开"] || [val isEqualToString:@"打开"] ||
                      [val isEqualToString:@"启用"] || [val isEqualToString:@"on"];
            BOOL off = [val isEqualToString:@"关"] || [val isEqualToString:@"关闭"] ||
                       [val isEqualToString:@"停用"] || [val isEqualToString:@"off"];
            if (!on && !off) {
                reply(@"用法：@insomnia 代发 开/关（总开关）｜代发 跳转 开/关｜代发 署名 开/关｜代发记录");
                return YES;
            }
            NSString *key = nil;
            if ([what isEqualToString:@"跳转"]) key = @"navigate";
            else if ([what isEqualToString:@"署名"]) key = @"sign";
            else if ([what isEqualToString:@"开"] || [what isEqualToString:@"关"] ||
                     [what isEqualToString:@"打开"] || [what isEqualToString:@"关闭"] ||
                     [what isEqualToString:@"启用"] || [what isEqualToString:@"停用"]) {
                key = @"enabled";
                on = [what isEqualToString:@"开"] || [what isEqualToString:@"打开"] || [what isEqualToString:@"启用"];
                off = !on;
            }
            if (!key) {
                reply(@"认得的开关：代发 开/关、代发 跳转 开/关、代发 署名 开/关。");
                return YES;
            }
            store[key] = @(on);
            InsRelaySave();
            if ([key isEqualToString:@"enabled"]) {
                reply(on ? @"代发已打开。已授权的人可以继续转达，内容检查照旧。"
                         : @"代发已关闭。已授权的请求一律拒绝，授权关系保留。");
            } else if ([key isEqualToString:@"navigate"]) {
                reply(on ? @"允许为代发跳转会话（对方会话没开着会短暂切到那个聊天窗口）。"
                         : @"不再跳转：只发当前已打开的会话，发不出去就排队，不会抢屏。");
            } else {
                reply(on ? @"代发时会在正文前加「（<发起人> 让我转达）」，对方知道是谁说的话。"
                         : @"代发内容原样发出，不加署名。");
            }
            return YES;
        }

        if ([p hasPrefix:@"取消授权"] || [p hasPrefix:@"撤销授权"]) {
            NSString *arg = InsRelayTrim([p substringFromIndex:4]);
            NSArray *toks = InsRelayTokens(arg);
            NSMutableDictionary *routes = store[@"routes"];
            if (![routes isKindOfClass:[NSMutableDictionary class]]) {
                routes = [NSMutableDictionary dictionary];
                store[@"routes"] = routes;
            }
            if (!toks.count) {
                reply(@"用法：@insomnia 取消授权 林健（收回他的全部代发权限）｜取消授权 林健 张鹏（只收回这一个）｜取消授权 全部");
                return YES;
            }
            if ([toks.firstObject isEqualToString:@"全部"]) {
                NSUInteger n = routes.count;
                [routes removeAllObjects];
                InsRelaySave();
                reply([NSString stringWithFormat:@"已收回全部代发授权（%lu 人）。", (unsigned long)n]);
                return YES;
            }
            NSDictionary *who = InsRelayResolve(toks.firstObject);
            if (who[@"error"]) { reply(who[@"error"]); return YES; }
            NSString *fromWxid = who[@"wxid"];
            NSMutableDictionary *route = routes[fromWxid];
            if (![route isKindOfClass:[NSMutableDictionary class]]) {
                reply([NSString stringWithFormat:@"本来就没人被授权代发（没找到 %@ 的授权）。", who[@"name"]]);
                return YES;
            }
            if (toks.count > 1) {
                NSRange fr = [arg rangeOfString:toks.firstObject];
                NSString *targetName = fr.location == NSNotFound ? toks[1]
                    : InsRelayTrim([arg substringFromIndex:NSMaxRange(fr)]);
                NSMutableDictionary *targets = [route[@"targets"] isKindOfClass:[NSDictionary class]]
                    ? [route[@"targets"] mutableCopy] : [NSMutableDictionary dictionary];
                NSMutableArray *hit = [NSMutableArray array];
                for (NSString *wxid in targets) {
                    if ([targets[wxid][@"name"] isEqualToString:targetName]) [hit addObject:wxid];
                }
                if (!hit.count) {
                    reply([NSString stringWithFormat:@"%@ 本来就没有发给「%@」的权限。", who[@"name"], targetName]);
                    return YES;
                }
                for (NSString *wxid in hit) [targets removeObjectForKey:wxid];
                route[@"targets"] = targets;
                if (!targets.count) [routes removeObjectForKey:fromWxid];
                InsRelaySave();
                reply([NSString stringWithFormat:@"已收回：%@ → %@。", who[@"name"], targetName]);
                return YES;
            }
            [routes removeObjectForKey:fromWxid];
            InsRelaySave();
            reply([NSString stringWithFormat:@"已收回 %@ 的全部代发授权。", who[@"name"]]);
            return YES;
        }

        // ---------- 授权 X Y ----------
        NSString *arg = InsRelayTrim([p substringFromIndex:2]);
        NSArray *toks = InsRelayTokens(arg);
        if (toks.count < 2) {
            reply(@"用法：@insomnia 授权 林健 张鹏\n"
                  @"意思是「允许林健让我给张鹏发消息」。可以给同一个人授权多个对象，重复执行即可。\n"
                  @"收回：@insomnia 取消授权 林健 [张鹏]；查看：@insomnia 授权列表");
            return YES;
        }
        NSString *fromName = toks.firstObject;
        NSRange fr = [arg rangeOfString:fromName];
        NSString *toRaw = InsRelayTrim([arg substringFromIndex:NSMaxRange(fr)]);
        NSDictionary *from = InsRelayResolve(fromName);
        if (from[@"error"]) {
            reply([NSString stringWithFormat:
                   @"发起人：%@\n通讯录读到 %lu 个联系人（来源：%@）。\n"
                   @"发「%@ 查人 %@」看能匹配到谁，或直接写 wxid：%@ 授权 wxid_xxx %@",
                   from[@"error"], (unsigned long)[InsStat knownContactCount], [InsStat contactSource],
                   trigger, fromName, trigger, toRaw]);
            return YES;
        }
        NSDictionary *to = InsRelayResolve(toRaw);
        if (to[@"error"]) {
            reply([NSString stringWithFormat:
                   @"收件人：%@\n通讯录读到 %lu 个联系人（来源：%@）。\n"
                   @"发「%@ 查人 %@」看能匹配到谁；也可以直接指定 wxid：%@ 授权 %@ wxid_xxx\n"
                   @"通讯录一直读不到时：打开和对方的聊天、让他发一条消息，再发「%@ sync」，名字就会进索引。",
                   to[@"error"], (unsigned long)[InsStat knownContactCount], [InsStat contactSource],
                   trigger, toRaw, trigger, from[@"name"], trigger]);
            return YES;
        }
        if ([from[@"wxid"] isEqualToString:to[@"wxid"]]) {
            reply(@"自己发给自己没意义，换个收件人。");
            return YES;
        }

        NSMutableDictionary *routes = [store[@"routes"] isKindOfClass:[NSDictionary class]]
            ? [store[@"routes"] mutableCopy] : [NSMutableDictionary dictionary];
        NSString *fromWxid = from[@"wxid"];
        NSMutableDictionary *route = [routes[fromWxid] isKindOfClass:[NSDictionary class]]
            ? [routes[fromWxid] mutableCopy] : [NSMutableDictionary dictionary];
        route[@"name"] = from[@"name"];
        route[@"created"] = route[@"created"] ?: @([[NSDate date] timeIntervalSince1970]);
        if (![route[@"limit"] unsignedIntegerValue]) route[@"limit"] = @5;
        NSMutableDictionary *targets = [route[@"targets"] isKindOfClass:[NSDictionary class]]
            ? [route[@"targets"] mutableCopy] : [NSMutableDictionary dictionary];
        targets[to[@"wxid"]] = @{ @"name": to[@"name"] };
        route[@"targets"] = targets;
        routes[fromWxid] = route;
        store[@"routes"] = routes;
        store[@"enabled"] = @YES;
        InsRelaySave();

        NSMutableArray *names = [NSMutableArray array];
        for (NSString *wxid in targets) {
            NSString *n = targets[wxid][@"name"];
            if (n.length) [names addObject:n];
        }
        reply([NSString stringWithFormat:
               @"已授权：%@ 可以让我给 %@ 发消息。\n"
               @"对方在这条单聊里发「%@ 给%@发消息说<内容>」即可转达。\n"
               @"每条都会先做内容检查（辱骂/威胁/要钱/链接一律拒），并按每小时 5 条限流；"
               @"记录可用 %@ 代发记录 查，随时 %@ 取消授权 %@ 收回。",
               from[@"name"], [names componentsJoinedByString:@"、"], trigger,
               to[@"name"], trigger, trigger, from[@"name"]]);
        InsRelayNote([NSString stringWithFormat:@"授权 %@(%@) → %@(%@)",
                      from[@"name"], fromWxid, to[@"name"], to[@"wxid"]]);
        return YES;
    }

    // ---------- 代发正文 ----------
    NSDictionary *req = InsRelayParseSend(p);
    if (!req) return NO;

    NSMutableDictionary *store = InsRelayStore();
    NSString *targetName = req[@"name"];
    NSString *text = req[@"text"];

    if (![store[@"enabled"] boolValue]) {
        reply(@"代发功能现在是关闭的。让账号主人发「授权」重新打开。");
        InsRelayAudit(senderName, targetName, text, NO, @"代发总开关关闭");
        return YES;
    }
    if (!text.length) {
        reply([NSString stringWithFormat:@"要发给%@什么？这样发：%@ 给%@发消息说<内容>",
               targetName, trigger, targetName]);
        return YES;
    }

    NSString *fromWxid = talker ?: @"";
    NSString *fromLabel = senderName.length ? senderName : fromWxid;
    if (!owner && [talker hasSuffix:@"@chatroom"]) {
        reply(@"群聊里不能用代发（分不清是谁在借号说话）。在单聊里发这个命令。");
        InsRelayAudit(fromLabel, targetName, text, NO, @"群聊拒绝");
        return YES;
    }

    NSMutableDictionary *routes = [store[@"routes"] isKindOfClass:[NSDictionary class]]
        ? [store[@"routes"] mutableCopy] : [NSMutableDictionary dictionary];
    NSMutableDictionary *route = nil;
    if (owner) {
        route = [NSMutableDictionary dictionary];
        route[@"name"] = fromLabel;
        route[@"limit"] = @20;
        route[@"owner"] = @YES;
    } else {
        NSDictionary *found = routes[fromWxid];
        if (![found isKindOfClass:[NSDictionary class]]) {
            if (![req[@"strong"] boolValue]) return NO;   // 不像命令，交回普通问答
            reply([NSString stringWithFormat:
                   @"你还没有代发权限。\n让账号主人在文件传输助手发：%@ 授权 %@ <对方备注>",
                   trigger, fromLabel]);
            InsRelayAudit(fromLabel, targetName, text, NO, @"未授权");
            return YES;
        }
        route = [found mutableCopy];
    }

    // 目标解析：主人按名字查通讯录；被授权人只允许发给授权列表里的人
    NSString *toWxid = nil, *toName = nil;
    if (owner) {
        NSDictionary *to = InsRelayResolve(targetName);
        if (to[@"error"]) { reply([NSString stringWithFormat:@"收件人：%@", to[@"error"]]); return YES; }
        toWxid = to[@"wxid"];
        toName = to[@"name"];
    } else {
        NSMutableDictionary *targets = [route[@"targets"] isKindOfClass:[NSDictionary class]]
            ? [route[@"targets"] mutableCopy] : [NSMutableDictionary dictionary];
        NSMutableArray *exact = [NSMutableArray array];
        NSMutableArray *fuzzy = [NSMutableArray array];
        for (NSString *wxid in targets) {
            NSString *n = targets[wxid][@"name"] ?: @"";
            if ([n isEqualToString:targetName]) [exact addObject:wxid];
            else if (n.length >= 2 && ([n containsString:targetName] || [targetName containsString:n])) {
                [fuzzy addObject:wxid];
            }
        }
        NSArray *hit = exact.count ? exact : fuzzy;
        if (hit.count != 1) {
            NSMutableArray *allowed = [NSMutableArray array];
            for (NSString *wxid in targets) {
                NSString *n = targets[wxid][@"name"];
                if (n.length) [allowed addObject:n];
            }
            if (!allowed.count) {
                reply(@"账号主人还没授权你给任何人发消息。");
            } else if (hit.count > 1) {
                reply([NSString stringWithFormat:@"「%@」在你被授权的名单里对应多个：%@。请说得更准确些。",
                       targetName, [allowed componentsJoinedByString:@"、"]]);
            } else {
                reply([NSString stringWithFormat:@"你没有给「%@」发消息的权限。你能发给：%@。",
                       targetName, [allowed componentsJoinedByString:@"、"]]);
            }
            InsRelayAudit(fromLabel, targetName, text, NO, @"目标不在授权范围");
            return YES;
        }
        toWxid = hit.firstObject;
        toName = targets[toWxid][@"name"] ?: toWxid;
    }
    if (!toWxid.length) return YES;

    // 合规检查
    NSString *veto = InsRelayVeto(text, trigger);
    if (veto) {
        reply([NSString stringWithFormat:@"这条没发出去：%@。\n换句话再试；辱骂、威胁、要钱/验证码、链接一律不支持。", veto]);
        InsRelayAudit(fromLabel, toName, text, NO, veto);
        return YES;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    // 同一句话 60 秒内别重复发（防手抖/刷屏）
    NSArray *audit = store[@"audit"];
    if ([audit isKindOfClass:[NSArray class]] && audit.count) {
        NSDictionary *lastOK = nil;
        for (NSDictionary *e in audit) {
            if ([e[@"ok"] boolValue] && [e[@"from"] isEqualToString:fromLabel] &&
                [e[@"to"] isEqualToString:toName]) { lastOK = e; break; }
        }
        if (lastOK && now - [lastOK[@"t"] doubleValue] < 60 &&
            [lastOK[@"text"] isEqualToString:(text.length > 40 ? [[text substringToIndex:40] stringByAppendingString:@"…"] : text)]) {
            reply([NSString stringWithFormat:@"刚给%@发过一模一样的话，没重复发。", toName]);
            return YES;
        }
    }

    NSString *quota = InsRelayQuotaError(route, now) ?: InsRelayGlobalQuotaError(now);
    if (quota) {
        reply(quota);
        InsRelayAudit(fromLabel, toName, text, NO, quota);
        return YES;
    }

    NSString *outText = text;
    if ([store[@"sign"] boolValue] && !owner) {
        outText = [NSString stringWithFormat:@"（%@ 让我转达）%@", fromLabel, text];
    }

    // 额度只算「真送达」的那几次：以前一发起就扣，连试几次失败就把自己限流了
    if (!owner) {
        routes[fromWxid] = route;
        store[@"routes"] = routes;
    }
    InsRelaySave();
    InsRelayNote([NSString stringWithFormat:@"%@ 请求发给 %@：%@",
                  fromLabel, toName, text.length > 20 ? [[text substringToIndex:20] stringByAppendingString:@"…"] : text]);

    // 20 秒没等到发送结果就不再干等：回执先发出去，避免对方以为命令丢了
    NSObject *token = [NSObject new];
    __block BOOL replied = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
        @synchronized (token) {
            if (replied) return;
            replied = YES;
        }
        InsRelayAudit(fromLabel, toName, text, NO, @"发送超时");
        reply([NSString stringWithFormat:@"发给%@的消息 45 秒没等到结果：可能发出去了，也可能卡在打开会话那一步。先看对方有没有收到，别再连发。", toName]);
    });

    deliver(outText, toWxid, [store[@"navigate"] boolValue], ^(BOOL ok, NSString *how) {
        @synchronized (token) {
            if (replied) return;
            replied = YES;
        }
        NSString *trigger = [InsConfig shared].trigger.length ? [InsConfig shared].trigger : @"@insomnia";
        if (ok) {
            // 送达才记额度（失败不扣，失败的人可以立刻换句话重试）
            if (!owner) {
                NSMutableDictionary *st = InsRelayStore();
                NSMutableDictionary *rt = st[@"routes"][fromWxid];
                if ([rt isKindOfClass:[NSMutableDictionary class]]) {
                    InsRelayStamp(rt, [[NSDate date] timeIntervalSince1970]);
                    InsRelaySave();
                }
            }
            InsRelayAudit(fromLabel, toName, text, YES, how ?: @"");
            InsRelayNote([NSString stringWithFormat:@"已送达：%@ → %@（走 %@）", fromLabel, toName, how ?: @"-"]);
            reply([NSString stringWithFormat:@"已发给%@：%@", toName, text]);
            return;
        }
        InsRelayAudit(fromLabel, toName, text, NO, how ?: @"发送失败");
        InsRelayNote([NSString stringWithFormat:@"发送失败：%@ → %@（已试 %@）", fromLabel, toName, how ?: @"-"]);
        NSString *tip = @"";
        if (![store[@"navigate"] boolValue]) {
            tip = [NSString stringWithFormat:@"\n（「代发 跳转」现在是关的，所以没去打开%@的会话）", toName];
        }
        reply([NSString stringWithFormat:
               @"没能发给%@。已按顺序试过：%@。%@\n让账号主人发「%@ 代发体检 %@」看卡在哪一步，再发「%@ 代发 跳转 开」重试。",
               toName, how.length ? how : @"全部通道", tip, trigger, toName, trigger]);
    });
    return YES;
}

+ (BOOL)navigateEnabled {
    return [InsRelayStore()[@"navigate"] boolValue];
}

#pragma mark - 状态与列表

+ (NSString *)statusLine {
    NSMutableDictionary *store = InsRelayStore();
    NSMutableDictionary *routes = store[@"routes"];
    BOOL on = [store[@"enabled"] boolValue];
    NSUInteger targets = 0;
    for (NSString *wxid in routes) {
        NSDictionary *t = routes[wxid][@"targets"];
        if ([t isKindOfClass:[NSDictionary class]]) targets += t.count;
    }
    if (!routes.count) return [NSString stringWithFormat:@"代发 %@ / 还没授权任何人", on ? @"开" : @"关"];
    return [NSString stringWithFormat:@"代发 %@ / 授权 %lu 人 · %lu 条通道",
            on ? @"开" : @"关", (unsigned long)routes.count, (unsigned long)targets];
}

+ (NSString *)listText {
    NSMutableDictionary *store = InsRelayStore();
    NSMutableDictionary *routes = store[@"routes"];
    if (![routes isKindOfClass:[NSDictionary class]] || !routes.count) {
        return [NSString stringWithFormat:
                @"还没有任何代发授权。\n授权：%@ 授权 林健 张鹏（允许林健让我给张鹏发消息）",
                [InsConfig shared].trigger];
    }
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSMutableString *out = [NSMutableString stringWithFormat:@"代发授权（%@）：",
                            [store[@"enabled"] boolValue] ? @"开" : @"关"];
    for (NSString *wxid in routes) {
        NSDictionary *route = routes[wxid];
        NSDictionary *targets = route[@"targets"];
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *t in targets) {
            NSString *n = targets[t][@"name"];
            if (n.length) [names addObject:n];
        }
        NSUInteger used = InsRelayCountWithin(route[@"stamps"] ?: @[], now, 3600);
        [out appendFormat:@"\n- %@ → %@（这一小时 %lu/%@ 条，wxid %@）",
         route[@"name"] ?: wxid, names.count ? [names componentsJoinedByString:@"、"] : @"(无)",
         (unsigned long)used, route[@"limit"] ?: @5, wxid];
    }
    [out appendString:@"\n\n收回：取消授权 <名字> [对方]；明细：代发记录"];
    return out;
}

+ (NSString *)auditText {
    NSMutableDictionary *store = InsRelayStore();
    NSArray *audit = store[@"audit"];
    if (![audit isKindOfClass:[NSArray class]] || !audit.count) return @"还没有代发记录。";
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.dateFormat = @"MM-dd HH:mm";
    });
    NSMutableArray *lines = [NSMutableArray array];
    NSInteger n = 0;
    for (NSDictionary *e in audit) {
        if (n >= 10) break;
        n++;
        NSString *when = [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:[e[@"t"] doubleValue]]];
        [lines addObject:[NSString stringWithFormat:@"%@ %@→%@ %@%@",
                          when, e[@"from"] ?: @"?", e[@"to"] ?: @"?",
                          [e[@"ok"] boolValue] ? @"✅ " : @"❌ ",
                          [e[@"ok"] boolValue] ? (e[@"text"] ?: @"") : (e[@"reason"] ?: @"")]];
    }
    return [NSString stringWithFormat:@"最近 %ld 条代发记录：\n%@",
            (long)lines.count, [lines componentsJoinedByString:@"\n"]];
}

@end
