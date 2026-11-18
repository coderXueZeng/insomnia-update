#import "InsSend.h"
#import "InsConfig.h"
#import "InsMCP.h"
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <sys/select.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <fcntl.h>

static void InsNote(NSString *line) { [InsConfig log:line]; }

static id InsCall1(id target, SEL sel, id arg) {
    if (!target || ![target respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (sig.numberOfArguments != 3) return nil;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
    invocation.target = target;
    invocation.selector = sel;
    [invocation setArgument:&arg atIndex:2];
    @try {
        [invocation invoke];
    } @catch (NSException *e) {
        InsNote([NSString stringWithFormat:@"%@ 异常: %@", NSStringFromSelector(sel), e.reason]);
        return nil;
    }
    __unsafe_unretained id result = nil;
    [invocation getReturnValue:&result];
    return result;
}

static id InsCall0(id target, SEL sel) {
    if (!target || ![target respondsToSelector:sel]) return nil;
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (sig.numberOfArguments != 2) return nil;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
    invocation.target = target;
    invocation.selector = sel;
    @try {
        [invocation invoke];
    } @catch (NSException *e) {
        InsNote([NSString stringWithFormat:@"%@ 异常: %@", NSStringFromSelector(sel), e.reason]);
        return nil;
    }
    __unsafe_unretained id result = nil;
    [invocation getReturnValue:&result];
    return result;
}

static id InsService(NSString *className) {
    Class center = NSClassFromString(@"MMServiceCenter");
    Class service = NSClassFromString(className);
    if (!center || !service) return nil;
    id defaultCenter = [center performSelector:@selector(defaultCenter)];
    return defaultCenter ? InsCall1(defaultCenter, NSSelectorFromString(@"getService:"), service) : nil;
}

static NSString *InsCapabilityReport(void) {
    NSMutableString *out = [NSMutableString string];
    NSArray *classes = @[@"CMessageMgr", @"MMMsgLogicManager", @"MMNewSessionMgr",
                         @"CSessionMgr", @"CContactMgr"];
    for (NSString *cls in classes) {
        id svc = InsService(cls);
        if (!svc) {
            [out appendFormat:@"%@：取不到\n", cls];
            continue;
        }
        unsigned count = 0;
        Method *methods = class_copyMethodList([svc class], &count);
        NSMutableArray *hits = [NSMutableArray array];
        for (unsigned i = 0; i < count && hits.count < 40; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if ([name rangeOfString:@"Send" options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            if ([name rangeOfString:@"Image"].location != NSNotFound) continue;
            if ([name rangeOfString:@"Video"].location != NSNotFound) continue;
            if ([name rangeOfString:@"Voice"].location != NSNotFound) continue;
            NSUInteger args = method_getNumberOfArguments(methods[i]);
            [hits addObject:[NSString stringWithFormat:@"%@/%lu", name, (unsigned long)(args > 2 ? args - 2 : 0)]];
        }
        if (methods) free(methods);
        [out appendFormat:@"%@（%lu 个 Send*）：%@\n", cls, (unsigned long)hits.count,
                          hits.count ? [hits componentsJoinedByString:@" "] : @"无"];
    }
    return out;
}

static NSString *InsName(id object) {
    return object ? NSStringFromClass([object class]) : @"nil";
}

/// 当前打开的聊天界面，且必须就是目标会话（GetLogicController: 对未打开的会话会崩）
static id InsCurrentLogicController(NSString *talker) {
    id manager = InsService(@"MMMsgLogicManager");
    if (!manager) {
        InsNote(@"逻辑管理器不可用");
        return nil;
    }
    SEL current = NSSelectorFromString(@"GetCurrentLogicController");
    if (![manager respondsToSelector:current]) {
        InsNote(@"没有 GetCurrentLogicController");
        return nil;
    }
    id logic = nil;
    @try {
        logic = [manager performSelector:current];
    } @catch (NSException *e) {
        InsNote([NSString stringWithFormat:@"取当前控制器异常: %@", e.reason]);
        return nil;
    }
    if (!logic) {
        InsNote(@"当前没有打开的聊天界面");
        return nil;
    }
    NSString *name = InsCall0(logic, NSSelectorFromString(@"GetContactName"));
    if (talker.length && name.length && ![name isEqualToString:talker]) {
        InsNote([NSString stringWithFormat:@"当前界面是 %@，不是目标 %@", name, talker]);
        return nil;
    }
    return logic;
}

static NSString *InsSendSelectorsOn(id object) {
    if (!object) return @"(nil)";
    NSMutableArray *names = [NSMutableArray array];
    unsigned count = 0;
    Method *methods = class_copyMethodList([object class], &count);
    for (unsigned i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if (![name hasPrefix:@"Send"]) continue;
        if ([name rangeOfString:@"Image"].location != NSNotFound || [name hasPrefix:@"SendText"]) {
            [names addObject:name];
        }
    }
    free(methods);
    return names.count ? [names componentsJoinedByString:@", "] : @"无匹配方法";
}

/// 写入相册，成功返回 PHAsset 的 localIdentifier
static NSString *InsSaveToAlbum(NSData *image, NSString **failure) {
    UIImage *bitmap = [UIImage imageWithData:image];
    if (!bitmap) { *failure = @"图片数据无法解码"; return nil; }
    __block NSString *localIdentifier = nil;
    __block NSError *libraryError = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
        PHAssetChangeRequest *request = [PHAssetChangeRequest creationRequestForAssetFromImage:bitmap];
        localIdentifier = request.placeholderForCreatedAsset.localIdentifier;
    } completionHandler:^(BOOL success, NSError *error) {
        if (!success) libraryError = error;
        dispatch_semaphore_signal(semaphore);
    }];
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC))) != 0) {
        *failure = @"写入相册超时";
        return nil;
    }
    if (libraryError) {
        *failure = [NSString stringWithFormat:@"写入相册失败：%@", libraryError.localizedDescription];
        return nil;
    }
    if (!localIdentifier.length) { *failure = @"相册没有返回资产 ID"; return nil; }
    return localIdentifier;
}

