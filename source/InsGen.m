#import "InsGen.h"
#import "InsMCP.h"
#import "InsConfig.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <stdatomic.h>

static dispatch_queue_t gGenQueue = nil;
static AVAudioPlayer *gAlivePlayer = nil;
static UIBackgroundTaskIdentifier gAliveBgTask = NSUIntegerMax;   // == UIBackgroundTaskInvalid
static atomic_bool gGenerating = false;
static NSString *gLastPrompt = nil;   // 上一次成功发出去的提示词；指针读写本身是原子的，供跨线程查询

static NSError *InsErr(NSString *format, ...) {
    va_list ap;
    va_start(ap, format);
    NSString *text = [[NSString alloc] initWithFormat:format arguments:ap];
    va_end(ap);
    return [NSError errorWithDomain:@"InsomniaGen" code:-1 userInfo:@{NSLocalizedDescriptionKey: text}];
}

static void InsNote(NSString *line) {
    [InsConfig log:line];
}

/// 后台任务必须在主线程申请/结束；已在主线程则直接执行
static void InsOnMain(dispatch_block_t block) {
    if ([NSThread isMainThread]) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}


/// 微信切到后台约 20 秒就会被挂起，用静音循环播放把它留在前台可运行状态
static void InsAliveStart(void) {
    // 关键：静音音频保活会被 ChatGPT 的音频会话打断失效。再叠加 UIApplication
    // 后台任务，双保险撑住生图等待窗口，否则微信被冻结、等待线程停摆，图生成了也发不出去。
    InsOnMain(^{
        if (gAliveBgTask == UIBackgroundTaskInvalid) {
            gAliveBgTask = [[UIApplication sharedApplication]
                beginBackgroundTaskWithName:@"InsomniaGenAlive"
                expirationHandler:^{
                    // 系统给的宽限期(约30秒)将尽时再续一段，撑到生图完成；过期前必须再申请，否则仍会被冻结
                    InsOnMain(^{
                        if (gAliveBgTask != UIBackgroundTaskInvalid) {
                            [[UIApplication sharedApplication] endBackgroundTask:gAliveBgTask];
                            gAliveBgTask = UIBackgroundTaskInvalid;
                        }
                        if (atomic_load_explicit(&gGenerating, memory_order_relaxed)) {
                            gAliveBgTask = [[UIApplication sharedApplication]
                                beginBackgroundTaskWithName:@"InsomniaGenAlive2"
                                expirationHandler:^{
                                    InsNote(@"后台保活续期到期");
                                }];
                            InsNote(@"后台保活已续期");
                        }
                    });
                }];
            InsNote(@"后台任务保活已启动");
        }
    });
    if (gAlivePlayer && gAlivePlayer.isPlaying) return;
    if (gAlivePlayer) {
        [gAlivePlayer stop];
        gAlivePlayer = nil;
        InsNote(@"保活音频已停，重新启动");
    }
    static dispatch_once_t onceObserve;
    dispatch_once(&onceObserve, ^{
        // ChatGPT 的语音功能会激活自己的音频会话打断保活播放，被打断后要能自己续上
        [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification
                                                          object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) {
            NSDictionary *info = note.userInfo;
            NSNumber *type = info[AVAudioSessionInterruptionTypeKey];
            NSNumber *options = info[AVAudioSessionInterruptionOptionKey];
            if (type.integerValue == AVAudioSessionInterruptionTypeEnded &&
                (options.integerValue & AVAudioSessionInterruptionOptionShouldResume)) {
                InsNote(@"保活音频被其他 App 打断，正在恢复");
                InsAliveStart();
            }
        }];
    });
    NSString *path = [[InsConfig rootDir] stringByAppendingPathComponent:@"silent.wav"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        // 0.5 秒、8kHz、8bit 单声道全零 PCM，WAV 容器
        int sampleRate = 8000, bytes = 4000;
        unsigned char header[44] = {'R','I','F','F'};
        int riffLen = 36 + bytes, dataOff = 4;
        header[dataOff] = riffLen & 0xFF; header[5] = (riffLen >> 8) & 0xFF;
        header[6] = (riffLen >> 16) & 0xFF; header[7] = (riffLen >> 24) & 0xFF;
        memcpy(header + 8, "WAVEfmt ", 8);
        int fmtLen = 16;
        header[16] = fmtLen; header[17] = 0; header[18] = 0; header[19] = 0;
        short pcm = 1, channels = 1, blockAlign = 1;
        memcpy(header + 20, &pcm, 2);
        memcpy(header + 22, &channels, 2);
        memcpy(header + 24, &sampleRate, 4);
        memcpy(header + 28, &sampleRate, 4);   // byte rate
        memcpy(header + 32, &blockAlign, 2);
        short bits = 8;
        memcpy(header + 34, &bits, 2);
        memcpy(header + 36, "data", 4);
        memcpy(header + 40, &bytes, 4);
        NSMutableData *audio = [NSMutableData dataWithBytes:header length:sizeof(header)];
        void *zeros = calloc(1, bytes);
        [audio appendData:[NSData dataWithBytesNoCopy:zeros length:bytes freeWhenDone:YES]];
        [audio writeToFile:path atomically:YES];
    }
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
             withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    [session setActive:YES error:nil];
    gAlivePlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:nil];
    if (gAlivePlayer) {
        gAlivePlayer.numberOfLoops = -1;
        gAlivePlayer.volume = 0.01;
        [gAlivePlayer prepareToPlay];
        [gAlivePlayer play];
        InsNote(@"静音保活已启动");
    } else {
        InsNote(@"静音保活启动失败，后台可能被挂起");
    }
}

