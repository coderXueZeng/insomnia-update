#import "InsUpdate.h"
#import "InsConfig.h"
#import "InsMCP.h"
#import <CommonCrypto/CommonDigest.h>

// 微信进程处于沙箱内，popen 执行 /var/jb 下的 sudo/dpkg 会返回 127。
// 所有 shell 操作统一交给 ios-mcp 守护进程（沙箱外、PATH 含越狱工具链）。
static NSString *InsDaemon(NSString *command, NSError **error) {
    return [[InsMCP shared] shell:command error:error] ?: @"";
}

static NSData *InsHTTPGet(NSString *url, NSTimeInterval timeout, NSError **error) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.timeoutInterval = timeout;
    req.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
    __block NSData *data = nil;
    __block NSURLResponse *resp = nil;
    __block NSError *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        data = d; resp = r; err = e;
        dispatch_semaphore_signal(sem);
    }] resume];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 10) * NSEC_PER_SEC)))) {
        if (error) *error = [NSError errorWithDomain:@"Insomnia" code:-21
                                            userInfo:@{NSLocalizedDescriptionKey: @"下载超时"}];
        return nil;
    }
    if (err) { if (error) *error = err; return nil; }
    NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
    if (code < 200 || code >= 300) {
        if (error) *error = [NSError errorWithDomain:@"Insomnia" code:code
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:@"HTTP %ld", (long)code]}];
        return nil;
    }
    return data;
}

static NSString *InsTail(NSString *text, NSUInteger len) {
    if (text.length <= len) return text ?: @"";
    return [text substringFromIndex:text.length - len];
}

