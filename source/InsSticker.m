#import "InsSticker.h"
#import "InsConfig.h"
#import "InsMCP.h"
#import "InsSend.h"
#include <stdatomic.h>

static void InsSNote(NSString *line) {
    [InsConfig log:[@"斗图： " stringByAppendingString:(line ?: @"")]];
}

static NSString *InsSRoot(void) { return [InsConfig rootDir]; }
static NSString *InsSIndexPath(void) { return [InsSRoot() stringByAppendingPathComponent:@"stickers.json"]; }
static NSString *InsSMinePath(void) { return [InsSRoot() stringByAppendingPathComponent:@"stickers_mine.json"]; }
static NSString *InsSCursorPath(void) { return [InsSRoot() stringByAppendingPathComponent:@"sticker_cursor.json"]; }
static NSString *InsSOwnDir(void) { return [InsSRoot() stringByAppendingPathComponent:@"stickers"]; }

static NSObject *gLock = nil;
static NSArray<NSDictionary *> *gItems = nil;
static NSDictionary *gMeta = nil;
static NSMutableDictionary *gLastFire = nil;
static NSMutableDictionary *gFireWindow = nil;
static NSMutableDictionary *gLastPicked = nil;
static NSUInteger gCursor = 0;
static dispatch_queue_t gQueue = nil;
static _Atomic BOOL gBusy = false;
/// 本次进程里「我发出的表情」条数。斗图前后比一下，就知道一次任务到底发了几张
static _Atomic NSUInteger gOwnSent = 0;

static void InsSInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLock = [NSObject new];
        gLastFire = [NSMutableDictionary dictionary];
        gFireWindow = [NSMutableDictionary dictionary];
        gLastPicked = [NSMutableDictionary dictionary];
        gQueue = dispatch_queue_create("com.xuezeng.insomnia.sticker", DISPATCH_QUEUE_SERIAL);
        gItems = @[];
        gMeta = @{};
        NSData *raw = [NSData dataWithContentsOfFile:InsSIndexPath()];
        NSDictionary *db = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : nil;
        if ([db isKindOfClass:[NSDictionary class]]) {
            if ([db[@"items"] isKindOfClass:[NSArray class]]) gItems = db[@"items"];
            gMeta = db;
        }
        NSData *cursorRaw = [NSData dataWithContentsOfFile:InsSCursorPath()] ?: [NSData data];
        NSDictionary *cur = [NSJSONSerialization JSONObjectWithData:cursorRaw options:0 error:nil];
        if ([cur isKindOfClass:[NSDictionary class]]) gCursor = [cur[@"cursor"] unsignedIntegerValue];
        [[NSFileManager defaultManager] createDirectoryAtPath:InsSOwnDir()
                              withIntermediateDirectories:YES attributes:nil error:nil];
    });
}

