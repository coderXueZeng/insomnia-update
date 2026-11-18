#import "InsStat.h"
#import "InsHistory.h"
#import "InsMemory.h"
#import "InsConfig.h"
#import "InsSend.h"
#import <sqlite3.h>

static NSCharacterSet *InsStatTrim(void) {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSCharacterSet characterSetWithCharactersInString:
               @" \t\n，。、,.:：;；!！?？~～…·\"'“”‘’「」『』【】（）()<>《》-—"];
    });
    return set;
}

static NSString *InsStatClean(NSString *s) {
    return [s stringByTrimmingCharactersInSet:InsStatTrim()];
}

@interface InsStat ()
@end

@implementation InsStat

#pragma mark - 意图解析

/// 「统计」「数一下」这类前缀不影响人名，先切掉
+ (NSString *)stripLeadWords:(NSString *)s {
    static NSArray *leads = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        leads = @[@"帮我统计一下", @"帮我统计", @"帮我数一下", @"帮我数数", @"帮我数",
                  @"统计一下", @"统计", @"数一下", @"数数", @"数", @"算一下", @"算算",
                  @"查一下", @"看一下", @"看看", @"请问", @"问一下", @"一共", @"总共", @"count"];
    });
    NSString *out = InsStatClean(s);
    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (NSString *w in leads) {
            if (!w.length) continue;
            if ([out.lowercaseString hasPrefix:w.lowercaseString]) {
                out = InsStatClean([out substringFromIndex:w.length]);
                changed = YES;
            }
        }
    }
    return out;
}

/// 「林健刚才说了多少句」里「刚才/最近」是时间词，不是名字的一部分
+ (NSString *)stripTimeWords:(NSString *)s {
    static NSArray *words = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = @[@"刚才", @"刚刚", @"最近", @"这段时间", @"这段时间里", @"之前", @"以前",
                  @"上次", @"那次", @"今天", @"昨天", @"这会儿", @"那时候", @"当时",
                  @"那个", @"这个", @"他们", @"她们"];
    });
    NSString *out = s;
    BOOL changed = YES;
    while (changed) {
        changed = NO;
        for (NSString *w in words) {
            while ([out hasSuffix:w]) {
                out = [out substringToIndex:out.length - w.length];
                changed = YES;
            }
            while ([out hasPrefix:w]) {
                out = [out substringFromIndex:w.length];
                changed = YES;
            }
        }
        out = InsStatClean(out);
    }
    return out;
}