static NSString *InsDiagOnce(NSString *talker) {
    NSMutableString *out = [NSMutableString string];
    Class center = NSClassFromString(@"MMServiceCenter");
    [out appendFormat:@"MMServiceCenter:%@\n", center ? @"有" : @"没有"];
    InsNote([NSString stringWithFormat:@"诊断1 MMServiceCenter=%@", center ? @"有" : @"没有"]);
    id defaultCenter = nil;
    @try {
        defaultCenter = [center performSelector:@selector(defaultCenter)];
    } @catch (NSException *e) {
        [out appendFormat:@"defaultCenter异常:%@\n", e.reason];
    }
    InsNote([NSString stringWithFormat:@"诊断2 defaultCenter=%@", InsName(defaultCenter)]);
    id manager = InsService(@"MMMsgLogicManager");
    [out appendFormat:@"MMMsgLogicManager:%@\n", InsName(manager)];
    InsNote([NSString stringWithFormat:@"诊断3 逻辑管理=%@", InsName(manager)]);
    id contacts = InsService(@"CContactMgr");
    [out appendFormat:@"CContactMgr:%@\n", InsName(contacts)];
    InsNote([NSString stringWithFormat:@"诊断4 联系人管理=%@", InsName(contacts)]);
    id contact = contacts ? InsCall1(contacts, NSSelectorFromString(@"getContactByName:"), talker) : nil;
    [out appendFormat:@"contact(%@):%@\n", talker, InsName(contact)];
    id logic = InsCurrentLogicController(talker);
    [out appendFormat:@"logic:%@\n", InsName(logic)];
    InsNote([NSString stringWithFormat:@"诊断6 logic=%@ 方法=%@", InsName(logic), logic ? InsSendSelectorsOn(logic) : @"-"]);
    return out;
}

static BOOL InsSendTextOnce(NSString *text, NSString *talker) {
    id logic = InsCurrentLogicController(talker);
    if (!logic) {
        // 每次回复都打三行会让日志没法看，只在整条链路失败时留一行结论
        return NO;
    }
    for (NSString *name in @[@"SendTextMessage:", @"SendTextMessage:externInfo:"]) {
        SEL sel = NSSelectorFromString(name);
        if (![logic respondsToSelector:sel]) continue;
        NSMethodSignature *sig = [logic methodSignatureForSelector:sel];
        NSUInteger args = sig.numberOfArguments;
        if (args < 3) continue;
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
        invocation.target = logic;
        invocation.selector = sel;
        [invocation setArgument:&text atIndex:2];
        if (args >= 4) {
            id extra = nil;
            [invocation setArgument:&extra atIndex:3];
        }
        @try {
            [invocation invoke];
            InsNote([NSString stringWithFormat:@"文本发送 ok: %@", name]);
            return YES;
        } @catch (NSException *e) {
            InsNote([NSString stringWithFormat:@"文本发送 %@ 异常: %@", name, e.reason]);
        }
    }
    InsNote([NSString stringWithFormat:@"文本发送失败：%@ 没有可用发送方法",
             NSStringFromClass([logic class])]);
    return NO;
}

/// 内部发图接口会把微信进程打死，改成像人一样点「+」→「照片」→选中→「发送」
static NSDictionary *InsCenter(NSDictionary *element) {
    NSDictionary *rect = element[@"visible_rect"] ?: element[@"rect"];
    if (![rect isKindOfClass:[NSDictionary class]]) return nil;
    CGFloat x = [rect[@"x"] doubleValue] + [rect[@"width"] doubleValue] / 2.0;
    CGFloat y = [rect[@"y"] doubleValue] + [rect[@"height"] doubleValue] / 2.0;
    return @{@"x": @(x), @"y": @(y)};
}

static NSArray *InsScreen(void) {
    return [[InsMCP shared] uiElements][@"elements"] ?: @[];
}

static BOOL InsTapAt(NSDictionary *point) {
    if (!point) return NO;
    [[InsMCP shared] callTool:@"tap_screen" args:point error:NULL];
    return YES;
}

/// 找屏幕下半部分文字完全匹配的元素（避开顶部同名按钮）
static NSDictionary *InsButton(NSArray *elements, NSString *text, CGFloat minY) {
    for (id item in elements) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        if (![item[@"text"] isEqual:text]) continue;
        NSDictionary *point = InsCenter(item);
        if (point && [point[@"y"] doubleValue] >= minY) return point;
    }
    return nil;
}

/// 相册格子文案形如「照片6151,拍摄时间,2026年11月13日 13:39」
static NSArray *InsAlbumCells(NSArray *elements) {
    NSMutableArray *rows = [NSMutableArray array];
    for (id item in elements) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = item[@"text"];
        if (![text isKindOfClass:[NSString class]] || ![text hasPrefix:@"照片"]) continue;
        NSArray *parts = [text componentsSeparatedByString:@","];
        if (parts.count < 3) continue;
        long ordinal = 0;
        BOOL hasDigits = NO;
        NSString *head = parts[0];
        for (NSUInteger i = 2; i < head.length; i++) {
            unichar ch = [head characterAtIndex:i];
            if (ch < '0' || ch > '9') break;
            ordinal = ordinal * 10 + (ch - '0');
            hasDigits = YES;
        }
        if (!hasDigits) continue;
        NSDictionary *point = InsCenter(item);
        if (!point) continue;
        NSString *when = [parts.lastObject stringByReplacingOccurrencesOfString:@" " withString:@""];
        [rows addObject:@{@"ordinal": @(ordinal), @"time": when, @"point": point}];
    }
    return rows;
}

