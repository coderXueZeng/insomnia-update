#import "InsOutbox.h"
#import "InsConfig.h"
#import "InsSend.h"

static NSString *InsOBoxPath(void) {
    return [[InsConfig rootDir] stringByAppendingPathComponent:@"outbox.json"];
}

static NSUInteger const InsOBoxMaxItems = 20;
static NSUInteger const InsOBoxMaxAttempts = 5;
static NSUInteger const InsOBoxBatch = 3;

static NSMutableDictionary *InsOBoxLoad(void) {
    NSData *raw = [NSData dataWithContentsOfFile:InsOBoxPath()];
    NSDictionary *dict = raw ? [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil] : nil;
    NSMutableDictionary *box = [NSMutableDictionary dictionary];
    if ([dict isKindOfClass:[NSDictionary class]]) [box addEntriesFromDictionary:dict];
    if (![box[@"items"] isKindOfClass:[NSArray class]]) box[@"items"] = [NSMutableArray array];
    else box[@"items"] = [box[@"items"] mutableCopy];
    return box;
}

static void InsOBoxSave(NSDictionary *box) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:box options:0 error:nil];
    if (!data) return;
    NSString *path = InsOBoxPath();
    if ([data writeToFile:path atomically:YES]) {
        // 锁屏状态下也要能读写，否则重发队列会跟着配置文件一起「消失」
        [[NSFileManager defaultManager] setAttributes:@{NSFileProtectionKey: NSFileProtectionNone}
                                        ofItemAtPath:path error:nil];
    }
}

static NSString *InsOBoxTime(long long stamp) {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"MM-dd HH:mm";
    return [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)stamp]];
}

static NSString *InsOBoxChatName(NSDictionary *item) {
    NSString *name = item[@"chatName"];
    if ([name isKindOfClass:[NSString class]] && name.length) return name;
    NSString *talker = item[@"talker"];
    return [talker isKindOfClass:[NSString class]] ? talker : @"";
}

@implementation InsOutbox

+ (void)enqueueText:(NSString *)text
           toTalker:(NSString *)talker
           chatName:(NSString *)chatName
              error:(NSString *)error {
    if (!text.length || !talker.length) return;
    @synchronized (self) {
        NSMutableDictionary *box = InsOBoxLoad();
        NSMutableArray *items = box[@"items"];
        // 同一条内容重复入队没意义（比如同一句状态连发两次）
        for (NSDictionary *old in items) {
            if ([old[@"text"] isEqual:text] && [old[@"talker"] isEqual:talker] &&
                (long long)[[NSDate date] timeIntervalSince1970] - [old[@"createdAt"] longLongValue] < 300) {
                return;
            }
        }
        [items addObject:@{
            @"text": text.length > 1500 ? [text substringToIndex:1500] : text,
            @"talker": talker,
            @"chatName": chatName ?: @"",
            @"createdAt": @((long long)[[NSDate date] timeIntervalSince1970]),
            @"attempts": @0,
            @"error": error ?: @"",
        }];
        while (items.count > InsOBoxMaxItems) [items removeObjectAtIndex:0];
        // 超过一天还发不出去的多半是对方已经删会话/被封，留着只会反复骚扰
        long long now = (long long)[[NSDate date] timeIntervalSince1970];
        for (NSInteger i = (NSInteger)items.count - 1; i >= 0; i--) {
            if (now - [items[(NSUInteger)i][@"createdAt"] longLongValue] > 24 * 3600) {
                [items removeObjectAtIndex:(NSUInteger)i];
            }
        }
        InsOBoxSave(box);
    }
    [InsConfig log:[NSString stringWithFormat:
        @"回复没发出去，已进重发队列（%@）：%@", talker, [text substringToIndex:MIN(text.length, 30)]]];
}

+ (NSUInteger)count {
    @synchronized (self) {
        return [InsOBoxLoad()[@"items"] count];
    }
}

+ (NSString *)statusLine {
    NSUInteger n = [self count];
    if (!n) return @"回复送达 正常（没有待重发）";
    return [NSString stringWithFormat:@"回复送达 有待重发 %lu 条（%@ 补发 立刻重试）",
            (unsigned long)n, [InsConfig shared].trigger];
}