+ (NSDictionary *)parseCountQuestion:(NSString *)payload {
    // 把自己发出的回执原样发回来（「【统计】… 关键词「你小子」」）也要能重跑。
    // 必须拿**原文**找，InsStatClean 会把结尾的「」剪掉，剪完就找不到右引号了。
    NSRange head = [payload rangeOfString:@"关键词「"];
    if (head.location != NSNotFound) {
        NSUInteger start = NSMaxRange(head);
        NSRange area = NSMakeRange(start, payload.length - start);
        NSRange end = [payload rangeOfString:@"」" options:0 range:area];
        NSString *kw = nil;
        if (end.location != NSNotFound) {
            kw = [payload substringWithRange:NSMakeRange(start, end.location - start)];
        } else if (end.location == NSNotFound && area.length) {
            // 回执被截断、右引号丢了：取到行尾即可
            kw = [payload substringWithRange:area];
            NSRange cut = [kw rangeOfString:@"\n"];
            if (cut.location != NSNotFound) kw = [kw substringToIndex:cut.location];
        }
        kw = InsStatClean(kw ?: @"");
        if (kw.length && kw.length <= 24) {
            return @{@"who": @"", @"keyword": kw, @"from": @"both"};
        }
    }
    NSString *s = InsStatClean(payload);
    if (s.length < 3) return nil;
    // 「说了多少句」「讲过几次」「出现了多少回」，动词都可省
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"(?:一共|总共)?\\s*(?:说|讲|发|提|喊|叫|骂|念|写|出现|用)?(?:了|过)?\\s*(?:多少|几)\\s*(?:句|次|遍|回|条|个)"
        options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m) return nil;

    NSString *before = InsStatClean([s substringToIndex:m.range.location]);
    NSString *after = InsStatClean([s substringFromIndex:NSMaxRange(m.range)]);
    // 「出现了多少次」这种把关键词放在前面的问法
    for (NSString *tail in @[@"出现", @"说", @"讲", @"提到", @"喊", @"叫"]) {
        if ([before hasSuffix:tail]) before = InsStatClean([before substringToIndex:before.length - tail.length]);
    }
    if (!after.length) {
        after = before;
        before = @"";
    }
    NSString *keyword = InsStatClean(after);
    // 关键词前面常带「了/的/过/个」和说话动词
    for (NSString *lead in @[@"了", @"的", @"过", @"个", @"说", @"喊", @"讲"]) {
        while ([keyword hasPrefix:lead] && keyword.length > lead.length) {
            keyword = InsStatClean([keyword substringFromIndex:lead.length]);
        }
    }
    // 混进了回执模板的碎片（「…的会话 · 关键词「X」」）：抠出引号里的真关键词
    NSRange inner = [keyword rangeOfString:@"关键词「"];
    if (inner.location != NSNotFound) {
        keyword = InsStatClean([keyword substringFromIndex:NSMaxRange(inner)]);
        NSRange endQuote = [keyword rangeOfString:@"」"];
        if (endQuote.location != NSNotFound) keyword = [keyword substringToIndex:endQuote.location];
        keyword = InsStatClean(keyword);
    }
    if (!keyword.length || keyword.length > 24) return nil;   // 太长的句子多半不是统计
    for (NSString *junk in @[@"的会话", @"【统计】", @"·", @"已送达"]) {
        if ([keyword rangeOfString:junk].location != NSNotFound) return nil;
    }

    NSString *who = [self stripTimeWords:[self stripLeadWords:before]];
    NSString *from = @"partner";
    NSString *selfLabel = [InsMemory selfLabel];
    if ([who isEqualToString:@"我"] || [who isEqualToString:@"自己"] ||
        [who isEqualToString:@"咱"] || (selfLabel.length && [who isEqualToString:selfLabel])) {
        who = @"";
        from = @"me";
    } else if (!who.length) {
        from = @"both";
    }
    // 「你小子我一共说了多少遍」：关键词末尾的「我」其实是说话人
    if ([from isEqualToString:@"both"] &&
        ([keyword hasSuffix:@"我"] || [keyword hasSuffix:@"自己"]) && keyword.length > 1) {
        keyword = InsStatClean([keyword substringToIndex:keyword.length - ([keyword hasSuffix:@"我"] ? 1 : 2)]);
        from = @"me";
    }
    // 带疑问/转述的碎片（「他问我」）不是要统计的词
    for (NSString *bad in @[@"问", @"吗", @"呢", @"啥", @"怎么", @"为什么", @"什么", @"多少"]) {
        if ([keyword rangeOfString:bad].location != NSNotFound) return nil;
    }
    if (!keyword.length) return nil;
    if (who.length > 20) who = @"";
    return @{@"who": who ?: @"", @"keyword": keyword, @"from": from};
}

+ (NSDictionary *)parseExplicitCount:(NSString *)payload {
    NSString *s = InsStatClean(payload);
    // 回执原文（【统计】…）不是命令，别被「统计」两个字骗进来
    if ([payload rangeOfString:@"【统计】"].location != NSNotFound) return nil;
    if ([payload rangeOfString:@"关键词「"].location != NSNotFound) return nil;
    NSString *prefix = nil;
    for (NSString *w in @[@"统计", @"数", @"count"]) {
        if ([s.lowercaseString hasPrefix:w]) { prefix = w; break; }
    }
    if (!prefix) return nil;
    NSString *rest = [s substringFromIndex:prefix.length];
    if (!rest.length) return nil;
    // 「数完了没」「统计】林健…」这类正常语句/碎文本别当成命令：前缀后面必须紧跟空格
    unichar first = [rest characterAtIndex:0];
    if (first != ' ' && first != '\t' && first != '\n') return nil;
    rest = InsStatClean(rest);
    if (!rest.length) return nil;
    NSArray *parts = [rest componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSString *p in parts) {
        NSString *t = InsStatClean(p);
        if (t.length) [tokens addObject:t];
    }
    if (!tokens.count) return nil;
    NSString *who = tokens.count >= 2 ? tokens[0] : @"";
    NSString *keyword = tokens.count >= 2
        ? [[tokens subarrayWithRange:NSMakeRange(1, tokens.count - 1)] componentsJoinedByString:@" "]
        : tokens[0];
    keyword = InsStatClean(keyword);
    if (!keyword.length || keyword.length > 24) return nil;
    NSString *from = @"partner";
    if ([who isEqualToString:@"我"] || [who isEqualToString:@"自己"]) { who = @""; from = @"me"; }
    else if (!who.length) from = @"both";
    return @{@"who": who, @"keyword": keyword, @"from": from};
}

#pragma mark - 人名 → 会话

static id InsStatKV(id object, NSString *key) {
    if (!object) return nil;
    @try {
        id value = [object valueForKey:key];
        if ([value isKindOfClass:[NSString class]] && [value length]) return value;
    } @catch (__unused NSException *e) {}
    return nil;
}