static NSString *InsMinuteStamp(void) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"zh_CN"];
    formatter.dateFormat = @"yyyy年M月d日HH:mm";
    return [formatter stringFromDate:[NSDate date]];
}

/// 会话列表顶部的「搜索」入口，只有在这个页面上才找得到。
/// 微信 8.x 的占位文字是「搜索本地或网络结果」，不再是一个光秃秃的「搜索」，
/// 所以这里改成包含匹配，否则永远当不了「已在会话列表」
static NSDictionary *InsSearchEntry(NSArray *elements) {
    for (id item in elements) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = item[@"text"];
        if (![text isKindOfClass:[NSString class]] || !text.length) continue;
        if ([text rangeOfString:@"搜索"].location == NSNotFound) continue;
        NSDictionary *point = InsCenter(item);
        if (point && [point[@"y"] doubleValue] < 200) return point;
    }
    return nil;
}

/// 会话列表里的目标那一行，形如「林健,[动画表情],15:16」
static NSDictionary *InsChatRow(NSArray *elements, NSString *name) {
    NSString *prefix = [name stringByAppendingString:@","];
    NSDictionary *best = nil;
    CGFloat bestY = CGFLOAT_MAX;
    for (id item in elements) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = item[@"text"];
        if (![text isKindOfClass:[NSString class]] || ![text hasPrefix:prefix]) continue;
        NSDictionary *point = InsCenter(item);
        CGFloat y = point ? [point[@"y"] doubleValue] : 0;
        if (y < 120 || y > 760 || y >= bestY) continue;
        bestY = y;
        best = point;
    }
    return best;
}

/// 搜索结果里的会话条目，形如「林健, 联系人」或「某某群, 群聊」。
/// 新版微信把名字和类型拆成两行，行里可能只剩「张鹏」三个字，所以退一步也认「文字完全等于名字」的那行
static NSDictionary *InsSearchRow(NSArray *elements, NSString *name) {
    NSDictionary *loose = nil;
    for (id item in elements) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = item[@"text"];
        if (![text isKindOfClass:[NSString class]] || ![text hasPrefix:name]) continue;
        if ([text rangeOfString:@"包含"].location != NSNotFound) continue;   // 群聊「包含:张鹏」
        NSDictionary *point = InsCenter(item);
        if (!point || [point[@"y"] doubleValue] <= 140) continue;
        if ([text rangeOfString:@"联系人"].location != NSNotFound) return point;
        if ([text rangeOfString:@"群聊"].location != NSNotFound) continue;
        if (!loose && [text isEqualToString:name]) loose = point;
    }
    return loose;
}

/// 相册页盖在聊天页上面时，底下的会话控制器一般还在栈里。
/// 只有明确读到「另一个会话」才判定被切走，读不到就放行，避免误伤正常流程。
static BOOL InsChatStillTarget(NSString *talker) {
    __block BOOL mismatch = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        @try {
            id manager = InsService(@"MMMsgLogicManager");
            id logic = InsCall0(manager, NSSelectorFromString(@"GetCurrentLogicController"));
            NSString *name = InsCall0(logic, NSSelectorFromString(@"GetContactName"));
            mismatch = name.length && talker.length && ![name isEqualToString:talker];
            if (mismatch) {
                InsNote([NSString stringWithFormat:@"目标 %@ 已被切成 %@", talker, name]);
            }
        } @catch (NSException *e) {
            mismatch = NO;
        }
    });
    return !mismatch;
}

/// 走完「+ → 照片 → 选中新生成的图 → 发送」，成功返回 nil
static NSString *InsSendViaAlbumPicker(NSString *talker, NSString *stamp) {
    NSString *failure = nil;
    NSArray *elements = InsScreen();
    if (!InsButton(elements, @"照片", 400)) {
        if (!InsTapAt(InsButton(elements, @"更多", 400))) return @"没找到聊天框右边的加号";
        [NSThread sleepForTimeInterval:1.2];
        elements = InsScreen();
        if (!InsTapAt(InsButton(elements, @"照片", 400))) failure = @"加号面板里没有照片入口";
    } else {
        InsTapAt(InsButton(elements, @"照片", 400));
    }
    [NSThread sleepForTimeInterval:2.5];

    NSDictionary *target = nil;
    for (int i = 0; !failure && i < 10 && !target; i++) {
        NSArray *cells = InsAlbumCells(InsScreen());
        if (!cells.count) {
            [NSThread sleepForTimeInterval:1.5];
            continue;
        }
        for (NSDictionary *cell in cells) {
            if ([cell[@"time"] isEqual:stamp] &&
                (!target || [cell[@"ordinal"] longValue] > [target[@"ordinal"] longValue])) {
                target = cell;
            }
        }
        if (target) break;
        [[InsMCP shared] callTool:@"swipe_screen"
                             args:@{@"fromX": @195, @"fromY": @600, @"toX": @195, @"toY": @220,
                                    @"duration": @300}
                            error:NULL];
        [NSThread sleepForTimeInterval:1.2];
    }
    if (!failure && !target) failure = [NSString stringWithFormat:@"相册里没找到新图片（时间标记 %@）", stamp];

    if (!failure && !InsChatStillTarget(talker)) {
        failure = @"会话被切走了，图片没有发出，请停留在目标会话再试一次";
    }
    if (!failure) {
        InsTapAt(target[@"point"]);
        [NSThread sleepForTimeInterval:1.2];
        if (!InsTapAt(InsButton(InsScreen(), @"发送", 600))) {
            failure = @"相册底部没有发送按钮";
        } else {
            [NSThread sleepForTimeInterval:2];
            InsNote([NSString stringWithFormat:@"已通过相册发送图片（照片%@）",
                     [target[@"ordinal"] stringValue]]);
        }
    }

    // 收尾：收起加号面板，失败时再把相册页关掉
    elements = InsScreen();
    if (InsButton(elements, @"照片", 400)) {
        InsTapAt(InsButton(elements, @"更多", 400));
    } else if (failure && InsButton(elements, @"关闭", 0)) {
        InsTapAt(InsButton(elements, @"关闭", 0));
    }
    return failure;
}
static void InsConfirmChat(NSString *talker, int attempt,
                           void (^onReady)(void), void (^onFailed)(NSString *)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id logic = nil;
        @try {
            logic = InsCurrentLogicController(talker);
        } @catch (NSException *e) {
            logic = nil;
        }
        if (logic) { onReady(); return; }
        // 会话没打开时干等不会让它自己出现，最多给 3 轮(约6秒)覆盖切换动画，
        // 之后立刻走 fallback 用内部接口主动打开，别再白耗 16 秒。
        if (attempt < 3) {
            InsNote([NSString stringWithFormat:@"发图等待 %d/3：聊天界面还没回到 %@", attempt + 1, talker]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                InsConfirmChat(talker, attempt + 1, onReady, onFailed);
            });
            return;
        }
        onFailed(@"聊天界面不在目标会话，已尝试跳转");
    });
}