/// 只读主线程 API（MMServiceCenter / UIKit）统一走这里，避免后台线程取服务拿到 nil
static void InsSMainSync(void (^block)(void)) {
    if (!block) return;
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

static NSString *InsSImageKind(NSData *d) {
    if (d.length < 4) return nil;
    const unsigned char *b = d.bytes;
    if (b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') return @"png";
    if (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return @"jpg";
    if (d.length >= 6 && b[0] == 'G' && b[1] == 'I' && b[2] == 'F') return @"gif";
    return nil;
}

static NSData *InsSHead(NSString *path) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;
    NSData *head = [fh readDataOfLength:8];
    [fh closeFile];
    return head;
}

static NSString *InsSAttr(NSString *xml, NSString *name) {
    if (!xml.length) return nil;
    NSString *pattern = [NSString stringWithFormat:@"%@=\"([^\"]*)\"", name];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                              options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
    return m ? [xml substringWithRange:[m rangeAtIndex:1]] : nil;
}

static NSString *InsSFirstString(id obj, NSArray *keys) {
    if (!obj) return nil;
    for (NSString *key in keys) {
        @try {
            id value = [obj valueForKey:key];
            if ([value isKindOfClass:[NSString class]] && [value length]) return value;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

/// 微信自己的自定义/收藏表情列表（CEmoticonMgr）。拿不到也不影响后面的兜底路径
static NSArray *InsSWraps(NSString **outClass) {
    __block NSArray *list = nil;
    __block NSString *className = nil;
    InsSMainSync(^{
        Class center = NSClassFromString(@"MMServiceCenter");
        Class mgrClass = NSClassFromString(@"CEmoticonMgr");
        if (!center || !mgrClass) return;
        SEL dcSel = NSSelectorFromString(@"defaultCenter");
        if (![center respondsToSelector:dcSel]) return;
        id dc = [center performSelector:dcSel];
        SEL get = NSSelectorFromString(@"getService:");
        if (![dc respondsToSelector:get]) return;
        id mgr = [dc performSelector:get withObject:mgrClass];
        if (!mgr) return;
        className = NSStringFromClass([mgr class]);
        SEL sel = NSSelectorFromString(@"GetEmoticonList");
        if ([mgr respondsToSelector:sel]) {
            id value = [mgr performSelector:sel];
            if ([value isKindOfClass:[NSArray class]]) list = value;
        }
    });
    if (outClass) *outClass = className;
    return list;
}

/// 递归扫表情目录里的图片文件，最多两层、最多 300 张
static void InsSScanDir(NSString *dir, NSMutableArray *items, NSMutableSet *seen, NSInteger depth) {
    if (depth > 2 || items.count >= 300) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
        if (items.count >= 300) return;
        NSString *path = [dir stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir]) continue;
        if (isDir) { InsSScanDir(path, items, seen, depth + 1); continue; }
        if ([seen containsObject:path]) continue;
        NSString *kind = InsSImageKind(InsSHead(path));
        if (!kind) continue;               // 跳过 wxgf / 配置 / 占位文件
        NSNumber *size = [fm attributesOfItemAtPath:path error:nil][NSFileSize];
        if ([size unsignedIntegerValue] < 1024) continue;
        [seen addObject:path];
        [items addObject:@{@"md5": [[name stringByDeletingPathExtension] lowercaseString],
                           @"path": path, @"kind": kind,
                           @"bytes": size ?: @0}];
    }
}

static NSUInteger InsSBumpCursor(void) {
    @synchronized (gLock) {
        gCursor++;
        [[NSJSONSerialization dataWithJSONObject:@{@"cursor": @(gCursor)} options:0 error:nil]
         writeToFile:InsSCursorPath() atomically:YES];
        return gCursor - 1;
    }
}

/// 只记「我发过的表情」，作为素材积累与诊断；去重后最多留 300 条
static void InsSRememberMine(NSString *md5, NSString *cdn, NSString *xml) {
    if (!md5.length) return;
    @synchronized (gLock) {
        NSData *raw = [NSData dataWithContentsOfFile:InsSMinePath()];
        NSMutableArray *arr = raw ? [[NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] mutableCopy] : nil;
        if (![arr isKindOfClass:[NSMutableArray class]]) arr = [NSMutableArray array];
        NSMutableIndexSet *dup = [NSMutableIndexSet indexSet];
        [arr enumerateObjectsUsingBlock:^(id old, NSUInteger idx, BOOL *stop) {
            if ([old isKindOfClass:[NSDictionary class]] && [old[@"md5"] isEqual:md5]) [dup addIndex:idx];
        }];
        [arr removeObjectsAtIndexes:dup];
        NSString *brief = xml.length > 300 ? [xml substringToIndex:300] : (xml ?: @"");
        [arr addObject:@{@"md5": md5, @"cdnurl": cdn ?: @"", @"xml": brief}];
        while (arr.count > 300) [arr removeObjectAtIndex:0];
        [[NSJSONSerialization dataWithJSONObject:arr options:0 error:nil]
         writeToFile:InsSMinePath() atomically:YES];
    }
}

/// 同一会话的冷却 + 每分钟上限，防止对方连发表情时把聊天刷爆
static BOOL InsSAllowFire(NSString *talker, NSString **why) {
    InsConfig *cfg = [InsConfig shared];
    NSDate *now = [NSDate date];
    @synchronized (gLock) {
        NSInteger cool = cfg.stickerBattleCooldown > 0 ? cfg.stickerBattleCooldown : 8;
        NSDate *last = gLastFire[talker];
        if (last && [now timeIntervalSinceDate:last] < cool) {
            *why = [NSString stringWithFormat:@"距上次不到 %ld 秒", (long)cool];
            return NO;
        }
        NSMutableArray *win = gFireWindow[talker];
        if (!win) { win = [NSMutableArray array]; gFireWindow[talker] = win; }
        NSMutableIndexSet *expired = [NSMutableIndexSet indexSet];
        [win enumerateObjectsUsingBlock:^(NSDate *d, NSUInteger idx, BOOL *stop) {
            if ([now timeIntervalSinceDate:d] > 60) [expired addIndex:idx];
        }];
        [win removeObjectsAtIndexes:expired];
        NSInteger cap = cfg.stickerBattleMaxPerMinute > 0 ? cfg.stickerBattleMaxPerMinute : 4;
        if (win.count >= cap) {
            *why = [NSString stringWithFormat:@"一分钟内已经回过 %ld 张", (long)cap];
            return NO;
        }
        [win addObject:now];
        gLastFire[talker] = now;
        return YES;
    }
}

// ------- UI：微信表情面板 -------

static NSArray *InsSUI(void) {
    return [[InsMCP shared] uiElements][@"elements"] ?: @[];
}

static NSString *InsSText(NSDictionary *e) {
    id t = e[@"text"];
    return [t isKindOfClass:[NSString class]] ? t : @"";
}

static NSDictionary *InsSRect(NSDictionary *e) {
    NSDictionary *r = e[@"visible_rect"] ?: e[@"rect"];
    return [r isKindOfClass:[NSDictionary class]] ? r : nil;
}

static NSDictionary *InsSCenter(NSDictionary *e) {
    NSDictionary *r = InsSRect(e);
    if (!r) return nil;
    CGFloat x = [r[@"x"] doubleValue] + [r[@"width"] doubleValue] / 2.0;
    CGFloat y = [r[@"y"] doubleValue] + [r[@"height"] doubleValue] / 2.0;
    return @{@"x": @(x), @"y": @(y)};
}

static void InsSTap(NSDictionary *point) {
    if (!point) return;
    [[InsMCP shared] callTool:@"tap_screen"
                         args:@{@"x": point[@"x"], @"y": point[@"y"]} error:NULL];
}

static BOOL InsSHasText(NSArray *elements, NSString *word) {
    for (NSDictionary *e in elements) {
        if ([e isKindOfClass:[NSDictionary class]] &&
            [InsSText(e) rangeOfString:word].location != NSNotFound) return YES;
    }
    return NO;
}

/// 把读到的界面元素打进日志：手机不在电脑旁边时，用户贴一份日志就能照着修定位规则
static void InsSLogElements(NSString *stage, NSArray *elements) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSDictionary *e in elements) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *c = InsSCenter(e);
        NSString *t = InsSText(e);
        if (t.length > 12) t = [t substringToIndex:12];
        [parts addObject:[NSString stringWithFormat:@"%@@%.0f,%.0f", t,
                          c ? [c[@"x"] doubleValue] : 0, c ? [c[@"y"] doubleValue] : 0]];
        if (parts.count >= 45) break;
    }
    InsSNote([NSString stringWithFormat:@"%@ 元素 %lu 个：%@", stage,
              (unsigned long)elements.count, [parts componentsJoinedByString:@" | "]]);
}

