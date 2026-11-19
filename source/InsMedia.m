#import "InsMedia.h"
#import "InsConfig.h"
#import "InsMCP.h"
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonDigest.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <sqlite3.h>

static NSMutableDictionary *gMedia = nil;

static NSString *InsMediaPath(void) {
    return [[InsConfig rootDir] stringByAppendingPathComponent:@"media.json"];
}

static void InsMediaLoad(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *data = [NSData dataWithContentsOfFile:InsMediaPath()];
        NSDictionary *dict = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        gMedia = [dict isKindOfClass:[NSDictionary class]] ? [dict mutableCopy] : [NSMutableDictionary dictionary];
    });
}

static void InsMediaSave(void) {
    NSData *data = nil;
    @synchronized (gMedia) {
        data = [NSJSONSerialization dataWithJSONObject:gMedia options:0 error:nil];
    }
    [data writeToFile:InsMediaPath() atomically:YES];
}

static NSString *InsMD5(NSString *s) {
    const char *c = [s UTF8String];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(c, (CC_LONG)strlen(c), digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSString *InsXMLAttr(NSString *xml, NSString *name) {
    NSString *pattern = [NSString stringWithFormat:@"%@=\"([^\"]*)\"", name];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
    return m ? [xml substringWithRange:[m rangeAtIndex:1]] : nil;
}

static NSString *InsXMLTag(NSString *xml, NSString *tag) {
    NSString *pattern = [NSString stringWithFormat:@"<%1$@>\\s*(?:<!\\[CDATA\\[)?(.*?)(?:\\]\\]>)?\\s*</%1$@>", tag];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                              options:NSRegularExpressionDotMatchesLineSeparators error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
    return m ? [xml substringWithRange:[m rangeAtIndex:1]] : nil;
}

static NSString *InsNormalizeURL(NSString *url);

/// 去掉 <![CDATA[ ... ]]> 包裹，微信的 title/des/content 常用它
static NSString *InsStripCDATA(NSString *s) {
    NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length >= 12 && [t hasPrefix:@"<![CDATA["] && [t hasSuffix:@"]]>"]) {
        return [t substringWithRange:NSMakeRange(9, t.length - 12)];
    }
    return s;
}

/// HTML 实体解码：被引用的消息内容是转义过的 XML，不解开就读不到 <url>
static NSString *InsHTMLEntities(NSString *s) {
    if (!s.length) return @"";
    for (NSArray *pair in @[@[@"&lt;", @"<"], @[@"&gt;", @">"], @[@"&quot;", @"\""],
                            @[@"&apos;", @"'"], @[@"&#39;", @"'"], @[@"&nbsp;", @" "],
                            @[@"&amp;", @"&"]]) {
        s = [s stringByReplacingOccurrencesOfString:pair[0] withString:pair[1]];
    }
    return s;
}

/// 纯文本里的第一个 http(s) 地址，去掉中文标点尾巴
static NSString *InsFirstURL(NSString *s) {
    if (!s.length) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"https?://[^\\s<>\"'`\\)\\]}]+" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (!m) return nil;
    NSString *url = [s substringWithRange:m.range];
    NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:@"，。、；：！？,.;:!?）)】》\"'"];
    return InsNormalizeURL([url stringByTrimmingCharactersInSet:trim]);
}

static BOOL InsPlainImage(NSData *d) {
    if (d.length < 8) return NO;
    const uint8_t *b = d.bytes;
    return (b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) ||
           (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47);
}

static NSData *InsAESKey(NSString *aeskey, BOOL hexDecode) {
    NSData *raw = nil;
    if (hexDecode) {
        NSMutableData *out = [NSMutableData data];
        NSString *clean = [[aeskey lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@""];
        for (NSUInteger i = 0; i + 1 < clean.length; i += 2) {
            unsigned byte = 0;
            if (sscanf([clean substringWithRange:NSMakeRange(i, 2)].UTF8String, "%02x", &byte) != 1) return nil;
            [out appendBytes:&byte length:1];
        }
        raw = out;
    } else {
        raw = [aeskey dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (raw.length < 16) return nil;
    return [raw subdataWithRange:NSMakeRange(0, 16)];
}

static NSData *InsAESDecrypt(NSData *data, NSData *key) {
    if (!data.length || key.length != 16) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:data.length + 16];
    size_t moved = 0;
    CCCryptorStatus st = CCCrypt(kCCDecrypt, kCCAlgorithmAES, kCCOptionECBMode | kCCOptionPKCS7Padding,
                                 key.bytes, 16, NULL, data.bytes, data.length,
                                 out.mutableBytes, out.length, &moved);
    if (st != kCCSuccess) return nil;
    out.length = moved;
    return out;
}

/// wxgf 容器里是未加密的 HEVC 裸流（首帧常为空白占位帧），逐帧解码取最后一帧
static NSArray<NSData *> *InsHEVCNALs(NSData *d) {
    const uint8_t *b = d.bytes;
    NSUInteger n = d.length;
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSUInteger i = 0;
    while (i + 3 < n) {
        NSUInteger sc = 0;
        if (i + 4 < n && b[i] == 0 && b[i+1] == 0 && b[i+2] == 0 && b[i+3] == 1) sc = 4;
        else if (b[i] == 0 && b[i+1] == 0 && b[i+2] == 1) sc = 3;
        if (!sc) { i++; continue; }
        [starts addObject:@(i + sc)];
        i += sc;
    }
    NSMutableArray<NSData *> *nals = [NSMutableArray array];
    for (NSUInteger k = 0; k < starts.count; k++) {
        NSUInteger from = starts[k].unsignedIntegerValue;
        NSUInteger to = k + 1 < starts.count ? starts[k+1].unsignedIntegerValue - (b[starts[k+1].unsignedIntegerValue - 1] == 0 ? 4 : 3) : n;
        if (to > from) [nals addObject:[d subdataWithRange:NSMakeRange(from, to - from)]];
    }
    return nals;
}

static void InsHEVCOutput(void *ctx, void *src, OSStatus status, VTDecodeInfoFlags flags,
                          CVImageBufferRef buf, CMTime pts, CMTime dur) {
    CVImageBufferRef *hold = ctx;
    if (status == noErr && buf) {
        if (*hold) CVPixelBufferRelease(*hold);
        *hold = CVPixelBufferRetain(buf);
    }
}

static NSData *InsHEVCToJPEG(NSData *bitstream) {
    NSArray<NSData *> *nals = InsHEVCNALs(bitstream);
    NSMutableArray<NSData *> *params = [NSMutableArray array];
    NSData *jpeg = nil;
    for (NSData *nal in nals) {
        if (nal.length < 2) continue;
        uint8_t type = (((const uint8_t *)nal.bytes)[0] >> 1) & 0x3F;
        if (type == 32) [params removeAllObjects];
        if (type == 32 || type == 33 || type == 34) { [params addObject:nal]; continue; }
        if (type > 31 || params.count != 3) continue;

        const uint8_t *ptrs[3];
        size_t sizes[3];
        for (int k = 0; k < 3; k++) { ptrs[k] = params[k].bytes; sizes[k] = params[k].length; }
        CMVideoFormatDescriptionRef desc = NULL;
        if (CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, 3, ptrs, sizes, 4, NULL, &desc) != noErr || !desc) continue;

        NSMutableData *sample = [NSMutableData data];
        uint32_t len = CFSwapInt32HostToBig((uint32_t)nal.length);
        [sample appendBytes:&len length:4];
        [sample appendData:nal];
        CMBlockBufferRef block = NULL;
        CMSampleBufferRef sb = NULL;
        CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, sample.mutableBytes, sample.length,
                                           kCFAllocatorNull, NULL, 0, sample.length, 0, &block);
        if (block) {
            CMSampleTimingInfo timing = { kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid };
            CMSampleBufferCreate(kCFAllocatorDefault, block, true, NULL, NULL, desc, 1, 1, &timing, 0, NULL, &sb);
        }
        if (sb) {
            CVImageBufferRef hold = NULL;
            VTDecompressionOutputCallbackRecord rec = { InsHEVCOutput, &hold };
            VTDecompressionSessionRef session = NULL;
            if (VTDecompressionSessionCreate(kCFAllocatorDefault, desc, NULL, NULL, &rec, &session) == noErr && session) {
                VTDecompressionSessionDecodeFrame(session, sb, 0, NULL, NULL);
                VTDecompressionSessionWaitForAsynchronousFrames(session);
                if (hold) {
                    CGImageRef cg = NULL;
                    if (VTCreateCGImageFromCVPixelBuffer(hold, NULL, &cg) == noErr && cg) {
                        jpeg = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
                        CGImageRelease(cg);
                    }
                    CVPixelBufferRelease(hold);
                }
                VTDecompressionSessionInvalidate(session);
                CFRelease(session);
            }
            CFRelease(sb);
        }
        if (block) CFRelease(block);
        CFRelease(desc);
    }
    return jpeg;
}