/// 会话在通讯录里显示的名字，跳转搜索要用它；只能在主线程调用
static NSString *InsChatDisplayName(NSString *talker) {
    static NSDictionary *special = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        special = @{@"filehelper": @"文件传输助手", @"weixin": @"微信团队",
                    @"mphelper": @"公众平台安全助手", @"floatbottle": @"朋友圈",
                    @"medianote": @"语音记事本", @"qqmail": @"邮件提醒"};
    });
    NSString *known = special[talker];
    if (known) return known;
    id contacts = InsService(@"CContactMgr");
    id contact = contacts ? InsCall1(contacts, NSSelectorFromString(@"getContactByName:"), talker) : nil;
    NSString *name = contact ? InsCall0(contact, NSSelectorFromString(@"getContactDisplayName")) : nil;
    // 查不到人时 getContactDisplayName 会退回原始 id，拿去搜索没有意义
    if (!name.length || [name isEqualToString:talker]) return nil;
    return name;
}

static BOOL InsAnyChatPageOpen(void);
static BOOL InsPopChatPage(void);

/// 目标会话没在前台时，像人一样点进列表项或搜索结果；只能在非主线程调用
static BOOL InsOpenChatNamed(NSString *name) {
    if (!name.length) return NO;
    InsNote([NSString stringWithFormat:@"尝试跳转会话「%@」", name]);
    // 还停在某个聊天页里：先退出来，否则既找不到搜索框也找不到返回键
    BOOL didPop = InsAnyChatPageOpen() && InsPopChatPage();
    if (didPop) [NSThread sleepForTimeInterval:1.2];  // 等 pop 动画走完，否则读到空白过渡态会误判「找不到返回入口」
    for (int round = 0; round < 4; round++) {
        NSArray *elements = InsScreen();
        NSDictionary *entry = InsSearchEntry(elements);
        if (entry) {
            NSDictionary *row = InsChatRow(elements, name);
            if (row) {
                InsTapAt(row);
                [NSThread sleepForTimeInterval:3];
                InsNote(@"已从会话列表进入");
                return YES;
            }
            InsTapAt(entry);
            [NSThread sleepForTimeInterval:1.5];
            [[InsMCP shared] callTool:@"input_text" args:@{@"text": name} error:NULL];
            [NSThread sleepForTimeInterval:3];
            NSDictionary *hit = InsSearchRow(InsScreen(), name);
            if (hit) {
                InsTapAt(hit);
                [NSThread sleepForTimeInterval:3];
                InsNote(@"已从搜索结果进入");
                return YES;
            }
            InsNote([NSString stringWithFormat:@"搜索结果里没有「%@」", name]);
            return NO;
        }
        // 不在会话列表页，先退回上一页
        NSDictionary *back = InsButton(elements, @"返回", 0) ?: InsButton(elements, @"微信", 700);
        if (!back) {
            // 弹页后导航栈可能被清空（界面全黑，连返回键都没有）：
            // 主动点底部「微信」tab 回到会话列表，绝不能把用户留在黑屏。
            InsNote(@"找不到返回入口，尝试点微信 tab 恢复会话列表");
            [[InsMCP shared] callTool:@"tap_element" args:@{@"text": @"微信", @"match": @"exact", @"role": @"control"} error:NULL];
            [NSThread sleepForTimeInterval:1.5];
            if (InsSearchEntry(InsScreen())) {
                InsNote(@"已恢复回会话列表（避免黑屏）");
            }
            return NO;
        }
        InsTapAt(back);
        [NSThread sleepForTimeInterval:2];
    }
    return NO;
}

#pragma mark - 用微信内部接口打开会话（不依赖屏幕模拟）

/// 顶层控制器：取 keyWindow 上最靠前的那个
static UIViewController *InsTopViewController(void) {
    UIWindow *keyWindow = nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) { keyWindow = window; break; }
    }
    if (!keyWindow) keyWindow = [UIApplication sharedApplication].keyWindow;
    if (!keyWindow) {
        for (UIWindow *window in [UIApplication sharedApplication].windows) { keyWindow = window; break; }
    }
    UIViewController *vc = keyWindow.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