/// 先按无障碍文案找笑脸按钮；找不到就用「更多」(加号) 的位置往左推一格。
/// y 门槛不能写死 560：键盘收起时表情按钮在 782，键盘弹出时整行抬到 449
/// （实测就是这么报「聊天界面没找到表情按钮」的）。消息气泡的文案是「我,表情」，
/// 精确匹配「表情」不会把它当成按钮。
static NSDictionary *InsSFindEmojiButton(NSArray *elements) {
    NSDictionary *plus = nil;
    for (NSDictionary *e in elements) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *c = InsSCenter(e);
        if (!c || [c[@"y"] doubleValue] < 380) continue;
        NSString *t = InsSText(e);
        NSString *low = [t lowercaseString];
        if ([t isEqualToString:@"表情"] || [t isEqualToString:@"表情按钮"] ||
            [t rangeOfString:@"笑脸"].location != NSNotFound ||
            [low rangeOfString:@"emoji"].location != NSNotFound ||
            [low rangeOfString:@"emoticon"].location != NSNotFound) return c;
        if ([t isEqualToString:@"更多"] || [t isEqualToString:@"加号"]) plus = c;
    }
    if (plus) {
        CGFloat x = [plus[@"x"] doubleValue] - 48;
        if (x > 20) return @{@"x": @(x), @"y": plus[@"y"]};
    }
    return nil;
}