static NSData *InsDownload(NSString *url, NSTimeInterval timeout) {
    if (!url.length) return nil;
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return nil;
    __block NSData *data = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.timeoutInterval = timeout;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        data = d;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 5) * NSEC_PER_SEC)));
    return data;
}

/// 网页专用下载：不少站点对 NSURLSession 默认 UA 直接弹验证页，这里伪装成微信内置浏览器
static NSData *InsDownloadHTML(NSString *url, NSTimeInterval timeout) {
    if (!url.length) return nil;
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return nil;
    __block NSData *data = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:u];
    req.timeoutInterval = timeout;
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 17_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.49(0x18003128) NetType/WIFI Language/zh_CN"
          forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
          forHTTPHeaderField:@"Accept"];
    [req setValue:@"zh-CN,zh;q=0.9" forHTTPHeaderField:@"Accept-Language"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSInteger status = [(NSHTTPURLResponse *)r statusCode];
        data = (e || status >= 400) ? nil : d;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 5) * NSEC_PER_SEC)));
    return data;
}

/// 微信分享 XML 里的 URL 常带 &amp; 之类实体，不解码会抓到错地址
static NSString *InsNormalizeURL(NSString *url) {
    NSString *s = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSArray *pair in @[@[@"&amp;", @"&"], @[@"&#39;", @"'"], @[@"&quot;", @"\""],
                            @[@"&lt;", @"<"], @[@"&gt;", @">"]]) {
        s = [s stringByReplacingOccurrencesOfString:pair[0] withString:pair[1]];
    }
    return s;
}

