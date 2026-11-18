#import "InsHistory.h"
#import "InsConfig.h"
#import <sqlite3.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *InsMD5Table(NSString *wxid) {
    NSString *lower = [wxid lowercaseString];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5([lower UTF8String], (CC_LONG)strlen([lower UTF8String]), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return [@"Chat_" stringByAppendingString:hex];
}

static NSArray<NSString *> *InsDatabasePaths(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSMutableArray *paths = [NSMutableArray array];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in [fm contentsOfDirectoryAtPath:docs error:nil]) {
        if (dir.length != 32) continue;
        NSString *dbDir = [[docs stringByAppendingPathComponent:dir] stringByAppendingPathComponent:@"DB"];
        for (NSString *file in [fm contentsOfDirectoryAtPath:dbDir error:nil]) {
            if ([file hasPrefix:@"message_"] && [file hasSuffix:@".sqlite"]) {
                [paths addObject:[dbDir stringByAppendingPathComponent:file]];
            }
        }
    }
    return [paths sortedArrayUsingSelector:@selector(compare:)];
}

static NSUInteger gInsSkippedCompressed = 0;

static NSString *InsDecodeMessage(sqlite3_stmt *stmt, int col, int ctCol) {
    int ct = sqlite3_column_int(stmt, ctCol);
    const unsigned char *bytes = sqlite3_column_text(stmt, col);
    NSUInteger len = (NSUInteger)sqlite3_column_bytes(stmt, col);
    if (!bytes || !len) return nil;
    if (ct != 0) {
        gInsSkippedCompressed++;
        return nil;
    }
    return [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
}

@implementation InsHistory

/// 文件传输助手是单向的：只会是账号主人往里发，它永远不回消息。
/// 拿它当「Des 语义」的标尺——如果它的行全是 Des=0，说明这个版本的库里
/// Des=0 才表示「我发出的」，别的会话读取时就要按这个值判断，不能写死 1。
+ (NSInteger)meDesValue {
    static NSInteger cached = -2;   // -2 尚未计算，-1 算不出来（按 1 处理）
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cached = -1;
        NSString *table = InsMD5Table(@"filehelper");
        for (NSString *path in InsDatabasePaths()) {
            sqlite3 *db = NULL;
            if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
                if (db) sqlite3_close(db);
                continue;
            }
            sqlite3_stmt *stmt = NULL;
            NSMutableSet *vals = [NSMutableSet set];
            NSString *sql = [NSString stringWithFormat:
                @"SELECT DISTINCT Des FROM %@ WHERE Type = 1 LIMIT 3;", table];
            if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) == SQLITE_OK) {
                while (sqlite3_step(stmt) == SQLITE_ROW) {
                    [vals addObject:@(sqlite3_column_int(stmt, 0))];
                }
            }
            if (stmt) sqlite3_finalize(stmt);
            sqlite3_close(db);
            if (!vals.count) continue;      // 这个库里没有这张表，换下一个库
            if (vals.count == 1) {
                cached = [[vals anyObject] integerValue] ? 1 : 0;
                [InsConfig log:[NSString stringWithFormat:
                    @"方向校准：文件传输助手全为 Des=%ld，判定 Des=%ld 表示账号主人发出的消息",
                    (long)cached, (long)cached]];
            } else {
                [InsConfig log:@"方向校准：文件传输助手 Des 混杂，无法校准，按 Des=1 处理"];
            }
            break;
        }
    });
    return cached == 0 ? 0 : 1;
}

/// 单向账号：消息只会是账号主人发出的，不需要看 Des
+ (BOOL)isOneWayAccount:(NSString *)wxid {
    static NSSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithArray:@[@"filehelper", @"weixin", @"weixinteam", @"notification_messages",
                                    @"qqmail", @"qqsafe", @"weixinpay", @"fmessage", @"medianote",
                                    @"newsapp", @"weibo", @"facebook", @"twitter"]];
    });
    return wxid.length && [set containsObject:wxid.lowercaseString];
}