static id InsStatCall(id target, NSString *selector, id arg) {
    if (!target) return nil;
    SEL sel = NSSelectorFromString(selector);
    if (![target respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = target;
    inv.selector = sel;
    if (arg && sig.numberOfArguments >= 3) [inv setArgument:&arg atIndex:2];
    @try { [inv invoke]; } @catch (__unused NSException *e) { return nil; }
    __unsafe_unretained id result = nil;
    [inv getReturnValue:&result];
    return result;
}

/// 通讯录里所有人：@{ wxid: 名字数组 }。
/// 两个来源：微信通讯录接口（后台线程常返回 nil，必须切主线程）＋ 本地通讯录库 rcontact。
/// 旧版用 dispatch_once 缓存，第一次读到空就永久为空——「张鹏明明在通讯录里却查不到」就是这么来的。
static NSDictionary *gStatContacts = nil;
static NSTimeInterval gStatContactsAt = 0;
static NSString *gStatContactSource = nil;

static void InsStatMergeNames(NSMutableDictionary *out, NSString *wxid, NSArray *values) {
    if (!wxid.length) return;
    // 公众号、群、系统号不参与找人
    if ([wxid hasPrefix:@"gh_"] || [wxid hasPrefix:@"@"] || [wxid hasPrefix:@"qq"]) return;
    NSArray *special = @[@"filehelper", @"weixin", @"mphelper", @"medianote", @"fmessage",
                         @"floatbottle", @"newsapp", @"notifymessage", @"qqmail", @"brandsessionholder",
                         @"weibo", @"facebook", @"twitter", @"linkedin"];
    if ([special containsObject:wxid]) return;

    NSMutableArray *names = out[wxid];
    if (!names) {
        names = [NSMutableArray array];
        out[wxid] = names;
    }
    for (NSString *v in values) {
        if (![v isKindOfClass:[NSString class]]) continue;
        NSString *t = InsStatClean(v);
        if (!t.length || [t isEqualToString:wxid] || t.length > 40) continue;
        if (![names containsObject:t]) [names addObject:t];
    }
    if (!names.count) [out removeObjectForKey:wxid];
}

static void InsStatMergeContact(NSMutableDictionary *out, NSString *wxid,
                                NSString *remark, NSString *nick, NSString *alias) {
    InsStatMergeNames(out, wxid, @[remark ?: @"", nick ?: @"", alias ?: @""]);
}

static NSString *InsStatColText(sqlite3_stmt *stmt, int idx) {
    const unsigned char *p = sqlite3_column_text(stmt, idx);
    if (!p) return @"";
    return [NSString stringWithUTF8String:(const char *)p] ?: @"";
}

static NSArray<NSString *> *InsStatDBDirs(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *dirs = [NSMutableArray array];
    for (NSString *d in [fm contentsOfDirectoryAtPath:docs error:nil]) {
        if (d.length != 32) continue;       // 账号目录是 32 位 hash
        NSString *dbDir = [[docs stringByAppendingPathComponent:d] stringByAppendingPathComponent:@"DB"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:dbDir isDirectory:&isDir] && isDir) [dirs addObject:dbDir];
    }
    return dirs;
}

/// 直接读通讯录表：微信接口取不到时的兜底
static BOOL InsStatCollectFromDB(NSMutableDictionary *out) {
    NSArray *files = @[@"wccontact_new2.db", @"wccontact_new.db", @"contact.db", @"MM.sqlite"];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL hit = NO;
    for (NSString *dir in InsStatDBDirs()) {
        for (NSString *file in files) {
            NSString *path = [dir stringByAppendingPathComponent:file];
            if (![fm fileExistsAtPath:path]) continue;
            sqlite3 *db = NULL;
            if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
                if (db) sqlite3_close(db);
                continue;
            }
            sqlite3_busy_timeout(db, 1500);
            sqlite3_stmt *stmt = NULL;
            const char *sql = "SELECT username, IFNULL(conRemark,''), IFNULL(nickname,''), IFNULL(alias,'') FROM rcontact;";
            if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
                while (sqlite3_step(stmt) == SQLITE_ROW) {
                    NSString *wxid = InsStatColText(stmt, 0);
                    if (!wxid.length) continue;
                    InsStatMergeContact(out, wxid,
                                        InsStatColText(stmt, 1), InsStatColText(stmt, 2), InsStatColText(stmt, 3));
                    hit = YES;
                }
            }
            if (stmt) sqlite3_finalize(stmt);
            sqlite3_close(db);
        }
    }
    return hit;
}