/// 反爬验证页 / 空壳页判定，别把「环境异常」当正文交给模型
static BOOL InsIsUselessBody(NSString *text) {
    if (text.length < 120) return YES;
    NSArray *marks = @[@"环境异常", @"需要验证", @"访问验证", @"请完成验证", @"安全验证",
                       @"请开启JavaScript", @"请开启 JavaScript", @"滑动验证", @"验证码",
                       @"Just a moment", @"Checking your browser", @"Access Denied",
                       @"403 Forbidden", @"captcha"];
    for (NSString *mark in marks) {
        if ([text rangeOfString:mark options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

/// 微信「合并转发聊天记录」是 appmsg type 19，正文装在 <recorditem> 的 CDATA 里
static BOOL InsIsChatRecordXML(NSString *xml) {
    if (!xml.length) return NO;
    for (NSString *mark in @[@"<recorditem", @"<recordinfo", @"<datalist", @"<type>19</type>"]) {
        if ([xml rangeOfString:mark].location != NSNotFound) return YES;
    }
    return NO;
}

static NSString *InsCleanRecordField(NSString *s) {
    NSString *t = InsHTMLEntities(InsStripCDATA(s ?: @""));
    NSRegularExpression *tag = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
    t = [tag stringByReplacingMatchesInString:t options:0 range:NSMakeRange(0, t.length) withTemplate:@" "];
    NSRegularExpression *ws = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    t = [ws stringByReplacingMatchesInString:t options:0 range:NSMakeRange(0, t.length) withTemplate:@" "];
    return [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

/// 把 <datalist> 里的每条 <dataitem> 还原成「序号. 发言人（时间）：内容」
static NSString *InsChatRecordTextFrom(NSString *xml, NSInteger *outCount) {
    NSString *raw = InsHTMLEntities(xml ?: @"");
    if (!InsIsChatRecordXML(raw)) return nil;
    NSRegularExpression *itemRe = [NSRegularExpression regularExpressionWithPattern:
        @"<dataitem\\b[^>]*>([\\s\\S]*?)</dataitem>"
        options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:nil];
    NSArray *matches = [itemRe matchesInString:raw options:0 range:NSMakeRange(0, raw.length)];
    if (!matches.count) return nil;
    NSMutableString *out = [NSMutableString string];
    NSInteger n = 0, shown = 0;
    for (NSTextCheckingResult *m in matches) {
        NSString *block = [raw substringWithRange:[m rangeAtIndex:1]];
        NSString *name = InsCleanRecordField(InsXMLTag(block, @"sourcename"));
        NSString *content = InsCleanRecordField(InsXMLTag(block, @"content"));
        NSString *when = InsCleanRecordField(InsXMLTag(block, @"sourcetime"));
        if (!content.length) content = InsCleanRecordField(InsXMLTag(block, @"datatitle"));
        if (!content.length) content = InsCleanRecordField(InsXMLTag(block, @"datadesc"));
        if (!content.length) content = @"[图片/文件等非文本消息]";
        if (!name.length) name = @"某人";
        if (content.length > 300) content = [[content substringToIndex:300] stringByAppendingString:@"…"];
        if (when.length > 24) when = [when substringToIndex:24];
        n++;
        if (shown < 60 && out.length < 8000) {
            [out appendFormat:@"%ld. %@%@：%@\n", (long)n, name,
             when.length ? [NSString stringWithFormat:@"（%@）", when] : @"", content];
            shown++;
        }
    }
    if (outCount) *outCount = n;
    if (!out.length) return nil;
    if (n > shown) [out appendFormat:@"（后面还有 %ld 条，先分析前面这些）\n", (long)(n - shown)];
    return out;
}

/// ocr_screen / get_ui_elements 的返回可能是 JSON，也可能是纯文本，统一抽成一行行的文字
static NSString *InsScreenReadableText(NSString *raw) {
    if (!raw.length) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:[raw dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0 error:nil];
    NSMutableString *out = [NSMutableString string];
    if ([json isKindOfClass:[NSDictionary class]]) {
        for (NSString *key in @[@"texts", @"elements", @"items"]) {
            NSArray *arr = json[key];
            if (![arr isKindOfClass:[NSArray class]]) continue;
            for (id it in arr) {
                NSString *t = nil;
                if ([it isKindOfClass:[NSString class]]) t = it;
                else if ([it isKindOfClass:[NSDictionary class]]) t = it[@"text"] ?: it[@"content"] ?: it[@"label"];
                if ([t isKindOfClass:[NSString class]] && t.length) [out appendFormat:@"%@\n", t];
            }
        }
        if (!out.length && [json[@"text"] isKindOfClass:[NSString class]]) [out appendString:json[@"text"]];
        if (!out.length && [json[@"output"] isKindOfClass:[NSString class]]) [out appendString:json[@"output"]];
    }
    if (!out.length) [out appendString:raw];
    return out;
}

/// 去掉 OCR 里的界面按钮/重复行，只留像正文的内容
static NSString *InsCleanScreenText(NSString *text) {
    NSArray *noise = @[@"返回", @"完成", @"分享", @"刷新", @"复制链接", @"在浏览器中打开",
                       @"Safari", @"搜索或输入网址", @"取消", @"关闭", @"更多"];
    NSMutableString *out = [NSMutableString string];
    NSString *lastLine = nil;
    for (NSString *rawLine in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length < 4 || [line isEqualToString:lastLine]) continue;
        BOOL skip = NO;
        for (NSString *n in noise) if ([line isEqualToString:n]) { skip = YES; break; }
        if (skip) continue;
        lastLine = line;
        [out appendFormat:@"%@\n", line];
        if (out.length > 6000) break;
    }
    return out;
}

static BOOL InsScreenTextUseful(NSString *t) {
    if (t.length < 60) return NO;
    for (NSString *mark in @[@"环境异常", @"需要验证", @"请完成验证", @"安全验证",
                             @"Just a moment", @"Checking your browser", @"Access Denied",
                             @"无法打开页面", @"打不开该网页", @"404 Not Found"]) {
        if ([t rangeOfString:mark options:NSCaseInsensitiveSearch].location != NSNotFound) return NO;
    }
    return YES;
}

static NSMutableDictionary *gScreenAttempts = nil;

/// 自动兜底时同一网址 10 分钟只试一次，避免用户每问一次手机就跳一次浏览器
static BOOL InsScreenShouldTry(NSString *url, BOOL force) {
    if (force) return YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gScreenAttempts = [NSMutableDictionary dictionary]; });
    @synchronized (gScreenAttempts) {
        NSDate *last = gScreenAttempts[url];
        if (last && [[NSDate date] timeIntervalSinceDate:last] < 600) return NO;
        gScreenAttempts[url] = [NSDate date];
        if (gScreenAttempts.count > 30) [gScreenAttempts removeAllObjects];
    }
    return YES;
}

/// 微信收图目录：Documents/<账号md5>/Img/<会话md5>/<消息localID>.pic[_thum]
static NSString *InsImgDir(NSString *talker) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *sub = [@"Img/" stringByAppendingString:InsMD5([talker lowercaseString])];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *dir in [fm contentsOfDirectoryAtPath:docs error:nil]) {
        if (dir.length != 32) continue;
        NSString *path = [[docs stringByAppendingPathComponent:dir] stringByAppendingPathComponent:sub];
        if ([fm fileExistsAtPath:path]) return path;
    }
    return nil;
}

@implementation InsMedia

+ (void)remember:(NSString *)talker
            type:(NSUInteger)type
             xml:(NSString *)xml
         localID:(NSUInteger)localID
            time:(uint32_t)time {
    if (!talker.length || !xml.length) return;
    NSString *kind = nil;
    if (type == 3) kind = @"image";
    else if (type == 49 && InsIsChatRecordXML(xml)) kind = @"record";
    else if (type == 49 && [xml rangeOfString:@"<type>5</type>"].location != NSNotFound) kind = @"link";
    if (!kind) return;
    InsMediaLoad();
    @synchronized (gMedia) {
        NSMutableDictionary *slot = [gMedia[talker] isKindOfClass:[NSDictionary class]]
            ? [gMedia[talker] mutableCopy] : [NSMutableDictionary dictionary];
        NSDictionary *item = @{@"xml": xml, @"localID": @(localID), @"time": @(time)};
        slot[kind] = item;
        if ([kind isEqual:@"image"]) {
            // 「分析上面这两张图」很常见，只留最后一张就会丢掉前一秒发的另一张，
            // 所以图片也留一个最近列表（最多 6 张），lastForTalker 仍然可用
            NSMutableArray *arr = [slot[@"recentImages"] isKindOfClass:[NSArray class]]
                ? [slot[@"recentImages"] mutableCopy] : [NSMutableArray array];
            NSMutableIndexSet *dup = [NSMutableIndexSet indexSet];
            [arr enumerateObjectsUsingBlock:^(id old, NSUInteger idx, BOOL *stop) {
                if (![old isKindOfClass:[NSDictionary class]]) return;
                // 同一条消息重复到达/重发时按 localID+时间 去重，避免同一张被算成两张
                if ([old[@"localID"] unsignedIntegerValue] == localID &&
                    [old[@"time"] unsignedIntegerValue] == time) [dup addIndex:idx];
            }];
            if (dup.count) [arr removeObjectsAtIndexes:dup];
            [arr addObject:item];
            while (arr.count > 6) [arr removeObjectAtIndex:0];
            slot[@"recentImages"] = arr;
        }
        if ([kind isEqual:@"link"]) {
            // 会话里可能连着发好几条链接，只存「最后一条」不够用，留一个最近列表供「第N条/上一条」选择
            NSMutableArray *arr = [slot[@"recentLinks"] isKindOfClass:[NSArray class]]
                ? [slot[@"recentLinks"] mutableCopy] : [NSMutableArray array];
            NSString *url = [self linkInfoFor:item][@"url"] ?: @"";
            if (url.length) {
                NSMutableIndexSet *dup = [NSMutableIndexSet indexSet];
                [arr enumerateObjectsUsingBlock:^(id old, NSUInteger idx, BOOL *stop) {
                    if (![old isKindOfClass:[NSDictionary class]]) return;
                    NSString *oldURL = [self linkInfoFor:old][@"url"] ?: @"";
                    if ([oldURL isEqualToString:url]) [dup addIndex:idx];
                }];
                [arr removeObjectsAtIndexes:dup];
            }
            [arr addObject:item];
            while (arr.count > 8) [arr removeObjectAtIndex:0];
            slot[@"recentLinks"] = arr;
        }
        if ([kind isEqual:@"record"]) {
            NSMutableArray *arr = [slot[@"recentRecords"] isKindOfClass:[NSArray class]]
                ? [slot[@"recentRecords"] mutableCopy] : [NSMutableArray array];
            [arr addObject:item];
            while (arr.count > 3) [arr removeObjectAtIndex:0];
            slot[@"recentRecords"] = arr;
        }
        gMedia[talker] = slot;
    }
    InsMediaSave();
    NSString *label = [kind isEqual:@"image"] ? @"图片"
                    : ([kind isEqual:@"record"] ? @"聊天记录" : @"链接");
    [InsConfig log:[NSString stringWithFormat:@"记下最近%@ %@ localID=%lu",
                    label, talker, (unsigned long)localID]];
}

+ (NSArray<NSDictionary *> *)recordsForTalker:(NSString *)talker {
    if (!talker.length) return @[];
    InsMediaLoad();
    @synchronized (gMedia) {
        NSDictionary *slot = gMedia[talker];
        NSArray *arr = slot[@"recentRecords"];
        NSMutableArray *out = [NSMutableArray array];
        if ([arr isKindOfClass:[NSArray class]]) {
            for (id item in [arr reverseObjectEnumerator]) {
                if ([item isKindOfClass:[NSDictionary class]]) [out addObject:item];
            }
        }
        if (!out.count) {
            NSDictionary *one = slot[@"record"];
            if ([one isKindOfClass:[NSDictionary class]]) [out addObject:one];
        }
        return out;
    }
}

+ (NSArray<NSDictionary *> *)linksForTalker:(NSString *)talker {
    if (!talker.length) return @[];
    InsMediaLoad();
    @synchronized (gMedia) {
        NSDictionary *slot = gMedia[talker];
        NSArray *arr = slot[@"recentLinks"];
        if ([arr isKindOfClass:[NSArray class]] && arr.count) {
            NSMutableArray *out = [NSMutableArray array];
            for (id item in [arr reverseObjectEnumerator]) {
                if ([item isKindOfClass:[NSDictionary class]]) [out addObject:item];
            }
            return out;
        }
        NSDictionary *one = slot[@"link"];
        return [one isKindOfClass:[NSDictionary class]] ? @[one] : @[];
    }
}

+ (NSDictionary *)lastForTalker:(NSString *)talker kind:(NSString *)kind {
    if (!talker.length) return nil;
    InsMediaLoad();
    @synchronized (gMedia) {
        NSDictionary *slot = gMedia[talker];
        NSDictionary *m = slot[kind];
        return [m isKindOfClass:[NSDictionary class]] ? m : nil;
    }
}

+ (NSArray<NSDictionary *> *)imagesForTalker:(NSString *)talker limit:(NSUInteger)limit {
    if (!talker.length) return @[];
    InsMediaLoad();
    @synchronized (gMedia) {
        NSDictionary *slot = gMedia[talker];
        NSArray *arr = slot[@"recentImages"];
        NSMutableArray *out = [NSMutableArray array];
        if ([arr isKindOfClass:[NSArray class]] && arr.count) {
            for (id item in [arr reverseObjectEnumerator]) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                // 同一张缩略图可能占两条（不同 localID），按 xml 去重
                BOOL dup = NO;
                for (NSDictionary *old in out) {
                    if ([old[@"xml"] isEqual:item[@"xml"]]) { dup = YES; break; }
                }
                if (dup) continue;
                [out addObject:item];
                if (limit && out.count >= limit) break;
            }
        }
        if (!out.count) {
            NSDictionary *one = slot[@"image"];
            if ([one isKindOfClass:[NSDictionary class]]) [out addObject:one];
        }
        return out;
    }
}