+ (NSArray<NSDictionary *> *)rowsInDatabase:(NSString *)path
                                       table:(NSString *)table
                                   afterTime:(uint32_t)afterTime
                                    maxCount:(NSInteger)maxCount
                                     newest:(BOOL)newest
                                     oneWay:(BOOL)oneWay {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return @[];
    }
    NSString *sql;
    if (newest) {
        sql = [NSString stringWithFormat:
            @"SELECT CreateTime, Des, Message, WCDB_CT_Message FROM %@ "
            @"WHERE Type = 1 AND CreateTime > %u ORDER BY CreateTime DESC LIMIT %ld;",
            table, afterTime, (long)maxCount];
    } else {
        sql = [NSString stringWithFormat:
            @"SELECT CreateTime, Des, Message, WCDB_CT_Message FROM %@ "
            @"WHERE Type = 1 AND CreateTime > %u ORDER BY CreateTime ASC LIMIT %ld;",
            table, afterTime, (long)maxCount];
    }
    sqlite3_stmt *stmt = NULL;
    NSMutableArray *rows = [NSMutableArray array];
    NSInteger meVal = [self meDesValue];
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            NSString *text = InsDecodeMessage(stmt, 2, 3);
            if (!text.length) continue;
            NSInteger des = sqlite3_column_int(stmt, 1);
            [rows addObject:@{
                @"t": @(sqlite3_column_int(stmt, 0)),
                @"me": @(oneWay ? YES : (des == meVal)),
                @"des": @(des),
                @"text": text,
            }];
        }
    } else {
        // 会话表只落在某几个 message_N.sqlite 里，「no such table」是正常降级，
        // 逐个库刷日志会把 @insomnia log 的 25 行全占满，这里不再记。
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);
    return rows;
}

+ (NSArray<NSDictionary *> *)collectForTalker:(NSString *)wxid
                                    afterTime:(uint32_t)afterTime
                                     maxCount:(NSInteger)maxCount
                                      newest:(BOOL)newest {
    if (!wxid.length) return @[];
    NSString *table = InsMD5Table(wxid);
    NSMutableArray *all = [NSMutableArray array];
    NSUInteger skippedBefore = gInsSkippedCompressed;
    NSArray *paths = InsDatabasePaths();
    BOOL oneWay = [self isOneWayAccount:wxid];
    for (NSString *path in paths) {
        NSArray *rows = [self rowsInDatabase:path table:table afterTime:afterTime
                                    maxCount:maxCount newest:newest oneWay:oneWay];
        [all addObjectsFromArray:rows];
    }
    NSUInteger skipped = gInsSkippedCompressed - skippedBefore;
    if (skipped) {
        [InsConfig log:[NSString stringWithFormat:@"历史查询：%lu 个库中跳过压缩消息 %lu 条",
                        (unsigned long)paths.count, (unsigned long)skipped]];
    }
    [all sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"t"] compare:b[@"t"]];
    }];
    if (!newest && maxCount > 0 && (NSInteger)all.count > maxCount) {
        [all removeObjectsInRange:NSMakeRange(maxCount, all.count - maxCount)];
    }
    if (newest && maxCount > 0 && (NSInteger)all.count > maxCount) {
        [all removeObjectsInRange:NSMakeRange(0, all.count - maxCount)];
    }
    return all;
}

+ (NSArray<NSDictionary *> *)textMessagesForTalker:(NSString *)wxid
                                         afterTime:(uint32_t)afterTime
                                          maxCount:(NSInteger)maxCount {
    return [self collectForTalker:wxid afterTime:afterTime maxCount:maxCount newest:NO];
}

+ (NSArray<NSDictionary *> *)latestTextMessagesForTalker:(NSString *)wxid count:(NSInteger)count {
    return [self collectForTalker:wxid afterTime:0 maxCount:count newest:YES];
}

+ (NSUInteger)totalTextMessageCountForTalker:(NSString *)wxid {
    NSString *table = InsMD5Table(wxid);
    NSUInteger total = 0;
    for (NSString *path in InsDatabasePaths()) {
        sqlite3 *db = NULL;
        if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
            if (db) sqlite3_close(db);
            continue;
        }
        sqlite3_stmt *stmt = NULL;
        NSString *sql = [NSString stringWithFormat:@"SELECT count(*) FROM sqlite_master WHERE type='table' AND name='%@';", table];
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) == SQLITE_OK &&
            sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int(stmt, 0) > 0) {
            sqlite3_finalize(stmt);
            stmt = NULL;
            NSString *countSql = [NSString stringWithFormat:@"SELECT count(*) FROM %@ WHERE Type = 1;", table];
            if (sqlite3_prepare_v2(db, countSql.UTF8String, -1, &stmt, NULL) == SQLITE_OK &&
                sqlite3_step(stmt) == SQLITE_ROW) {
                total += (NSUInteger)sqlite3_column_int64(stmt, 0);
            }
        }
        if (stmt) sqlite3_finalize(stmt);
        sqlite3_close(db);
    }
    return total;
}