/// 聊天窗口要 push 进的那个导航控制器（微信是 tab + 内嵌 nav 的结构）
static UINavigationController *InsNavigationForChat(void) {
    UIViewController *vc = InsTopViewController();
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *selected = ((UITabBarController *)vc).selectedViewController;
        if (selected) vc = selected;
    }
    if ([vc isKindOfClass:[UINavigationController class]]) return (UINavigationController *)vc;
    if (vc.navigationController) return vc.navigationController;
    for (UIViewController *child in vc.childViewControllers) {
        if ([child isKindOfClass:[UINavigationController class]]) return (UINavigationController *)child;
        if (child.navigationController) return child.navigationController;
    }
    return nil;
}

static BOOL InsChatIsOpenQuiet(NSString *talker);

/// 是不是停在某个聊天页（读不到就当没有）
static BOOL InsAnyChatPageOpen(void) {
    __block BOOL open = NO;
    void (^work)(void) = ^{
        id mgr = InsService(@"MMMsgLogicManager");
        open = InsCall0(mgr, NSSelectorFromString(@"GetCurrentLogicController")) != nil;
    };
    if ([NSThread isMainThread]) work();
    else dispatch_sync(dispatch_get_main_queue(), work);
    return open;
}

/// 等一小段时间，但绝不能冻住主线程 runloop：
/// 微信的 PopLogicController / Push 转场动画跑在主 runloop 上，
/// 一旦在主线程用 [NSThread sleepForTimeInterval:] 把 runloop 冻住，pop 动画走不完，
/// 紧接着 push 新会话就会转场错乱 → 界面全黑（实测 16:40/16:50 两次黑屏都栽在这）。
/// 主线程用 runMode:beforeDate: 让动画继续跑；后台线程才用普通 sleep。
static void InsWaitNoFreeze(NSTimeInterval seconds) {
    if ([NSThread isMainThread]) {
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
        while ([until timeIntervalSinceNow] > 0) {
            @autoreleasepool {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                         beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }
        }
    } else {
        [NSThread sleepForTimeInterval:seconds];
    }
}

/// 弹掉当前聊天页，回到会话列表。
/// 微信只允许「从列表页」push 新会话：页面上已经压着一个聊天时，
/// OpenMsgWindowByContact 会被静默忽略（实测给「张鹏」发消息就卡在这）。
static BOOL InsPopChatPage(void) {
    __block BOOL popped = NO;
    void (^work)(void) = ^{
        @try {
            id mgr = InsService(@"MMMsgLogicManager");
            id logic = InsCall0(mgr, NSSelectorFromString(@"GetCurrentLogicController"));
            if (!logic) return;
            SEL pop = NSSelectorFromString(@"PopLogicController:");
            if (![mgr respondsToSelector:pop]) return;
            NSMethodSignature *sig = [mgr methodSignatureForSelector:pop];
            if (!sig || sig.numberOfArguments != 3) return;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = mgr;
            inv.selector = pop;
            [inv setArgument:&logic atIndex:2];
            [inv invoke];
            popped = YES;
        } @catch (NSException *e) {
            InsNote([NSString stringWithFormat:@"弹聊天页异常: %@", e.reason]);
        }
    };
    if ([NSThread isMainThread]) work();
    else dispatch_sync(dispatch_get_main_queue(), work);
    if (popped) {
        InsNote(@"先把当前聊天页弹回会话列表");
        InsWaitNoFreeze(0.8);   // 不能冻住主 runloop，否则 pop 动画走不完 → 黑屏
    }
    return popped;
}

/// 轮询等目标会话真的就绪（每轮 0.2 秒）
static BOOL InsWaitChatOpen(NSString *talker, int rounds) {
    for (int i = 0; i < rounds; i++) {
        __block BOOL open = NO;
        if ([NSThread isMainThread]) {
            open = InsChatIsOpenQuiet(talker);
        } else {
            dispatch_semaphore_t wait = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_main_queue(), ^{
                open = InsChatIsOpenQuiet(talker);
                dispatch_semaphore_signal(wait);
            });
            dispatch_semaphore_wait(wait, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
        }
        if (open) return YES;
        [NSThread sleepForTimeInterval:0.2];
    }
    return NO;
}

/// 当前聊天界面是不是这个会话（不打日志，轮询用）
static BOOL InsChatIsOpenQuiet(NSString *talker) {
    if (!talker.length) return NO;
    id manager = InsService(@"MMMsgLogicManager");
    id logic = InsCall0(manager, NSSelectorFromString(@"GetCurrentLogicController"));
    if (!logic) return NO;
    NSString *name = InsCall0(logic, NSSelectorFromString(@"GetContactName"));
    return [name isKindOfClass:[NSString class]] && [name isEqualToString:talker];
}