+ (NSData *)imageDataFor:(NSDictionary *)media talker:(NSString *)talker error:(NSError **)error {
    NSString *xml = media[@"xml"];
    NSUInteger localID = [media[@"localID"] unsignedIntegerValue];
    uint32_t time = [media[@"time"] unsignedIntValue];
    NSString *dir = InsImgDir(talker);
    NSString *base = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%lu", (unsigned long)localID]];

    NSData *full = [NSData dataWithContentsOfFile:[base stringByAppendingString:@".pic"]];
    if (InsPlainImage(full)) {
        [InsConfig log:@"看图：用本地全图"];
        return full;
    }
    if (full.length > 4 && memcmp(full.bytes, "wxgf", 4) == 0) {
        NSData *jpg = InsHEVCToJPEG(full);
        if (jpg.length) {
            [InsConfig log:[NSString stringWithFormat:@"看图：wxgf HEVC 解出全图 %lu 字节", (unsigned long)jpg.length]];
            return jpg;
        }
    }

    // 老版本消息的 cdnmidimgurl 才是 http 直链；新版换成了内部 CDN token，下载不了。
    // 引用消息没有本地文件可退（它的 localID 是当前那条命令消息的），只能全力在线上找：
    // cdnbigimgurl / cdnmidimgurl / cdnthumburl 三个地址都试，key 也 ascii / hex 各试一次。
    NSString *aeskey = InsXMLAttr(xml, @"aeskey");
    NSString *cdn = InsXMLAttr(xml, @"cdnmidimgurl");
    NSString *thumbKey = InsXMLAttr(xml, @"cdnthumbaeskey");
    NSArray *cands = @[
        @[(InsXMLAttr(xml, @"cdnbigimgurl") ?: @""), (aeskey ?: @"")],
        @[(cdn ?: @""), (aeskey ?: @"")],
        @[(InsXMLAttr(xml, @"cdnthumburl") ?: @""), (thumbKey.length ? thumbKey : (aeskey ?: @""))],
    ];
    NSUInteger candIndex = 0;
    for (NSArray *pair in cands) {
        candIndex++;
        NSString *link = [pair[0] isKindOfClass:[NSString class]] ? pair[0] : @"";
        NSString *aes = [pair[1] isKindOfClass:[NSString class]] ? pair[1] : @"";
        if (![link hasPrefix:@"http"]) continue;
        NSData *blob = InsDownload(link, 15);
        if (InsPlainImage(blob)) {
            [InsConfig log:[NSString stringWithFormat:@"看图：用 CDN 原图（第 %lu 个地址）", (unsigned long)candIndex]];
            return blob;
        }
        if (blob.length && aes.length) {
            for (NSNumber *hex in @[@NO, @YES]) {
                NSData *dec = InsAESDecrypt(blob, InsAESKey(aes, hex.boolValue));
                if (InsPlainImage(dec)) {
                    [InsConfig log:[NSString stringWithFormat:@"看图：CDN 解密成功（第 %lu 个地址，%@ key）",
                                    (unsigned long)candIndex, hex.boolValue ? @"hex" : @"ascii"]];
                    return dec;
                }
            }
        }
    }

    NSData *thum = [NSData dataWithContentsOfFile:[base stringByAppendingString:@".pic_thum"]];
    if (InsPlainImage(thum)) {
        [InsConfig log:@"看图：用本地缩略图"];
        return thum;
    }

    // localID 对不上时按收图时间窗找：先找全图 .pic（有时要看清图里的字），没有再退缩略图。
    // 时间来自引用消息的 createtime，窗口收紧到 90 秒——宁可报错，也别拿成邻桌那张。
    if (dir.length && time) {
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *bestFull = nil, *bestThumb = nil;
        NSTimeInterval fullDelta = DBL_MAX, thumbDelta = DBL_MAX;
        for (NSString *file in [fm contentsOfDirectoryAtPath:dir error:nil]) {
            BOOL isFull = [file hasSuffix:@".pic"];
            BOOL isThumb = [file hasSuffix:@".pic_thum"];
            if (!isFull && !isThumb) continue;
            NSString *path = [dir stringByAppendingPathComponent:file];
            NSDictionary *attr = [fm attributesOfItemAtPath:path error:nil];
            NSTimeInterval delta = fabs([[attr fileModificationDate] timeIntervalSince1970] - (NSTimeInterval)time);
            if (delta > 90) continue;
            if (isFull && delta < fullDelta) { fullDelta = delta; bestFull = path; }
            if (isThumb && delta < thumbDelta) { thumbDelta = delta; bestThumb = path; }
        }
        for (NSString *path in @[bestFull ?: @"", bestThumb ?: @""]) {
            if (!path.length) continue;
            BOOL isFull = [path isEqualToString:bestFull];
            NSData *d = [NSData dataWithContentsOfFile:path];
            if (InsPlainImage(d)) {
                [InsConfig log:[NSString stringWithFormat:@"看图：按时间窗兜底%@（差 %.0f 秒）",
                                isFull ? @"全图" : @"缩略图", isFull ? fullDelta : thumbDelta]];
                return d;
            }
            if (d.length > 4 && memcmp(d.bytes, "wxgf", 4) == 0) {
                NSData *jpg = InsHEVCToJPEG(d);
                if (jpg.length) {
                    [InsConfig log:[NSString stringWithFormat:
                        @"看图：按时间窗兜底全图（wxgf 解码 %lu 字节，差 %.0f 秒）",
                        (unsigned long)jpg.length, isFull ? fullDelta : thumbDelta]];
                    return jpg;
                }
            }
        }
    }
    if (error) *error = [NSError errorWithDomain:@"InsMedia" code:-1
                                        userInfo:@{NSLocalizedDescriptionKey: @"本地和 CDN 都没拿到可用图片"}];
    return nil;
}

+ (NSDictionary *)linkInfoFor:(NSDictionary *)media {
    return [self linkInfoFromText:media[@"xml"]] ?: @{ @"title": @"", @"des": @"", @"url": @"" };
}

+ (NSString *)chatRecordTextFrom:(NSString *)xml {
    return InsChatRecordTextFrom(xml, NULL);
}

+ (NSDictionary *)linkInfoFromText:(NSString *)text {
    NSString *raw = InsHTMLEntities(text ?: @"");
    if (!raw.length) return nil;
    NSString *title = InsStripCDATA(InsXMLTag(raw, @"title") ?: @"");
    NSString *des = InsStripCDATA(InsXMLTag(raw, @"des") ?: @"");
    if (!des.length) des = InsStripCDATA(InsXMLTag(raw, @"description") ?: @"");
    NSString *url = InsNormalizeURL(InsStripCDATA(InsXMLTag(raw, @"url") ?: @""));
    if (!url.length) {
        // 老式链接卡片把地址放在 appmsg 的 url 属性上；加 \s 边界，免得误抓 thumburl="..."
        NSRegularExpression *attrRe = [NSRegularExpression regularExpressionWithPattern:
            @"\\surl=\"([^\"]*)\"" options:0 error:nil];
        NSTextCheckingResult *am = [attrRe firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)];
        if (am) url = InsNormalizeURL([raw substringWithRange:[am rangeAtIndex:1]]);
    }
    if (!url.length) url = InsFirstURL(raw) ?: @"";
    if (![url.lowercaseString hasPrefix:@"http"]) return nil;
    return @{ @"title": title ?: @"", @"des": des ?: @"", @"url": url ?: @"" };
}