/// 表情面板顶部的「收藏 / 自定义表情」页签。
/// 这一行在输入栏上方，y 约 460~528。**不能只判 y>=690**：表情格子自己的无障碍文案
/// 也叫「收藏的表情」，y 从 540 一直排到 836，早先的写法会把第 4 行的格子当成页签点一下
/// —— 在微信里点格子就是直接发出去，等于白送对方一张（实测一次连发三张就是这么来的）。
static NSDictionary *InsSFindFavoriteTab(NSArray *elements) {
    for (NSDictionary *e in elements) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *c = InsSCenter(e);
        if (!c) continue;
        CGFloat y = [c[@"y"] doubleValue];
        if (y < 455 || y > 528) continue;                 // 只认页签行
        NSString *t = InsSText(e);
        if ([t isEqualToString:@"收藏的表情"]) continue;   // 这是格子文案，不是页签
        if ([t rangeOfString:@"搜索"].location != NSNotFound) continue;
        for (NSString *w in @[@"收藏", @"自定义", @"爱心", @"我的表情", @"个人表情",
                              @"添加的", @"单个表情"]) {
            if ([t rangeOfString:w].location != NSNotFound) return c;
        }
    }
    return nil;
}

/// 表情面板里的格子：尺寸像表情位、位置在面板中间区域，排除发送/删除/搜索等按钮
static NSArray *InsSFindCells(NSArray *elements) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *excluded = @[@"发送", @"删除", @"更多", @"表情", @"搜索", @"返回", @"关闭", @"设置"];
    for (NSDictionary *e in elements) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *r = InsSRect(e);
        NSDictionary *c = InsSCenter(e);
        if (!r || !c) continue;
        CGFloat w = [r[@"width"] doubleValue], h = [r[@"height"] doubleValue];
        CGFloat y = [c[@"y"] doubleValue];
        if (w < 32 || w > 170 || h < 32 || h > 150) continue;
        // 面板网格：页签行 484，格子从 540 起，每行 80；到 780 为止（836 已出可视区）
        if (y < 528 || y > 812) continue;
        NSString *t = InsSText(e);
        if ([excluded containsObject:t]) continue;
        if ([t rangeOfString:@"设置"].location != NSNotFound ||
            [t rangeOfString:@"搜索"].location != NSNotFound) continue;
        // 收藏页第一行上方那格「添加的单个表情」是按钮，点它只会打开添加页，不是发表情
        if ([t isEqualToString:@"添加的单个表情"]) continue;
        if ([t isEqualToString:@"最近使用"] || [t isEqualToString:@"所有表情"] ||
            [t isEqualToString:@"黄脸表情"] || [t isEqualToString:@"我的自拍表情"] ||
            [t isEqualToString:@"长辈聊天专属"] || [t isEqualToString:@"纯文字表情包"]) continue;
        [out addObject:@{@"x": c[@"x"], @"y": c[@"y"], @"text": t}];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        CGFloat ay = [a[@"y"] doubleValue], by = [b[@"y"] doubleValue];
        if (fabs(ay - by) > 30) return ay < by ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"x"] doubleValue] < [b[@"x"] doubleValue] ? NSOrderedAscending : NSOrderedDescending;
    }];
    return out;
}

/// 收起表情面板：点面板底部的「键盘」按钮切回输入键盘。
/// 千万不要拿「打开面板前」读到的表情按钮坐标去点 —— 那时面板还开着，同一位置已经
/// 变成第 4 列的表情格子，点一下又是一张（实测一次斗图连发三张，第三张就是这么来的）。
static BOOL InsSCloseBoard(void) {
    NSArray *now = InsSUI();
    for (NSDictionary *e in now) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *c = InsSCenter(e);
        if (!c) continue;
        if ([c[@"y"] doubleValue] < 400) continue;      // 只看底部输入栏那一行
        NSString *t = InsSText(e);
        if ([t isEqualToString:@"键盘"]) {
            InsSTap(c);
            InsSNote([NSString stringWithFormat:@"收面板：点「键盘」(%.0f,%.0f)",
                      [c[@"x"] doubleValue], [c[@"y"] doubleValue]]);
            return YES;
        }
    }
    InsSNote(@"收面板：没找到「键盘」按钮，不盲点（盲点会误发一张）");
    return NO;
}