static void InsAliveStop(void) {
    [gAlivePlayer stop];
    gAlivePlayer = nil;
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    InsOnMain(^{
        if (gAliveBgTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:gAliveBgTask];
            gAliveBgTask = UIBackgroundTaskInvalid;
            InsNote(@"后台任务保活已结束");
        }
    });
    InsNote(@"静音保活已停止");
}

static NSString *InsCacheDir(void) {
    static NSString *cached = nil;
    if (cached.length) return cached;
    InsConfig *cfg = [InsConfig shared];
    NSString *json = [[InsMCP shared] textOfTool:@"get_app_info"
                                            args:@{@"bundle_id": cfg.chatgptBundle} error:NULL];
    id info = json.length ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                            options:0 error:nil] : nil;
    NSString *container = [info isKindOfClass:[NSDictionary class]] ? info[@"data_container"] : nil;
    if (container.length) {
        cached = [[container stringByAppendingPathComponent:cfg.kfCacheSubpath] copy];
        InsNote([NSString stringWithFormat:@"图像缓存目录 %@", cached]);
    }
    return cached;
}

static NSDictionary *InsTapTarget(NSArray *elements, NSString *hint) {
    if (!hint.length) return nil;
    for (id item in elements) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = item[@"text"];
        NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
        if (![text isKindOfClass:[NSString class]] || !rect) continue;
        if ([text rangeOfString:hint].location != NSNotFound) {
            return @{@"x": @([rect[@"x"] floatValue] + [rect[@"width"] floatValue] / 2.0),
                    @"y": @([rect[@"y"] floatValue] + [rect[@"height"] floatValue] / 2.0),
                    @"w": @([rect[@"width"] floatValue])};
        }
    }
    return nil;
}