+ (NSString *)detail {
    NSMutableString *out = [NSMutableString string];
    NSArray *items = nil;
    @synchronized (self) {
        items = [InsOBoxLoad()[@"items"] copy];
    }
    [out appendFormat:@"%@\n", [self lastDeliveryLine]];
    if (!items.count) {
        [out appendString:@"重发队列是空的：最近没有「只在本地显示、对方收不到」的回复。"];
        return out;
    }
    [out appendFormat:@"重发队列 %lu 条（最多留 %lu 条，24 小时后自动清）：\n",
        (unsigned long)items.count, (unsigned long)InsOBoxMaxItems];
    NSInteger i = 1;
    for (NSDictionary *item in items) {
        NSString *text = [item[@"text"] isKindOfClass:[NSString class]] ? item[@"text"] : @"";
        text = [text stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        [out appendFormat:@"%ld. %@ → %@，失败 %@ 次：%@\n",
            (long)i++, InsOBoxTime([item[@"createdAt"] longLongValue]),
            InsOBoxChatName(item), item[@"attempts"] ?: @0,
            [text substringToIndex:MIN(text.length, 24)]];
    }
    [out appendFormat:@"发「%@ 补发」立刻重试。", [InsConfig shared].trigger];
    return out;
}

+ (void)flushWithCompletion:(void (^)(NSString *))done {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSArray *snapshot = nil;
        @synchronized (self) {
            snapshot = [InsOBoxLoad()[@"items"] copy];
        }
        if (!snapshot.count) {
            if (done) done(@"重发队列是空的，没有要补的。");
            return;
        }
        NSUInteger sent = 0, failed = 0;
        NSString *lastError = nil;
        NSUInteger tried = 0;
        for (NSDictionary *item in snapshot) {
            if (tried >= InsOBoxBatch) break;
            tried++;
            NSString *text = item[@"text"];
            NSString *talker = item[@"talker"];
            if (!text.length || !talker.length) {
                @synchronized (self) {
                    NSMutableDictionary *box = InsOBoxLoad();
                    NSMutableArray *items = box[@"items"];
                    [items removeObject:item];
                    InsOBoxSave(box);
                }
                continue;
            }
            __block BOOL ok = NO;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [InsSend sendTextAfterNavigating:text
                                    toTalker:talker
                                    chatName:InsOBoxChatName(item)
                                  completion:^(BOOL success) {
                ok = success;
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)));

            @synchronized (self) {
                NSMutableDictionary *box = InsOBoxLoad();
                NSMutableArray *items = box[@"items"];
                NSUInteger idx = NSUIntegerMax;
                for (NSUInteger i = 0; i < items.count; i++) {
                    NSDictionary *cur = items[i];
                    if ([cur[@"talker"] isEqual:talker] && [cur[@"text"] isEqual:text] &&
                        [cur[@"createdAt"] isEqual:item[@"createdAt"]]) { idx = i; break; }
                }
                if (idx != NSUIntegerMax) {
                    if (ok) {
                        [items removeObjectAtIndex:idx];
                        sent++;
                    } else {
                        NSMutableDictionary *cur = [items[idx] mutableCopy];
                        NSUInteger attempts = [cur[@"attempts"] unsignedIntegerValue] + 1;
                        cur[@"attempts"] = @(attempts);
                        cur[@"error"] = @"会话打不开或没有可用的发送方法";
                        lastError = cur[@"error"];
                        if (attempts >= InsOBoxMaxAttempts) {
                            [items removeObjectAtIndex:idx];
                            [InsConfig log:[NSString stringWithFormat:
                                @"重发 %lu 次仍失败，放弃这条：%@", (unsigned long)attempts,
                                [text substringToIndex:MIN(text.length, 30)]]];
                        } else {
                            items[idx] = cur;
                        }
                        failed++;
                    }
                }
                InsOBoxSave(box);
            }
            if (ok) {
                [self noteDeliveryVia:@"重发队列补发" talker:talker];
                [InsConfig log:[NSString stringWithFormat:@"重发成功（%@）：%@",
                                talker, [text substringToIndex:MIN(text.length, 30)]]];
            }
        }
        NSUInteger left = [self count];
        NSString *report = nil;
        if (sent && !failed) {
            report = [NSString stringWithFormat:@"补发完成：成功 %lu 条%@。",
                      (unsigned long)sent, left ? [NSString stringWithFormat:@"，还剩 %lu 条", (unsigned long)left] : @""];
        } else if (sent && failed) {
            report = [NSString stringWithFormat:@"补发部分成功：成功 %lu 条、失败 %lu 条，还剩 %lu 条等下次。",
                      (unsigned long)sent, (unsigned long)failed, (unsigned long)left];
        } else {
            report = [NSString stringWithFormat:
                @"补发失败 %lu 条：%@。多半是微信不在前台或会话打不开，"
                @"先手动打开一次那个聊天，再发一次补发。",
                (unsigned long)failed, lastError ?: @"未知原因"];
        }
        if (done) done(report);
    });
}

+ (void)noteDeliveryVia:(NSString *)channel talker:(NSString *)talker {
    @synchronized (self) {
        NSMutableDictionary *box = InsOBoxLoad();
        box[@"lastDelivery"] = @{
            @"channel": channel ?: @"",
            @"talker": talker ?: @"",
            @"at": @((long long)[[NSDate date] timeIntervalSince1970]),
        };
        InsOBoxSave(box);
    }
}

+ (NSString *)lastDeliveryLine {
    NSDictionary *last = nil;
    @synchronized (self) {
        last = [InsOBoxLoad()[@"lastDelivery"] copy];
    }
    if (![last isKindOfClass:[NSDictionary class]]) return @"最近一次回复：还没有记录";
    return [NSString stringWithFormat:@"最近一次真实送达：%@ %@（%@）",
            InsOBoxTime([last[@"at"] longLongValue]),
            last[@"channel"] ?: @"",
            last[@"talker"] ?: @""];
}

@end