/// 聊天区里「我发的表情气泡」个数。点击后用它确认真的发出去了 ——
/// 不能只靠消息回调计数：微信有时自己发出去的消息不走 AsyncOnAddMsg（实测有过，
/// fromMe 计数没涨、会话里其实已经多了一张，那会让上层误判为「没发出去」继续点）。
static NSUInteger InsSCountMyBubbles(NSArray *elements) {
    NSUInteger n = 0;
    for (NSDictionary *e in elements) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        if ([InsSText(e) hasPrefix:@"我,表情"]) n++;
    }
    return n;
}

/// 走微信原生表情面板发一张（发出去的是真正的表情消息）。成功返回 nil，失败返回原因
static NSString *InsSSendViaBoard(void) {
    NSArray *before = InsSUI();
    InsSLogElements(@"点表情前", before);
    NSDictionary *button = InsSFindEmojiButton(before);
    // 上一次失败可能把面板留在打开状态：这时聊天界面找不到表情按钮，但格子已经在屏幕上，
    // 硬要按钮只会判失败、白丢一次斗图
    BOOL boardOpen = (InsSFindCells(before).count >= 3) && InsSHasText(before, @"键盘");
    if (!button && !boardOpen) return @"聊天界面没找到表情按钮（把 @insomnia log 发来看元素）";
    if (button && !boardOpen) {
        InsSTap(button);
        [NSThread sleepForTimeInterval:1.3];
    } else {
        InsSNote(@"进来时表情面板已经开着，直接挑格子");
    }

    NSArray *opened = InsSUI();
    InsSLogElements(@"表情面板", opened);
    // get_ui_elements 最多返回 120 个，前后都可能被截断，光比元素个数会误判；
    // 所以再认几个只有表情面板才会出现的文案
    BOOL looksOpen = opened.count >= before.count + 3 ||
                     InsSHasText(opened, @"收藏") || InsSHasText(opened, @"自定义") ||
                     InsSHasText(opened, @"爱心") || InsSHasText(opened, @"最近使用") ||
                     InsSFindCells(opened).count >= 3;
    if (!looksOpen) {
        InsSCloseBoard();      // 面板可能只是没认出来：有「键盘」就收起，没有就不动
        return @"点了表情按钮但没看到表情面板（元素列表已写进日志），改用图片兜底";
    }

    NSArray *page = opened;
    NSDictionary *favorite = InsSFindFavoriteTab(opened);
    if (favorite) {
        InsSTap(favorite);
        [NSThread sleepForTimeInterval:1.0];
        page = InsSUI();
        InsSLogElements(@"收藏表情页", page);
    } else {
        InsSNote(@"没找到「收藏/自定义表情」入口，直接用当前表情页");
    }

    // 点一格 → 确认真的发出去了 → 没发就换下一格。表情面板里有些格子（动图、占位格）
    // 点了没反应，有些（带名字的）一点就发；早先「只点一次就当成功」会既可能白点，
    // 也可能因为盲点连发好几张。这里每点一次都核对「我发出的表情」计数：
    // 一旦 +1 立刻停手，绝不点第二下。
    NSUInteger seq = InsSBumpCursor();
    NSUInteger attempts = 0;
    BOOL sent = NO;
    NSUInteger bubbles = InsSCountMyBubbles(InsSUI());
    while (attempts < 3 && !sent) {
        NSArray *pageNow = (attempts == 0) ? page : InsSUI();
        NSArray *cells = InsSFindCells(pageNow);
        NSDictionary *target = nil;
        if (cells.count >= 3) {
            NSUInteger idx = (seq + attempts) % cells.count;
            target = cells[idx];
            InsSNote([NSString stringWithFormat:@"面板读到 %lu 个表情位，点第 %lu 个（%@）(%.0f,%.0f)",
                      (unsigned long)cells.count, (unsigned long)idx + 1,
                      target[@"text"] ?: @"无文字",
                      [target[@"x"] doubleValue], [target[@"y"] doubleValue]]);
        } else {
            // 表情格子常常没有无障碍文案，读不到时按 4 列网格兜底点一个
            NSUInteger k = (seq + attempts) % 8;
            CGFloat x = 48 + (k % 4) * 98;
            CGFloat y = 607 + (k / 4) * 80;
            target = @{@"x": @(x), @"y": @(y)};
            InsSNote([NSString stringWithFormat:@"面板只识别到 %lu 个表情位（可能不是格子），"
                      @"用网格坐标兜底点 (%.0f,%.0f)", (unsigned long)cells.count, x, y]);
        }
        NSUInteger mark = atomic_load(&gOwnSent);
        InsSTap(target);
        [NSThread sleepForTimeInterval:0.9];
        NSArray *afterTap = InsSUI();
        NSUInteger nowBubbles = InsSCountMyBubbles(afterTap);
        sent = (atomic_load(&gOwnSent) > mark) || (nowBubbles > bubbles);
        if (sent) {
            bubbles = nowBubbles;
        } else {
            InsSNote(@"这一下没发出表情，换下一格再试");
        }
        attempts += 1;
    }
    // 自定义表情点一下就发出去了；再切回输入键盘（必须找「键盘」按钮，别盲点表情按钮）
    InsSCloseBoard();
    if (!sent) return @"点了几个表情位都没有发出去（可能都是动图/占位格）";
    return nil;
}