/// dpkg 装本地 deb：有 sudoPassword 走 askpass，没有就赌守护进程本身是 root。
/// 返回是否成功，output 回传原始输出方便诊断。
static BOOL InsDpkgInstall(NSString *debPath, NSString *sudoPassword, NSString **output) {
    NSString *askpass = [[InsConfig rootDir] stringByAppendingPathComponent:@".ap"];
    NSString *cmd = nil;
    if (sudoPassword.length) {
        NSString *script = [NSString stringWithFormat:@"#!/bin/sh\necho '%@'\n", sudoPassword];
        [script writeToFile:askpass atomically:YES encoding:NSUTF8StringEncoding error:nil];
        cmd = [NSString stringWithFormat:
            @"chmod 700 '%@'; SUDO_ASKPASS='%@' sudo -A dpkg -i '%@' 2>&1; __rc=$?; rm -f '%@'; echo __INS_RC__=$__rc",
            askpass, askpass, debPath, askpass];
    } else {
        [InsConfig log:@"未配置 sudoPassword：先试免密 dpkg（守护进程通常不是 root，多半会失败）"];
        cmd = [NSString stringWithFormat:@"dpkg -i '%@' 2>&1; __rc=$?; echo __INS_RC__=$__rc", debPath];
    }
    NSString *out = InsDaemon(cmd, NULL);
    if (output) *output = out;
    NSRange rcRange = [out rangeOfString:@"__INS_RC__=" options:NSBackwardsSearch];
    NSString *rcText = rcRange.location == NSNotFound ? @"" :
        [[out substringFromIndex:NSMaxRange(rcRange)]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [[NSFileManager defaultManager] removeItemAtPath:askpass error:nil];
    return [rcText isEqualToString:@"0"];
}

/// 装完让守护进程延迟拉起微信（必须带 --bundleid，否则 rc=0 但没反应）
static BOOL InsRestartWeChat(void) {
    NSString *probe = InsDaemon(@"test -x /var/jb/usr/bin/uiopen && echo yes", NULL);
    if (![probe containsString:@"yes"]) return NO;
    NSError *mcpErr = nil;
    InsDaemon(@"(sleep 5; /var/jb/usr/bin/uiopen --bundleid com.tencent.xin) >/dev/null 2>&1 &", &mcpErr);
    return mcpErr == nil;
}

@implementation InsUpdate

+ (void)runWithProgress:(void (^)(NSString *))progress
             completion:(void (^)(NSString *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        InsConfig *cfg = [InsConfig shared];
        void (^fail)(NSString *) = ^(NSString *msg) {
            [InsConfig log:[@"更新失败: " stringByAppendingString:msg]];
            if (completion) completion(nil, [NSError errorWithDomain:@"Insomnia" code:-20
                                                            userInfo:@{NSLocalizedDescriptionKey: msg}]);
        };
        // 清单地址是公开信息：config.json 被清空时仍走内置入口，避免自更新彻底断掉。
        // GitHub 直连在国内经常直接超时（日志里「拉取版本清单失败: 请求超时」就是这么来的），
        // 所以按「GitHub → jsDelivr → fastly」依次兜底，任一能通就能更新。
        NSArray<NSString *> *manifestURLs = cfg.updateManifest.length
            ? @[cfg.updateManifest]
            : @[@"https://github.com/coderXueZeng/insomnia-update/releases/latest/download/latest.json",
                @"https://cdn.jsdelivr.net/gh/coderXueZeng/insomnia-update@main/latest.json",
                @"https://fastly.jsdelivr.net/gh/coderXueZeng/insomnia-update@main/latest.json"];
        if (progress) progress(@"正在检查更新…");

        NSError *err = nil;
        NSData *mdata = nil;
        NSString *goodManifest = nil;
        for (NSString *raw in manifestURLs) {
            // 固定入口的 302 会被 CDN 或运营商缓存，带时间戳强制回源，
            // 否则新版本发布后手机仍拿到旧清单
            NSString *sep = [raw containsString:@"?"] ? @"&" : @"?";
            NSString *freshManifest = [NSString stringWithFormat:@"%@%@_=%lld", raw, sep,
                                       (long long)([[NSDate date] timeIntervalSince1970] * 1000)];
            NSError *one = nil;
            mdata = InsHTTPGet(freshManifest, 12, &one);
            err = one;
            if (mdata.length) { goodManifest = raw; break; }
            [InsConfig log:[NSString stringWithFormat:@"更新：清单入口不通 %@（%@）",
                            raw, one.localizedDescription ?: @"无响应"]];
        }
        if (!mdata) { fail([@"拉取版本清单失败: " stringByAppendingString:err.localizedDescription ?: @""]); return; }
        if (goodManifest.length) {
            [InsConfig log:[NSString stringWithFormat:@"更新：清单来自 %@", goodManifest]];
        }
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:mdata options:0 error:nil];
        NSString *version = [manifest[@"version"] isKindOfClass:[NSString class]] ? manifest[@"version"] : nil;
        NSString *url = [manifest[@"url"] isKindOfClass:[NSString class]] ? manifest[@"url"] : nil;
        NSString *sha = [manifest[@"sha256"] isKindOfClass:[NSString class]] ? manifest[@"sha256"] : nil;
        NSString *notes = [manifest[@"notes"] isKindOfClass:[NSString class]] ? manifest[@"notes"] : @"";
        if (!version.length || !url.length || !sha.length) { fail(@"版本清单缺 version/url/sha256"); return; }
        if (![url hasPrefix:@"https://"]) { fail(@"下载地址必须是 https"); return; }

        NSString *current = [InsDaemon(@"dpkg-query -W -f='${Version}' com.xuezeng.insomnia 2>/dev/null", NULL)
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (current.length && [current isEqualToString:version]) {
            if (completion) completion([NSString stringWithFormat:@"已是最新版 %@，无需更新。", version], nil);
            return;
        }
        if (progress) progress([NSString stringWithFormat:@"发现新版 %@（当前 %@），开始下载…",
                                version, current.length ? current : @"未知"]);

        NSData *deb = InsHTTPGet(url, 120, &err);
        if (!deb || deb.length < 10240) {
            // 主下载地址（jsDelivr）偶发 5xx/超时，换 fastly 同一个文件重试一次
            NSString *alt = [url hasPrefix:@"https://cdn.jsdelivr.net"]
                ? [url stringByReplacingOccurrencesOfString:@"https://cdn.jsdelivr.net"
                                                 withString:@"https://fastly.jsdelivr.net"]
                : nil;
            if (alt.length) {
                [InsConfig log:@"更新：deb 主地址失败，换 fastly 重试"];
                deb = InsHTTPGet(alt, 120, &err);
            }
        }
        if (!deb || deb.length < 10240) {
            fail([@"deb 下载失败: " stringByAppendingString:err.localizedDescription ?: @"文件过小"]);
            return;
        }
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(deb.bytes, (CC_LONG)deb.length, digest);
        NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
        for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
        if (![hex isEqualToString:sha.lowercaseString]) { fail(@"sha256 校验不一致，已丢弃下载内容"); return; }

        NSString *debPath = [[InsConfig rootDir] stringByAppendingPathComponent:@"update.deb"];
        if (![deb writeToFile:debPath atomically:YES]) { fail(@"deb 落盘失败"); return; }
        if (progress) progress(@"校验通过，正在安装…");

        // askpass 与 deb 都放在插件目录，守护进程（root）可直接读写；用完即删
        NSString *out = nil;
        BOOL ok = InsDpkgInstall(debPath, cfg.sudoPassword, &out);
        [InsConfig log:[NSString stringWithFormat:@"update dpkg(%@): %@", ok ? @"0" : @"fail", InsTail(out, 400)]];
        if (!ok) {
            BOOL denied = [out rangeOfString:@"超级用户权限"].location != NSNotFound ||
                          [out rangeOfString:@"Permission denied"].location != NSNotFound;
            NSString *hint = cfg.sudoPassword.length
                ? @"（密码可能不对，发 @insomnia 密码 <密码> 重新写一次）"
                : (denied
                   ? @"（守护进程不是 root，必须给 sudo 密码：发 @insomnia 密码 <密码>，v58 及更早用 @insomnia setup eyJzdWRvUGFzc3dvcmQiOiI... 这类短串）"
                   : @"（可用 setup 补回 sudoPassword）");
            fail([NSString stringWithFormat:@"dpkg 安装失败: %@%@", InsTail(out, 200), hint]);
            return;
        }
        [[NSFileManager defaultManager] removeItemAtPath:debPath error:nil];

        // 重启：让守护进程 5 秒后拉起微信，再退出本进程
        BOOL restarted = InsRestartWeChat();
        if (!restarted) {
            if (completion) completion([NSString stringWithFormat:
                @"已安装 %@%@，但自动重启不可用，请手动杀掉微信再打开。",
                version, notes.length ? [@"：" stringByAppendingString:notes] : @""], nil);
            return;
        }
        if (progress) progress([NSString stringWithFormat:@"安装完成，5 秒后自动重启微信。%@",
                                notes.length ? [@"更新内容：" stringByAppendingString:notes] : @""]);
        usleep(3 * 1000000);
        exit(0);
    });
}