#pragma mark - 文件消息（appmsg type 6）

/// MMServiceCenter 只在主线程给服务，调用方负责切线程
static id InsMediaService(NSString *className) {
    Class center = NSClassFromString(@"MMServiceCenter");
    Class service = NSClassFromString(className);
    if (!center || !service) return nil;
    @try {
        id (*call0)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id (*call1)(id, SEL, id) = (id (*)(id, SEL, id))objc_msgSend;
        id c = call0((id)center, NSSelectorFromString(@"defaultCenter"));
        return c ? call1(c, NSSelectorFromString(@"getService:"), (id)service) : nil;
    } @catch (NSException *e) { return nil; }
}

/// 账号数据目录（Documents 下 32 位 hash）；文件下载在 <账号>/OpenData 里
static NSArray<NSString *> *InsMediaAccountDirs(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *d in [fm contentsOfDirectoryAtPath:docs error:nil]) {
        if (d.length != 32) continue;
        NSString *root = [docs stringByAppendingPathComponent:d];
        BOOL isDir = NO;
        NSString *open = [root stringByAppendingPathComponent:@"OpenData"];
        if ([fm fileExistsAtPath:open isDirectory:&isDir] && isDir) [out addObject:root];
    }
    return out;
}

/// 微信把收到的文件放在 OpenData/<md5(会话)>/<消息 localID>/ 下，
/// 文件名有的保留原名（x.txt），有的换成内容 md5（xxx.pdf）。
/// 所以只认目录，不认文件名。
static NSString *InsMediaAttachDir(NSString *talker, unsigned long long localID) {
    if (!localID || !talker.length) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dirName = [NSString stringWithFormat:@"%llu", localID];
    for (NSString *root in InsMediaAccountDirs()) {
        NSString *p = [[[[root stringByAppendingPathComponent:@"OpenData"]
                         stringByAppendingPathComponent:InsMD5(talker)]
                        stringByAppendingPathComponent:dirName] copy];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:p isDirectory:&isDir] && isDir) return p;
    }
    return nil;
}

/// 目录里挑出「正片」：排除缩略图/临时分片
static NSString *InsMediaMainFileIn(NSString *dir) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *best = nil;
    unsigned long long bestSize = 0;
    for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
        NSString *lower = f.lowercaseString;
        if ([lower hasSuffix:@".pic_thum"] || [lower hasSuffix:@".record_thumb"] ||
            [lower hasSuffix:@".record_dat_temp"] || [lower hasSuffix:@"_thumb"] ||
            [lower hasPrefix:@"."]) continue;
        NSString *p = [dir stringByAppendingPathComponent:f];
        unsigned long long size = [[fm attributesOfItemAtPath:p error:nil] fileSize];
        if (size > bestSize) { bestSize = size; best = p; }
    }
    return best;
}

/// 内部接口偶尔拿不到消息（主线程忙时超时），退回直接读库：
/// Chat_<md5(会话)> 表里 MesSvrID 就是服务端 ID，MesLocalID 就是我们要的目录名
static unsigned long long InsMediaLocalIDFromDB(NSString *svrid, NSString *talker) {
    if (!svrid.length || !talker.length) return 0;
    NSString *table = [NSString stringWithFormat:@"Chat_%@", InsMD5(talker)];
    for (NSString *root in InsMediaAccountDirs()) {
        NSString *path = [[root stringByAppendingPathComponent:@"DB"] stringByAppendingPathComponent:@"MM.sqlite"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        sqlite3 *db = NULL;
        if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
            if (db) sqlite3_close(db);
            continue;
        }
        sqlite3_busy_timeout(db, 1500);
        unsigned long long out = 0;
        sqlite3_stmt *stmt = NULL;
        NSString *sql = [NSString stringWithFormat:@"SELECT MesLocalID FROM %@ WHERE MesSvrID=? LIMIT 1;", table];
        if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(stmt, 1, (sqlite3_int64)[svrid longLongValue]);
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                out = (unsigned long long)sqlite3_column_int64(stmt, 0);
            }
        }
        if (stmt) sqlite3_finalize(stmt);
        sqlite3_close(db);
        if (out) return out;
    }
    return 0;
}

/// svrid → 本地消息 ID（只有本地 ID 才能定位到文件目录）
static unsigned long long InsMediaLocalIDForSvrId(NSString *svrid, NSString *talker, id *wrapOut) {
    if (!svrid.length || !talker.length) return 0;
    __block unsigned long long localID = 0;
    __block id found = nil;
    for (int attempt = 0; attempt < 2 && !localID; attempt++) {
        void (^work)(void) = ^{
            @try {
                id mgr = InsMediaService(@"CMessageMgr");
                SEL sel = NSSelectorFromString(@"GetMsg:n64SvrID:");
                if (!mgr || ![mgr respondsToSelector:sel]) return;
                id (*call2)(id, SEL, id, long long) = (id (*)(id, SEL, id, long long))objc_msgSend;
                id wrap = call2(mgr, sel, talker, (long long)[svrid longLongValue]);
                if (!wrap) return;
                found = wrap;
                id v = [wrap valueForKey:@"m_uiMesLocalID"];
                localID = [v respondsToSelector:@selector(unsignedLongLongValue)] ? [v unsignedLongLongValue] : 0;
            } @catch (NSException *e) {}
        };
        if ([NSThread isMainThread]) {
            work();
        } else {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            dispatch_async(dispatch_get_main_queue(), ^{ work(); dispatch_semaphore_signal(sem); });
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        }
        if (!localID && attempt == 0) [NSThread sleepForTimeInterval:0.4];
    }
    if (!localID) {
        // 主线程拿不到就退回直接查库：Chat_<md5(会话)> 里 MesSvrID 就是它
        localID = InsMediaLocalIDFromDB(svrid, talker);
        if (localID) [InsConfig log:[NSString stringWithFormat:
            @"文件：内部接口没给消息，改从库里查到 localID=%llu", localID]];
    }
    if (wrapOut) *wrapOut = found;
    [InsConfig log:[NSString stringWithFormat:@"文件：定位 svrid=%@ talker=%@ → localID=%llu wrap=%@",
                    svrid, talker, localID, found ? @"有" : @"无"]];
    return localID;
}