/// 保证微信在前台、且停在目标会话（表情面板和相册发送都要求聊天界面开着）
static BOOL InsSEnsureChat(NSString *talker, NSString *chatName) {
    InsMCP *mcp = [InsMCP shared];
    NSString *front = [mcp textOfTool:@"get_frontmost_app" args:@{} error:NULL] ?: @"";
    if ([front rangeOfString:@"com.tencent.xin"].location == NSNotFound) {
        [mcp callTool:@"launch_app" args:@{@"bundle_id": @"com.tencent.xin"} error:NULL];
        [NSThread sleepForTimeInterval:2.5];
    }
    if ([InsSend isChatOpen:talker]) return YES;
    NSString *name = chatName.length ? chatName : talker;
    if (![InsSend openChatNamed:name]) return NO;
    [NSThread sleepForTimeInterval:2.0];
    return [InsSend isChatOpen:talker];
}

/// 从表情库里轮换挑一张（尽量别和上一张重复），返回图片字节
static NSData *InsSPickImage(NSString *talker) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *usable = [NSMutableArray array];
    for (NSDictionary *item in [InsSticker library]) {
        NSString *path = item[@"path"];
        if ([path isKindOfClass:[NSString class]] && [fm fileExistsAtPath:path]) [usable addObject:item];
    }
    if (!usable.count) return nil;
    NSUInteger seq = InsSBumpCursor();
    NSUInteger idx = seq % usable.count;
    NSString *last = nil;
    @synchronized (gLock) { last = gLastPicked[talker]; }
    if (usable.count > 1 && [usable[idx][@"md5"] isEqual:last]) idx = (idx + 1) % usable.count;
    NSDictionary *item = usable[idx];
    @synchronized (gLock) { gLastPicked[talker] = item[@"md5"] ?: @""; }
    NSData *data = [NSData dataWithContentsOfFile:item[@"path"]];
    if (!InsSImageKind(data)) return nil;
    InsSNote([NSString stringWithFormat:@"用表情库图片 %@（%@，%lu 字节）",
              item[@"md5"], item[@"kind"], (unsigned long)data.length]);
    return data;
}

static NSString *InsSPerform(NSString *talker) {
    InsConfig *cfg = [InsConfig shared];
    NSString *mode = cfg.stickerBattleMode.length ? cfg.stickerBattleMode : @"auto";
    NSString *chatName = [InsSend displayNameForTalker:talker];
    if (!InsSEnsureChat(talker, chatName)) {
        return @"斗图失败：进不去目标会话（微信没在前台，或找不到这个聊天）";
    }
    if (![mode isEqualToString:@"image"]) {
        NSString *reason = InsSSendViaBoard();
        if (!reason) return @"斗图完成：已通过微信表情面板回了一张";
        InsSNote([@"表情面板不可用： " stringByAppendingString:reason]);
        if ([mode isEqualToString:@"board"]) {
            return [@"斗图失败： " stringByAppendingString:reason];
        }
    }
    NSData *image = InsSPickImage(talker);
    if (!image.length) {
        return @"斗图失败：表情面板没打开，本地表情库也没有可用图片；"
                @"可发「@insomnia 斗图 图片」强制走图片，或「@insomnia 表情包」看库里有什么";
    }
    __block NSString *failure = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [InsSend sendImageData:image toTalker:talker chatName:chatName completion:^(NSString *f) {
        failure = f;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90 * NSEC_PER_SEC)));
    return failure ? [@"斗图失败（图片通道）：" stringByAppendingString:failure]
                   : @"斗图完成：已用表情库图片回了一张";
}

@implementation InsSticker