/// 输入框可能叫"新消息""询问 ChatGPT""Message"等，逐个尝试
static NSDictionary *InsChatGptInput(NSArray *elements, NSString *configured) {
    NSMutableArray *hints = [NSMutableArray array];
    if (configured.length) [hints addObject:configured];
    for (NSString *hint in @[@"新消息", @"询问 ChatGPT", @"Message", @"提问", @"发消息"]) {
        if (![hints containsObject:hint]) [hints addObject:hint];
    }
    for (NSString *hint in hints) {
        NSDictionary *target = InsTapTarget(elements, hint);
        if (target) {
            // 输入框上方可能有同名菜单项，取最靠屏幕下沿的那个
            if ([target[@"y"] floatValue] < 300) {
                NSDictionary *lower = nil;
                for (id item in elements) {
                    if (![item isKindOfClass:[NSDictionary class]]) continue;
                    NSString *text = item[@"text"];
                    NSDictionary *rect = item[@"visible_rect"] ?: item[@"rect"];
                    if (![text isKindOfClass:[NSString class]] || !rect) continue;
                    if ([text rangeOfString:hint].location == NSNotFound) continue;
                    float y = [rect[@"y"] floatValue];
                    if (y >= 300 && (!lower || y > [lower[@"y"] floatValue])) {
                        lower = @{@"x": @([rect[@"x"] floatValue] + [rect[@"width"] floatValue] / 2.0),
                                 @"y": @(y + [rect[@"height"] floatValue] / 2.0),
                                 @"w": @([rect[@"width"] floatValue])};
                    }
                }
                if (lower) target = lower;
            }
            InsNote([NSString stringWithFormat:@"命中输入框提示词「%@」(%@, %@)",
                     hint, target[@"x"], target[@"y"]]);
            return target;
        }
    }
    return nil;
}

/// 找发送按钮
static NSDictionary *InsSendButton(NSArray *elements) {
    for (NSString *hint in @[@"发送", @"Send"]) {
        NSDictionary *target = InsTapTarget(elements, hint);
        if (target) return target;
    }
    return nil;
}

/// 提示词发出去后会变成消息气泡，气泡里的文本包含提示词开头。
/// 输入框的占位标签「新消息」是常驻的，不能用来判断是否已发送。
static NSInteger InsPromptBubbles(NSArray *elements, NSString *prompt) {
    if (prompt.length < 2) return 0;
    NSString *needle = [prompt substringToIndex:MIN((NSUInteger)16, prompt.length)];
    NSInteger count = 0;
    for (id item in elements) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = item[@"text"];
        if (![text isKindOfClass:[NSString class]]) continue;
        if ([text rangeOfString:needle].location != NSNotFound) count++;
    }
    return count;
}