/// 让微信自己去下载这条 AppAttach（等于用户在聊天里点了一下文件）。
/// 微信内部这条下载链路有五个变体，版本之间谁在不一定，逐个试到有一个接住为止。
static BOOL InsMediaStartDownload(id wrap, NSDictionary *info) {
    if (!wrap) return NO;
    __block BOOL started = NO;
    __block NSString *used = @"";
    void (^work)(void) = ^{
        @try {
            id mgr = InsMediaService(@"CMessageMgr");
            if (!mgr) return;
            NSString *attachId = info[@"attachid"] ?: @"";
            unsigned int size = (unsigned int)[info[@"size"] longLongValue];
            NSString *ext = info[@"ext"] ?: @"";
            BOOL (*f4)(id, SEL, id, id, BOOL, BOOL) = (BOOL (*)(id, SEL, id, id, BOOL, BOOL))objc_msgSend;
            SEL full = NSSelectorFromString(@"StartDownloadAppAttach:MsgWrap:Silent:autoDownload:");
            if ([mgr respondsToSelector:full] && f4(mgr, full, nil, wrap, YES, YES)) {
                started = YES; used = @"Silent:autoDownload";
            }
            SEL plain = NSSelectorFromString(@"StartDownloadAppAttach:MsgWrap:");
            if (!started && [mgr respondsToSelector:plain]) {
                BOOL (*f2)(id, SEL, id, id) = (BOOL (*)(id, SEL, id, id))objc_msgSend;
                if (f2(mgr, plain, nil, wrap)) { started = YES; used = @"MsgWrap"; }
            }
            SEL withInfo = NSSelectorFromString(@"StartDownloadAppAttach:MsgWrap:AttachId:AttachDataSize:AttachFileExt:");
            if (!started && [mgr respondsToSelector:withInfo]) {
                BOOL (*f5)(id, SEL, id, id, id, unsigned int, id) =
                    (BOOL (*)(id, SEL, id, id, id, unsigned int, id))objc_msgSend;
                if (f5(mgr, withInfo, nil, wrap, attachId, size, ext)) { started = YES; used = @"AttachId"; }
            }
            SEL behave = NSSelectorFromString(@"StartDownloadAppAttach:MsgWrap:Silent:autoDownload:behavior:");
            if (!started && [mgr respondsToSelector:behave]) {
                BOOL (*f6)(id, SEL, id, id, BOOL, BOOL, NSInteger) =
                    (BOOL (*)(id, SEL, id, id, BOOL, BOOL, NSInteger))objc_msgSend;
                if (f6(mgr, behave, nil, wrap, YES, YES, 0)) { started = YES; used = @"behavior"; }
            }
            SEL cdn = NSSelectorFromString(@"StartDownloadAppAttachInCDN:MsgWrap:Silent:autoDownload:behavior:");
            if (!started && [mgr respondsToSelector:cdn]) {
                BOOL (*f7)(id, SEL, id, id, BOOL, BOOL, NSInteger) =
                    (BOOL (*)(id, SEL, id, id, BOOL, BOOL, NSInteger))objc_msgSend;
                if (f7(mgr, cdn, nil, wrap, YES, YES, 0)) { started = YES; used = @"InCDN"; }
            }
        } @catch (NSException *e) {}
    };
    if ([NSThread isMainThread]) work();
    else {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{ work(); dispatch_semaphore_signal(sem); });
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    }
    [InsConfig log:[NSString stringWithFormat:@"文件：下载请求 %@（%@）",
                    started ? [NSString stringWithFormat:@"已提交 via %@", used] : @"全部接口都没接住",
                    info[@"name"] ?: @"?"]];
    return started;
}

/// 按 UTF-8 → GB18030 → UTF-16 依次试，读不成文本就说明是二进制
static NSString *InsMediaReadTextFile(NSString *path, NSUInteger maxChars, NSString **reason) {
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long size = [[fm attributesOfItemAtPath:path error:nil] fileSize];
    if (!size) {
        if (reason) *reason = @"文件是空的";
        return nil;
    }
    if (size > 2 * 1024 * 1024) {
        if (reason) *reason = [NSString stringWithFormat:@"文件有 %.1f MB，太大了，我只读 2 MB 以内的文本",
                               size / 1048576.0];
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) {
        if (reason) *reason = @"文件读不出来";
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        NSStringEncoding gbk = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
        text = [[NSString alloc] initWithData:data encoding:gbk];
    }
    if (!text) text = [[NSString alloc] initWithData:data encoding:NSUTF16StringEncoding];
    if (!text) {
        // 前 512 字节里出现 NUL 基本就是二进制（zip/pdf/docx 之类）
        NSUInteger probe = MIN((NSUInteger)512, data.length);
        const unsigned char *p = data.bytes;
        NSUInteger nul = 0;
        for (NSUInteger i = 0; i < probe; i++) if (p[i] == 0) nul++;
        if (reason) {
            *reason = nul > probe / 20
                ? [NSString stringWithFormat:@"「%@」是二进制文件（PDF/Word/压缩包这类），我目前只能读纯文本",
                   path.lastPathComponent]
                : @"编码认不出来，读成乱码了";
        }
        return nil;
    }
    if (text.length > maxChars) text = [[text substringToIndex:maxChars] stringByAppendingString:@"…（后面还有，已截断）"];
    return text;
}

+ (NSDictionary *)fileInfoFromXML:(NSString *)xml {
    if (!xml.length) return nil;
    NSString *raw = InsHTMLEntities(xml);
    // 文件消息用 <appattach> 装附件；图片是 <img>、视频是 <videomsg>，不会误判
    if ([raw rangeOfString:@"<appattach"].location == NSNotFound) return nil;
    NSString *name = InsStripCDATA(InsXMLTag(raw, @"title") ?: @"");
    if (!name.length) name = InsStripCDATA(InsXMLTag(raw, @"filename") ?: @"");
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) return nil;
    // 合并转发里被转发的文件 title 会带上「文件:」前缀
    if ([name hasPrefix:@"文件:"]) name = [name substringFromIndex:3];
    NSString *ext = InsStripCDATA(InsXMLTag(raw, @"fileext") ?: @"") ?: @"";
    // 双保险：文件必须有扩展名（或者 XML 明确给了 fileext）。
    // 少了这一条，群里带引用的普通聊天会被整条 XML 里的 appattach 字眼误判成文件。
    NSString *dotExt = name.pathExtension.lowercaseString ?: @"";
    if (!ext.length && (dotExt.length < 1 || dotExt.length > 6)) return nil;
    if (!ext.length) ext = dotExt;
    NSString *attrMd5 = InsXMLAttr(raw, @"md5");
    NSString *md5 = InsStripCDATA(InsXMLTag(raw, @"md5") ?: @"") ?: @"";
    if (!md5.length) md5 = attrMd5 ?: @"";
    NSString *total = InsStripCDATA(InsXMLTag(raw, @"totallen") ?: @"") ?: @"0";
    NSString *attachId = InsStripCDATA(InsXMLTag(raw, @"attachid") ?: @"") ?: @"";
    return @{ @"name": name,
              @"md5": [md5 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]],
              @"ext": ext.lowercaseString ?: @"",
              @"size": @([total longLongValue]),
              @"attachid": attachId };
}

+ (NSString *)fileTextFor:(NSDictionary *)info talker:(NSString *)talker reason:(NSString **)reason {
    NSString *name = info[@"name"] ?: @"";
    NSString *svrid = info[@"svrid"] ?: @"";
    if (!name.length && !svrid.length) {
        if (reason) *reason = @"没认出是哪个文件";
        return nil;
    }
    if (!name.length) name = @"文件";
    // 1) 定位这条消息的本地 ID → 文件目录
    id wrap = nil;
    unsigned long long localID = InsMediaLocalIDForSvrId(svrid, talker, &wrap);
    // 消息本体里才有 attachid/大小/扩展名，下载接口要用；调用方给的名字优先
    if (wrap) {
        NSDictionary *fromWrap = [self fileInfoFromXML:[wrap valueForKey:@"m_nsContent"]];
        if (fromWrap.count) {
            NSMutableDictionary *merged = [fromWrap mutableCopy];
            NSString *given = info[@"name"];
            if (given.length && ![given isEqualToString:@"文件"]) merged[@"name"] = given;
            if (svrid.length) merged[@"svrid"] = svrid;
            info = merged;
            name = info[@"name"] ?: name;
        }
    }
    NSString *dir = InsMediaAttachDir(talker, localID);
    NSString *path = dir ? InsMediaMainFileIn(dir) : nil;
    NSString *how = @"本地已有";
    // 2) 没下载：让微信按这条消息去取，边下边等（约 10 秒）
    if (!path && svrid.length) {
        BOOL started = InsMediaStartDownload(wrap, info);
        [InsConfig log:[NSString stringWithFormat:
            @"文件：本地没有「%@」（localID=%llu），%@",
            name, localID, started ? @"已让微信开始下载，最多等 10 秒" : @"下载请求没发出去"]];
        if (started) {
            for (int i = 0; i < 20; i++) {
                [NSThread sleepForTimeInterval:0.5];
                dir = InsMediaAttachDir(talker, localID);
                path = dir ? InsMediaMainFileIn(dir) : nil;
                if (path) { how = @"刚下载完成"; break; }
            }
        }
    }
    if (!path) {
        if (reason) {
            *reason = [NSString stringWithFormat:
                @"手机上还没有这个文件（微信要等你点开才下载）。你在微信里点一下「%@」，我就能读了。", name];
        }
        return nil;
    }
    NSString *why = nil;
    NSString *text = InsMediaReadTextFile(path, 20000, &why);
    if (!text.length) {
        if (reason) *reason = why ?: @"文件内容读不出来";
        return nil;
    }
    [InsConfig log:[NSString stringWithFormat:@"文件：读到「%@」%lu 字（%@）", name,
                    (unsigned long)text.length, how]];
    return text;
}