/// 新版微信的通讯录在 WCDB_Contact.sqlite 的 Friend 表里，名字不是列而是 protobuf blob
/// （dbContactRemark：1 昵称 / 3 备注 / 4 微信号 / 2、5 其它别名）。这里把里面的字符串全挖出来。
/// 老库用 rcontact 表，已经读不到东西了——「张鹏明明在通讯录里却查不到」就是栽在这。
static NSArray<NSString *> *InsStatPBStrings(NSData *data, NSUInteger depth) {
    if (!data.length || depth > 2) return @[];
    const uint8_t *p = (const uint8_t *)data.bytes;
    NSUInteger len = data.length, i = 0;
    NSMutableArray *out = [NSMutableArray array];
    while (i < len) {
        uint64_t key = 0;
        int shift = 0;
        BOOL done = NO;
        while (i < len) {
            uint8_t c = p[i++];
            key |= (uint64_t)(c & 0x7f) << shift;
            shift += 7;
            if (!(c & 0x80)) { done = YES; break; }
            if (shift > 63) break;
        }
        if (!done) break;
        uint32_t field = (uint32_t)(key >> 3);
        uint32_t wire = (uint32_t)(key & 7);
        if (wire == 0) {
            while (i < len && (p[i++] & 0x80)) {}
        } else if (wire == 2) {
            uint64_t l = 0;
            shift = 0;
            BOOL gotLen = NO;
            while (i < len) {
                uint8_t c = p[i++];
                l |= (uint64_t)(c & 0x7f) << shift;
                shift += 7;
                if (!(c & 0x80)) { gotLen = YES; break; }
                if (shift > 63) break;
            }
            if (!gotLen || i + l > len) break;
            NSData *sub = [data subdataWithRange:NSMakeRange(i, (NSUInteger)l)];
            i += (NSUInteger)l;
            NSString *s = [[NSString alloc] initWithData:sub encoding:NSUTF8StringEncoding];
            BOOL printable = s.length > 0 && s.length <= 40;
            for (NSUInteger k = 0; printable && k < s.length; k++) {
                unichar ch = [s characterAtIndex:k];
                if (ch < 0x20 || ch == 0xFFFD) printable = NO;
            }
            if (printable) {
                if (field >= 1 && field <= 5) [out addObject:s];   // 6 是拼音，跳过
            } else if (!s.length) {
                [out addObjectsFromArray:InsStatPBStrings(sub, depth + 1)];
            }
        } else if (wire == 5) {
            i += 4;
        } else if (wire == 1) {
            i += 8;
        } else {
            break;
        }
    }
    return out;
}

/// 新版通讯录库（WCDB）：Friend 表 + protobuf 备注
static BOOL InsStatCollectFromWCDB(NSMutableDictionary *out) {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in InsStatDBDirs()) {
        for (NSString *file in @[@"WCDB_Contact.sqlite", @"wccontact_new2.db", @"wccontact_new.db"]) {
            NSString *path = [dir stringByAppendingPathComponent:file];
            if (![fm fileExistsAtPath:path]) continue;
            sqlite3 *db = NULL;
            if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
                if (db) sqlite3_close(db);
                continue;
            }
            sqlite3_busy_timeout(db, 2000);
            sqlite3_stmt *stmt = NULL;
            BOOL hit = NO;
            if (sqlite3_prepare_v2(db, "SELECT userName, dbContactRemark FROM Friend", -1, &stmt, NULL) == SQLITE_OK) {
                while (sqlite3_step(stmt) == SQLITE_ROW) {
                    NSString *wxid = InsStatColText(stmt, 0);
                    if (!wxid.length) continue;
                    const void *bytes = sqlite3_column_blob(stmt, 1);
                    int blen = sqlite3_column_bytes(stmt, 1);
                    if (!bytes || blen <= 0) continue;
                    NSData *blob = [NSData dataWithBytes:bytes length:(NSUInteger)blen];
                    InsStatMergeNames(out, wxid, InsStatPBStrings(blob, 0));
                    hit = YES;
                }
            }
            if (stmt) sqlite3_finalize(stmt);
            sqlite3_close(db);
            if (hit) return YES;
        }
    }
    return NO;
}

/// 会话列表兜底：MM.sqlite 的 Session 表带着每个会话的显示名（备注优先）。
/// 通讯录枚举接口读不到时，靠它也能按备注名找到人（比如「林健」）。
static BOOL InsStatCollectFromSessions(NSMutableDictionary *out) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL hit = NO;
    for (NSString *dir in InsStatDBDirs()) {
        NSString *path = [dir stringByAppendingPathComponent:@"MM.sqlite"];
        if (![fm fileExistsAtPath:path]) continue;
        sqlite3 *db = NULL;
        if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
            if (db) sqlite3_close(db);
            continue;
        }
        sqlite3_busy_timeout(db, 1500);
        // 不同版本列名大小写不一样，挨个试
        NSArray *sqls = @[@"SELECT UsrName, NickName FROM Session",
                          @"SELECT userName, nickName FROM Session",
                          @"SELECT username, nickname FROM Session",
                          @"SELECT UsrName, IFNULL(Remark,'') FROM Session"];
        BOOL done = NO;
        for (NSString *sql in sqls) {
            sqlite3_stmt *stmt = NULL;
            if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) != SQLITE_OK) continue;
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                NSString *wxid = InsStatColText(stmt, 0);
                if (!wxid.length) continue;
                InsStatMergeContact(out, wxid, InsStatColText(stmt, 1), @"", @"");
                hit = YES;
            }
            sqlite3_finalize(stmt);
            done = YES;
            break;
        }
        sqlite3_close(db);
        if (done) break;
    }
    return hit;
}