/// 调 -[MMMsgLogicManager OpenMsgWindowByContact:…]，或退一步用 PushLogicControllerByContact:…
/// 只能在主线程调用；返回是否成功发起了跳转
/// 起一次「打开会话」。preferOpenMsgWindow=NO 走 Push（直接压导航栈，最像手动点进去），
/// =YES 走 OpenMsgWindowByContact（微信自己的开窗逻辑，有时它才认）
static BOOL InsOpenChatInProcessOnce(NSString *talker, BOOL preferOpenMsgWindow, NSString **how) {
    if (InsChatIsOpenQuiet(talker)) { if (how) *how = @"已经是当前会话"; return YES; }
    // 页面上压着别的聊天时，微信会把 push / OpenMsgWindow 都当空气：先退回会话列表
    InsPopChatPage();
    id logicMgr = InsService(@"MMMsgLogicManager");
    id contactMgr = InsService(@"CContactMgr");
    if (!logicMgr) { if (how) *how = @"MMMsgLogicManager 不可用"; return NO; }
    if (!contactMgr) { if (how) *how = @"CContactMgr 不可用"; return NO; }
    id contact = InsCall1(contactMgr, NSSelectorFromString(@"getContactByName:"), talker);
    if (!contact) { if (how) *how = @"通讯录里拿不到这个会话对象"; return NO; }

    SEL open = NSSelectorFromString(@"OpenMsgWindowByContact:jumpToLocationNode:reuse:extraInfo:completion:");
    SEL push = NSSelectorFromString(@"PushLogicControllerByContact:navigationController:animated:jumpToLocationNode:");
    BOOL canOpen = [logicMgr respondsToSelector:open];
    BOOL canPush = [logicMgr respondsToSelector:push];
    if (!canOpen && !canPush) { if (how) *how = @"没有可用的开会话方法"; return NO; }

    if (preferOpenMsgWindow ? canOpen : canPush) {
        if (preferOpenMsgWindow) {
            NSMethodSignature *sig = [logicMgr methodSignatureForSelector:open];
            if (sig && sig.numberOfArguments >= 7) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = logicMgr;
                inv.selector = open;
                id none = nil;
                BOOL reuse = NO;
                [inv setArgument:&contact atIndex:2];
                [inv setArgument:&none atIndex:3];
                [inv setArgument:&reuse atIndex:4];
                [inv setArgument:&none atIndex:5];
                [inv setArgument:&none atIndex:6];
                @try {
                    [inv invoke];
                    InsNote([NSString stringWithFormat:@"内部打开会话 OpenMsgWindow：%@", talker]);
                    if (how) *how = @"OpenMsgWindow 已调用";
                    return YES;
                } @catch (NSException *e) {
                    InsNote([NSString stringWithFormat:@"OpenMsgWindow 异常: %@", e.reason]);
                }
            }
        } else {
            UINavigationController *nav = InsNavigationForChat();
            if (nav) {
                NSMethodSignature *sig = [logicMgr methodSignatureForSelector:push];
                if (sig && sig.numberOfArguments >= 6) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.target = logicMgr;
                    inv.selector = push;
                    id none = nil;
                    BOOL animated = NO;
                    [inv setArgument:&contact atIndex:2];
                    [inv setArgument:&nav atIndex:3];
                    [inv setArgument:&animated atIndex:4];
                    [inv setArgument:&none atIndex:5];
                    @try {
                        [inv invoke];
                        InsNote([NSString stringWithFormat:@"内部打开会话 Push：%@", talker]);
                        if (how) *how = @"PushLogicController 已调用";
                        return YES;
                    } @catch (NSException *e) {
                        InsNote([NSString stringWithFormat:@"PushLogicController 异常: %@", e.reason]);
                        if (how) *how = [NSString stringWithFormat:@"Push 异常:%@", e.reason];
                    }
                }
            } else if (how) {
                *how = @"拿不到导航控制器";
            }
        }
    }

    // 首选那条走不通，换成另一条再试一次
    if (preferOpenMsgWindow && canPush) {
        UINavigationController *nav = InsNavigationForChat();
        if (nav) {
            NSMethodSignature *sig = [logicMgr methodSignatureForSelector:push];
            if (sig && sig.numberOfArguments >= 6) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = logicMgr;
                inv.selector = push;
                id none = nil;
                BOOL animated = NO;
                [inv setArgument:&contact atIndex:2];
                [inv setArgument:&nav atIndex:3];
                [inv setArgument:&animated atIndex:4];
                [inv setArgument:&none atIndex:5];
                @try {
                    [inv invoke];
                    InsNote([NSString stringWithFormat:@"内部打开会话 Push：%@", talker]);
                    if (how) *how = @"PushLogicController 已调用";
                    return YES;
                } @catch (NSException *e) { (void)e; }
            }
        }
    }
    return NO;
}

/// 端口探测：判断本机 MCP 屏幕模拟通道是否真的在监听（点屏依赖它）
static BOOL InsLocalPortOpen(uint16_t port, double timeout) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int ret = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    BOOL open = NO;
    if (ret == 0) {
        open = YES;
    } else if (errno == EINPROGRESS) {
        fd_set set, errset;
        FD_ZERO(&set); FD_SET(fd, &set);
        FD_ZERO(&errset); FD_SET(fd, &errset);
        struct timeval tv;
        tv.tv_sec = (long)timeout;
        tv.tv_usec = (long)((timeout - (double)tv.tv_sec) * 1000000);
        if (select(fd + 1, NULL, &set, &errset, &tv) > 0) {
            int err = 0;
            socklen_t len = sizeof(err);
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len);
            open = (err == 0);
        }
    }
    close(fd);
    return open;
}

/// 等会话打开 → 相册发送；打不开就跳转后再试一次
static void InsSendWhenReady(NSString *talker, NSString *chatName, NSString *stamp,
                             BOOL navigated, void (^finish)(NSString *)) {
    InsConfirmChat(talker, 0, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            finish(InsSendViaAlbumPicker(talker, stamp));
        });
    }, ^(NSString *message) {
        if (navigated) { finish(message); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            // 先用微信内部接口把会话打开（不依赖屏幕模拟），失败再退回点屏幕
            if ([InsSend openChatInProcess:talker]) {
                InsSendWhenReady(talker, chatName, stamp, YES, finish);
                return;
            }
            if (!InsOpenChatNamed(chatName)) { finish(message); return; }
            InsSendWhenReady(talker, chatName, stamp, YES, finish);
        });
    });
}

@implementation InsSend

+ (NSString *)capabilityReport {
    // MMServiceCenter 只在主线程给服务；命令跑在后台队列，这里切过去取
    __block NSString *report = @"（主线程没响应）";
    void (^work)(void) = ^{ report = InsCapabilityReport(); };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            work();
            dispatch_semaphore_signal(sem);
        });
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC));
    }
    return report;
}

+ (void)diagnoseForTalker:(NSString *)talker completion:(void (^)(NSString *))done {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *report = nil;
        @try {
            report = InsDiagOnce(talker);
        } @catch (NSException *e) {
            report = [NSString stringWithFormat:@"诊断异常: %@", e.reason];
        }
        if (done) done(report);
    });
}