+ (BOOL)battleEnabled { return [InsConfig shared].stickerBattleEnabled; }
+ (NSString *)battleMode { return [InsConfig shared].stickerBattleMode ?: @"auto"; }
+ (void)setEnabled:(BOOL)on { [[InsConfig shared] setStickerBattleEnabledPersisted:on]; }
+ (void)setMode:(NSString *)mode { [[InsConfig shared] setStickerBattleModePersisted:mode]; }

+ (void)bootstrap {
    InsSInit();
    // 启动时扫一次库，别在收到表情的那一刻才做几百次文件 IO
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
        [self refreshLibrary];
    });
}

+ (NSUInteger)refreshLibrary {
    InsSInit();
    NSMutableArray *items = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length) {
        for (NSString *top in [fm contentsOfDirectoryAtPath:docs error:nil] ?: @[]) {
            NSString *account = [docs stringByAppendingPathComponent:top];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:account isDirectory:&isDir] || !isDir) continue;
            if (items.count >= 300) break;
            for (NSString *sub in [fm contentsOfDirectoryAtPath:account error:nil] ?: @[]) {
                NSString *low = [sub lowercaseString];
                BOOL hit = [low rangeOfString:@"emoticon"].location != NSNotFound ||
                           [low rangeOfString:@"emoji"].location != NSNotFound ||
                           [low rangeOfString:@"sticker"].location != NSNotFound;
                if (!hit) continue;
                NSString *folder = [account stringByAppendingPathComponent:sub];
                BOOL folderDir = NO;
                if ([fm fileExistsAtPath:folder isDirectory:&folderDir] && folderDir) {
                    InsSScanDir(folder, items, seen, 0);
                }
            }
        }
        // 也可以自己往 Insomnia/stickers/ 里放图片，作为自定义斗图素材
        InsSScanDir(InsSOwnDir(), items, seen, 0);
    }

    NSString *mgrClass = nil;
    NSArray *wraps = InsSWraps(&mgrClass);
    NSMutableArray *sample = [NSMutableArray array];
    for (id wrap in wraps ?: @[]) {
        NSString *md5 = InsSFirstString(wrap, @[@"m_nsEmoticonMD5", @"m_nsMD5", @"m_nsMd5",
                                                @"md5", @"MD5", @"emoticonMd5"]);
        if (md5.length && sample.count < 5) [sample addObject:md5];
        NSString *path = InsSFirstString(wrap, @[@"m_nsThumbPath", @"m_nsEmoticonPath",
                                                 @"m_nsPath", @"path"]);
        if (!path.length || [seen containsObject:path]) continue;
        if (![path hasPrefix:@"/"]) continue;
        NSString *kind = InsSImageKind(InsSHead(path));
        if (!kind) continue;
        NSNumber *size = [fm attributesOfItemAtPath:path error:nil][NSFileSize];
        [seen addObject:path];
        [items addObject:@{@"md5": (md5 ?: [[path lastPathComponent] lowercaseString]),
                           @"path": path, @"kind": kind, @"bytes": size ?: @0}];
    }

    NSDictionary *db = @{@"updatedAt": @((long long)[[NSDate date] timeIntervalSince1970]),
                         @"mgrClass": mgrClass ?: @"不可用",
                         @"mgrCount": @(wraps.count),
                         @"mgrSample": sample,
                         @"items": items};
    [[NSJSONSerialization dataWithJSONObject:db options:0 error:nil]
     writeToFile:InsSIndexPath() atomically:YES];
    @synchronized (gLock) { gItems = [items copy]; gMeta = db; }
    InsSNote([NSString stringWithFormat:@"表情库刷新：微信自定义表情列表 %lu 条（%@），本地可用图片 %lu 张",
              (unsigned long)wraps.count, mgrClass ?: @"服务不可用", (unsigned long)items.count]);
    return items.count;
}

+ (NSArray<NSDictionary *> *)library {
    InsSInit();
    @synchronized (gLock) { return gItems ?: @[]; }
}