static void InsStatCollectFromAPI(NSMutableDictionary *out) {
    Class center = NSClassFromString(@"MMServiceCenter");
    Class mgrClass = NSClassFromString(@"CContactMgr");
    if (!center || !mgrClass) return;
    id defaultCenter = [center performSelector:@selector(defaultCenter)];
    id mgr = defaultCenter ? InsStatCall(defaultCenter, @"getService:", mgrClass) : nil;
    if (!mgr) return;

    // 不同微信版本暴露的枚举方法不一样，挨个试
    id list = nil;
    for (NSString *sel in @[@"getAllFriendContact", @"getContactList", @"getAllContact",
                            @"getAllFriendContactList", @"getContactListWithType:"]) {
        list = InsStatCall(mgr, sel, [sel hasSuffix:@":"] ? @0 : nil);
        if ([list isKindOfClass:[NSArray class]] && [(NSArray *)list count]) break;
    }
    if (![list isKindOfClass:[NSArray class]]) return;
    for (id contact in (NSArray *)list) {
        NSString *wxid = InsStatKV(contact, @"m_nsUsrName")
                      ?: InsStatKV(contact, @"m_nsUserName");
        if (!wxid.length) continue;
        NSString *display = InsStatCall(contact, @"getContactDisplayName", nil);
        InsStatMergeContact(out, wxid,
                            [display isKindOfClass:[NSString class]] ? display : InsStatKV(contact, @"m_nsRemark"),
                            InsStatKV(contact, @"m_nsNickName"),
                            InsStatKV(contact, @"m_nsAliasName"));
    }
}

static NSDictionary<NSString *, NSArray<NSString *> *> *InsStatContactNames(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    @synchronized ([InsStat class]) {
        if (gStatContacts.count && now - gStatContactsAt < 600) return gStatContacts;
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    __block BOOL apiRead = NO;
    void (^collect)(void) = ^{
        NSUInteger before = out.count;
        InsStatCollectFromAPI(out);
        if (out.count > before) apiRead = YES;
    };
    if ([NSThread isMainThread]) {
        collect();
    } else {
        // 后台线程读通讯录会拿到 nil：切主线程取一次，最多等 3 秒，别把命令卡死
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            collect();
            dispatch_semaphore_signal(sem);
        });
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC));
    }

    NSDictionary *result = out.count ? [out copy] : nil;
    NSString *source = @"微信通讯录";
    // 接口一个都没读到，或读得明显偏少（有些版本只给部分联系人）：用本地库补齐
    if (!result || out.count < 30) {
        NSMutableDictionary *merged = [out mutableCopy];
        BOOL dbHit = InsStatCollectFromDB(merged);
        BOOL wcdbHit = InsStatCollectFromWCDB(merged);
        BOOL sesHit = InsStatCollectFromSessions(merged);
        if ((dbHit || wcdbHit || sesHit) && merged.count > out.count) {
            result = [merged copy];
            NSString *tail = sesHit ? @"+会话列表" : @"";
            if (apiRead) source = [NSString stringWithFormat:@"微信通讯录+本地库%@", tail];
            else source = [NSString stringWithFormat:@"%@%@", wcdbHit ? @"本地通讯录库" : @"会话列表", tail];
        }
    }

    @synchronized ([InsStat class]) {
        if (result.count) {
            gStatContacts = result;
            gStatContactsAt = now;
            gStatContactSource = source;
        } else if (gStatContacts.count) {
            return gStatContacts;           // 这次没读到就先用上一次的，别把能用的数据清空
        }
    }
    if (result.count) {
        [InsConfig log:[NSString stringWithFormat:@"通讯录：读到 %lu 个联系人（%@）",
                        (unsigned long)result.count, source]];
    }
    return result ?: @{};
}