/// 手动兜底通道：@insomnia 装 <deb 直链>
/// 配置被清空、清单地址丢了、甚至自更新链路整个断掉时，靠这一条仍然能把新包装回去。
+ (void)installFromURL:(NSString *)url
              progress:(void (^)(NSString *))progress
            completion:(void (^)(NSString *, NSError *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        InsConfig *cfg = [InsConfig shared];
        void (^fail)(NSString *) = ^(NSString *msg) {
            [InsConfig log:[@"安装失败: " stringByAppendingString:msg]];
            if (completion) completion(nil, [NSError errorWithDomain:@"Insomnia" code:-22
                                                            userInfo:@{NSLocalizedDescriptionKey: msg}]);
        };
        NSString *u = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (![u.lowercaseString hasPrefix:@"https://"]) { fail(@"地址必须是 https 直链"); return; }
        if (![u.lowercaseString containsString:@".deb"]) {
            // jsDelivr 之类的链接可能不带扩展名，但 GitHub Release 的一定带，给个明确提示
            [InsConfig log:@"安装地址不含 .deb，仍继续尝试"];
        }
        if (progress) progress(@"开始下载 deb…");
        NSError *err = nil;
        NSData *deb = InsHTTPGet(u, 240, &err);
        if (!deb || deb.length < 10240) {
            fail([@"下载失败: " stringByAppendingString:err.localizedDescription ?: @"文件过小"]);
            return;
        }
        NSString *debPath = [[InsConfig rootDir] stringByAppendingPathComponent:@"manual.deb"];
        if (![deb writeToFile:debPath atomically:YES]) { fail(@"deb 落盘失败"); return; }
        if (progress) progress([NSString stringWithFormat:@"下载完成（%lu KB），正在安装…",
                                (unsigned long)(deb.length / 1024)]);
        NSString *out = nil;
        BOOL ok = InsDpkgInstall(debPath, cfg.sudoPassword, &out);
        [InsConfig log:[NSString stringWithFormat:@"装 dpkg(%@): %@", ok ? @"0" : @"fail", InsTail(out, 400)]];
        if (!ok) {
            fail([NSString stringWithFormat:@"dpkg 安装失败: %@%@", InsTail(out, 200),
                  cfg.sudoPassword.length ? @"（密码可能不对，发 @insomnia 密码 <密码> 重写）"
                                          : @"（需要 sudo 密码：发 @insomnia 密码 <密码>）"]);
            return;
        }
        [[NSFileManager defaultManager] removeItemAtPath:debPath error:nil];
        NSString *ver = [InsDaemon(@"dpkg-query -W -f='${Version}' com.xuezeng.insomnia 2>/dev/null", NULL)
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        BOOL restarted = InsRestartWeChat();
        if (!restarted) {
            if (completion) completion([NSString stringWithFormat:
                @"已安装 %@，自动重启不可用，请手动杀掉微信再打开。", ver.length ? ver : @"新版本"], nil);
            return;
        }
        if (progress) progress([NSString stringWithFormat:@"已装 %@，5 秒后重启微信。", ver.length ? ver : @"新版本"]);
        usleep(3 * 1000000);
        exit(0);
    });
}

@end