+ (void)sendText:(NSString *)text toTalker:(NSString *)talker completion:(void (^)(BOOL))done {
    if (!text.length || !talker.length) {
        if (done) done(NO);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL ok = NO;
        @try {
            ok = InsSendTextOnce(text, talker);
        } @catch (NSException *e) {
            InsNote([NSString stringWithFormat:@"文本发送异常: %@", e.reason]);
        }
        if (done) done(ok);
    });
}

+ (void)sendTextAfterNavigating:(NSString *)text
                       toTalker:(NSString *)talker
                       chatName:(NSString *)chatName
                     completion:(void (^)(BOOL))done {
    if (!text.length || !talker.length) {
        if (done) done(NO);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 微信可能不在前台，先拉起；再像人一样进到目标会话
        [[InsMCP shared] callTool:@"launch_app" args:@{@"bundle_id": @"com.tencent.xin"} error:NULL];
        [NSThread sleepForTimeInterval:2];
        // 联系人查询只能在主线程，displayNameForTalker 内部会切
        NSString *name = chatName.length ? chatName : ([self displayNameForTalker:talker] ?: talker);
        // 先走微信内部接口开会话：屏幕模拟那条路（InsOpenChatNamed）会先弹掉当前聊天页，
        // 连续切换两次（代发给 A → 回执给 B）时会把导航栈弹空 → 微信黑屏。
        // 实测 16:40 林健代发张鹏后回执就黑在这。内部接口成功后直接发，失败才退回屏幕模拟。
        if (![self isChatOpen:talker] && ![self openChatInProcess:talker]) {
            if (!InsOpenChatNamed(name)) {
                InsNote([NSString stringWithFormat:@"跳转「%@」失败，文本没法发出", name]);
                if (done) done(NO);
                return;
            }
        }
        [NSThread sleepForTimeInterval:1];
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL ok = NO;
            @try {
                ok = InsSendTextOnce(text, talker);
            } @catch (NSException *e) {
                InsNote([NSString stringWithFormat:@"跳转后文本发送异常: %@", e.reason]);
            }
            if (done) done(ok);
        });
    });
}

+ (NSString *)displayNameForTalker:(NSString *)talker {
    if (!talker.length) return nil;
    if ([NSThread isMainThread]) return InsChatDisplayName(talker);
    __block NSString *name = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
        name = InsChatDisplayName(talker);
    });
    return name;
}

+ (BOOL)isChatOpen:(NSString *)talker {
    if (!talker.length) return NO;
    if ([NSThread isMainThread]) return InsCurrentLogicController(talker) != nil;
    __block BOOL open = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        open = InsCurrentLogicController(talker) != nil;
    });
    return open;
}

+ (BOOL)openChatInProcess:(NSString *)talker {
    if (!talker.length) return NO;
    if ([self isChatOpen:talker]) return YES;

    __block BOOL started = NO;
    __block NSString *how = nil;
    if ([NSThread isMainThread]) {
        started = InsOpenChatInProcessOnce(talker, NO, &how);
    } else {
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            started = InsOpenChatInProcessOnce(talker, NO, &how);
            dispatch_semaphore_signal(semaphore);
        });
        if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC))) != 0) {
            InsNote(@"内部打开会话：主线程 10 秒没响应");
            return NO;
        }
    }
    if (!started) {
        InsNote([NSString stringWithFormat:@"内部打开会话失败：%@", how ?: @"未知"]);
        return NO;
    }
    // 等界面真正就绪（取到目标会话的 logic 才算成）
    for (int i = 0; i < 30; i++) {
        __block BOOL open = NO;
        if ([NSThread isMainThread]) {
            open = InsChatIsOpenQuiet(talker);
        } else {
            dispatch_semaphore_t wait = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_main_queue(), ^{
                open = InsChatIsOpenQuiet(talker);
                dispatch_semaphore_signal(wait);
            });
            dispatch_semaphore_wait(wait, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
        }
        if (open) {
            InsNote([NSString stringWithFormat:@"内部打开会话就绪：%@（%d 轮）", talker, i + 1]);
            [NSThread sleepForTimeInterval:0.3];   // 给输入区一点初始化时间
            return YES;
        }
        [NSThread sleepForTimeInterval:0.2];
    }
    // 这个版本 OpenMsgWindow 后界面常常慢半拍：刚判失败时动画还没走完，
    // 再等 2 秒复查一次，比直接放弃靠谱（实测 15:28 就是死在「刚失败就弹页」上）
    [NSThread sleepForTimeInterval:2.0];
    {
        __block BOOL late = NO;
        if ([NSThread isMainThread]) {
            late = InsChatIsOpenQuiet(talker);
        } else {
            dispatch_semaphore_t wait = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_main_queue(), ^{
                late = InsChatIsOpenQuiet(talker);
                dispatch_semaphore_signal(wait);
            });
            dispatch_semaphore_wait(wait, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
        }
        if (late) {
            InsNote([NSString stringWithFormat:@"内部打开会话就绪（延迟 2 秒后才到）：%@", talker]);
            [NSThread sleepForTimeInterval:0.3];
            return YES;
        }
    }
    InsNote([NSString stringWithFormat:@"内部打开会话没就绪：%@（%@）", talker, how ?: @"-"]);

    // 换另一个入口再试：Push 没成，就让微信自己的 OpenMsgWindowByContact 来开一次
    {
        __block BOOL started2 = NO;
        __block NSString *how2 = nil;
        void (^work2)(void) = ^{ started2 = InsOpenChatInProcessOnce(talker, YES, &how2); };
        if ([NSThread isMainThread]) {
            work2();
        } else {
            dispatch_semaphore_t sem2 = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_main_queue(), ^{ work2(); dispatch_semaphore_signal(sem2); });
            dispatch_semaphore_wait(sem2, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
        }
        if (started2 && InsWaitChatOpen(talker, 25)) {
            InsNote([NSString stringWithFormat:@"内部打开会话就绪（换 OpenMsgWindow）：%@", talker]);
            [NSThread sleepForTimeInterval:0.3];
            return YES;
        }
        if (how2.length) how = how2;
    }

    // 已 push 但界面没到位：把刚推上去的聊天页弹掉，别留一个假空页
    if ([how hasPrefix:@"OpenMsgWindow"] || [how hasPrefix:@"PushLogicController"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            id logicMgr = InsService(@"MMMsgLogicManager");
            id logic = InsCall0(logicMgr, NSSelectorFromString(@"GetCurrentLogicController"));
            if (logic && [logicMgr respondsToSelector:NSSelectorFromString(@"PopLogicController:")]) {
                SEL pop = NSSelectorFromString(@"PopLogicController:");
                NSMethodSignature *sig = [logicMgr methodSignatureForSelector:pop];
                if (sig && sig.numberOfArguments == 3) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.target = logicMgr;
                    inv.selector = pop;
                    [inv setArgument:&logic atIndex:2];
                    @try { [inv invoke]; } @catch (NSException *e) { (void)e; }
                }
            }
        });
        // 等 pop 动画走完再返回，否则紧接着的「屏幕模拟跳转」会找不到返回入口
        [NSThread sleepForTimeInterval:1.5];
    }
    return NO;
}