+ (NSArray<NSDictionary *> *)candidatesForName:(NSString *)name {
    NSString *query = InsStatClean(name);
    if (query.length < 1) return @[];
    NSMutableDictionary *exact = [NSMutableDictionary dictionary];   // wxid → item
    NSMutableDictionary *fuzzy = [NSMutableDictionary dictionary];

    // 同一个人有昵称/备注/微信号好几个名字，必须每个都比一遍；
    // 以前一个 wxid 只看第一个名字（张鹏的昵称是「zp」），备注「张鹏」就被整条漏掉了
    void (^consider)(NSString *, NSString *, NSUInteger) = ^(NSString *wxid, NSString *label, NSUInteger scanned) {
        if (!wxid.length || !label.length) return;
        BOOL isExact = [label isEqualToString:query];
        BOOL isFuzzy = !isExact && label.length >= 2 &&
            ([label containsString:query] || [query containsString:label]);
        if (!isExact && !isFuzzy) return;
        NSMutableDictionary *bag = isExact ? exact : fuzzy;
        NSDictionary *old = bag[wxid];
        NSDictionary *item = @{@"wxid": wxid, @"name": label, @"scanned": @(scanned)};
        if (!old) { bag[wxid] = item; return; }
        // 同一个人命中多个名字：留「有聊天记录」的那条，其次留更短更像备注的
        BOOL oldTouched = [old[@"scanned"] unsignedIntegerValue] > 0;
        BOOL newTouched = scanned > 0;
        if (newTouched && !oldTouched) { bag[wxid] = item; return; }
        if (oldTouched == newTouched && [old[@"name"] length] > label.length) bag[wxid] = item;
    };

    // 0) 人名簿：见过的名字（通讯录枚举读不到时全靠它），权重给到最高
    InsStatNameBookLoad();
    NSDictionary *book = nil;
    @synchronized ([InsStat class]) { book = [gNameBook copy]; }
    for (NSString *wxid in book) {
        for (NSString *label in book[wxid]) {
            consider(wxid, label, 9999);
        }
    }
    // 1) 记忆索引：这里的名字就是聊天列表里的备注，命中率最高
    for (NSDictionary *entry in [InsMemory nameIndex]) {
        consider(entry[@"wxid"], entry[@"name"], [entry[@"scanned"] unsignedIntegerValue]);
    }
    // 2) 通讯录：还没同步过记忆的人也能查
    NSDictionary *contacts = InsStatContactNames();
    for (NSString *wxid in contacts) {
        for (NSString *label in contacts[wxid]) {
            consider(wxid, label, 0);
        }
    }
    // 备注完全一致 > 包含关系；同分按已同步条数多的优先
    NSArray *result = [exact.allValues arrayByAddingObjectsFromArray:fuzzy.allValues];
    return [result sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSUInteger sa = [a[@"scanned"] unsignedIntegerValue], sb = [b[@"scanned"] unsignedIntegerValue];
        return sa > sb ? NSOrderedAscending : (sa < sb ? NSOrderedDescending : NSOrderedSame);
    }];
}

#pragma mark - 统计回执

static NSString *InsStatTime(uint32_t t, NSString *format) {
    if (!t) return @"未知";
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [NSDateFormatter new];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    });
    @synchronized (fmt) {
        fmt.dateFormat = format;
        return [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]];
    }
}