#pragma mark - 关键词统计

/// LIKE 里 % _ \ 都要转义，否则「100%」「a_b」这类词会误匹配整表
static NSString *InsLikePattern(NSString *keyword) {
    NSMutableString *p = [keyword mutableCopy];
    [p replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:0 range:NSMakeRange(0, p.length)];
    [p replaceOccurrencesOfString:@"%" withString:@"\\%" options:0 range:NSMakeRange(0, p.length)];
    [p replaceOccurrencesOfString:@"_" withString:@"\\_" options:0 range:NSMakeRange(0, p.length)];
    return [NSString stringWithFormat:@"%%%@%%", p];
}

+ (BOOL)table:(NSString *)table existsIn:(sqlite3 *)db {
    sqlite3_stmt *stmt = NULL;
    BOOL exists = NO;
    if (sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?;",
                           -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, table.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) exists = sqlite3_column_int(stmt, 0) > 0;
    }
    if (stmt) sqlite3_finalize(stmt);
    return exists;
}

/// 老版本库里可能没有 WCDB_CT_Message 列：先探测，缺了就退化成不过滤
+ (BOOL)hasCompressionColumnIn:(sqlite3 *)db table:(NSString *)table {
    sqlite3_stmt *stmt = NULL;
    BOOL has = NO;
    NSString *sql = [NSString stringWithFormat:@"PRAGMA table_info(%@);", table];
    if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *name = sqlite3_column_text(stmt, 1);
            if (name && !strcmp((const char *)name, "WCDB_CT_Message")) { has = YES; break; }
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    return has;
}