+ (NSString *)debugInfo {
    InsSInit();
    InsConfig *cfg = [InsConfig shared];
    NSArray *items = [self library];
    NSDictionary *meta = nil;
    @synchronized (gLock) { meta = gMeta ?: @{}; }
    NSData *mine = [NSData dataWithContentsOfFile:InsSMinePath()];
    NSArray *mineArr = mine ? [NSJSONSerialization JSONObjectWithData:mine options:0 error:nil] : nil;
    NSMutableArray *sample = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if (sample.count >= 3) break;
        [sample addObject:[NSString stringWithFormat:@"%@(%@)", item[@"md5"] ?: @"?",
                           item[@"kind"] ?: @"?"]];
    }
    return [NSString stringWithFormat:
        @"斗图：%@ / 模式 %@ / 冷却 %ld 秒 / 每分钟最多 %ld 张\n"
        @"表情库：本地图片 %lu 张；微信表情列表 %@ 条（%@）\n"
        @"我发过的表情：%lu 条\n库样例：%@",
        cfg.stickerBattleEnabled ? @"开" : @"关",
        cfg.stickerBattleMode ?: @"auto",
        (long)cfg.stickerBattleCooldown, (long)cfg.stickerBattleMaxPerMinute,
        (unsigned long)items.count, meta[@"mgrCount"] ?: @"0", meta[@"mgrClass"] ?: @"未知",
        (unsigned long)([mineArr isKindOfClass:[NSArray class]] ? mineArr.count : 0),
        sample.count ? [sample componentsJoinedByString:@"、"] : @"(空，发 @insomnia 表情包 刷新)"];
}

+ (void)handleMessage:(NSString *)xml
               talker:(NSString *)talker
               fromMe:(BOOL)fromMe
              allowed:(BOOL)allowed {
    if (!talker.length) return;
    InsSInit();
    NSString *md5 = InsSAttr(xml, @"md5") ?: @"";
    NSString *cdn = InsSAttr(xml, @"cdnurl") ?: @"";
    NSString *pid = InsSAttr(xml, @"productid") ?: @"";
    NSString *emojiType = InsSAttr(xml, @"type") ?: @"";
    InsSNote([NSString stringWithFormat:@"%@表情 md5=%@ type=%@ pid=%@ 会话=%@",
              fromMe ? @"我发" : @"收到", md5.length ? md5 : @"未知",
              emojiType.length ? emojiType : @"-", pid.length ? pid : @"-", talker]);
    if (fromMe) {
        atomic_fetch_add(&gOwnSent, 1);
        InsSRememberMine(md5, cdn, xml);
        return;
    }
    if (!allowed) { InsSNote(@"这个会话不在放行范围，忽略"); return; }
    if (![InsConfig shared].stickerBattleEnabled) return;
    NSString *why = nil;
    if (!InsSAllowFire(talker, &why)) {
        InsSNote([@"限流跳过： " stringByAppendingString:(why ?: @"太频繁")]);
        return;
    }
    [self sendOneTo:talker reply:nil];
}

+ (void)sendOneTo:(NSString *)talker reply:(void (^)(NSString *))reply {
    if (!talker.length) { if (reply) reply(@"会话为空"); return; }
    InsSInit();
    BOOL expected = false;
    if (!atomic_compare_exchange_strong_explicit(&gBusy, &expected, true,
                                                 memory_order_relaxed, memory_order_relaxed)) {
        InsSNote(@"已有斗图任务在跑，这条跳过");
        if (reply) reply(@"上一条表情还在发，稍等几秒再试");
        return;
    }
    dispatch_async(gQueue, ^{
        NSString *result = nil;
        NSUInteger before = atomic_load(&gOwnSent);
        // 任何异常都必须把占坑位释放掉，否则后面所有斗图都会被「上一条还在发」挡住
        @try {
            result = InsSPerform(talker);
        } @catch (NSException *e) {
            result = [NSString stringWithFormat:@"斗图异常：%@", e.reason ?: @"未知"];
        } @finally {
            atomic_store_explicit(&gBusy, false, memory_order_relaxed);
        }
        InsSNote(result ?: @"斗图结束（无结果）");
        // 后验：斗图本该只发一张。多发说明点击又落在表情格子上，日志里直接点名
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       gQueue, ^{
            NSUInteger delta = atomic_load(&gOwnSent) - before;
            if (delta > 1) {
                InsSNote([NSString stringWithFormat:
                          @"警告：这次斗图发了 %lu 张表情（正常只该 1 张），点击位置又误触了",
                          (unsigned long)delta]);
            } else if (delta == 1) {
                InsSNote(@"自检：本次斗图正好发出 1 张");
            } else {
                InsSNote(@"自检：消息回调里没数到自己的表情（微信有时不回调，以会话里实际气泡为准）");
            }
        });
        if (reply) dispatch_async(dispatch_get_main_queue(), ^{ reply(result); });
    });
}

@end