+ (NSString *)reportForQuestion:(NSString *)payload talker:(NSString *)talker {
    NSDictionary *intent = [self parseCountQuestion:payload] ?: [self parseExplicitCount:payload];
    if (!intent) return nil;
    NSString *keyword = intent[@"keyword"];
    NSString *who = intent[@"who"];
    NSString *from = intent[@"from"];

    NSString *target = talker;
    NSString *label = [InsMemory partnerLabelForTalker:talker];
    NSString *note = nil;
    if (who.length) {
        // 最常见的情况：就在跟这个人聊天，问题里又带了他的名字。
        // 这时候没必要去通讯录查（查不到就会误判成「不认识这个人」再落到大模型）。
        BOOL sameAsHere = [who isEqualToString:label] ||
            (label.length >= 2 && ([label containsString:who] || [who containsString:label]));
        if (!sameAsHere) {
            NSArray *candidates = [self candidatesForName:who];
            if (!candidates.count) {
                // 「他问我说了几次」这类句子会解析出不是人名的碎片，别抢答
                for (NSString *bad in @[@"说", @"讲", @"问", @"看", @"想", @"觉得", @"知道", @"时候", @"怎么"]) {
                    if ([who rangeOfString:bad].location != NSNotFound) return nil;
                }
                if (who.length < 2) return nil;
                NSMutableArray *names = [NSMutableArray array];
                for (NSDictionary *entry in [InsMemory nameIndex]) {
                    if (names.count >= 5) break;
                    [names addObject:entry[@"name"]];
                }
                return [NSString stringWithFormat:
                    @"没找到「%@」这个会话。%@\n"
                    @"要么把他的会话打开、在里面发「%@ 数 %@」（数这个会话的人），"
                    @"要么用聊天列表里的备注名再试：%@ 数 <备注名> %@。",
                    who,
                    names.count ? [NSString stringWithFormat:@"我这边能按名字找到的有：%@。", [names componentsJoinedByString:@"、"]] : @"",
                    [InsConfig shared].trigger, keyword,
                    [InsConfig shared].trigger, keyword];
            }
            NSDictionary *best = candidates.firstObject;
            target = best[@"wxid"];
            label = best[@"name"];
            if (candidates.count > 1) {
                NSMutableArray *names = [NSMutableArray array];
                for (NSDictionary *c in candidates) {
                    if (names.count >= 3) break;
                    [names addObject:c[@"name"]];
                }
                note = [NSString stringWithFormat:@"（同名/相近的有 %lu 个：%@…，先按「%@」算）",
                        (unsigned long)candidates.count,
                        [names componentsJoinedByString:@"、"], label];
            }
        } else {
            note = @"（就在这个会话里数的）";
        }
    }
    [InsConfig log:[NSString stringWithFormat:@"统计：who=%@ 关键词=%@ 会话=%@ 范围=%@",
                    who.length ? who : @"(当前)", keyword, target, from]];

    NSDictionary *stats = [InsHistory keywordStatsForTalker:target keyword:keyword samples:5];
    NSUInteger total = [stats[@"total"] unsignedIntegerValue];
    NSUInteger fromMe = [stats[@"fromMe"] unsignedIntegerValue];
    NSUInteger fromPartner = [stats[@"fromPartner"] unsignedIntegerValue];
    NSUInteger textTotal = [stats[@"textTotal"] unsignedIntegerValue];
    NSUInteger compressed = [stats[@"compressed"] unsignedIntegerValue];
    BOOL group = [target hasSuffix:@"@chatroom"];

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"【统计】%@ 的会话 · 关键词「%@」", label, keyword];
    if (note.length) [out appendFormat:@"\n%@", note];
    if (!total) {
        [out appendFormat:@"\n没查到含「%@」的消息。\n扫描范围：该会话本地可读文本 %lu 条",
         keyword, (unsigned long)textTotal];
        if (compressed) [out appendFormat:@"（另有 %lu 条压缩消息读不出字面）", (unsigned long)compressed];
        [out appendString:@"\n可能原因：这段聊天不在这台手机上，或者这句话里没有这个写法。"];
        [out appendFormat:@"\n换个更短的词再试：「%@ 数 %@」。", [InsConfig shared].trigger,
         keyword.length > 4 ? [keyword substringToIndex:4] : keyword];
        return out;
    }

    if (group) {
        [out appendFormat:@"\n群里提到「%@」的消息共 %lu 条（群消息只能分「你」和「其他人」，分不出具体是谁）", keyword, (unsigned long)total];
        [out appendFormat:@"\n- 你：%lu 条\n- 其他人：%lu 条", (unsigned long)fromMe, (unsigned long)fromPartner];
    } else {
        if ([from isEqualToString:@"me"]) {
            [out appendFormat:@"\n- 你 说了 %lu 条", (unsigned long)fromMe];
        } else if ([from isEqualToString:@"partner"]) {
            [out appendFormat:@"\n- %@ 说了 %lu 条", label, (unsigned long)fromPartner];
            if (fromMe) [out appendFormat:@"\n- 你 说了 %lu 条（合计 %lu）", (unsigned long)fromMe, (unsigned long)total];
        } else {
            [out appendFormat:@"\n- %@：%lu 条\n- 你：%lu 条（合计 %lu）",
             label, (unsigned long)fromPartner, (unsigned long)fromMe, (unsigned long)total];
        }
    }
    uint32_t first = [stats[@"first"] unsignedIntValue], last = [stats[@"last"] unsignedIntValue];
    if (first) {
        [out appendFormat:@"\n时间跨度：%@ ~ %@",
         InsStatTime(first, @"yyyy-MM-dd HH:mm"), InsStatTime(last, @"yyyy-MM-dd HH:mm")];
    }
    [out appendFormat:@"\n数据来源：本地聊天库可读文本 %lu 条", (unsigned long)textTotal];
    if (compressed) {
        [out appendFormat:@"（另有 %lu 条压缩消息读不出字面，可能漏计）", (unsigned long)compressed];
    }
    NSArray *samples = stats[@"samples"];
    if ([samples isKindOfClass:[NSArray class]] && samples.count) {
        [out appendString:@"\n最近几条："];
        for (NSDictionary *row in samples) {
            NSString *text = row[@"text"];
            if (text.length > 50) text = [[text substringToIndex:50] stringByAppendingString:@"…"];
            NSString *speaker = [InsMemory speakerLabelForMe:[row[@"me"] boolValue] talker:target speakerName:nil];
            [out appendFormat:@"\n%@ %@：%@", InsStatTime([row[@"t"] unsignedIntValue], @"MM-dd HH:mm"),
             speaker, text];
        }
    }
    [out appendFormat:@"\n（按字面匹配统计，同音/近义词不算；发「%@ 数 %@ <词>」可指定别的词）",
     [InsConfig shared].trigger, label];
    return out;
}

#pragma mark - 人名簿