+ (NSDictionary *)keywordStatsForTalker:(NSString *)wxid
                               keyword:(NSString *)keyword
                               samples:(NSInteger)samples {
    NSMutableDictionary *out = [@{
        @"total": @0, @"fromMe": @0, @"fromPartner": @0,
        @"first": @0, @"last": @0, @"textTotal": @0, @"compressed": @0,
        @"samples": @[],
    } mutableCopy];
    if (!wxid.length || !keyword.length) return out;

    NSString *table = InsMD5Table(wxid);
    NSString *pattern = InsLikePattern(keyword);
    NSInteger meVal = [self meDesValue];
    BOOL oneWay = [self isOneWayAccount:wxid];
    NSMutableArray *samplesOut = [NSMutableArray array];
    NSUInteger total = 0, fromMe = 0, fromPartner = 0, textTotal = 0, compressed = 0;
    uint32_t first = 0, last = 0;

    for (NSString *path in InsDatabasePaths()) {
        sqlite3 *db = NULL;
        if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
            if (db) sqlite3_close(db);
            continue;
        }
        if (![self table:table existsIn:db]) { sqlite3_close(db); continue; }
        BOOL hasCt = [self hasCompressionColumnIn:db table:table];
        NSString *ctFilter = hasCt ? @" AND IFNULL(WCDB_CT_Message, 0) = 0" : @"";

        // 会话在这张库里：先看清可读文本总量与压缩条数，用来交代统计覆盖面
        sqlite3_stmt *stmt = NULL;
        NSString *coverage = hasCt
            ? [NSString stringWithFormat:
                @"SELECT count(*), sum(CASE WHEN IFNULL(WCDB_CT_Message,0)<>0 THEN 1 ELSE 0 END) FROM %@ WHERE Type = 1;", table]
            : [NSString stringWithFormat:@"SELECT count(*), 0 FROM %@ WHERE Type = 1;", table];
        if (sqlite3_prepare_v2(db, coverage.UTF8String, -1, &stmt, NULL) == SQLITE_OK &&
            sqlite3_step(stmt) == SQLITE_ROW) {
            textTotal += (NSUInteger)sqlite3_column_int64(stmt, 0);
            compressed += (NSUInteger)sqlite3_column_int64(stmt, 1);
        }
        if (stmt) sqlite3_finalize(stmt);
        stmt = NULL;

        NSString *agg = [NSString stringWithFormat:
            @"SELECT count(*),"
            @" sum(CASE WHEN Des = ? THEN 1 ELSE 0 END),"
            @" sum(CASE WHEN Des <> ? THEN 1 ELSE 0 END),"
            @" min(CreateTime), max(CreateTime)"
            @" FROM %@ WHERE Type = 1%@ AND Message LIKE ? ESCAPE '\\';",
            table, ctFilter];
        if (sqlite3_prepare_v2(db, agg.UTF8String, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int(stmt, 1, (int)meVal);
            sqlite3_bind_int(stmt, 2, (int)meVal);
            sqlite3_bind_text(stmt, 3, pattern.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                total += (NSUInteger)sqlite3_column_int64(stmt, 0);
                fromMe += (NSUInteger)sqlite3_column_int64(stmt, 1);
                fromPartner += (NSUInteger)sqlite3_column_int64(stmt, 2);
                uint32_t mn = (uint32_t)sqlite3_column_int64(stmt, 3);
                uint32_t mx = (uint32_t)sqlite3_column_int64(stmt, 4);
                if (mn && (!first || mn < first)) first = mn;
                if (mx > last) last = mx;
            }
        }
        if (stmt) sqlite3_finalize(stmt);
        stmt = NULL;

        if (samples > 0) {
            NSString *sql = [NSString stringWithFormat:
                @"SELECT CreateTime, Des, Message FROM %@ WHERE Type = 1%@ AND Message LIKE ? ESCAPE '\\'"
                @" ORDER BY CreateTime DESC LIMIT %ld;", table, ctFilter, (long)samples];
            if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) == SQLITE_OK) {
                sqlite3_bind_text(stmt, 1, pattern.UTF8String, -1, SQLITE_TRANSIENT);
                while (sqlite3_step(stmt) == SQLITE_ROW) {
                    const unsigned char *bytes = sqlite3_column_text(stmt, 2);
                    if (!bytes) continue;
                    NSString *text = [NSString stringWithUTF8String:(const char *)bytes];
                    if (!text.length) continue;
                    NSInteger des = sqlite3_column_int(stmt, 1);
                    [samplesOut addObject:@{
                        @"t": @(sqlite3_column_int(stmt, 0)),
                        @"me": @(oneWay ? YES : (des == meVal)),
                        @"text": text,
                    }];
                }
            }
            if (stmt) sqlite3_finalize(stmt);
        }
        sqlite3_close(db);
    }

    if (oneWay) { fromMe = total; fromPartner = 0; }
    [samplesOut sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"t"] compare:a[@"t"]];
    }];
    if ((NSInteger)samplesOut.count > samples) {
        [samplesOut removeObjectsInRange:NSMakeRange(MAX(samples, 0), samplesOut.count - MAX(samples, 0))];
    }
    out[@"total"] = @(total);
    out[@"fromMe"] = @(fromMe);
    out[@"fromPartner"] = @(fromPartner);
    out[@"first"] = @(first);
    out[@"last"] = @(last);
    out[@"textTotal"] = @(textTotal);
    out[@"compressed"] = @(compressed);
    out[@"samples"] = samplesOut;
    return out;
}

/// 引用消息里的 svrid → 本地 MesLocalID。
/// 图片消息的磁盘文件名就是 MesLocalID，所以这是「引用某张图」唯一可靠的定位方式：
/// 引用消息只带 svrid，本地文件却没法和 svrid 对应。
+ (NSUInteger)localIDForSvrID:(NSString *)svrid talker:(NSString *)wxid {
    if (!svrid.length || !wxid.length) return 0;
    long long svr = [svrid longLongValue];
    if (svr <= 0) return 0;
    NSString *table = InsMD5Table(wxid);
    for (NSString *path in InsDatabasePaths()) {
        sqlite3 *db = NULL;
        if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
            if (db) sqlite3_close(db);
            continue;
        }
        BOOL hasTable = NO;
        sqlite3_stmt *st = NULL;
        if (sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master WHERE type='table' AND name=?;",
                               -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_text(st, 1, table.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(st) == SQLITE_ROW) hasTable = sqlite3_column_int(st, 0) > 0;
        }
        sqlite3_finalize(st);
        if (!hasTable) { sqlite3_close(db); continue; }
        NSUInteger found = 0;
        NSString *sql = [NSString stringWithFormat:
            @"SELECT MesLocalID FROM %@ WHERE MesSvrID = ? LIMIT 1;", table];
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(st, 1, svr);
            if (sqlite3_step(st) == SQLITE_ROW) found = (NSUInteger)sqlite3_column_int64(st, 0);
        }
        sqlite3_finalize(st);
        sqlite3_close(db);
        if (found) return found;
    }
    return 0;
}

@end