+ (NSString *)openDiagnosis:(NSString *)talker {
    NSMutableString *out = [NSMutableString string];
    __block NSString *contactInfo = @"-";
    __block NSString *apiInfo = @"-";
    __block NSString *how = nil;
    __block BOOL opened = NO;

    void (^probe)(void) = ^{
        id contactMgr = InsService(@"CContactMgr");
        id contact = contactMgr ? InsCall1(contactMgr, NSSelectorFromString(@"getContactByName:"), talker) : nil;
        contactInfo = contact ? [NSString stringWithFormat:@"找到（%@）", talker] : @"拿不到会话对象";

        id logicMgr = InsService(@"MMMsgLogicManager");
        if (!logicMgr) {
            apiInfo = @"MMMsgLogicManager 不可用";
            return;
        }
        BOOL hasOpen = [logicMgr respondsToSelector:
                        NSSelectorFromString(@"OpenMsgWindowByContact:jumpToLocationNode:reuse:extraInfo:completion:")];
        BOOL hasPush = [logicMgr respondsToSelector:
                        NSSelectorFromString(@"PushLogicControllerByContact:navigationController:animated:jumpToLocationNode:")];
        UINavigationController *nav = InsNavigationForChat();
        apiInfo = [NSString stringWithFormat:@"OpenMsgWindow：%@｜Push：%@｜导航控制器：%@",
                   hasOpen ? @"有" : @"无", hasPush ? @"有" : @"无", nav ? @"有" : @"无"];
        if (contact) opened = InsOpenChatInProcessOnce(talker, NO, &how);
    };
    if ([NSThread isMainThread]) probe();
    else dispatch_sync(dispatch_get_main_queue(), probe);

    [out appendFormat:@"代发体检 · %@\n", talker];
    [out appendFormat:@"- 联系人：%@\n", contactInfo];
    [out appendFormat:@"- 内部接口：%@\n", apiInfo];
    [out appendFormat:@"- 打开会话：%@（%@）\n", opened ? @"成功发起" : @"失败", how ?: @"-"];

    if (opened) {
        BOOL ready = NO;
        for (int i = 0; i < 30; i++) {
            __block BOOL open = NO;
            dispatch_semaphore_t wait = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_main_queue(), ^{
                open = InsChatIsOpenQuiet(talker);
                dispatch_semaphore_signal(wait);
            });
            dispatch_semaphore_wait(wait, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
            if (open) { ready = YES; break; }
            [NSThread sleepForTimeInterval:0.2];
        }
        [out appendFormat:@"- 界面就绪：%@\n", ready ? @"是" : @"否（会话打开了但输入区没就绪）"];
    }

    BOOL mcp = InsLocalPortOpen(8090, 1.5);
    [out appendFormat:@"- 屏幕模拟（127.0.0.1:8090）：%@\n", mcp ? @"可用" : @"连不上"];
    [out appendString:@"（发送只依赖前四项；8090 只在内部接口都失败时才用得上）"];
    InsNote([NSString stringWithFormat:@"代发体检：%@", [out stringByReplacingOccurrencesOfString:@"\n" withString:@" / "]]);
    return out;
}

+ (BOOL)openChatNamed:(NSString *)name {
    if ([NSThread isMainThread]) {
        InsNote(@"不能在主线程跳转会话");
        return NO;
    }
    return InsOpenChatNamed(name);
}

+ (void)sendImageData:(NSData *)image
             toTalker:(NSString *)talker
             chatName:(NSString *)chatName
           completion:(void (^)(NSString *))done {
    if (!image.length || !talker.length) {
        done(@"参数为空");
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *failure = nil;
        NSString *localIdentifier = InsSaveToAlbum(image, &failure);
        if (!localIdentifier) { InsNote(failure); done(failure); return; }
        NSString *stamp = InsMinuteStamp();
        InsNote([NSString stringWithFormat:@"图片已进相册 %@（时间标记 %@）", localIdentifier, stamp]);
        NSString *target = chatName.length ? chatName : [self displayNameForTalker:talker];
        if (!target.length) target = talker;   // 顶多跳转失败，不影响正常路径
        InsSendWhenReady(talker, target, stamp, NO, done);
    });
}

@end