/// 通讯录枚举接口在这台机器上恒为 0（getAllFriendContact 返回 nil），
/// 但按 wxid 单查是好的。所以平时见到谁的消息就记一笔「名字 → wxid」，
/// 按名字找人（代发、授权、查人）先翻这本簿子，不再完全依赖通讯录。
static NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *gNameBook = nil;
static NSTimeInterval gNameBookSavedAt = 0;

static NSString *InsStatNameBookPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs.length) return nil;
    NSString *dir = [docs stringByAppendingPathComponent:@"Insomnia"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"names.json"];
}

static void InsStatNameBookLoad(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gNameBook = [NSMutableDictionary dictionary];
        NSString *path = InsStatNameBookPath();
        NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:[NSDictionary class]]) return;
        for (NSString *wxid in (NSDictionary *)json) {
            NSArray *names = ((NSDictionary *)json)[wxid];
            if (![names isKindOfClass:[NSArray class]]) continue;
            gNameBook[wxid] = [names mutableCopy];
        }
    });
}

/// 写盘节流：连着来一串消息时别每条都落盘
static void InsStatNameBookSave(BOOL force) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && now - gNameBookSavedAt < 3) return;
    NSString *path = InsStatNameBookPath();
    if (!path) return;
    NSDictionary *snapshot = nil;
    @synchronized ([InsStat class]) { snapshot = [gNameBook copy]; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    if (data) {
        [data writeToFile:path atomically:YES];
        gNameBookSavedAt = now;
    }
}

+ (void)learnName:(NSString *)name forWxid:(NSString *)wxid {
    NSString *w = InsStatClean(wxid ?: @"");
    NSString *n = InsStatClean(name ?: @"");
    if (w.length < 3 || !n.length) return;
    if ([n isEqualToString:w]) return;
    InsStatNameBookLoad();
    BOOL added = NO;
    @synchronized ([InsStat class]) {
        NSMutableArray *names = gNameBook[w];
        if (!names) {
            names = [NSMutableArray array];
            gNameBook[w] = names;
        }
        if (![names containsObject:n]) {
            [names addObject:n];
            // 一个人可能有备注、昵称、微信号多个名字，留最近 6 个够用
            if (names.count > 6) [names removeObjectAtIndex:0];
            added = YES;
        }
    }
    if (added) InsStatNameBookSave(NO);
}

/// 人名簿里有几条（报错文案里用来区分「没这个人」和「一本簿子都没记」）
static NSUInteger InsStatNameBookCount(void) {
    InsStatNameBookLoad();
    @synchronized ([InsStat class]) { return gNameBook.count; }
}

#pragma mark - 找人

+ (NSUInteger)knownContactCount {
    // 通讯录 + 人名簿（通讯录读不到时，至少还能说清楚「手里有几个名字」）
    NSUInteger contacts = InsStatContactNames().count;
    NSUInteger book = InsStatNameBookCount();
    return MAX(contacts, book);
}

+ (NSString *)contactSource {
    InsStatContactNames();      // 触发一次读取，顺便把来源记下来
    NSString *src = gStatContactSource ?: @"还没读到";
    NSUInteger book = InsStatNameBookCount();
    if (book) src = [NSString stringWithFormat:@"%@+人名簿 %lu 人", src, (unsigned long)book];
    return src;
}

+ (NSString *)searchReport:(NSString *)keyword {
    NSString *q = InsStatClean(keyword ?: @"");
    NSString *trigger = [InsConfig shared].trigger;
    if (!q.length) {
        return [NSString stringWithFormat:@"用法：%@ 查人 <名字或其中几个字>\n会列出备注名、昵称和 wxid，授权时可以直接用 wxid。", trigger];
    }
    NSArray *cs = [self candidatesForName:q];
    NSUInteger total = InsStatContactNames().count;
    if (!cs.count) {
        return [NSString stringWithFormat:
                @"没匹配到「%@」。\n通讯录读到 %lu 个联系人（来源：%@）。\n"
                @"如果这里数字是 0，说明这台机器的通讯录库读不出来，可以直接发 wxid：%@ 授权 林健 wxid_xxx",
                q, (unsigned long)total, [self contactSource], trigger];
    }
    NSMutableArray *lines = [NSMutableArray array];
    for (NSDictionary *c in cs) {
        if (lines.count >= 12) break;
        [lines addObject:[NSString stringWithFormat:@"%@  %@", c[@"name"], c[@"wxid"]]];
    }
    return [NSString stringWithFormat:@"匹配到 %lu 人（通讯录共 %lu 个，来源：%@）：\n%@%@",
            (unsigned long)cs.count, (unsigned long)total, [self contactSource],
            [lines componentsJoinedByString:@"\n"],
            cs.count > lines.count ? @"\n…（只列前 12 个）" : @""];
}

@end