+ (NSDictionary *)parseQuote:(NSString *)content {
    if (!content.length) return nil;
    NSString *reply = nil;
    NSString *quoted = nil;
    NSRange ref = [content rangeOfString:@"<refermsg"];
    if (ref.location != NSNotFound || [content rangeOfString:@"<type>57</type>"].location != NSNotFound) {
        // 外层 appmsg 的 <title> 才是用户打的字；被引用内容的 <title> 在 refermsg 里面，别拿错
        NSString *head = ref.location == NSNotFound ? content : [content substringToIndex:ref.location];
        reply = InsHTMLEntities(InsStripCDATA(InsXMLTag(head, @"title") ?: @""));
        if (ref.location != NSNotFound) {
            NSString *block = [content substringFromIndex:ref.location];
            quoted = InsHTMLEntities(InsStripCDATA(InsXMLTag(block, @"content") ?: @""));
        }
    } else {
        // 部分版本把引用写成纯文本："某某：原文\n------\n回复内容"
        for (NSString *sep in @[@"\n------\n", @"\n------", @"------\n", @"\n——————\n", @"\n———\n"]) {
            NSRange hit = [content rangeOfString:sep];
            if (hit.location == NSNotFound) continue;
            quoted = [content substringToIndex:hit.location];
            reply = [content substringFromIndex:NSMaxRange(hit)];
            break;
        }
    }
    if (!reply.length && !quoted.length) return nil;
    NSDictionary *link = [self linkInfoFromText:quoted] ?: @{};
    // <refermsg><type> 是被引用消息的类型：3 = 图片，49 = 链接/卡片，1 = 文本
    NSString *refType = @"";
    NSString *svrid = @"";
    NSString *refBlock = @"";
    uint32_t refTime = 0;
    if (ref.location != NSNotFound) {
        refBlock = [content substringFromIndex:ref.location];
        refType = InsStripCDATA(InsXMLTag(refBlock, @"type") ?: @"") ?: @"";
        // 引用消息只带 svrid，本地图片文件名却是 MesLocalID —— 必须靠 svrid 反查才能拿到那张图。
        // createtime 是备用的第二条路（同一秒发两张图时会撞车，所以 svrid 优先）。
        svrid = [(InsStripCDATA(InsXMLTag(refBlock, @"svrid") ?: @"") ?: @"")
                 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *ct = InsStripCDATA(InsXMLTag(refBlock, @"createtime") ?: @"");
        refTime = (uint32_t)[ct longLongValue];
        if (!refType.length) {
            // 线上出现「类型=（空）」的情况，说明 refermsg 结构和假设不一致。
            // 只记结构（wxid 打码），够看出标签名，不会把聊天内容写进日志。
            NSString *head = refBlock.length > 300 ? [refBlock substringToIndex:300] : refBlock;
            NSRegularExpression *mask = [NSRegularExpression regularExpressionWithPattern:
                @"wxid_[A-Za-z0-9_-]+" options:0 error:nil];
            head = [mask stringByReplacingMatchesInString:head options:0
                                                   range:NSMakeRange(0, head.length)
                                            withTemplate:@"wxid_***"];
            [InsConfig log:[NSString stringWithFormat:@"引用诊断：type 没解析出来，refermsg 头=%@", head]];
        }
    }
    // 被引用那条是谁说的：refermsg 里 chatusr 是发送者 wxid，displayname 是他的昵称。
    // 不拿到这个，模型只会看到「同一句话出现两次」，分不清是对方又发了一遍还是主人在引用追问。
    NSString *quoter = @"";
    NSString *quoterName = @"";
    if (refBlock.length) {
        // refermsg 后面还可能跟着别的 appmsg 节点，限定在 <refermsg>…</refermsg> 内取
        NSRange end = [refBlock rangeOfString:@"</refermsg>"];
        NSString *scope = end.location == NSNotFound ? refBlock
                                                     : [refBlock substringToIndex:NSMaxRange(end)];
        quoter = InsStripCDATA(InsXMLTag(scope, @"chatusr") ?: @"") ?: @"";
        if (!quoter.length) quoter = InsStripCDATA(InsXMLTag(scope, @"fromusr") ?: @"") ?: @"";
        quoter = [quoter stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        quoterName = InsHTMLEntities(InsStripCDATA(InsXMLTag(scope, @"displayname") ?: @"") ?: @"");
        quoterName = [quoterName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    NSString *kind = @"";
    NSString *recordText = @"";
    NSDictionary *fileInfo = nil;
    NSDictionary *sticker = @{};
    BOOL isRecord = InsIsChatRecordXML(quoted ?: @"") || InsIsChatRecordXML(content);
    if (isRecord) {
        kind = @"record";
        link = @{};
        recordText = [self chatRecordTextFrom:quoted] ?: [self chatRecordTextFrom:content] ?: @"";
    } else if ((fileInfo = [self fileInfoFromXML:quoted])) {
        // 引用的是文件（appmsg type 6）：文件名在 title，附件在 appattach。
        // 正文要靠 svrid 找到本地那份下载副本，所以把 svrid 一起带上。
        // 只认 quoted（被引用那条自己的 XML）：整条 content 里带着回复文字和转义结构，
        // 拿它判会把群里的普通引用误认成文件。
        kind = @"file";
        link = @{};
        NSMutableDictionary *withId = [fileInfo mutableCopy];
        if (svrid.length) withId[@"svrid"] = svrid;
        fileInfo = withId;
    } else if ([refType isEqualToString:@"47"] ||
               [quoted rangeOfString:@"<emoji"].location != NSNotFound ||
               [quoted rangeOfString:@"&lt;emoji"].location != NSNotFound) {
        // 引用的是微信表情消息：emoji XML 带 md5/cdnurl/aeskey，别当成链接卡片去抓正文
        kind = @"sticker";
        link = @{};
        NSString *emojiXML = InsHTMLEntities(quoted ?: @"");
        if (!emojiXML.length || [emojiXML rangeOfString:@"<emoji"].location == NSNotFound)
            emojiXML = InsHTMLEntities(refBlock ?: @"");
        sticker = @{ @"md5": InsXMLAttr(emojiXML, @"md5") ?: @"",
                     @"cdnurl": InsXMLAttr(emojiXML, @"cdnurl") ?: @"",
                     @"aeskey": InsXMLAttr(emojiXML, @"aeskey") ?: @"",
                     @"xml": emojiXML };
    } else if ([refType isEqualToString:@"3"] ||
               [quoted rangeOfString:@"<img"].location != NSNotFound ||
               [quoted rangeOfString:@"cdnmidimgurl"].location != NSNotFound ||
               [quoted rangeOfString:@"&lt;img"].location != NSNotFound ||
               [quoted rangeOfString:@"&lt;cdnmidimgurl"].location != NSNotFound ||
               [refBlock rangeOfString:@"&lt;img"].location != NSNotFound ||
               [refBlock rangeOfString:@"<type>3</type>"].location != NSNotFound) {
        // 图片优先：图片消息里的 cdnmidimgurl/thumburl 也是 http 地址，先判链接会误判
        kind = @"image";
        link = @{};
    } else if (link.count) {
        kind = @"link";
    } else {
        // 引用的不是图片时才用整段 XML 找 URL
        NSDictionary *fromWhole = [self linkInfoFromText:content];
        if (fromWhole.count) { link = fromWhole; kind = @"link"; }
    }
    return @{ @"reply": reply ?: @"", @"quoted": quoted ?: @"", @"link": link,
              @"kind": kind, @"record": recordText,
              @"file": fileInfo ?: @{},
              @"sticker": sticker ?: @{},
              @"svrid": svrid ?: @"", @"time": @(refTime),
              @"quoter": quoter, @"quoterName": quoterName };
}

+ (NSString *)fetchLinkText:(NSString *)url error:(NSError **)error {
    NSData *data = InsDownloadHTML(url, 20);
    if (!data.length) {
        if (error) *error = [NSError errorWithDomain:@"InsMedia" code:-2
                                            userInfo:@{NSLocalizedDescriptionKey: @"链接抓不到内容"}];
        return nil;
    }
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        NSStringEncoding gbk = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
        text = [[NSString alloc] initWithData:data encoding:gbk];
    }
    if (!text.length) return nil;
    NSRegularExpression *block = [NSRegularExpression regularExpressionWithPattern:@"<(script|style)[^>]*>[\\s\\S]*?</\\1>"
                                              options:NSRegularExpressionCaseInsensitive error:nil];
    text = [block stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@" "];
    NSRegularExpression *tag = [NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil];
    text = [tag stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@" "];
    for (NSArray *pair in @[@[@"&amp;", @"&"], @[@"&lt;", @"<"], @[@"&gt;", @">"],
                            @[@"&quot;", @"\""], @[@"&#39;", @"'"], @[@"&nbsp;", @" "]]) {
        text = [text stringByReplacingOccurrencesOfString:pair[0] withString:pair[1]];
    }
    NSRegularExpression *ws = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    text = [ws stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@" "];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (text.length > 6000) text = [text substringToIndex:6000];
    return text;
}

+ (NSString *)fetchLinkArticle:(NSString *)url reason:(NSString **)reason {
    NSString *clean = InsNormalizeURL(url);
    if (!clean.length) {
        if (reason) *reason = @"链接地址为空";
        return nil;
    }
    NSString *body = [self fetchLinkText:clean error:nil];
    if (body.length && !InsIsUselessBody(body)) return body;
    if (reason) {
        if (!body.length) *reason = @"网页没返回内容或请求失败";
        else if (body.length < 120) *reason = @"网页正文太短，可能是空壳页或需要 JS 渲染";
        else *reason = @"网页返回了验证页（反爬拦截）";
    }
    return nil;
}

+ (NSString *)readLinkOnScreen:(NSString *)url title:(NSString *)title force:(BOOL)force
                        reason:(NSString **)reason {
    NSString *clean = InsNormalizeURL(url);
    if (!clean.length) { if (reason) *reason = @"链接地址为空"; return nil; }
    if (!InsScreenShouldTry(clean, force)) {
        if (reason) *reason = @"刚试过屏幕读取，短时间内不重复";
        return nil;
    }
    InsMCP *mcp = [InsMCP shared];
    NSError *err = nil;
    // 先探一次守护进程；连不上就立刻放弃，别让后面每个调用各等 35 秒
    NSString *front = [mcp textOfTool:@"get_frontmost_app" args:@{} error:&err];
    if (!front && err) {
        if (reason) *reason = [NSString stringWithFormat:@"屏幕读取通道不可用：%@", err.localizedDescription];
        return nil;
    }
    BOOL inWeChat = [front rangeOfString:@"com.tencent.xin"].location != NSNotFound;
    BOOL tappedCard = NO;

    // 优先在聊天界面点那条链接卡片，用微信内置浏览器打开——微信不进后台，也不会掉登录态
    NSString *needle = InsHTMLEntities(title ?: @"");
    needle = [needle stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (needle.length > 10) needle = [needle substringToIndex:10];
    if (inWeChat && needle.length >= 4) {
        NSString *elementsRaw = [mcp textOfTool:@"get_ui_elements"
                                           args:@{@"max_elements": @120} error:NULL] ?: @"";
        id json = [NSJSONSerialization JSONObjectWithData:
                   [elementsRaw dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSArray *elements = [json isKindOfClass:[NSDictionary class]] ? json[@"elements"] : nil;
        for (id e in elements ?: @[]) {
            if (![e isKindOfClass:[NSDictionary class]]) continue;
            NSString *t = [e[@"text"] isKindOfClass:[NSString class]] ? e[@"text"] : @"";
            if ([t rangeOfString:needle].location == NSNotFound) continue;
            NSDictionary *r = [e[@"rect"] isKindOfClass:[NSDictionary class]] ? e[@"rect"] : @{};
            CGFloat x = [r[@"x"] floatValue] + [r[@"width"] floatValue] / 2;
            CGFloat y = [r[@"y"] floatValue] + [r[@"height"] floatValue] / 2;
            if (x < 10 || y < 70 || y > 780) continue;  // 避开状态栏和输入框
            [mcp textOfTool:@"tap_screen" args:@{@"x": @(x), @"y": @(y)} error:NULL];
            tappedCard = YES;
            break;
        }
    }

    if (tappedCard) {
        [InsConfig log:@"屏幕读：点了聊天里的链接卡片（微信内置浏览器）"];
    } else {
        NSString *opened = [mcp textOfTool:@"open_url" args:@{@"url": clean} error:&err];
        if (!opened && err) {
            if (reason) *reason = [NSString stringWithFormat:@"打不开网页：%@", err.localizedDescription];
            return nil;
        }
        [InsConfig log:@"屏幕读：卡片没找到，用 open_url 打开网页"];
        // 保险：Safari 打开后微信若被挂起，守护进程这条后台任务也会把它拉回前台，
        // 插件恢复执行后继续 OCR 和回复，不会永远卡住。9 秒足够正常路径先跑完。
        [mcp shell:@"(sleep 9; /var/jb/usr/bin/uiopen --bundleid com.tencent.xin) >/dev/null 2>&1 & echo scheduled"
             error:NULL];
    }

    // 等待交给守护进程侧：微信万一被挂起，恢复前台后这条链还能接着往下跑
    [mcp shell:@"sleep 5" error:NULL];
    NSMutableString *rawText = [NSMutableString string];
    NSString *ocrText = InsScreenReadableText([mcp textOfTool:@"ocr_screen" args:@{} error:&err]);
    if (ocrText.length) [rawText appendString:ocrText];
    NSString *uiText = InsScreenReadableText([mcp textOfTool:@"get_ui_elements"
                                                        args:@{@"max_elements": @120} error:NULL]);
    if (uiText.length) [rawText appendString:uiText];

    // 不管读到没读到都把微信拉回前台，否则回复发不出去
    if (tappedCard) {
        [mcp textOfTool:@"tap_screen" args:@{@"x": @28, @"y": @52} error:NULL];  // webview 返回
    } else {
        [mcp shell:@"/var/jb/usr/bin/uiopen --bundleid com.tencent.xin" error:NULL];
    }

    NSString *body = InsCleanScreenText(rawText);
    [InsConfig log:[NSString stringWithFormat:@"屏幕读：%@ 读到 %lu 字",
                    tappedCard ? @"微信内置浏览器" : @"Safari", (unsigned long)body.length]];
    if (!InsScreenTextUseful(body)) {
        if (reason) *reason = body.length ? @"屏幕上也还是验证页或空白" : @"屏幕没读到文字";
        return nil;
    }
    if (reason) *reason = nil;
    return body;
}

@end