/// 列出缓存目录里最近的图片：size mtime magic name
static NSArray<NSDictionary *> *InsListImages(NSString *dir, NSError **error) {
    NSString *command = [NSString stringWithFormat:
        @"cd '%@' && for f in $(ls -t | head -12); do "
        @"printf '%%s %%s %%s %%s\\n' $(stat -c '%%s %%Y' \"$f\") $(od -An -tx1 -N4 \"$f\" | tr -d ' \\n') \"$f\"; done", dir];
    NSString *out = [[InsMCP shared] shell:command error:error];
    if (!out) return nil;
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *line in [out componentsSeparatedByString:@"\n"]) {
        NSArray *parts = [line componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        parts = [parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (parts.count < 4) continue;
        [rows addObject:@{@"size": @([parts[0] longLongValue]),
                          @"mtime": @([parts[1] longLongValue]),
                          @"magic": parts[2],
                          @"name": [parts lastObject]}];
    }
    return rows;
}

/// 已发过的图片指纹，用来识破「ChatGPT 把旧图重新缓存成新文件」被误当成本次结果
static NSString *InsSentListPath(void) {
    return [[InsConfig rootDir] stringByAppendingPathComponent:@"sent_images.txt"];
}

static NSArray<NSString *> *InsSentHashes(void) {
    NSString *text = [NSString stringWithContentsOfFile:InsSentListPath() encoding:NSUTF8StringEncoding error:nil];
    return [[text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
            filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
}

static void InsRememberSentHash(NSString *hash) {
    NSMutableArray *list = [InsSentHashes() mutableCopy];
    [list addObject:hash];
    while (list.count > 30) [list removeObjectAtIndex:0];
    NSString *text = [[list componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    [text writeToFile:InsSentListPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static NSString *InsSHA1(NSData *data) {
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static void InsGenerateOnce(NSString *prompt, BOOL continuation, NSData **outImage, NSString **outPath, NSError **outError);
static void InsResumeOnce(NSString *prompt, long long startedAt, NSData **outImage, NSString **outPath, NSError **outError);
static void InsWaitForImage(NSString *dir, long long baseline, NSSet *before, NSInteger budget,
                            NSData **outImage, NSString **outPath);

@implementation InsGen

+ (void)initialize {
    if (self == [InsGen class]) {
        gGenQueue = dispatch_queue_create("com.xuezeng.insomnia.gen", DISPATCH_QUEUE_SERIAL);
    }
}

+ (void)stopAlive { InsAliveStop(); }

+ (BOOL)isGenerating {
    return atomic_load_explicit(&gGenerating, memory_order_relaxed);
}

+ (BOOL)available {
    NSError *error = nil;
    NSString *out = [[InsMCP shared] shell:@"echo ok" error:&error];
    return [out rangeOfString:@"ok"].location != NSNotFound;
}

+ (void)generateImage:(NSString *)prompt
         continuation:(BOOL)continuation
           completion:(void (^)(NSData *, NSString *, NSError *))done {
    dispatch_async(gGenQueue, ^{
        atomic_store_explicit(&gGenerating, true, memory_order_relaxed);
        NSData *image = nil;
        NSString *path = nil;
        NSError *error = nil;
        InsGenerateOnce(prompt, continuation, &image, &path, &error);
        atomic_store_explicit(&gGenerating, false, memory_order_relaxed);
        done(image, path, error);
    });
}

+ (NSString *)lastPrompt {
    return gLastPrompt;
}

+ (void)resumeImage:(NSString *)prompt
              since:(long long)startedAt
         completion:(void (^)(NSData *, NSString *, NSError *))done {
    dispatch_async(gGenQueue, ^{
        atomic_store_explicit(&gGenerating, true, memory_order_relaxed);
        NSData *image = nil;
        NSString *path = nil;
        NSError *error = nil;
        InsResumeOnce(prompt, startedAt, &image, &path, &error);
        atomic_store_explicit(&gGenerating, false, memory_order_relaxed);
        done(image, path, error);
    });
}

@end

static void InsGenerateOnce(NSString *prompt, BOOL continuation, NSData **outImage, NSString **outPath, NSError **outError) {
    InsConfig *cfg = [InsConfig shared];
    NSString *dir = InsCacheDir();
    if (!dir.length) {
        *outError = InsErr(@"拿不到 ChatGPT 图像缓存目录，MCP 通道可能不通");
        return;
    }

    NSString *stamp = [[InsMCP shared] shell:@"date +%s" error:NULL];
    long long baseline = [[stamp stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]] longLongValue];
    NSSet *before = [NSSet setWithArray:[InsListImages(dir, NULL) valueForKey:@"name"] ?: @[]];
    InsNote([NSString stringWithFormat:@"开始生图 %@ (基线 %lld，已有 %lu 张图)",
             prompt, baseline, (unsigned long)before.count]);

    InsAliveStart();
    NSError *error = nil;
    [[InsMCP shared] callTool:@"launch_app" args:@{@"bundle_id": cfg.chatgptBundle} error:&error];
    if (error) { *outError = error; InsAliveStop(); return; }

    // 「打开→输入→发送」整体最多走两遍：ChatGPT 中途被杀会丢掉输入框里的文字，重启后要重发一次
    BOOL sent = NO;
    for (int attempt = 0; attempt < 2 && !sent; attempt++) {
        if (attempt > 0) {
            InsNote(@"第 2 遍尝试：重新拉起 ChatGPT 再发一次");
            [[InsMCP shared] callTool:@"launch_app" args:@{@"bundle_id": cfg.chatgptBundle} error:NULL];
        }

        // 等 ChatGPT 界面出来，最多 20 秒；界面迟迟不出现就重新拉起
        NSDictionary *input = nil;
        NSArray *elements = nil;
        for (int i = 0; i < 8 && !input; i++) {
            [NSThread sleepForTimeInterval:i ? 3 : 2];
            if (i && i % 2 == 0) {
                [[InsMCP shared] callTool:@"launch_app" args:@{@"bundle_id": cfg.chatgptBundle} error:NULL];
                InsNote(@"ChatGPT 界面没出现，重新拉起");
            }
            elements = [[InsMCP shared] uiElements][@"elements"];
            input = InsChatGptInput(elements, cfg.chatGptInputHint);
        }
        if (!input) continue;

        // 默认点「新聊天」把界面清干净；优化/修改类请求要接着上一张图的会话继续问（重试遍不再点）
        NSDictionary *newChat = InsTapTarget(elements, @"新聊天");
        if (attempt == 0 && continuation && gLastPrompt.length && InsPromptBubbles(elements, gLastPrompt) > 0) {
            if (InsSendButton(elements)) {
                InsAliveStop();
                *outError = InsErr(@"要继续上次会话，但 ChatGPT 输入框里还有残留文字，请先到 ChatGPT 清掉再试");
                return;
            }
            InsNote(@"优化请求，续接上次会话继续问");
        } else if (attempt == 0) {
            if (continuation) InsNote(@"没找到上次生图的会话，改开新会话");
            if (newChat) {
                [[InsMCP shared] callTool:@"tap_screen" args:newChat error:NULL];
                [NSThread sleepForTimeInterval:2];
                elements = [[InsMCP shared] uiElements][@"elements"];
                input = InsChatGptInput(elements, cfg.chatGptInputHint) ?: input;
                InsNote(@"已开新会话");
            }
        } else if (InsSendButton(elements) && newChat) {
            // 重试遍：只有输入框里真压着上一遍没发出去的文字时才开新会话清掉
            [[InsMCP shared] callTool:@"tap_screen" args:newChat error:NULL];
            [NSThread sleepForTimeInterval:2];
            elements = [[InsMCP shared] uiElements][@"elements"];
            input = InsChatGptInput(elements, cfg.chatGptInputHint) ?: input;
            InsNote(@"重试前清掉残留文字");
        }

        [[InsMCP shared] callTool:@"tap_screen" args:@{@"x": input[@"x"], @"y": input[@"y"]} error:NULL];
        [NSThread sleepForTimeInterval:1];
        error = nil;
        [[InsMCP shared] callTool:@"input_text" args:@{@"text": prompt} error:&error];
        if (error) continue;
        [NSThread sleepForTimeInterval:2];

        // 反复尝试发送，直到提示词变成气泡为止；之前只点一次就往下走，文字一直压在输入框里
        for (int i = 0; i < 6 && !sent; i++) {
            NSArray *els = [[InsMCP shared] uiElements][@"elements"];
            if (InsPromptBubbles(els, prompt) > 0) { sent = YES; break; }
            NSDictionary *button = InsSendButton(els);
            if (button) {
                [[InsMCP shared] callTool:@"tap_screen" args:button error:NULL];
                InsNote([NSString stringWithFormat:@"点了发送按钮（第 %d 次）", i + 1]);
            } else {
                NSError *keyError = nil;
                [[InsMCP shared] callTool:@"press_key" args:@{@"key": @"return"} error:&keyError];
                InsNote(keyError ? @"回车发送失败" : @"已用回车发送");
            }
            for (int k = 0; k < 3 && !sent; k++) {
                [NSThread sleepForTimeInterval:2];
                sent = InsPromptBubbles([[InsMCP shared] uiElements][@"elements"], prompt) > 0;
            }
        }
    }
    if (!sent) {
        InsAliveStop();
        *outError = InsErr(@"提示词没能发送出去，ChatGPT 界面可能变了");
        return;
    }
    gLastPrompt = [prompt copy];

    // 提示词确认已发出，此刻起算基线才可靠
    NSString *sentAt = [[InsMCP shared] shell:@"date +%s" error:NULL];
    long long sentStamp = [[sentAt stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]] longLongValue];
    if (sentStamp > baseline) {
        baseline = sentStamp;
        InsNote([NSString stringWithFormat:@"提示词已发出，基线收紧到 %lld", baseline]);
    }

    // 提示词已交给 ChatGPT，出图由服务端完成，不需要微信一直停在后台。
    // 立即切回微信前台，让等待线程在活跃进程里轮询，避免被系统冻结导致图生成了也发不出去。
    [[InsMCP shared] callTool:@"launch_app" args:@{@"bundle_id": @"com.tencent.xin"} error:NULL];
    [NSThread sleepForTimeInterval:2];
    InsNote(@"已切回微信前台等待出图");

    InsWaitForImage(dir, baseline, before, MAX(12, cfg.genTimeout / 5), outImage, outPath);

    if (!(*outImage).length) {
        *outError = InsErr(@"等了约 %ld 秒（活跃轮询）仍没有拿到这次新生的图片，可能 ChatGPT 还在忙上一条", (long)cfg.genTimeout);
        return;
    }
    InsNote([NSString stringWithFormat:@"生图完成 %@ (%ld KB)", *outPath, (long)((*outImage).length / 1024)]);
}

/// 轮询缓存目录等新图出现；budget 按轮数（每轮约 5 秒活跃轮询）计，微信被挂起时轮次不走，不耗超时
static void InsWaitForImage(NSString *dir, long long baseline, NSSet *before, NSInteger budget,
                            NSData **outImage, NSString **outPath) {
    InsConfig *cfg = [InsConfig shared];
    for (NSInteger round = 0; round < budget; round++) {
        InsAliveStart();
        if (round > 0 && round % 3 == 0) {
            // 保持微信在前台：微信后台超过约3分钟会被系统冻结，等待线程一旦停摆，
            // 图生成了也没人取、没人切回去发。ChatGPT 出图是服务端的事，切后台不影响。
            [[InsMCP shared] callTool:@"launch_app" args:@{@"bundle_id": @"com.tencent.xin"} error:NULL];
        }
        [NSThread sleepForTimeInterval:5];
        for (NSDictionary *row in InsListImages(dir, NULL)) {
            NSString *name = row[@"name"];
            NSString *magic = row[@"magic"];
            BOOL isImage = [magic hasPrefix:@"89504e47"] || [magic hasPrefix:@"ffd8ff"];
            if (!isImage || [row[@"size"] longLongValue] < cfg.minImageBytes) continue;
            if (before && [before containsObject:name]) continue;
            if (baseline && [row[@"mtime"] longLongValue] < baseline) continue;
            NSError *dlError = nil;
            NSData *image = [[InsMCP shared] download:[dir stringByAppendingPathComponent:name]
                                                error:&dlError];
            if (!image.length) continue;
            NSString *hash = InsSHA1(image);
            if ([InsSentHashes() containsObject:hash]) {
                InsNote([NSString stringWithFormat:@"忽略 %@：和之前发过的图内容相同", name]);
                continue;
            }
            InsRememberSentHash(hash);
            *outPath = [dir stringByAppendingPathComponent:name];
            *outImage = image;
            break;
        }
        if ((*outImage).length) break;
        InsNote(@"等待 ChatGPT 出图…");
    }
}

/// 重启后的恢复路径：提示词早已发出，只等缓存里出现 mtime 晚于 startedAt 的新图
static void InsResumeOnce(NSString *prompt, long long startedAt, NSData **outImage, NSString **outPath, NSError **outError) {
    InsConfig *cfg = [InsConfig shared];
    NSString *dir = InsCacheDir();
    if (!dir.length) {
        *outError = InsErr(@"拿不到 ChatGPT 图像缓存目录，MCP 通道可能不通");
        return;
    }
    InsAliveStart();
    // ChatGPT 可能也一起被杀/被挂起了：先拉起它，让服务端在跑的生成能把结果写回缓存
    [[InsMCP shared] callTool:@"launch_app" args:@{@"bundle_id": cfg.chatgptBundle} error:NULL];
    InsNote([NSString stringWithFormat:@"恢复等待生图：%@（起点 %lld）", prompt, startedAt]);
    InsWaitForImage(dir, startedAt, nil, MAX(12, cfg.genTimeout / 5), outImage, outPath);

    [NSThread sleepForTimeInterval:2];
    [[InsMCP shared] callTool:@"launch_app" args:@{@"bundle_id": @"com.tencent.xin"} error:NULL];
    [NSThread sleepForTimeInterval:4];

    if (!(*outImage).length) {
        *outError = InsErr(@"恢复后等了约 %ld 秒仍没有拿到新图，可能那条请求当时没真正发出去", (long)cfg.genTimeout);
        return;
    }
    InsNote([NSString stringWithFormat:@"恢复完成，生图 %@ (%ld KB)", *outPath, (long)((*outImage).length / 1024)]);
}
