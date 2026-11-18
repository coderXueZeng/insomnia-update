#import "InsVoice.h"
#import "InsConfig.h"
#import "InsSend.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <substrate.h>
#import <math.h>
#import <os/lock.h>
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIApplication.h>

/// Tweak.x 里的自己的 wxid
extern NSString *InsSelfWxidShared(void);

/// 语音期间保持屏幕常亮。息屏 → 微信切后台 → 音频会话失活 → 录音器不吐 PCM
///（日志里 gFedFrames 一直 0、没有 PCM userData/上传首片），是本类发送失败的主因。
/// 幂等：多次 NO 只是重复恢复。真正发完/失败在 InsVoiceFinishNow 及各失败分支里关掉。
/// 只能在主线程碰 UIApplication：翻唱下单/轮询跑在后台队列里，
/// 直接在那调用 [UIApplication sharedApplication] 会走 scene 查询，
/// iOS 17 上非主线程访问 UIKit 可能直接把微信打崩（「一发唱歌命令就闪退」）。
static void InsVoiceKeepScreenOn(BOOL on) {
    void (^apply)(void) = ^{
        @try {
            UIApplication *app = [UIApplication sharedApplication];
            if (app && app.applicationState == UIApplicationStateActive) {
                [app setIdleTimerDisabled:on];
            }
        } @catch (NSException *e) {
            [InsConfig log:[NSString stringWithFormat:@"保亮 %@ 抛异常：%@", on ? @"开" : @"关", e.reason]];
        }
    };
    if ([NSThread isMainThread]) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

static NSString *const kInsVoiceFallbackBase  = @"https://api.breeze.blue";
static NSString *const kInsVoiceFallbackVoice = @"voc_u3nxkd5578wc";
static NSString *const kInsVoiceFallbackModel = @"breeze-tts-2";
/// 唱歌指令默认值：明确要求「演唱」而不是念。写法上强调音高/旋律/拖音，
/// Breeze 对表演指令的跟随强度依赖 cfg_scale（见 InsVoiceSynthesizeWith 的 4）
static NSString *const kInsDefaultSingInstructions =
    @"这是一段歌词，请用歌声把它唱出来，绝对不要用说话的腔调：每个字都要落在音高上，"
    @"乐句有起伏的旋律线条，韵脚字拖长音，句与句之间有呼吸和停顿；情绪饱满，"
    @"像完整地唱一首歌，而不是朗诵。";

#pragma mark - 注入状态

/// 正在往微信录音器里灌的 PCM（Breeze 的 pcm_24000：单声道 16bit 24kHz）
static NSData *gPCM = nil;
/// 已消耗的源采样数（浮点，便于重采样累积）
static double gCursor = 0;
static NSUInteger gSrcSamples = 0;
static NSUInteger gOutSamples = 0;
static BOOL gInjecting = NO;
static BOOL gFinished = NO;
static NSUInteger gFedBytes = 0;
static NSUInteger gFedFrames = 0;
static NSUInteger gRecRate = 0;          // 推断出的录音器采样率
static NSInteger gLastPartErr = -1;
static NSTimeInterval gStartedAt = 0;
static NSString *gTargetTalker = nil;
static void (^gFinishBlock)(BOOL ok, NSString *note) = nil;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static BOOL gHookInstalled = NO;
static NSInteger gGeneration = 0;

static void (*gOrigOnPcm)(id, SEL, NSData *, id) = NULL;
/// 录音器底层输出（MJVoiceInputRecorder outputPcmBuffer:bufferSize:，裸指针）
static void (*gOrigOutputPcm)(id, SEL, void *, unsigned int) = NULL;
/// 各条 PCM 通道被调用的次数：判断微信到底走哪条路喂编码器
static NSUInteger gPcmHookCalls = 0;
static NSUInteger gRecPcmCalls = 0;
/// 编码器入口（真正把 PCM 变成 SILK/Opus 再上传的地方）
static BOOL InsVoiceEncoderTaken(void);
static id (*gOrigSilkEncode)(id, SEL, id) = NULL;
static id (*gOrigMJSilkEncode)(id, SEL, id) = NULL;
static id (*gOrigOpusEncode)(id, SEL, id) = NULL;
static NSUInteger gSilkCalls = 0;
static NSUInteger gMJSilkCalls = 0;
static NSUInteger gOpusCalls = 0;
/// 录音文件通道（CommonVoiceRecordAudioService）：语音条真正上传的就是这个文件
static void (*gOrigAppendPcm)(id, SEL, id) = NULL;
static void (*gOrigFinishFile)(id, SEL) = NULL;
static NSUInteger gAppendCalls = 0;
static NSUInteger gAppendBytes = 0;
static BOOL gAppendUseOpus = NO;
static BOOL gLoggedAppend = NO;
/// 本次录音用的录音器实例（收尾时读它自己的录音时长，用来判断注入速率对不对）
static id gRecorder = nil;
/// TTS 放完之后还在被要数据的帧数（这些帧都是静音，会让语音条尾巴变长）
static NSUInteger gSilentTail = 0;
/// 强制用哪条通道灌 TTS：0=自动 1=只走 AudioSender 旁路 2=只走录音文件 3=只走编码器
static NSInteger gForceChannel = 0;
/// 强制编码输入端的数据格式：0=自动判定 1=int16 2=float32。
/// 格式猜错时编码器会把 int16 的小数当 float 的尾数读，编出来就是一串静音帧 ——
/// 现象正是「语音条有时长、但一点声音都没有」，所以留个手动开关逐条试。
static NSInteger gForceFmt = 0;
/// 编码器输出侧的证据：编出来的数据到底有多少字节、每帧多大
static NSUInteger gEncBytes = 0;
static NSUInteger gEncFrames = 0;
static NSMutableData *gEncOut = nil;
/// 上传侧的证据：OnRecorderPart 才是真正被传出去/落成语音条的分片
static NSUInteger gPartCalls = 0;
static NSUInteger gPartBytes = 0;
static unsigned int gPartDuration = 0;
static BOOL gLoggedPart = NO;
static BOOL gLoggedTmpAudio = NO;
static NSUInteger gTmpServed = 0;
/// 语音条的真正格式是 SILK（文件头 \x02#!SILK_V3），不是 Opus。
/// 所以必须用微信自带的 SILK 编码器把 TTS 编成同一种流，否则注进去的数据永远进不了语音条
static NSData *gSilkFile = nil;
static NSString *gSilkNote = nil;
/// 我们自己调 SILK 编码器时会命中自己的 hook（同一个 MJSilkCodec）。
/// 不挡住就会把 TTS 当成"微信来要录音数据"消费掉，结果录音被立刻判定放完、直接停录、
/// 语音条 0 毫秒 —— 第一次实测就是这么失败的（注入 480/90240、duration=0ms、没找到 .aud）
static BOOL gSilkBusy = NO;
static BOOL InsVoiceOverwriteAud(NSString *why);
/// 本次录音的 .aud 所在目录，以及开始时目录里最大的 localID（用来认出这次新写的那个文件）
static NSString *gAudDir = nil;
static long long gAudSinceID = 0;

static NSString *InsVoiceChannelName(NSInteger c) {
    switch (c) {
        case 1: return @"只走 AudioSender 旁路";
        case 2: return @"只走录音文件";
        case 3: return @"只走编码器";
        default: return @"自动（编码器优先，其次录音文件，最后旁路）";
    }
}

/// 通道实验：自动没声时，可以手动指定让哪条通道去灌 TTS，一条条试
static NSString *InsVoiceChannelReport(void) {
    NSMutableString *out = [NSMutableString stringWithFormat:@"语音注入通道：%@（%ld）\n",
                            InsVoiceChannelName(gForceChannel), (long)gForceChannel];
    [out appendFormat:@"上次命中：sender %lu / 文件 %lu / silk %lu / mjsilk %lu / opus %lu\n",
        (unsigned long)gPcmHookCalls, (unsigned long)gAppendCalls,
        (unsigned long)gSilkCalls, (unsigned long)gMJSilkCalls, (unsigned long)gOpusCalls];
    [out appendFormat:@"输入格式：%@｜编码输出 %lu 字节 / %lu 帧｜上传分片 %lu 个 / %lu 字节\n",
        gForceFmt == 1 ? @"强制 int16" : (gForceFmt == 2 ? @"强制 float32" : @"自动判定"),
        (unsigned long)gEncBytes, (unsigned long)gEncFrames,
        (unsigned long)gPartCalls, (unsigned long)gPartBytes];
    [out appendString:@"0 自动｜1 只走 AudioSender 旁路｜2 只走录音文件｜3 只走编码器\n"];
    [out appendString:@"用法：语音 通道 2（重启微信后回到自动）\n"];
    [out appendString:@"没声音时先试：语音 格式 float32（格式猜错会编出一串静音）"];
    return out;
}
static void (*gOrigOnPartSent)(id, SEL, id, unsigned int) = NULL;
static void (*gOrigOnUploadFail)(id, SEL, id) = NULL;
/// 录音器把编码好的分片交给上传：OnRecorderPart:Offset:Len:EndFlag:ForceDelete:Duration:
/// 这是「语音条里到底是什么」最终的一手证据，之前完全没看过
static void (*gOrigOnPart)(id, SEL, id, unsigned int, unsigned int, BOOL, BOOL, unsigned int) = NULL;
/// GetTmpAudio: 取本次录音的临时音频数据，长度直接反映有没有内容
static id (*gOrigGetTmpAudio)(id, SEL, unsigned int) = NULL;
/// 录音结束回调：文件已经写完、还没上传，是替换语音文件的最佳时机
static void (*gOrigOnRecorderEnd)(id, SEL, id) = NULL;

#pragma mark - 小工具

static NSString *InsVoiceClean(NSString *s) {
    if (![s isKindOfClass:[NSString class]]) return @"";
    static NSCharacterSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSCharacterSet characterSetWithCharactersInString:
               @" \t\r\n\u3000，。、,.:：;；!！?？~～…·\"'“”‘’「」『』【】（）()<>《》-—"];
    });
    NSString *t = [s stringByTrimmingCharactersInSet:set];
    // 「《静夜思》」被去掉开头的《之后会剩一个孤零零的》，念出来很怪
    while (t.length > 1 && [@"》」』）)" rangeOfString:[t substringToIndex:1]].location != NSNotFound) {
        t = [t substringFromIndex:1];
    }
    // 语音要念得顺：换行、连续空白压成一个空格
    t = [t stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    while ([t rangeOfString:@"  "].location != NSNotFound) {
        t = [t stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    return t ?: @"";
}

/// 「语音 说早上好」里那个「说」是动词，不该念出来；剥掉动词只留内容
static NSString *InsVoiceStripVerb(NSString *s) {
    static NSArray<NSString *> *verbs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        verbs = @[@"给我说", @"跟我说", @"跟他说", @"对她说", @"对他说", @"帮我念", @"帮我读",
                  @"照着念", @"念一下", @"原文", @"照读", @"朗读", @"复述",
                  @"说一句", @"说句", @"念一句", @"念一段", @"读一下", @"说出来",
                  @"发一句", @"发句", @"说", @"念", @"讲", @"读"];
    });
    if (![s isKindOfClass:[NSString class]] || !s.length) return s ?: @"";
    for (NSString *v in verbs) {
        if (![s hasPrefix:v]) continue;
        NSString *rest = [[s substringFromIndex:v.length]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // 剥完得还剩点东西，否则「语音 说」会把内容剥没
        if (rest.length >= 2) return rest;
    }
    return s;
}

/// 自然说法归一：发条语音 说早上好 / 发个语音 / 用语音说 … → 语音 …
static NSString *InsVoiceNormalize(NSString *s) {
    static NSArray<NSString *> *prefixes = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 长的排前面，避免「发语音」先把「发一段语音」吃掉一半。
        // 「用语音回复/语音回复...」也要整串剥掉，否则只剩「回复」被当成问题内容发给大模型。
        prefixes = @[@"用语音回复", @"发语音回复", @"语音回复一下", @"语音回复",
                     @"发一段语音", @"发一条语音", @"发条语音", @"发个语音", @"来条语音",
                     @"来段语音", @"用语音", @"发语音"];
    });
    for (NSString *p in prefixes) {
        if (![s hasPrefix:p]) continue;
        NSString *rest = [[s substringFromIndex:p.length]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return rest.length ? [@"语音 " stringByAppendingString:rest] : @"语音";
    }
    // 「换音色：xxx」/「换音色 xxx」/「换音色：语音 声 voc_xxx」也按换音色处理。
    // 实测用户发「换音色：语音 声 voc_rc894j8q2auu」没被命令识别，落到大模型，
    // 模型幻觉出「收到，音色切成 voc_xxx」但配置根本没改。这里归一化到「语音 声 <voc>」。
    for (NSString *p in @[@"换音色：", @"换音色:", @"换音色 "]) {
        if (![s hasPrefix:p]) continue;
        NSString *rest = [[s substringFromIndex:p.length]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!rest.length) return @"语音 声";   // 光说「换音色」→ 出用法/音色列表
        // 用户可能已经在后面写了「语音 声 voc_xxx」「声 voc_xxx」，只取 voc_ 那一段
        NSRange voc = [rest rangeOfString:@"voc_"];
        NSString *voiceId = voc.location != NSNotFound ? [rest substringFromIndex:voc.location] : rest;
        return [@"语音 声 " stringByAppendingString:voiceId];
    }
    return s;
}

/// AudioSender 实例缓存：拿一次就记住，避免每次发语音都重新找
static id gSenderCache = nil;
static NSString *gSenderHow = nil;

static id InsVoiceSender(void) {
    if (gSenderCache) return gSenderCache;
    Class senderCls = NSClassFromString(@"AudioSender");
    if (!senderCls) { gSenderHow = @"找不到类"; return nil; }

    // ① 先走微信自己的 service 表（旧版本 AudioSender 是注册服务）
    Class centerCls = NSClassFromString(@"MMServiceCenter");
    id center = nil;
    if (centerCls && [centerCls respondsToSelector:@selector(defaultCenter)]) {
        @try { center = ((id (*)(id, SEL))objc_msgSend)((id)centerCls, @selector(defaultCenter)); }
        @catch (NSException *e) { center = nil; }
    }
    if (center && [center respondsToSelector:@selector(getService:)]) {
        @try {
            id s = ((id (*)(id, SEL, Class))objc_msgSend)(center, @selector(getService:), senderCls);
            if (s) {
                gSenderCache = s;
                gSenderHow = @"service 表";
                return s;
            }
        } @catch (NSException *e) {
            [InsConfig log:[NSString stringWithFormat:@"语音：getService 抛异常 %@", e.reason]];
        }
    }

    // ② 新版本里它不是 service，service 表永远拿不到 —— 自己造一个并挂到 mono service
    @try {
        id s = ((id (*)(id, SEL))objc_msgSend)((id)senderCls, @selector(alloc));
        if (s) s = ((id (*)(id, SEL))objc_msgSend)(s, @selector(init));
        if (s) {
            if ([s respondsToSelector:@selector(addMonoService)]) {
                ((void (*)(id, SEL))objc_msgSend)(s, @selector(addMonoService));
            }
            gSenderCache = s;
            gSenderHow = @"自建实例";
            [InsConfig log:@"语音：AudioSender 不在 service 表里，已自建实例"];
            return s;
        }
    } @catch (NSException *e) {
        [InsConfig log:[NSString stringWithFormat:@"语音：自建 AudioSender 失败 %@", e.reason]];
    }
    gSenderHow = @"拿不到";
    return nil;
}

/// 体检用：AudioSender 到底是什么情况
static NSString *InsVoiceSenderDiag(void) {
    Class cls = NSClassFromString(@"AudioSender");
    if (!cls) return @"找不到 AudioSender 类（微信改名）";
    Class sup = class_getSuperclass(cls);
    NSMutableString *d = [NSMutableString stringWithFormat:@"父类 %@",
                          sup ? NSStringFromClass(sup) : @"(无)"];
    Class centerCls = NSClassFromString(@"MMServiceCenter");
    if (centerCls && [centerCls respondsToSelector:@selector(defaultCenter)]) {
        @try {
            id center = ((id (*)(id, SEL))objc_msgSend)((id)centerCls, @selector(defaultCenter));
            if (center && [center respondsToSelector:@selector(isServiceExist:)]) {
                BOOL ex = ((BOOL (*)(id, SEL, Class))objc_msgSend)(center,
                            @selector(isServiceExist:), cls);
                [d appendFormat:@"｜service 表%@", ex ? @"有" : @"没有"];
            }
        } @catch (NSException *e) {}
    }
    if (gSenderHow) [d appendFormat:@"｜%@", gSenderHow];
    return d;
}

static BOOL InsVoiceCanSend(NSString *from, NSString *to, NSString **why) {
    id sender = InsVoiceSender();
    if (!sender) { if (why) *why = @"拿不到 AudioSender（微信版本可能改名了）"; return NO; }
    if (![sender respondsToSelector:@selector(StartRecordFrom:ToUser:UserInfo:)]) {
        if (why) *why = @"AudioSender 没有 StartRecordFrom:ToUser:UserInfo:";
        return NO;
    }
    if (!from.length) return YES;   // 拿不到自己的 wxid 就不做预检，交给 StartRecordFrom 自己判
    @try {
        if ([sender respondsToSelector:@selector(CanStartRecordFrom:ToUser:)]) {
            BOOL ok = ((BOOL (*)(id, SEL, id, id))objc_msgSend)(
                sender, @selector(CanStartRecordFrom:ToUser:), from, to);
            if (!ok) { if (why) *why = @"微信当前不允许在这个会话录音（CanStartRecordFrom 返回 NO）"; return NO; }
        }
    } @catch (NSException *e) {
        if (why) *why = [NSString stringWithFormat:@"CanStartRecordFrom 抛异常：%@", e.reason];
        return NO;
    }
    return YES;
}

#pragma mark - 注入：把麦克风数据换成 TTS 的 PCM

static void InsVoiceFinishNow(BOOL ok, NSString *note);
static void InsVoiceRecord(BOOL ok, NSString *note);

static void InsVoiceStopRecording(void) {
    id sender = InsVoiceSender();
    if (!sender) return;
    @try {
        if ([sender respondsToSelector:@selector(StopRecord)]) {
            ((BOOL (*)(id, SEL))objc_msgSend)(sender, @selector(StopRecord));
        } else if ([sender respondsToSelector:@selector(StopRecordingInTransState:)]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(sender, @selector(StopRecordingInTransState:), YES);
        }
    } @catch (NSException *e) {
        [InsConfig log:[NSString stringWithFormat:@"语音：停止录音抛异常 %@", e.reason]];
    }
    // 第一道保险：StopRecord 一回来就把语音文件换成 SILK
    if (gInjecting && gSilkFile.length) InsVoiceOverwriteAud(@"StopRecord 后");
    // AudioSender 的 StopRecord 有时只是「请求停止」：录音器还在抓麦克风，
    // 语音条后面就会拖出一两秒静音（日志里「微信侧时长」明显大于 TTS 时长就是这个）。
    // 等 0.9 秒还没停就绕过它，直接把录音器停掉。
    NSInteger gen = gGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(0, 0), ^{
        if (gen != gGeneration) return;
        // 第二道保险：录音器彻底停了再覆盖一次，防止它把文件又写回去
        if (gInjecting && gSilkFile.length) InsVoiceOverwriteAud(@"停录 0.9 秒后");
        id rec = gRecorder;
        if (!rec) return;
        @try {
            if (![rec respondsToSelector:@selector(isRecording)]) return;
            if (!((BOOL (*)(id, SEL))objc_msgSend)(rec, @selector(isRecording))) return;
            [InsConfig log:@"语音：StopRecord 没停住，直接停录音器"];
            if ([rec respondsToSelector:@selector(stopButNotNotify)]) {
                ((void (*)(id, SEL))objc_msgSend)(rec, @selector(stopButNotNotify));
            } else if ([rec respondsToSelector:@selector(stop)]) {
                ((void (*)(id, SEL))objc_msgSend)(rec, @selector(stop));
            }
            if ([sender respondsToSelector:@selector(StopRecordingInTransState:)]) {
                ((void (*)(id, SEL, BOOL))objc_msgSend)(sender, @selector(StopRecordingInTransState:), YES);
            }
        } @catch (NSException *e) {
            [InsConfig log:[NSString stringWithFormat:@"语音：强制停录音器失败 %@", e.reason]];
        }
    });
}

static void InsVoiceScheduleStop(void) {
    // 最后一个 PCM 帧喂完后留一点尾巴再停，避免微信把尾音截掉。
    // PCM 末尾已经补了 0.4 秒静音，这里再留 0.4 秒给微信把最后几帧编完 —— 之前 0.15 秒
    // 实测会把最后一个字切掉
    NSInteger gen = gGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gen != gGeneration) return;
        if (!gInjecting) return;
        InsVoiceStopRecording();
    });
}

/// 目标采样率：录音器/编码器真实用的那个。猜错会让语音变快或变慢（1.8 秒的话放成 0.9 秒）
static NSUInteger gTargetRate = 0;
static NSString *gRateFrom = nil;
/// 停止只排一次，避免多个通道同时到尾部反复 StopRecord
static BOOL gStopScheduled = NO;

/// 从编码器/录音器自己的属性里取真实采样率：编码器就是按这个采样率收数据的，最权威
static void InsVoiceAdoptRate(id codec) {
    if (gTargetRate || !codec) return;
    @try {
        for (NSString *name in @[@"encoderSampleRate", @"sampleRate", @"pcmSampleRate"]) {
            SEL sel = NSSelectorFromString(name);
            if (![codec respondsToSelector:sel]) continue;
            NSMethodSignature *sig = [codec methodSignatureForSelector:sel];
            if (!sig) continue;
            NSInteger v = (sig.methodReturnLength == 4)
                ? (NSInteger)((int (*)(id, SEL))objc_msgSend)(codec, sel)
                : (NSInteger)((long long (*)(id, SEL))objc_msgSend)(codec, sel);
            if (v < 8000 || v > 96000) continue;
            gTargetRate = (NSUInteger)v;
            gRateFrom = name;
            [InsConfig log:[NSString stringWithFormat:@"语音：编码器采样率 %ld（取自 %@）", (long)v, name]];
            return;
        }
    } @catch (NSException *e) {}
}

#pragma mark - 采样格式

/// 编码器要的数据格式。微信不同版本有 int16 和 float32 两种；
/// 格式猜错（把 int16 当成 float32 喂进去）编码结果几乎是 0 —— 语音条有时长、却一点声音都没有。
typedef NS_ENUM(NSInteger, InsPcmFmt) {
    InsPcmFmtUnknown = 0,
    InsPcmFmtInt16,
    InsPcmFmtFloat32,
};
static InsPcmFmt gInFmt = InsPcmFmtUnknown;
static NSString *gFmtNote = nil;

static NSUInteger InsVoiceBytesPerSample(void) {
    return (gInFmt == InsPcmFmtFloat32) ? 4 : 2;
}

/// 拿一帧真实录音数据判格式：同一段字节分别按 int16 / float32 解释，哪个像声音就用哪个。
/// authoritative=YES 表示这是编码器的输入（最可信），在还没喂过数据前可以覆盖之前的判断。
static void InsVoiceDetectFormat(NSData *d, BOOL authoritative) {
    // 手动指定优先：靠猜测判定在「原始录音几乎是静音」时本来就可能判错，
    // 而判错的代价是整条语音无声，所以必须留一条人工通路
    if (gForceFmt) {
        InsPcmFmt want = (gForceFmt == 2) ? InsPcmFmtFloat32 : InsPcmFmtInt16;
        if (gInFmt != want) {
            gInFmt = want;
            gFmtNote = @"手动指定";
            [InsConfig log:[NSString stringWithFormat:@"语音：输入格式手动指定为 %@",
                            (want == InsPcmFmtFloat32) ? @"float32" : @"int16"]];
        }
        return;
    }
    if (!d.length || d.length < 256) return;
    if (gInFmt != InsPcmFmtUnknown && !(authoritative && gFedFrames == 0)) return;

    const int16_t *s = (const int16_t *)d.bytes;
    NSUInteger ns = MIN(d.length / 2, (NSUInteger)3000);
    int iMax = 0;
    for (NSUInteger i = 0; i < ns; i++) {
        int v = (int)s[i];
        if (v < 0) v = -v;
        if (v > iMax) iMax = v;
    }
    float fMax = 0;
    if ((d.length % 4) == 0) {
        const float *f = (const float *)d.bytes;
        NSUInteger nf = MIN(d.length / 4, (NSUInteger)2000);
        for (NSUInteger i = 0; i < nf; i++) {
            float a = fabsf(f[i]);
            if (a > fMax) fMax = a;
        }
    }
    InsPcmFmt fmt;
    if (fMax > 0.0002f && fMax <= 4.0f && iMax < 1200) {
        fmt = InsPcmFmtFloat32;     // 按 float 解释落在 [-1,1]，按 int16 解释几乎是 0 → 是 float
    } else {
        fmt = InsPcmFmtInt16;
    }
    NSString *note = [NSString stringWithFormat:@"int16峰值=%d float峰值=%.4f（%lu 字节/帧）",
                      iMax, fMax, (unsigned long)d.length];
    BOOL changed = (fmt != gInFmt);
    gInFmt = fmt;
    gFmtNote = note;
    if (changed) {
        [InsConfig log:[NSString stringWithFormat:@"语音：编码输入判定为 %@ —— %@",
                        (fmt == InsPcmFmtFloat32) ? @"float32" : @"int16", note]];
    }
}

static BOOL gLoggedOutWave = NO;

/// 按微信这一帧要求的大小，生成等长的 PCM（含重采样与格式转换）。
/// 返回的缓冲永远是整帧长度：源音频放完了就用静音补满，调用方不需要再判 nil。
static NSData *InsVoiceNextChunk(NSUInteger wantBytes) {
    if (!wantBytes) wantBytes = 640;
    if (wantBytes % 2) wantBytes -= 1;
    if (!wantBytes) return nil;
    os_unfair_lock_lock(&gLock);
    if (!gPCM.length || gCursor >= (double)gSrcSamples) {
        os_unfair_lock_unlock(&gLock);
        return nil;
    }
    if (!gTargetRate) {
        // 兜底：录音器一帧通常 20ms，字节数 / 2 / 0.02 = 采样率。但大帧会一律落到 48000，
        // 所以上面 InsVoiceAdoptRate 优先，这里只是最后一道
        NSUInteger guess = wantBytes * 25;
        if (guess >= 40000) guess = 48000;
        else if (guess >= 20000) guess = 24000;
        else if (guess >= 12000) guess = 16000;
        else guess = 8000;
        gTargetRate = guess;
        gRateFrom = @"按帧长推断";
    }
    gRecRate = gTargetRate;
    const int16_t *src = (const int16_t *)gPCM.bytes;
    NSUInteger bps = InsVoiceBytesPerSample();       // 目标格式每采样字节数
    NSUInteger n = wantBytes / bps;                  // 这一帧要几个采样
    double ratio = 24000.0 / (double)gTargetRate;    // 源 24k → 目标
    NSMutableData *out = [NSMutableData dataWithLength:wantBytes];   // 余下的字节自然是 0
    if (gInFmt == InsPcmFmtFloat32) {
        float *dst = (float *)out.mutableBytes;
        for (NSUInteger i = 0; i < n; i++) {
            double pos = gCursor + (double)i * ratio;
            if (pos >= (double)(gSrcSamples - 1)) { dst[i] = 0.0f; continue; }
            NSUInteger i0 = (NSUInteger)pos;
            double frac = pos - (double)i0;
            double v0 = (double)src[i0];
            double v1 = (i0 + 1 < gSrcSamples) ? (double)src[i0 + 1] : v0;
            double v = v0 + (v1 - v0) * frac;        // int16 量纲 → 归一化到 ±1
            if (v > 32767.0) v = 32767.0;
            if (v < -32768.0) v = -32768.0;
            dst[i] = (float)(v / 32768.0);
        }
    } else {
        int16_t *dst = (int16_t *)out.mutableBytes;
        for (NSUInteger i = 0; i < n; i++) {
            double pos = gCursor + (double)i * ratio;
            if (pos >= (double)(gSrcSamples - 1)) { dst[i] = 0; continue; }
            NSUInteger i0 = (NSUInteger)pos;
            double frac = pos - (double)i0;
            double v0 = (double)src[i0];
            double v1 = (i0 + 1 < gSrcSamples) ? (double)src[i0 + 1] : v0;
            double v = v0 + (v1 - v0) * frac;
            if (v > 32767.0) v = 32767.0;
            if (v < -32768.0) v = -32768.0;
            dst[i] = (int16_t)lrint(v);
        }
    }
    gCursor += (double)n * ratio;
    if (gCursor > (double)gSrcSamples) gCursor = (double)gSrcSamples;
    gOutSamples += n;
    gFedBytes += wantBytes;
    gFedFrames += 1;
    // 判断「放完了」必须用源位置和源长度比；之前拿输出采样数比，48k 目标时刚过半就判定放完，
    // 结果只播了前半句、后半句全是静音
    BOOL done = (gCursor >= (double)gSrcSamples);
    BOOL first = (done && !gStopScheduled);
    if (first) gStopScheduled = YES;
    os_unfair_lock_unlock(&gLock);
    if (first) InsVoiceScheduleStop();
    // 第一帧输出自检：确认真正写进编码器的波形不是 0（之前静音时完全看不出是哪一环怪）
    if (!gLoggedOutWave) {
        gLoggedOutWave = YES;
        int peak = 0;
        if (gInFmt == InsPcmFmtFloat32) {
            const float *f = (const float *)out.bytes;
            for (NSUInteger i = 0; i < n && i < 4096; i++) {
                int v = (int)(fabsf(f[i]) * 32768.0f);
                if (v > peak) peak = v;
            }
        } else {
            const int16_t *q = (const int16_t *)out.bytes;
            for (NSUInteger i = 0; i < n && i < 4096; i++) {
                int v = q[i] < 0 ? -q[i] : q[i];
                if (v > peak) peak = v;
            }
        }
        [InsConfig log:[NSString stringWithFormat:
            @"语音：首帧输出 格式=%@ 目标率=%lu 帧字节=%lu 峰值(≈16bit)=%d 已用源采样=%.0f/%.0f",
            (gInFmt == InsPcmFmtFloat32) ? @"float32" : @"int16", (unsigned long)gTargetRate,
            (unsigned long)wantBytes, peak, gCursor, (double)gSrcSamples]];
    }
    return out;
}

#pragma mark - SILK：语音条真正的编码格式

/// 设备上的语音文件实测是 02 23 21 53 49 4C 4B 5F 56 33 …，也就是 0x02 + "#!SILK_V3"。
/// 也就是说语音条走的是 SILK，跟 OpusAudioCodec 那条完全无关 —— 之前注 Opus 注定无效。
static NSString *InsVoiceMD5Hex(NSString *s) {
    if (!s.length) return @"";
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_MD5_DIGEST_LENGTH];
    CC_MD5(d.bytes, (CC_LONG)d.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

/// 微信语音目录：Documents/<账号 hash>/Audio/<md5(wxid)>/
static NSString *InsVoiceAudDir(NSString *talker) {
    if (!talker.length) return nil;
    NSString *docs = [[InsConfig rootDir] stringByDeletingLastPathComponent];
    NSString *sub = InsVoiceMD5Hex([talker lowercaseString]);
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *name in [fm contentsOfDirectoryAtPath:docs error:nil]) {
        NSString *dir = [[[docs stringByAppendingPathComponent:name]
                          stringByAppendingPathComponent:@"Audio"]
                         stringByAppendingPathComponent:sub];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:dir isDirectory:&isDir] && isDir) return dir;
    }
    return nil;
}

static long long InsVoiceMaxAudID(NSString *dir) {
    if (!dir.length) return 0;
    long long best = 0;
    for (NSString *f in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil]) {
        if (![f hasSuffix:@".aud"]) continue;
        long long v = [[f stringByDeletingPathExtension] longLongValue];
        if (v > best) best = v;
    }
    return best;
}

/// 录音一结束就把这次新写的 .aud 换成我们编的 SILK（原文件先备份成 .orig）。
/// 这是「语音条内容」最后能改的时机：再晚微信就把文件读进内存准备上传了。
static BOOL InsVoiceOverwriteAud(NSString *why) {
    if (!gSilkFile.length || !gAudDir.length) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *best = nil;
    long long bestID = gAudSinceID;
    for (NSString *f in [fm contentsOfDirectoryAtPath:gAudDir error:nil]) {
        if (![f hasSuffix:@".aud"]) continue;
        long long v = [[f stringByDeletingPathExtension] longLongValue];
        if (v > bestID) { bestID = v; best = [gAudDir stringByAppendingPathComponent:f]; }
    }
    if (!best.length) {
        [InsConfig log:[NSString stringWithFormat:@"语音：%@没找到新 .aud（起始 localID %lld）",
                        why ?: @"", gAudSinceID]];
        return NO;
    }
    NSString *bak = [best stringByAppendingString:@".orig"];
    if (![fm fileExistsAtPath:bak]) [fm copyItemAtPath:best toPath:bak error:nil];
    BOOL ok = [gSilkFile writeToFile:best atomically:YES];
    [InsConfig log:[NSString stringWithFormat:@"语音：%@覆盖 %@ → %lu 字节（原文件已备份 .orig）%@",
                    why ?: @"", best.lastPathComponent, (unsigned long)gSilkFile.length,
                    ok ? @"" : @" 写入失败"]];
    return ok;
}

/// 用微信自己的 SILK 编码器把 24k int16 的 TTS 编成语音条那种流。
/// 先试 MJSilkCodec（encodeFromPCMData:），不行再试 SilkAudioEncoder（encodePcmBuffer:）。
static NSData *InsVoiceSilkEncode(NSData *pcm, NSUInteger rate, NSString **noteOut) {
    if (!pcm.length) return nil;
    if (rate < 8000 || rate > 48000) rate = 24000;
    NSUInteger frame = rate / 50;                 // 20ms 一帧
    if (!frame) frame = 480;
    NSUInteger frameBytes = frame * 2;

    id codec = nil;
    SEL encSel = NULL;
    NSString *kind = nil;
    Class mjCls = NSClassFromString(@"MJSilkCodec");
    if (mjCls) {
        @try {
            id c = [[mjCls alloc] init];
            SEL initSel = @selector(initEncoderWithSampleRate:);
            if ([c respondsToSelector:initSel] && [c respondsToSelector:@selector(encodeFromPCMData:)]) {
                BOOL ok = ((BOOL (*)(id, SEL, long long))objc_msgSend)(c, initSel, (long long)rate);
                if (ok) { codec = c; encSel = @selector(encodeFromPCMData:); kind = @"MJSilkCodec"; }
            }
        } @catch (NSException *e) {
            [InsConfig log:[NSString stringWithFormat:@"语音：MJSilkCodec 初始化异常 %@", e.reason]];
        }
    }
    if (!codec) {
        Class seCls = NSClassFromString(@"SilkAudioEncoder");
        if (seCls) {
            @try {
                id c = [[seCls alloc] init];
                SEL initSel = @selector(initWithSampleRate:bitRate:cpuType:);
                if ([c respondsToSelector:initSel] && [c respondsToSelector:@selector(encodePcmBuffer:)]) {
                    id r = ((id (*)(id, SEL, unsigned int, unsigned int, unsigned int))objc_msgSend)(
                        c, initSel, (unsigned int)rate, (unsigned int)24000, (unsigned int)0);
                    if (r) { codec = c; encSel = @selector(encodePcmBuffer:); kind = @"SilkAudioEncoder"; }
                }
            } @catch (NSException *e) {
                [InsConfig log:[NSString stringWithFormat:@"语音：SilkAudioEncoder 初始化异常 %@", e.reason]];
            }
        }
    }
    if (!codec) {
        if (noteOut) *noteOut = @"进程里没有可用的 SILK 编码器";
        return nil;
    }

    // 编码期间必须先关掉自己的注入 hook，否则每一次 encodeFromPCMData 都会被当成
    // 「微信来要录音数据」，把 TTS 一段段消费掉 —— 实测就是这样直接停录、语音条 0 秒
    gSilkBusy = YES;
    NSMutableData *frames = [NSMutableData data];
    BOOL sawHeader = NO;
    NSUInteger offset = 0, okFrames = 0, emptyFrames = 0;
    NSUInteger minLen = NSUIntegerMax, maxLen = 0;
    @try {
        while (offset < pcm.length) {
            NSUInteger n = MIN(frameBytes, pcm.length - offset);
            NSMutableData *chunk = [[pcm subdataWithRange:NSMakeRange(offset, n)] mutableCopy];
            if (n < frameBytes) [chunk appendData:[NSMutableData dataWithLength:frameBytes - n]];
            offset += n;
            id ret = nil;
            @try {
                ret = ((id (*)(id, SEL, id))objc_msgSend)(codec, encSel, chunk);
            } @catch (NSException *e) {
                if (noteOut) *noteOut = [NSString stringWithFormat:@"%@ 第 %lu 帧抛异常：%@",
                                         kind, (unsigned long)okFrames + 1, e.reason];
                return nil;
            }
            if (![ret isKindOfClass:[NSData class]] || ![(NSData *)ret length]) { emptyFrames++; continue; }
            NSData *d = (NSData *)ret;
            const unsigned char *b = d.bytes;
            // 第一帧自带 SILK 文件头（0x03 '#' '!' 'S' …）：微信 .aud 用的是 0x02 版本，
            // 把首字节换成 0x02 就是合法容器；这一帧后面串的包本来就带 2 字节长度
            if (d.length >= 10 && (b[0] == 0x02 || b[0] == 0x03) &&
                b[1] == '#' && b[2] == '!' && b[3] == 'S') {
                NSMutableData *m = [d mutableCopy];
                ((unsigned char *)m.mutableBytes)[0] = 0x02;
                [frames appendData:m];
                sawHeader = YES;
                okFrames++;
                if (d.length < minLen) minLen = d.length;
                if (d.length > maxLen) maxLen = d.length;
                continue;
            }
            // 有的版本返回带 2 字节长度头的帧，有的返回裸载荷：靠长度自洽性判断
            BOOL hasLen = (d.length >= 3) && ((NSUInteger)(b[0] | (b[1] << 8)) == d.length - 2);
            if (!hasLen) {
                uint16_t h = (uint16_t)d.length;
                [frames appendBytes:&h length:2];
            }
            [frames appendData:d];
            okFrames++;
            if (d.length < minLen) minLen = d.length;
            if (d.length > maxLen) maxLen = d.length;
        }
    } @finally {
        gSilkBusy = NO;
    }
    if (!frames.length) {
        if (noteOut) *noteOut = [NSString stringWithFormat:@"%@ 编出 0 帧（空帧 %lu）",
                                 kind, (unsigned long)emptyFrames];
        return nil;
    }
    NSMutableData *out = [NSMutableData data];
    if (!sawHeader) [out appendBytes:"\x02#!SILK_V3" length:10];
    [out appendData:frames];
    if (noteOut) {
        *noteOut = [NSString stringWithFormat:@"%@ %lu 帧 / %lu 字节（单帧 %lu~%lu，空帧 %lu）",
                    kind, (unsigned long)okFrames, (unsigned long)out.length,
                    (unsigned long)(minLen == NSUIntegerMax ? 0 : minLen),
                    (unsigned long)maxLen, (unsigned long)emptyFrames];
    }
    @try {
        if ([codec respondsToSelector:@selector(uninitEncoder)]) {
            ((BOOL (*)(id, SEL))objc_msgSend)(codec, @selector(uninitEncoder));
        }
    } @catch (NSException *e) {}
    return out;
}

/// 把 TTS 的裸 PCM 另存一份 wav 到 Insomnia 目录。
/// 「语音条没声音」有两种可能：合成出来就是静音，或者合成正常但没写进微信。
/// 有了这个文件，用户用文件传输助手把 wav 拉出来一听就能定案，不用靠猜。
static void InsVoiceDumpWav(NSData *pcm, NSUInteger rate) {
    if (!pcm.length || rate < 8000) return;
    uint32_t dataLen = (uint32_t)pcm.length;
    uint32_t riffLen = 36 + dataLen;
    uint16_t fmt = 1, ch = 1, bits = 16, blockAlign = 2;
    uint32_t r = (uint32_t)rate, byteRate = (uint32_t)(rate * 2);
    uint32_t subLen = 16;
    NSMutableData *wav = [NSMutableData dataWithCapacity:44 + dataLen];
    [wav appendBytes:"RIFF" length:4];
    [wav appendBytes:&riffLen length:4];
    [wav appendBytes:"WAVEfmt " length:8];
    [wav appendBytes:&subLen length:4];
    [wav appendBytes:&fmt length:2];
    [wav appendBytes:&ch length:2];
    [wav appendBytes:&r length:4];
    [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&blockAlign length:2];
    [wav appendBytes:&bits length:2];
    [wav appendBytes:"data" length:4];
    [wav appendBytes:&dataLen length:4];
    [wav appendData:pcm];
    NSString *path = [[InsConfig rootDir] stringByAppendingPathComponent:@"voice_last.wav"];
    [wav writeToFile:path atomically:YES];
}

/// 把 TTS 的 PCM 直接写进录音器给的裸内存（不新分配，避免格式/长度不匹配）
static BOOL gLoggedUserData = NO;

static BOOL InsVoiceFillRaw(void *dst, NSUInteger bytes) {
    if (!dst || !bytes) return NO;
    NSData *chunk = InsVoiceNextChunk(bytes);
    if (!chunk.length) {
        if (gInjecting) gSilentTail += 1;
        memset(dst, 0, bytes);
        return NO;
    }
    memcpy(dst, chunk.bytes, MIN(bytes, chunk.length));
    return YES;
}

/// MJVoiceInputRecorder 的底层输出：录音器把裸 PCM 交出去之前先就地换成 TTS 数据。
/// 比 AudioSender 的 OnOutputPcmBuffer 更靠近编码器，是正常发语音真正走的那条。
static void InsVoiceOnRecorderPcm(id self, SEL _cmd, void *buf, unsigned int size) {
    if (gInjecting && !gSilkBusy && buf && size > 0) {
        // 编码器已经在接管时，这里不能改：它可能正是编码器的输入源，改了等于喂两遍
        if (!InsVoiceEncoderTaken()) {
            gRecPcmCalls += 1;
            InsVoiceFillRaw(buf, size);
        }
    }
    if (gOrigOutputPcm) gOrigOutputPcm(self, _cmd, buf, size);
}

/// 同一份 TTS 只能被一条通道消费，否则会被切成几段、声音变碎。
/// 优先级：编码器（最靠近上传） > 录音器裸指针 > AudioSender 旁路
static BOOL InsVoiceEncoderTaken(void) {
    return (gSilkCalls + gMJSilkCalls + gOpusCalls) > 0;
}

/// 编码器返回的数据就是「要上传的语音」。静音帧只有 1~3 字节，正常说话一帧十几到几十字节
/// —— 语音条有时长却没声音，看这里立刻能分出「格式喂错（编出静音）」还是「编好了但没上传」
static void InsVoiceNoteEncOut(NSString *tag, id ret) {
    if (!gInjecting) return;
    NSUInteger len = [ret isKindOfClass:[NSData class]] ? [(NSData *)ret length] : 0;
    gEncFrames += 1;
    gEncBytes += len;
    if ([ret isKindOfClass:[NSData class]] && len) {
        if (!gEncOut) gEncOut = [NSMutableData data];
        [gEncOut appendData:(NSData *)ret];
    }
    if (gEncFrames <= 3) {
        NSMutableString *hex = [NSMutableString string];
        if ([ret isKindOfClass:[NSData class]]) {
            const unsigned char *b = (const unsigned char *)[(NSData *)ret bytes];
            NSUInteger n = MIN((NSUInteger)8, len);
            for (NSUInteger i = 0; i < n; i++) [hex appendFormat:@"%02x", b[i]];
        }
        [InsConfig log:[NSString stringWithFormat:@"语音：编码输出第 %lu 帧 %@ → %lu 字节 头=%@",
                        (unsigned long)gEncFrames, tag, (unsigned long)len,
                        hex.length ? hex : @"（空）"]];
    }
}

/// MJSilkCodec 的入口（encodeFromPCMData:），和 SilkAudioEncoder 二选一命中
static id InsVoiceOnMJSilkEncode(id self, SEL _cmd, id pcm) {
    if (gInjecting && !gSilkBusy) InsVoiceAdoptRate(self);
    if (gInjecting && !gSilkBusy && [pcm isKindOfClass:[NSData class]]) InsVoiceDetectFormat((NSData *)pcm, YES);
    if (gInjecting && !gSilkBusy && gSilkCalls == 0 && (gForceChannel == 0 || gForceChannel == 3) &&
        [pcm isKindOfClass:[NSData class]]) {
        NSUInteger want = [(NSData *)pcm length];
        if (want > 1 && want < 200000) {
            gMJSilkCalls += 1;
            NSData *mine = InsVoiceNextChunk(want);
            if (mine.length) {
                id ret = gOrigMJSilkEncode ? gOrigMJSilkEncode(self, _cmd, mine) : nil;
                InsVoiceNoteEncOut(@"mjsilk", ret);
                return ret;
            }
            if (gOrigMJSilkEncode) return gOrigMJSilkEncode(self, _cmd, [NSMutableData dataWithLength:want]);
        }
    }
    return gOrigMJSilkEncode ? gOrigMJSilkEncode(self, _cmd, pcm) : nil;
}

/// SILK 编码入口：参数就是要编码的 PCM，换成 TTS 的等长数据即可
static id InsVoiceOnSilkEncode(id self, SEL _cmd, id pcm) {
    if (gInjecting && !gSilkBusy) InsVoiceAdoptRate(self);
    if (gInjecting && !gSilkBusy && [pcm isKindOfClass:[NSData class]]) InsVoiceDetectFormat((NSData *)pcm, YES);
    if (gInjecting && !gSilkBusy && gMJSilkCalls == 0 && (gForceChannel == 0 || gForceChannel == 3) &&
        [pcm isKindOfClass:[NSData class]]) {
        NSUInteger want = [(NSData *)pcm length];
        if (want > 1 && want < 200000) {
            gSilkCalls += 1;
            NSData *mine = InsVoiceNextChunk(want);
            if (mine.length) {
                id ret = gOrigSilkEncode ? gOrigSilkEncode(self, _cmd, mine) : nil;
                InsVoiceNoteEncOut(@"silk", ret);
                return ret;
            }
            if (gOrigSilkEncode) return gOrigSilkEncode(self, _cmd, [NSMutableData dataWithLength:want]);
        }
    }
    return gOrigSilkEncode ? gOrigSilkEncode(self, _cmd, pcm) : nil;
}

/// Opus 编码入口：同上
static id InsVoiceOnOpusEncode(id self, SEL _cmd, id pcm) {
    if (gInjecting && !gSilkBusy) InsVoiceAdoptRate(self);
    if (gInjecting && !gSilkBusy && [pcm isKindOfClass:[NSData class]]) InsVoiceDetectFormat((NSData *)pcm, YES);
    if (gInjecting && !gSilkBusy && gSilkCalls == 0 && gMJSilkCalls == 0 &&
        (gForceChannel == 0 || gForceChannel == 3) && [pcm isKindOfClass:[NSData class]]) {
        NSUInteger want = [(NSData *)pcm length];
        if (want > 1 && want < 200000) {
            gOpusCalls += 1;
            NSData *mine = InsVoiceNextChunk(want);
            if (mine.length) {
                id ret = gOrigOpusEncode ? gOrigOpusEncode(self, _cmd, mine) : nil;
                InsVoiceNoteEncOut(@"opus", ret);
                return ret;
            }
            if (gOrigOpusEncode) return gOrigOpusEncode(self, _cmd, [NSMutableData dataWithLength:want]);
        }
    }
    return gOrigOpusEncode ? gOrigOpusEncode(self, _cmd, pcm) : nil;
}

/// 录音文件通道 —— 真正被打包成语音条上传的那份数据（CommonVoiceRecordAudioService）。
/// fileUseOpus=YES 时这里收到的是已编码的 opus 分片，不能替换；NO 时是裸 PCM，可以替换。
static void InsVoiceOnAppendPcm(id self, SEL _cmd, id data) {
    id use = data;
    if (gInjecting && !gSilkBusy && [data isKindOfClass:[NSData class]]) {
        NSUInteger len = [(NSData *)data length];
        BOOL useOpus = NO;
        @try {
            if ([self respondsToSelector:@selector(fileUseOpus)]) {
                useOpus = ((BOOL (*)(id, SEL))objc_msgSend)(self, @selector(fileUseOpus));
            }
        } @catch (NSException *e) {}
        if (!gLoggedAppend) {
            gLoggedAppend = YES;
            gAppendUseOpus = useOpus;
            [InsConfig log:[NSString stringWithFormat:
                @"语音：录音文件写入首块 %lu 字节 fileUseOpus=%d",
                (unsigned long)len, (int)useOpus]];
        }
        // 只有裸 PCM 才替换；已经编码过的分片替换了就成噪音
        BOOL take = (gForceChannel == 2) ||
                    (gForceChannel == 0 && !useOpus && !InsVoiceEncoderTaken() && !gRecPcmCalls);
        if (take && len >= 320 && (len % 2) == 0) {
            NSData *mine = InsVoiceNextChunk(len);
            if (mine.length) {
                gAppendCalls += 1;
                gAppendBytes += len;
                use = mine;
            }
        }
    }
    if (gOrigAppendPcm) gOrigAppendPcm(self, _cmd, use);
}

/// 录音文件收尾：把真正要上传的文件路径和大小打出来，这是「语音条内容」的最终证据
static void InsVoiceOnFinishFile(id self, SEL _cmd) {
    if (gOrigFinishFile) gOrigFinishFile(self, _cmd);
    if (!gInjecting && !gAppendCalls) return;
    @try {
        NSString *path = nil;
        if ([self respondsToSelector:@selector(recordFilePath)]) {
            path = ((id (*)(id, SEL))objc_msgSend)(self, @selector(recordFilePath));
        }
        unsigned long long size = 0;
        if (path.length) {
            NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
            size = [attr[NSFileSize] unsignedLongLongValue];
        }
        [InsConfig log:[NSString stringWithFormat:
            @"语音：录音文件收尾 %@ 大小 %llu 字节（注入块 %lu / %lu 字节）",
            path.length ? path.lastPathComponent : @"（没路径）", size,
            (unsigned long)gAppendCalls, (unsigned long)gAppendBytes]];
    } @catch (NSException *e) {}
}

static void InsVoiceOnPcmBuffer(id self, SEL _cmd, NSData *buffer, id userData) {
    if (!gInjecting || gSilkBusy || !gOrigOnPcm) {
        if (gOrigOnPcm) gOrigOnPcm(self, _cmd, buffer, userData);
        return;
    }
    gPcmHookCalls += 1;
    if (!gLoggedUserData) {
        gLoggedUserData = YES;
        // userData 若自带 PCM 指针，说明微信可能忽略我们传进去的 buffer —— 这条日志是判据
        [InsConfig log:[NSString stringWithFormat:@"语音：PCM userData=%@ %@",
                        NSStringFromClass([userData class]), userData ?: @"nil"]];
    }
    if (!InsVoiceEncoderTaken()) InsVoiceDetectFormat(buffer, NO);
    NSUInteger want = buffer.length ?: 640;
    // 前 0.5 秒先让真正的通道抢：编码器/录音文件通常第一帧就到了，
    // 旁路要是先吃掉一段，编码器拿到的就是从中间开始的音频（会听起来串音）
    BOOL grace = (gAppendCalls + gSilkCalls + gMJSilkCalls + gOpusCalls + gRecPcmCalls) == 0 &&
                 ([NSDate timeIntervalSinceReferenceDate] - gStartedAt) < 0.8;
    BOOL takeSender = (gForceChannel == 1) ||
                      (gForceChannel == 0 && !grace && !InsVoiceEncoderTaken() &&
                       gRecPcmCalls == 0 && gAppendCalls == 0);
    if (!takeSender) {
        // 更靠近编码器的通道已经接管，这条旁路只喂静音，避免同一份 TTS 被消费两遍
        gOrigOnPcm(self, _cmd, [NSMutableData dataWithLength:want], userData);
        return;
    }
    NSData *mine = InsVoiceNextChunk(want);
    if (!mine) {
        // 已经放完：喂等长静音，别把真实麦克风的声音录进语音条
        if (gInjecting) gSilentTail += 1;
        NSData *silence = [NSMutableData dataWithLength:want];
        gOrigOnPcm(self, _cmd, silence, userData);
        return;
    }
    gOrigOnPcm(self, _cmd, mine, userData);
}

/// 录音器交出的分片（part）通常是已编码的数据，len 是它的字节数。
/// 如果这里累计的字节数很小（几百字节），说明语音条里几乎没内容，问题在编码上游而不是发送
static void InsVoiceOnRecorderPart(id self, SEL _cmd, id part, unsigned int offset,
                                   unsigned int len, BOOL endFlag, BOOL forceDelete,
                                   unsigned int duration) {
    if (gInjecting) {
        gPartCalls += 1;
        gPartBytes += len;
        gPartDuration = duration;
        if (!gLoggedPart) {
            gLoggedPart = YES;
            NSUInteger plen = [part isKindOfClass:[NSData class]] ? [(NSData *)part length] : 0;
            NSMutableString *head = [NSMutableString string];
            if (plen) {
                const unsigned char *b = (const unsigned char *)[(NSData *)part bytes];
                for (NSUInteger i = 0; i < MIN((NSUInteger)12, plen); i++) [head appendFormat:@"%02x", b[i]];
            }
            [InsConfig log:[NSString stringWithFormat:
                @"语音：上传首片 part=%lu 字节 len=%u offset=%u end=%d del=%d duration=%ums 类=%@ 头=%@",
                (unsigned long)plen, len, offset, (int)endFlag, (int)forceDelete, duration,
                NSStringFromClass([part class]), head.length ? head : @"（非 NSData）"]];
        }
    }
    if (gOrigOnPart) gOrigOnPart(self, _cmd, part, offset, len, endFlag, forceDelete, duration);
}

/// 本次录音的临时音频：长度 + 头部字节。silk 头是 #!SILK_V3 / 0x02 0x23，opus 是 OggS 或微信自定义头。
/// TTS 已经放完（gStopScheduled）之后，这里要的就是最终语音内容 —— 直接把整条 SILK 换进去。
static id InsVoiceOnGetTmpAudio(id self, SEL _cmd, unsigned int audioId) {
    if (gInjecting && !gSilkBusy && gSilkFile.length && gStopScheduled) {
        gTmpServed += 1;
        if (gTmpServed <= 2) {
            [InsConfig log:[NSString stringWithFormat:
                @"语音：GetTmpAudio 返回我们编的 SILK %lu 字节（第 %lu 次）",
                (unsigned long)gSilkFile.length, (unsigned long)gTmpServed]];
        }
        return gSilkFile;
    }
    id ret = gOrigGetTmpAudio ? gOrigGetTmpAudio(self, _cmd, audioId) : nil;
    if (gInjecting && !gLoggedTmpAudio) {
        gLoggedTmpAudio = YES;
        NSUInteger len = [ret isKindOfClass:[NSData class]] ? [(NSData *)ret length] : 0;
        NSMutableString *head = [NSMutableString string];
        if (len) {
            const unsigned char *b = (const unsigned char *)[(NSData *)ret bytes];
            for (NSUInteger i = 0; i < MIN((NSUInteger)16, len); i++) [head appendFormat:@"%02x", b[i]];
        }
        [InsConfig log:[NSString stringWithFormat:@"语音：GetTmpAudio(id=%u) → %lu 字节 类型=%@ 头=%@",
                        audioId, (unsigned long)len, NSStringFromClass([ret class]),
                        head.length ? head : @"（空）"]];
    }
    return ret;
}

/// 录音一结束（上传之前）立刻替换语音文件：这条是 SILK 注入真正落地的地方
static void InsVoiceOnRecorderEnd(id self, SEL _cmd, id rec) {
    if (gInjecting && gSilkFile.length) InsVoiceOverwriteAud(@"录音结束");
    if (gOrigOnRecorderEnd) gOrigOnRecorderEnd(self, _cmd, rec);
}

static void InsVoiceOnPartSent(id self, SEL _cmd, id part, unsigned int errNo) {
    if (gOrigOnPartSent) gOrigOnPartSent(self, _cmd, part, errNo);
    if (!gInjecting) return;
    gLastPartErr = (NSInteger)errNo;
    [InsConfig log:[NSString stringWithFormat:@"语音：上传分片 err=%u（已喂 %lu 帧 / %lu 字节）",
                    errNo, (unsigned long)gFedFrames, (unsigned long)gFedBytes]];
    if (errNo == 0) {
        // 首片就成功说明上传通道通了；整条消息的落地由微信自己完成
        NSInteger gen = gGeneration;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(0, 0), ^{
            if (gen != gGeneration) return;
            InsVoiceFinishNow(YES, @"");
        });
    } else {
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            InsVoiceFinishNow(NO, [NSString stringWithFormat:@"上传语音分片失败（err=%u）", errNo]);
        });
    }
}

static void InsVoiceOnUploadFail(id self, SEL _cmd, id info) {
    if (gOrigOnUploadFail) gOrigOnUploadFail(self, _cmd, info);
    if (!gInjecting) return;
    [InsConfig log:[NSString stringWithFormat:@"语音：CDN 上传失败 %@", info]];
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        InsVoiceFinishNow(NO, @"语音上传到微信服务器失败（网络或 CDN 问题）");
    });
}

static void InsVoiceFinishNow(BOOL ok, NSString *note) {
    void (^cb)(BOOL, NSString *) = nil;
    @synchronized ([InsVoice class]) {
        if (gFinished) return;
        gFinished = YES;
        gInjecting = NO;
        cb = gFinishBlock;
        gFinishBlock = nil;
    }
    InsVoiceKeepScreenOn(NO);   // 发完/失败就恢复自动息屏，别一直亮着耗电
    NSUInteger used = (NSUInteger)MIN(gCursor, (double)gSrcSamples);
    NSMutableString *recNote = [NSMutableString string];
    @try {
        if (gRecorder) {
            if ([gRecorder respondsToSelector:@selector(audioDuration)]) {
                unsigned int d = ((unsigned int (*)(id, SEL))objc_msgSend)(gRecorder, @selector(audioDuration));
                [recNote appendFormat:@" 微信侧时长=%ums", d];
            }
            if ([gRecorder respondsToSelector:@selector(sampleRate)]) {
                long long r = ((long long (*)(id, SEL))objc_msgSend)(gRecorder, @selector(sampleRate));
                [recNote appendFormat:@" 录音器采样率=%lld", r];
            }
        }
    } @catch (NSException *e) {}
    [InsConfig log:[NSString stringWithFormat:
        @"语音：结束 ok=%d 帧=%lu 字节=%lu 格式=%@ 采样率=%lu(%@) 注入=%lu/%lu 采样(%.2f秒) 误差=%ld 通道(sender=%lu/recorder=%lu/silk=%lu/mjsilk=%lu/opus=%lu/file=%lu) 说明=%@",
        ok, (unsigned long)gFedFrames, (unsigned long)gFedBytes,
        (gInFmt == InsPcmFmtFloat32) ? @"float32" : (gInFmt == InsPcmFmtInt16 ? @"int16" : @"未判"),
        (unsigned long)gTargetRate, gRateFrom ?: @"默认", (unsigned long)used,
        (unsigned long)gSrcSamples, (double)used / 24000.0, (long)gLastPartErr,
        (unsigned long)gPcmHookCalls, (unsigned long)gRecPcmCalls,
        (unsigned long)gSilkCalls, (unsigned long)gMJSilkCalls,
        (unsigned long)gOpusCalls, (unsigned long)gAppendCalls, note ?: @"-"]];
    if (gSilentTail) {
        [InsConfig log:[NSString stringWithFormat:@"语音：尾部静音 %lu 帧（放完 TTS 后录音器还在要数据）",
                        (unsigned long)gSilentTail]];
    }
    if (recNote.length) [InsConfig log:[NSString stringWithFormat:@"语音：%@", recNote]];
    // 编码输出与上传分片的对账：语音条「有时长没声音」的时候，这两行是唯一的客观证据
    [InsConfig log:[NSString stringWithFormat:
        @"语音：编码输出 %lu 字节 / %lu 帧（平均 %.1f 字节/帧）｜上传分片 %lu 个 / %lu 字节 duration=%ums",
        (unsigned long)gEncBytes, (unsigned long)gEncFrames,
        gEncFrames ? (double)gEncBytes / (double)gEncFrames : 0.0,
        (unsigned long)gPartCalls, (unsigned long)gPartBytes, gPartDuration]];
    [InsConfig log:[NSString stringWithFormat:@"语音：SILK %@ 字节（%@）｜GetTmpAudio 替换 %lu 次",
                    gSilkFile.length ? [NSString stringWithFormat:@"%lu", (unsigned long)gSilkFile.length] : @"无",
                    gSilkNote ?: @"-", (unsigned long)gTmpServed]];
    if (gEncOut.length) {
        NSString *p = [[InsConfig rootDir] stringByAppendingPathComponent:@"voice_enc.bin"];
        [gEncOut writeToFile:p atomically:YES];
    }
    InsVoiceRecord(ok, note);
    if (cb) cb(ok, note);
}

#pragma mark - TTS：Key 池 + 自动降级

/// 熔断表：Key → 冷却截止时间（timeIntervalSince1970）；命中说明这把 Key 刚失败过
static NSMutableDictionary<NSString *, NSNumber *> *gKeyBadUntil = nil;
/// 上次合成成功的 Key：下次优先用它，避免每次都先撞死那把
static NSString *gKeyLastGood = nil;
/// 进程内累计降级次数（体检里给个直观数）
static NSUInteger gKeyFailoverTotal = 0;
/// 最近一次语音发送的结果：status 里要能一眼看出「上次到底成没成、卡在哪」
static BOOL gLastVoiceOK = NO;
static NSString *gLastVoiceNote = nil;
static NSTimeInterval gLastVoiceAt = 0;

static void InsVoiceRecord(BOOL ok, NSString *note) {
    gLastVoiceOK = ok;
    gLastVoiceNote = [note copy] ?: @"";
    gLastVoiceAt = [[NSDate date] timeIntervalSince1970];
}
static os_unfair_lock gKeyLock = OS_UNFAIR_LOCK_INIT;

static void InsVoiceKeyLocked(void (^body)(void)) {
    os_unfair_lock_lock(&gKeyLock);
    @try { if (body) body(); } @finally { os_unfair_lock_unlock(&gKeyLock); }
}

/// 日志/回执里只露 Key 的头尾，绝不打印整串
static NSString *InsVoiceKeyMask(NSString *k) {
    if (!k.length) return @"（空）";
    if (k.length <= 12) return k;
    return [NSString stringWithFormat:@"%@…%@", [k substringToIndex:6], [k substringFromIndex:k.length - 4]];
}

/// 一个字段可以写多把 Key：逗号/分号/空格/换行都算分隔
static void InsVoiceAppendKeys(NSMutableArray *out, NSString *raw) {
    if (![raw isKindOfClass:[NSString class]] || !raw.length) return;
    NSArray *parts = [raw componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@",，;； \t\r\n"]];
    for (NSString *p in parts) {
        NSString *k = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (k.length < 8) continue;
        if (![out containsObject:k]) [out addObject:k];
    }
}

/// 主 Key + 备用 Key 合起来的 Key 池（保持配置顺序、去重）
static NSArray<NSString *> *InsVoiceKeysRaw(void) {
    InsConfig *cfg = [InsConfig shared];
    NSMutableArray *out = [NSMutableArray array];
    InsVoiceAppendKeys(out, cfg.voiceApiKey);
    InsVoiceAppendKeys(out, cfg.voiceApiKey2);
    return out;
}

static BOOL InsVoiceKeyCooling(NSString *key) {
    __block BOOL cooling = NO;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    InsVoiceKeyLocked(^{
        NSNumber *until = gKeyBadUntil[key];
        if ([until isKindOfClass:[NSNumber class]] && until.doubleValue > now) cooling = YES;
    });
    return cooling;
}

/// 排序：上次成功的排最前 → 没失败过的 → 冷却中的。冷却中的仍然保留，全部不行时还会兜底试一次
static NSArray<NSString *> *InsVoiceKeysOrdered(void) {
    NSArray *raw = InsVoiceKeysRaw();
    if (raw.count < 2) return raw;
    NSMutableArray *arr = [raw mutableCopy];
    NSMutableDictionary *score = [NSMutableDictionary dictionary];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    __block NSString *lastGood = nil;
    __block NSDictionary *bad = nil;
    InsVoiceKeyLocked(^{
        lastGood = gKeyLastGood;
        bad = gKeyBadUntil ? [gKeyBadUntil copy] : @{};
    });
    for (NSUInteger i = 0; i < arr.count; i++) {
        NSString *k = arr[i];
        NSNumber *u = bad[k];
        double until = [u isKindOfClass:[NSNumber class]] ? u.doubleValue : 0;
        double sc = 1000000.0 + (double)i;                            // 基础分：保持配置顺序
        if (until > now) sc -= 500000.0;                              // 冷却中：整体往后排
        if (lastGood && [k isEqualToString:lastGood]) sc -= 2000000.0; // 上次成功：排最前
        score[k] = @(sc);
    }
    [arr sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        double sa = [score[a] doubleValue], sb = [score[b] doubleValue];
        if (sa < sb) return NSOrderedAscending;
        if (sa > sb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return arr;
}

static void InsVoiceKeyMarkGood(NSString *key) {
    if (!key.length) return;
    InsVoiceKeyLocked(^{
        if (!gKeyBadUntil) gKeyBadUntil = [NSMutableDictionary dictionary];
        [gKeyBadUntil removeObjectForKey:key];
        gKeyLastGood = [key copy];
    });
}

static void InsVoiceKeyPenalize(NSString *key, NSTimeInterval secs) {
    if (!key.length) return;
    NSTimeInterval until = [[NSDate date] timeIntervalSince1970] + MAX(secs, 30);
    InsVoiceKeyLocked(^{
        if (!gKeyBadUntil) gKeyBadUntil = [NSMutableDictionary dictionary];
        gKeyBadUntil[key] = @(until);
    });
}

static BOOL InsVoiceBodyIsJSONError(NSData *body) {
    return body.length > 1 && ((const char *)body.bytes)[0] == '{';
}

static NSString *InsVoiceBriefBody(NSData *body) {
    NSString *s = body.length ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : @"";
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    if (s.length > 160) s = [[s substringToIndex:160] stringByAppendingString:@"…"];
    return s.length ? s : @"服务端返回了错误";
}

static NSData *InsVoiceHTTP(NSMutableURLRequest *req, NSInteger *status, NSError **error) {
    __block NSData *body = nil;
    __block NSError *err = nil;
    __block NSInteger code = 0;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        body = d;
        err = e;
        code = [(NSHTTPURLResponse *)r statusCode];
        dispatch_semaphore_signal(sem);
    }] resume];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(40 * NSEC_PER_SEC)))) {
        if (error) *error = [NSError errorWithDomain:@"InsVoice" code:-2
                                            userInfo:@{NSLocalizedDescriptionKey: @"合成超时（40 秒没响应）"}];
        return nil;
    }
    if (status) *status = code;
    if (error && err) *error = err;
    return body;
}

static NSString *InsVoiceFailure(NSInteger status, NSData *body) {
    NSString *raw = body.length ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : @"";
    if (raw.length > 300) raw = [[raw substringToIndex:300] stringByAppendingString:@"…"];
    switch (status) {
        case 401: return @"Key 无效（401）。核对 Breeze 的 API Key，发「语音key <Key>」重设";
        case 402: return @"额度不足（402）。去 Breeze 控制台充值或换 Key";
        case 403: return [NSString stringWithFormat:@"没权限（403）：%@", raw];
        case 404: return @"音色或接口不存在（404）。发「语音 声 list」重新挑一个音色";
        case 422: return [NSString stringWithFormat:@"文本被拒（422）：%@", raw];
        case 429: return @"被限流了（429）";
        case 503: case 504: return @"Breeze 服务端暂时不可用，稍后再试";
        default: break;
    }
    return [NSString stringWithFormat:@"HTTP %ld：%@", (long)status, raw.length ? raw : @"空响应"];
}

/// 单把 Key 发一次请求（不含任何降级逻辑）
static NSData *InsVoiceCallOnce(NSString *urlStr, NSString *method, NSData *jsonBody,
                                NSString *accept, NSString *key,
                                NSInteger *outStatus, NSError **outErr) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = method ?: @"GET";
    req.timeoutInterval = 45;
    [req setValue:key forHTTPHeaderField:@"xi-api-key"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (accept.length) [req setValue:accept forHTTPHeaderField:@"Accept"];
    if (jsonBody.length) req.HTTPBody = jsonBody;
    return InsVoiceHTTP(req, outStatus, outErr);
}

/// 这次失败值不值得换下一把 Key 再试
static BOOL InsVoiceWorthNextKey(NSInteger status, BOOL hasBody, BOOL bodyIsJSONError) {
    if (!hasBody) return YES;                 // 网络层失败：换一把再试不亏
    if (bodyIsJSONError) return YES;          // 200 却回错误 JSON：多半是 Key/额度问题
    return status == 401 || status == 402 || status == 403 || status == 429;
}

/// 依次用 Key 池里的 Key 发同一个请求；全失败返回 nil 并给出汇总原因
/// expectBinary=YES（合成 PCM）：200 但回 JSON 视为错误；NO（音色列表等 JSON 接口）：JSON 是正常响应
static NSData *InsVoiceSend(NSString *urlStr, NSString *method, NSData *jsonBody, NSString *accept,
                            BOOL expectBinary,
                            NSInteger *outStatus, NSError **outErr,
                            NSString **failDetail, NSString **usedKey, BOOL *didFailover) {
    NSArray<NSString *> *keys = InsVoiceKeysOrdered();
    if (!keys.count) {
        if (failDetail) *failDetail = @"还没配语音 Key，发「语音key <Key>」";
        return nil;
    }
    NSMutableArray *fails = [NSMutableArray array];
    NSString *detail = @"语音合成失败";
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSString *key = keys[i];
        NSError *err = nil;
        NSInteger st = 0;
        NSData *body = InsVoiceCallOnce(urlStr, method, jsonBody, accept, key, &st, &err);
        BOOL jsonErr = expectBinary && InsVoiceBodyIsJSONError(body);
        if (body.length && st >= 200 && st < 300 && !jsonErr) {
            BOOL moved = (i > 0);
            InsVoiceKeyMarkGood(key);
            if (usedKey) *usedKey = key;
            if (didFailover) *didFailover = moved;
            if (moved) {
                [InsConfig log:[NSString stringWithFormat:@"语音：已降级到第 %lu 把 Key（%@）",
                                (unsigned long)(i + 1), InsVoiceKeyMask(key)]];
            }
            return body;
        }
        NSString *why = body.length
            ? (jsonErr ? InsVoiceBriefBody(body) : InsVoiceFailure(st, body))
            : (err.localizedDescription ?: @"没有响应（网络或超时）");
        [fails addObject:[NSString stringWithFormat:@"%@：%@", InsVoiceKeyMask(key), why]];
        BOOL worth = InsVoiceWorthNextKey(st, body.length > 0, jsonErr);
        if (worth && i + 1 < keys.count) {
            InsVoiceKeyPenalize(key, st == 429 ? 120 : (body.length ? 1800 : 60));
            gKeyFailoverTotal++;
            [InsConfig log:[NSString stringWithFormat:@"语音：Key %@ 失败（%@），换下一把",
                            InsVoiceKeyMask(key), why]];
            continue;
        }
        detail = fails.count > 1
            ? [NSString stringWithFormat:@"所有语音 Key 都不可用：%@", [fails componentsJoinedByString:@" / "]]
            : why;
        if (outStatus) *outStatus = st;
        if (outErr) *outErr = err;
        break;
    }
    if (failDetail) *failDetail = detail;
    return nil;
}

/// 合成 PCM；instructions 非空时优先用它（唱歌腔等特殊演绎），否则用全局语气。
/// withCfg = 指令跟随加 guidance（开源仓库建议 cfg_scale=4；托管接口不认识这个
/// 参数时会 400/422，此时自动去掉重发一次）。失败返回 nil 并填 errorMsg。
/// 内部按 Key 池自动降级，全部失败才报错
static NSData *InsVoiceSynthesizeWith(NSString *text, NSString *instructions,
                                      BOOL withCfg, NSString **errorMsg) {
    InsConfig *cfg = [InsConfig shared];
    if (!InsVoiceKeysRaw().count) {
        if (errorMsg) *errorMsg = @"还没配语音 Key，发「语音key <Key>」";
        return nil;
    }
    NSString *base = cfg.voiceBaseURL.length ? cfg.voiceBaseURL : kInsVoiceFallbackBase;
    NSString *voice = cfg.voiceId.length ? cfg.voiceId : kInsVoiceFallbackVoice;
    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/text-to-speech/%@?output_format=pcm_24000",
                        base, voice];

    NSString *useInstr = instructions.length ? instructions : cfg.voiceInstructions;
    NSString *fail = nil, *used = nil;
    BOOL failover = NO;
    NSInteger st = 0;
    NSError *err = nil;
    NSData *pcm = nil;

    for (NSInteger attempt = 0; attempt < 2; attempt++) {
        NSMutableDictionary *payload = [NSMutableDictionary dictionary];
        payload[@"text"] = text;
        payload[@"model_id"] = cfg.voiceModel.length ? cfg.voiceModel : kInsVoiceFallbackModel;
        payload[@"language_code"] = @"zh";
        if (useInstr.length) payload[@"instructions"] = useInstr;
        BOOL tryCfg = withCfg && attempt == 0;
        if (tryCfg) payload[@"cfg_scale"] = @4;
        NSData *json = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        pcm = InsVoiceSend(urlStr, @"POST", json, @"audio/pcm", YES,
                           &st, &err, &fail, &used, &failover);
        if (pcm.length) {
            if (tryCfg) [InsConfig log:@"语音：本次合成带 cfg_scale=4（演唱指令跟随加强）"];
            break;
        }
        // 接口不认识 cfg_scale（400/422）→ 去掉重发一次；其他错误照旧走 Key 降级
        if (!tryCfg || (st != 400 && st != 415 && st != 422)) break;
        [InsConfig log:[NSString stringWithFormat:@"语音：接口拒绝 cfg_scale（%ld），去掉重发", (long)st]];
        fail = nil; st = 0; err = nil;
    }
    if (!pcm.length) {
        if (errorMsg) *errorMsg = fail ?: @"合成失败";
        return nil;
    }
    if (failover && used.length) {
        [InsConfig log:[NSString stringWithFormat:@"语音：本次用备用 Key %@ 合成", InsVoiceKeyMask(used)]];
    }
    return pcm;
}

static NSData *InsVoiceSynthesize(NSString *text, NSString **errorMsg) {
    return InsVoiceSynthesizeWith(text, nil, NO, errorMsg);
}

/// 只用指定 Key 探一下（音色列表接口，很轻），体检/「语音key 测」用
static BOOL InsVoiceProbeKey(NSString *key, NSString **note, double *costMs) {
    InsConfig *cfg = [InsConfig shared];
    NSString *base = cfg.voiceBaseURL.length ? cfg.voiceBaseURL : kInsVoiceFallbackBase;
    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/voices?page_size=1", base];
    NSDate *t0 = [NSDate date];
    NSInteger st = 0;
    NSError *err = nil;
    NSData *body = InsVoiceCallOnce(urlStr, @"GET", nil, @"application/json", key, &st, &err);
    if (costMs) *costMs = -[t0 timeIntervalSinceNow] * 1000.0;
    // /v1/voices 正常响应本来就是 JSON，这里只看状态码 + 有没有 voices 字段
    BOOL ok = body.length && st == 200;
    if (ok) {
        id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
        if ([json isKindOfClass:[NSDictionary class]] && ![json[@"voices"] isKindOfClass:[NSArray class]]) {
            ok = (json[@"error"] == nil);
        }
    }
    if (ok) {
        InsVoiceKeyMarkGood(key);
        if (note) *note = @"可用";
        return YES;
    }
    if (!body.length) {
        if (note) *note = err.localizedDescription ?: @"没有响应";
        return NO;
    }
    if (note) *note = InsVoiceBriefBody(body);
    if (InsVoiceWorthNextKey(st, YES, NO)) {
        InsVoiceKeyPenalize(key, st == 429 ? 120 : 1800);
    }
    return NO;
}

/// 体检/命令用：Key 池概览（每把 Key 脱敏 + 冷却状态）
static NSString *InsVoiceKeysReport(BOOL probe) {
    NSArray<NSString *> *keys = InsVoiceKeysRaw();
    if (!keys.count) return @"还没配语音 Key。发「语音key <Key>」写主 Key，「语音key2 <Key>」写备用 Key";
    __block NSString *lastGood = nil;
    InsVoiceKeyLocked(^{ lastGood = gKeyLastGood; });
    NSMutableString *out = [NSMutableString stringWithFormat:@"语音 Key 池：%lu 把\n", (unsigned long)keys.count];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSString *k = keys[i];
        NSString *role = (i == 0) ? @"主" : (i == 1 ? @"备用" : @"再备用");
        if (lastGood && [k isEqualToString:lastGood]) role = [role stringByAppendingString:@"·在用"];
        if (InsVoiceKeyCooling(k)) role = [role stringByAppendingString:@"·冷却中"];
        if (!probe) {
            [out appendFormat:@"%lu) %@  %@（%lu 位）\n", (unsigned long)(i + 1),
             role, InsVoiceKeyMask(k), (unsigned long)k.length];
            continue;
        }
        NSString *note = nil;
        double ms = 0;
        BOOL ok = InsVoiceProbeKey(k, &note, &ms);
        [out appendFormat:@"%lu) %@  %@  %@（%.0f ms）\n", (unsigned long)(i + 1),
         role, InsVoiceKeyMask(k), ok ? @"✅ 可用" : note ?: @"不可用", ms];
    }
    if (keys.count == 1) {
        [out appendString:@"备用：没配（语音key2 <Key>）—— 主 Key 一挂就没得换\n"];
    }
    [out appendFormat:@"降级策略：401/402/403/429 或网络失败 → 自动换下一把；本次运行已降级 %lu 次\n",
     (unsigned long)gKeyFailoverTotal];
    [out appendString:@"换/加 Key：语音key <Key>（主）｜语音key2 <Key>（备用）｜语音key 列表｜语音key 测"];
    return out;
}

static NSData *InsVoiceWAV(NSData *pcm, NSUInteger rate) {
    NSMutableData *out = [NSMutableData data];
    uint32_t dataLen = (uint32_t)pcm.length;
    uint32_t riffLen = dataLen + 36;
    uint16_t fmt = 1, ch = 1, bits = 16, blockAlign = 2;
    uint32_t byteRate = (uint32_t)(rate * blockAlign);
    [out appendBytes:"RIFF" length:4];
    [out appendBytes:&riffLen length:4];
    [out appendBytes:"WAVEfmt " length:8];
    uint32_t fmtLen = 16;
    [out appendBytes:&fmtLen length:4];
    [out appendBytes:&fmt length:2];
    [out appendBytes:&ch length:2];
    uint32_t r = (uint32_t)rate;
    [out appendBytes:&r length:4];
    [out appendBytes:&byteRate length:4];
    [out appendBytes:&blockAlign length:2];
    [out appendBytes:&bits length:2];
    [out appendBytes:"data" length:4];
    [out appendBytes:&dataLen length:4];
    [out appendData:pcm];
    return out;
}

static AVAudioPlayer *gPreviewPlayer = nil;

static BOOL InsVoicePlayPCM(NSData *pcm, NSUInteger rate) {
    NSData *wav = InsVoiceWAV(pcm, rate);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ins_voice_preview.wav"];
    [wav writeToFile:path atomically:YES];
    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback withOptions:AVAudioSessionCategoryOptionMixWithOthers
                   error:nil];
    [session setActive:YES error:nil];
    gPreviewPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path] error:&err];
    if (!gPreviewPlayer) {
        [InsConfig log:[NSString stringWithFormat:@"语音：试听失败 %@", err.localizedDescription]];
        return NO;
    }
    [gPreviewPlayer play];
    return YES;
}

/// 按配置的秒数换算成中文可念的字数（普通话约 4.2 字/秒）
static NSString *InsVoiceClip(NSString *text, NSUInteger *trimmed, NSUInteger *maxChars) {
    InsConfig *cfg = [InsConfig shared];
    NSInteger secs = cfg.voiceMaxSeconds > 0 ? MIN(cfg.voiceMaxSeconds, 60) : 45;
    NSUInteger maxC = (NSUInteger)(secs * 4.2);
    if (maxC < 40) maxC = 40;
    if (maxChars) *maxChars = maxC;
    if (text.length <= maxC) {
        if (trimmed) *trimmed = 0;
        return text;
    }
    NSString *cut = [text substringToIndex:maxC];
    if (trimmed) *trimmed = text.length - maxC;
    return cut;
}

@implementation InsVoice

#pragma mark - 发语音条

typedef void (^InsVoiceReplyBlock)(NSString *text);

+ (void)speak:(NSString *)text
       talker:(NSString *)talker
        reply:(InsVoiceReplyBlock)reply {
    [self insSpeak:text instructions:nil talker:talker reply:reply];
}

/// 唱歌腔合成并发语音条：歌词照唱，演绎指令换成「演唱」而不是「说话」
+ (void)singLyrics:(NSString *)lyrics
            talker:(NSString *)talker
            reply:(InsVoiceReplyBlock)reply {
    [self singLyrics:lyrics instructions:nil talker:talker reply:reply];
}

+ (void)singLyrics:(NSString *)lyrics
        instructions:(NSString *)style
              talker:(NSString *)talker
              reply:(InsVoiceReplyBlock)reply {
    InsConfig *cfg = [InsConfig shared];
    // 强制演唱子句永远在前面：不管唱法描述写得多花哨，先把「不许说话腔」钉死
    NSString *sing = @"这是一段歌词，请用歌声演唱，绝对不要用说话的腔调，每个字都要有音高起伏。";
    NSString *instr;
    if (style.length) {
        instr = [NSString stringWithFormat:@"%@这首歌的唱法：%@", sing, style];
    } else if (cfg.singInstructions.length) {
        instr = cfg.singInstructions;
    } else {
        instr = kInsDefaultSingInstructions;
    }
    [self insSpeak:lyrics instructions:instr talker:talker reply:reply];
}

#pragma mark - 点歌翻唱（Mac 服务）

/// 简单 HTTP 请求（无鉴权），返回 body；失败填 err
static NSData *InsCoverHTTP(NSString *urlStr, NSString *method, NSData *body,
                            NSTimeInterval timeout, NSString **err) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    req.HTTPMethod = method;
    req.timeoutInterval = timeout;
    if (body) {
        req.HTTPBody = body;
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    __block NSData *out = nil;
    __block NSError *e = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *error) {
            out = d;
            e = error;
            dispatch_semaphore_signal(sem);
        }];
    [task resume];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                                   (int64_t)(timeout * NSEC_PER_SEC))) != 0) {
        if (err) *err = @"请求超时";
        return nil;
    }
    if (e) {
        if (err) *err = e.localizedDescription ?: @"网络错误";
        return nil;
    }
    return out;
}

/// 解析 24k mono s16 wav → 裸 PCM；不认识就返回 nil
static NSData *InsCoverPcmFromWav(NSData *wav) {
    const uint8_t *b = wav.bytes;
    NSUInteger n = wav.length;
    if (n < 44 || !(b[0] == 'R' && b[1] == 'I' && b[2] == 'F' && b[3] == 'F')) return nil;
    NSUInteger pos = 12;   // 跳过 RIFF....WAVE
    while (pos + 8 <= n) {
        char cid[5] = {b[pos], b[pos + 1], b[pos + 2], b[pos + 3], 0};
        uint32_t sz = (uint32_t)b[pos + 4] | ((uint32_t)b[pos + 5] << 8) |
                      ((uint32_t)b[pos + 6] << 16) | ((uint32_t)b[pos + 7] << 24);
        if (memcmp(cid, "data", 4) == 0 && pos + 8 + sz <= n) {
            return [wav subdataWithRange:NSMakeRange(pos + 8, sz)];
        }
        pos += 8 + sz + (sz & 1);
    }
    return nil;
}

/// 点歌翻唱：Mac 服务找歌→分离→换音色→合成，全程可能要几分钟，轮询拿成品发语音条
+ (void)singCoverWithSong:(NSString *)song
                      url:(NSString *)baseURL
                   talker:(NSString *)talker
                     full:(BOOL)full
                    reply:(InsVoiceReplyBlock)reply {
    NSString *root = [baseURL stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([root hasSuffix:@"/"]) root = [root substringToIndex:root.length - 1];
    NSString *err = nil;

    // 翻唱要等 6~8 分钟，这期间一旦息屏 → 微信被切后台、音频会话失活 →
    // 成品回来时录音器不吐 PCM（实测花海那次 gFedFrames=0、hook 全无回调）。
    // 从下单这一刻就保持常亮，覆盖整个等待窗口；发完/失败在 InsVoiceFinishNow 里恢复。
    // 埋点：这一行能区分「进程是在进入翻唱前就没了」还是「死在保亮/下单/轮询里」。
    [InsConfig log:[NSString stringWithFormat:@"翻唱：进入 singCover「%@」线程=%@",
                     song ?: @"", [NSThread isMainThread] ? @"主" : @"后台"]];
    InsVoiceKeepScreenOn(YES);
    [InsConfig log:@"翻唱：保亮请求已提交，准备下单"];

    // 1) 下单（完整版带 full=1，Mac 端不做 28 秒高潮截断）。
    //    云端 relay 可能是旧版、不认 full 字段，所以在歌名前再编码一个【完整版】前缀，
    //    Mac worker 会剥掉前缀还原歌名并置 full —— 这样无需重新部署云端也能生效。
    NSString *songToSend = full ? [@"【完整版】" stringByAppendingString:(song ?: @"")]
                                : (song ?: @"");
    [InsConfig log:[NSString stringWithFormat:@"翻唱：下单参数 song=%@ full=%@",
                     songToSend, full ? @"1" : @"0"]];
    NSData *post = [NSJSONSerialization dataWithJSONObject:
                    @{@"song": songToSend, @"full": @(full ? 1 : 0)}
                                                  options:0 error:nil];
    NSData *resp = InsCoverHTTP([NSString stringWithFormat:@"%@/cover", root], @"POST", post, 15, &err);
    NSNumber *jid = nil;
    if (resp.length) {
        id j = [NSJSONSerialization JSONObjectWithData:resp options:0 error:nil];
        if ([j isKindOfClass:[NSDictionary class]]) jid = j[@"id"];
    }
    if (!jid) {
        if (reply) reply([NSString stringWithFormat:@"翻唱没排上：服务没响应或返回不认识（%@）", err ?: @"-"]);
        return;
    }
    [InsConfig log:[NSString stringWithFormat:@"翻唱：已下单 id=%@ 歌曲「%@」", jid, song]];

    // 2) 轮询到完成：片段版 15 分钟；完整版 seed-vc 要处理几分钟音频，放宽到 25 分钟
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:full ? 1500 : 900];
    NSString *lastNote = @"";
    while ([deadline timeIntervalSinceNow] > 0) {
        [NSThread sleepForTimeInterval:5];
        NSData *st = InsCoverHTTP([NSString stringWithFormat:@"%@/status?id=%@",
                                   root, jid], @"GET", nil, 10, &err);
        if (!st.length) continue;
        id sj = [NSJSONSerialization JSONObjectWithData:st options:0 error:nil];
        if (![sj isKindOfClass:[NSDictionary class]]) continue;
        NSString *state = sj[@"state"] ?: @"";
        NSString *note = sj[@"note"] ?: @"";
        if ([state isEqualToString:@"done"]) {
            NSData *wav = InsCoverHTTP([NSString stringWithFormat:@"%@/audio?id=%@", root, jid],
                                       @"GET", nil, 60, &err);
            NSData *pcm = wav.length ? InsCoverPcmFromWav(wav) : nil;
            if (!pcm.length) {
                if (reply) reply([NSString stringWithFormat:@"翻唱成品拿不回来（%@）", err ?: @"wav 解析失败"]);
                return;
            }
            [InsConfig log:[NSString stringWithFormat:@"翻唱：拿到成品 %.1f 秒，开始发语音（full=%@）",
                            (double)pcm.length / 48000.0, full ? @"1" : @"0"]];
            if (full) {
                [self sendPCMFull:pcm talker:talker reply:reply];
            } else {
                [self sendPCMData:pcm talker:talker reply:reply];
            }
            return;
        }
        if ([state isEqualToString:@"error"]) {
            [InsConfig log:[NSString stringWithFormat:@"翻唱：服务报错 %@", note]];
            if (reply) reply([NSString stringWithFormat:@"翻唱失败：%@", note ?: @"未知"]);
            return;
        }
        if (note.length && ![note isEqualToString:lastNote]) {
            lastNote = note;
            [InsConfig log:[NSString stringWithFormat:@"翻唱：%@", note]];
        }
    }
    if (reply) reply(@"翻唱超时了（服务 15 分钟没出结果），稍后再试");
}

+ (void)insSpeak:(NSString *)text
     instructions:(NSString *)instructions
           talker:(NSString *)talker
            reply:(InsVoiceReplyBlock)reply {
    InsConfig *cfg = [InsConfig shared];
    NSString *clean = InsVoiceClean(text);
    if (!clean.length) {
        if (reply) reply(@"没有要念的内容。用法：@insomnia 语音 今天早点睡");
        return;
    }
    NSUInteger trimmed = 0, maxC = 0;
    NSString *spoken = InsVoiceClip(clean, &trimmed, &maxC);
    // 到底念了什么，日志里得看得见 —— 不然「念错内容」只能靠人去听
    [InsConfig log:[NSString stringWithFormat:@"语音：要念 %lu 字「%@%@」",
                    (unsigned long)spoken.length,
                    spoken.length > 40 ? [spoken substringToIndex:40] : spoken,
                    spoken.length > 40 ? @"…" : @""]];

    NSString *why = nil;
    NSString *from = InsSelfWxidShared();
    if (!InsVoiceCanSend(from, talker, &why)) {
        [InsConfig log:[NSString stringWithFormat:@"语音：前置检查没过 %@", why]];
        InsVoiceRecord(NO, why);
        if (reply) reply([NSString stringWithFormat:@"语音没发出去：%@\n下一步：%@ 语音体检 看录音通道为什么不通",
                          why, cfg.trigger]);
        return;
    }

    NSString *ttsErr = nil;
    NSDate *t0 = [NSDate date];
    NSData *pcm = InsVoiceSynthesizeWith(spoken, instructions, instructions.length, &ttsErr);
    if (!pcm.length) {
        [InsConfig log:[NSString stringWithFormat:@"语音：合成失败 %@", ttsErr]];
        InsVoiceRecord(NO, ttsErr ?: @"合成失败");
        if (reply) reply([NSString stringWithFormat:
            @"语音没发出去：%@\n下一步：%@ 语音key 测 逐把验 Key，%@ 语音体检 看合成与录音 hook",
            ttsErr ?: @"合成失败", cfg.trigger, cfg.trigger]);
        return;
    }
    double cost = -[t0 timeIntervalSinceNow];
    // 尾音被吃掉：TTS 的 PCM 末尾几乎紧贴最后一个字，注入一到底微信就停录，
    // SILK 编码器最后一帧也常来不及把这个字吐出来，听起来就是「最后一个字没说完」。
    // 统一在末尾补 0.4 秒静音，编码 / 注入 / 试听 / 证据文件都用这一份 —— 宁多 0.4 秒尾音，不丢字。
    double rawSecs = (double)pcm.length / 48000.0;
    {
        NSUInteger pad = (NSUInteger)(0.4 * 24000.0) * 2;   // 24k int16 → 19200 字节
        NSMutableData *padded = [pcm mutableCopy];
        [padded appendData:[NSMutableData dataWithLength:pad]];
        pcm = padded;
        [InsConfig log:[NSString stringWithFormat:@"语音：末尾补 %.2f 秒静音（%.1f → %.1f 秒）",
                        (double)pad / 48000.0, rawSecs, (double)pcm.length / 48000.0]];
    }
    double secs = (double)pcm.length / 48000.0;
    // 合成结果自检：这一段最关键。之前「发出去了但一点声音都没有」，
    // 到底是 TTS 给了静音、还是我们写进去的不是 PCM、还是编码器没吃，日志里分不出来。
    // 峰值≈0 就说明拿到的是静音（Key 没权限/额度、或返回了非裸 PCM），此时宁可报错也不发哑语音。
    {
        const int16_t *s = (const int16_t *)pcm.bytes;
        NSUInteger n = pcm.length / 2;
        int peak = 0;
        double sum = 0;
        for (NSUInteger i = 0; i < n; i++) {
            int v = s[i] < 0 ? -s[i] : s[i];
            if (v > peak) peak = v;
            sum += (double)s[i] * s[i];
        }
        double rms = n ? sqrt(sum / (double)n) : 0;
        const uint8_t *hb = (const uint8_t *)pcm.bytes;
        unsigned h0 = pcm.length > 0 ? hb[0] : 0, h1 = pcm.length > 1 ? hb[1] : 0;
        unsigned h2 = pcm.length > 2 ? hb[2] : 0, h3 = pcm.length > 3 ? hb[3] : 0;
        BOOL looksContainer = (h0 == 'R' && h1 == 'I' && h2 == 'F' && h3 == 'F') ||
                              (h0 == 'I' && h1 == 'D' && h2 == '3') ||
                              (h0 == 'O' && h1 == 'g' && h2 == 'g');
        [InsConfig log:[NSString stringWithFormat:
            @"语音：合成 %lu 字节 / %.1f 秒 / 耗时 %.1f 秒（音色 %@）波形 峰值=%d RMS=%.0f 头=%02x%02x%02x%02x%@",
            (unsigned long)pcm.length, secs, cost, cfg.voiceId, peak, rms, h0, h1, h2, h3,
            looksContainer ? @" ← 看起来是 WAV/MP3 容器，不是裸 PCM" : @""]];
        if (peak < 32) {
            NSString *why = [NSString stringWithFormat:
                @"TTS 返回的是静音（峰值 %d / RMS %.0f，%lu 字节）",
                peak, rms, (unsigned long)pcm.length];
            InsVoiceRecord(NO, why);
            if (reply) reply([NSString stringWithFormat:
                @"语音没发出去：%@\n"
                @"多半是语音 Key 没权限或额度没了，也可能是接口返回了非 PCM 数据。\n"
                @"下一步：%@ 语音key 测 逐把验；%@ 语音体检 看合成与波形",
                why, cfg.trigger, cfg.trigger]);
            return;
        }
    }

    // 顺手留一份 wav 证据：合成是不是静音，用文件传输助手把 voice_last.wav 拉出来一听就知道
    InsVoiceDumpWav(pcm, 24000);

    [self insInjectPCM:pcm label:spoken trimmed:trimmed talker:talker reply:reply];
}

/// 把备好的 24k 单声道 int16 裸 PCM 直接走注入管线发成语音条（翻唱音频等本地来源）
+ (void)sendPCMData:(NSData *)pcm0 talker:(NSString *)talker reply:(InsVoiceReplyBlock)reply {
    NSString *from = InsSelfWxidShared();
    NSString *why = nil;
    if (!pcm0.length) {
        if (reply) reply(@"语音没发出去：音频是空的");
        return;
    }
    if (!InsVoiceCanSend(from, talker, &why)) {
        [InsConfig log:[NSString stringWithFormat:@"翻唱：前置检查没过 %@", why]];
        if (reply) reply([NSString stringWithFormat:@"语音没发出去：%@", why]);
        return;
    }
    // 微信语音条：实测 56.4 秒在「录完收尾上传」阶段会把微信撑到卡死（43.9 秒 TTS 一直正常）。
    // 无论音频来自翻唱服务还是别处，这里都做硬截断 —— 语音条宁可少唱一句，也不能把微信打死。
    const double kInsVoiceMaxSecs = 42.0;
    const double kInsVoiceRate = 24000.0;
    NSUInteger maxBytes = (NSUInteger)(kInsVoiceMaxSecs * kInsVoiceRate) * 2;
    if (pcm0.length > maxBytes) {
        [InsConfig log:[NSString stringWithFormat:
            @"语音：音频 %.1f 秒超过 %.0f 秒上限，已截断（防止微信收尾崩溃）",
            (double)pcm0.length / kInsVoiceRate, kInsVoiceMaxSecs]];
        pcm0 = [pcm0 subdataWithRange:NSMakeRange(0, maxBytes)];
    }
    double rawSecs = (double)pcm0.length / kInsVoiceRate;
    NSUInteger pad = (NSUInteger)(0.4 * kInsVoiceRate) * 2;
    NSMutableData *padded = [pcm0 mutableCopy];
    [padded appendData:[NSMutableData dataWithLength:pad]];
    NSData *pcm = padded;
    InsVoiceDumpWav(pcm, 24000);
    [InsConfig log:[NSString stringWithFormat:@"翻唱：音频 %.1f → %.1f 秒（含尾静音）",
                    rawSecs, (double)pcm.length / kInsVoiceRate]];
    [self insInjectPCM:pcm label:@"一段翻唱歌曲" trimmed:0 talker:talker reply:reply];
}

/// 从云端翻唱服务按 job id 取回已做好的成品，直接发语音给指定人（主人命令「补成品」用）。
/// 成品本来就已经生成好了（比如当时息屏没发出去），这条路径不再重新下单、不用等 6~8 分钟。
+ (void)resendCoverJob:(NSString *)jobid
                   url:(NSString *)baseURL
                talker:(NSString *)talker
                 reply:(InsVoiceReplyBlock)reply {
    NSString *root = [baseURL stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([root hasSuffix:@"/"]) root = [root substringToIndex:root.length - 1];
    if (!jobid.length || !root.length) {
        if (reply) reply(@"补成品失败：任务号或服务地址为空");
        return;
    }
    NSString *err = nil;
    [InsConfig log:[NSString stringWithFormat:@"翻唱：补发成品 job %@ → %@", jobid, talker]];
    NSData *wav = InsCoverHTTP([NSString stringWithFormat:@"%@/audio?id=%@", root, jobid],
                               @"GET", nil, 60, &err);
    NSData *pcm = wav.length ? InsCoverPcmFromWav(wav) : nil;
    if (!pcm.length) {
        if (reply) reply([NSString stringWithFormat:@"补成品失败：拿不回成品（%@）", err ?: @"wav 解析失败"]);
        return;
    }
    [InsConfig log:[NSString stringWithFormat:@"翻唱：补发成品 %.1f 秒，开始发语音",
                    (double)pcm.length / 48000.0]];
    [self sendPCMData:pcm talker:talker reply:reply];
}

/// 注入管线公共段：备好 PCM 后打开会话、编码 SILK、触发录音注入
/// 完整版成品可能几分钟长，微信单条语音超过约 42 秒会在收尾上传时把微信撑崩。
/// 这里把长 PCM 切成多条 <=32 秒，串行注入：前一条的完成回调里再发下一条，
/// 中间留 1.5 秒让微信把上一条语音文件落定。录音器/编码器是全局单例，必须串行。
+ (void)sendPCMFull:(NSData *)pcm0 talker:(NSString *)talker reply:(InsVoiceReplyBlock)reply {
    const double rate = 24000.0;              // 成品是 24k mono s16
    const double chunkSecs = 32.0;            // 每条安全时长（< 42 秒崩溃线）
    NSUInteger chunkBytes = (NSUInteger)(chunkSecs * rate) * 2;
    NSMutableArray<NSData *> *chunks = [NSMutableArray array];
    NSUInteger off = 0;
    while (off < pcm0.length) {
        NSUInteger n = MIN(chunkBytes, pcm0.length - off);
        [chunks addObject:[pcm0 subdataWithRange:NSMakeRange(off, n)]];
        off += n;
    }
    if (!chunks.count) {
        if (reply) reply(@"语音没发出去：完整版成品是空的");
        return;
    }
    [InsConfig log:[NSString stringWithFormat:
        @"翻唱：完整版切成 %lu 条发送（每条 %.0f 秒，总 %.1f 秒）",
        (unsigned long)chunks.count, chunkSecs, (double)pcm0.length / (rate * 2)]];

    // 用信号量把异步的 sendPCMData 串成同步循环：发一条 -> 等它的 reply -> 再发下一条。
    // 不用递归 block，避免 block 自持有的 retain cycle（ARC 下会当 error）。
    __block NSUInteger okCount = 0;
    for (NSUInteger i = 0; i < chunks.count; i++) {
        NSData *piece = [chunks objectAtIndex:i];
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [self sendPCMData:piece talker:talker reply:^(NSString *text) {
            BOOL ok = [text hasPrefix:@"已发语音"];
            if (ok) okCount += 1;
            [InsConfig log:[NSString stringWithFormat:@"翻唱：完整版第 %lu/%lu 条：%@",
                            (unsigned long)(i + 1), (unsigned long)chunks.count, text]];
            dispatch_semaphore_signal(sem);
        }];
        // 等本条收尾（sendPCMData -> insInjectPCM 的完成回调会触发 reply）。
        // 上限 90 秒，和注入队列的等待上限一致，避免万一没回调就永久卡住。
        if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW,
                                    (int64_t)(90 * NSEC_PER_SEC))) != 0) {
            [InsConfig log:[NSString stringWithFormat:
                @"翻唱：完整版第 %lu 条等待收尾超时，停止后续", (unsigned long)(i + 1)]];
            break;
        }
        // 下一条前留 1.5 秒，让微信把上一条语音文件落定
        [NSThread sleepForTimeInterval:1.5];
    }
    [InsConfig log:[NSString stringWithFormat:@"翻唱：完整版发送结束，成功 %lu/%lu 条",
                    (unsigned long)okCount, (unsigned long)chunks.count]];
    if (reply) reply([NSString stringWithFormat:@"已发完整版语音（%lu/%lu 条成功）",
                      (unsigned long)okCount, (unsigned long)chunks.count]);
}

+ (void)insInjectPCM:(NSData *)pcm
               label:(NSString *)spoken
             trimmed:(NSUInteger)trimmed
              talker:(NSString *)talker
               reply:(InsVoiceReplyBlock)reply {
    InsConfig *cfg = [InsConfig shared];
    NSString *from = InsSelfWxidShared();
    double secs = (double)pcm.length / 48000.0;

    // 录音器、编码器、语音文件都是全局单例。翻唱现在跑在自己的队列上，
    // 和普通语音命令可以并行，两条语音同时注入会互相踩（前一条只剩残片）。
    // 这里排队等前一条收尾，最多等 90 秒。
    NSTimeInterval waitFrom = [NSDate timeIntervalSinceReferenceDate];
    if (gInjecting) {
        [InsConfig log:@"语音：上一条还在注入，这条等它收尾"];
    }
    while (gInjecting) {
        if ([NSDate timeIntervalSinceReferenceDate] - waitFrom > 90.0) {
            [InsConfig log:@"语音：等上一条注入超过 90 秒，放弃这条"];
            if (reply) reply(@"上一条语音还没发完，这条没排上，稍等一下再试");
            return;
        }
        [NSThread sleepForTimeInterval:0.2];
    }

    // 会话没开着：先用内部接口打开，语音必须发在有界面的会话里
    if (![InsSend isChatOpen:talker]) {
        if (![InsSend openChatInProcess:talker]) {
            InsVoiceRecord(NO, @"打不开会话");
            if (reply) reply([NSString stringWithFormat:
                @"语音没发出去：打不开这个会话（语音必须在能打开的单聊里录）\n下一步：%@ 语音体检 或 %@ 代发体检 <对方名字>",
                cfg.trigger, cfg.trigger]);
            return;
        }
    }

    @synchronized ([InsVoice class]) {
        gPCM = pcm;
        gSrcSamples = pcm.length / 2;
        gCursor = 0;
        gOutSamples = 0;
        gFedBytes = 0;
        gFedFrames = 0;
        gPcmHookCalls = 0;
        gRecPcmCalls = 0;
        gSilkCalls = 0;
        gMJSilkCalls = 0;
        gOpusCalls = 0;
        gAppendCalls = 0;
        gAppendBytes = 0;
        gLoggedAppend = NO;
        gAppendUseOpus = NO;
        gTargetRate = 0;
        gRateFrom = nil;
        gStopScheduled = NO;
        gSilentTail = 0;
        gInFmt = InsPcmFmtUnknown;
        gFmtNote = nil;
        gLoggedUserData = NO;
        gLoggedOutWave = NO;
        gEncBytes = 0;
        gEncFrames = 0;
        gEncOut = [NSMutableData data];
        gPartCalls = 0;
        gPartBytes = 0;
        gPartDuration = 0;
        gLoggedPart = NO;
        gLoggedTmpAudio = NO;
        gTmpServed = 0;
        gSilkFile = nil;
        gSilkNote = nil;
        gAudDir = nil;
        gAudSinceID = 0;
        gRecRate = 0;
        gLastPartErr = -1;
        gFinished = NO;
        gInjecting = YES;
        gTargetTalker = talker;
        gStartedAt = [NSDate timeIntervalSinceReferenceDate];
        gGeneration += 1;
        gFinishBlock = [^(BOOL ok, NSString *note) {
            if (ok) {
                NSString *head = [NSString stringWithFormat:@"已发语音（%.1f 秒）：%@", secs, spoken];
                if (trimmed) {
                    head = [head stringByAppendingFormat:@"\n（太长，后面 %lu 字没念）", (unsigned long)trimmed];
                }
                if (reply) reply(head);
            } else {
                if (reply) reply([NSString stringWithFormat:@"语音没发出去：%@", note ?: @"未知原因"]);
            }
        } copy];
    }

    // 语音条实际是 SILK 流，所以先把它编出来。编不出来就不发 —— 发一条没声音的空语音
    // 比直接报错更浪费时间（这正是之前几版一直在踩的坑）
    NSString *silkNote = nil;
    NSData *silk = InsVoiceSilkEncode(pcm, 24000, &silkNote);
    [InsConfig log:[NSString stringWithFormat:@"语音：SILK 编码%@（%@）",
                    silk.length ? @"成功" : @"失败", silkNote ?: @"-"]];
    if (!silk.length) {
        InsVoiceRecord(NO, silkNote ?: @"SILK 编码失败");
        if (reply) reply([NSString stringWithFormat:
            @"语音没发出去：编不成 SILK（%@）\n"
            @"微信语音条里装的是 SILK 流，编不出来就只能发一条没声音的空语音，所以这里直接报错。\n"
            @"把这条发给 WorkBuddy 定位。", silkNote ?: @"未知"]);
        return;
    }
    @synchronized ([InsVoice class]) {
        gSilkFile = silk;
        gSilkNote = silkNote;
    }
    gAudDir = InsVoiceAudDir(talker);
    gAudSinceID = InsVoiceMaxAudID(gAudDir);
    [InsConfig log:[NSString stringWithFormat:@"语音：语音目录 %@（起始 localID %lld）",
                    gAudDir.lastPathComponent ?: @"没找到", gAudSinceID]];

    NSInteger gen = gGeneration;
    InsVoiceKeepScreenOn(YES);   // 注入到收尾都要亮屏：息屏会让录音器停摆（见文件头注释）
    dispatch_async(dispatch_get_main_queue(), ^{
        id sender = InsVoiceSender();
        BOOL started = NO;
        @try {
            started = ((BOOL (*)(id, SEL, id, id, id))objc_msgSend)(
                sender, @selector(StartRecordFrom:ToUser:UserInfo:), from, talker, nil);
        } @catch (NSException *e) {
            [InsConfig log:[NSString stringWithFormat:@"语音：开始录音抛异常 %@", e.reason]];
        }
        if (!started) {
            dispatch_async(dispatch_get_global_queue(0, 0), ^{
                InsVoiceFinishNow(NO, @"微信没有开始录音（StartRecordFrom 返回 NO）");
            });
            return;
        }
        [InsConfig log:[NSString stringWithFormat:@"语音：开始录音 → %@", talker]];
        @try {
            if ([sender respondsToSelector:@selector(getCurrentRecorder)]) {
                id rec = ((id (*)(id, SEL))objc_msgSend)(sender, @selector(getCurrentRecorder));
                gRecorder = rec;
                // 录音器自己的采样率/录音格式，和编码器报的对一下就知道注入速率对不对
                NSMutableString *fmt = [NSMutableString string];
                if (rec && [rec respondsToSelector:@selector(getVoiceFormat)]) {
                    long long f = ((long long (*)(id, SEL))objc_msgSend)(rec, @selector(getVoiceFormat));
                    [fmt appendFormat:@" 格式=%lld", f];
                }
                if (rec && [rec respondsToSelector:@selector(audioDuration)]) {
                    unsigned int d = ((unsigned int (*)(id, SEL))objc_msgSend)(rec, @selector(audioDuration));
                    [fmt appendFormat:@" 已录=%ums", d];
                }
                [InsConfig log:[NSString stringWithFormat:
                    @"语音：当前录音器 %@（outputPcmBuffer=%@）%@",
                    rec ? NSStringFromClass([rec class]) : @"nil",
                    (rec && [rec respondsToSelector:@selector(outputPcmBuffer:bufferSize:)]) ? @"有" : @"无",
                    fmt]];
            }
        } @catch (NSException *e) {}
        // 3 秒还没见到 PCM：最常见的原因是发语音前微信在后台/屏幕熄了，录音器没被系统喂数据
        //（花海那次 gFedFrames=0、OnOutputPcmBuffer 一次没回调；而成功那次都有 PCM userData/上传首片）。
        // 不再是直接判死：先停掉这次录音，把界面/音频会话唤起来，重录一次；重录还不行才报错。
        // 用局部重试计数（按 gen 隔离），避免和下一轮语音串台。
        static NSInteger sRetryGen = -1;
        static NSInteger sRetryCount = 0;
        if (sRetryGen != gen) { sRetryGen = gen; sRetryCount = 0; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(0, 0), ^{
            if (gen != gGeneration) return;
            if (!gInjecting) return;
            if (gFedFrames > 0) return;   // 已经在正常吐 PCM，不用救
            [InsConfig log:@"语音：3 秒无 PCM，先停录并重试一次（重启录音器/唤前台）"];
            InsVoiceStopRecording();
            if (sRetryCount >= 1) {
                InsVoiceFinishNow(NO, @"录音器没吐出 PCM（重试一次仍失败）：请点亮屏幕、让微信保持在前台再试");
                return;
            }
            sRetryCount++;
            // 回主线程重新发起录音：这一步会把微信 App 激活到前台，重建音频会话
            dispatch_async(dispatch_get_main_queue(), ^{
                if (gen != gGeneration || !gInjecting) return;
                InsVoiceKeepScreenOn(YES);
                id s2 = InsVoiceSender();
                BOOL ok2 = NO;
                @try {
                    ok2 = ((BOOL (*)(id, SEL, id, id, id))objc_msgSend)(
                        s2, @selector(StartRecordFrom:ToUser:UserInfo:), from, talker, nil);
                } @catch (NSException *e) {
                    [InsConfig log:[NSString stringWithFormat:@"语音：重试录音抛异常 %@", e.reason]];
                }
                [InsConfig log:[NSString stringWithFormat:@"语音：重试 StartRecord %@", ok2 ? @"成功" : @"失败"]];
                if (!ok2) {
                    InsVoiceFinishNow(NO, @"重启录音失败：请点亮屏幕、让微信保持在前台再试");
                }
            });
            // 重录后再给 5 秒，还没有 PCM 就判失败（兜底超时仍会在 secs+15 兜住）
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(0, 0), ^{
                if (gen != gGeneration || !gInjecting) return;
                if (gFedFrames > 0) return;
                InsVoiceStopRecording();
                InsVoiceFinishNow(NO, @"重试后录音器仍没吐出 PCM：请点亮屏幕、让微信保持在前台再试");
            });
        });
        // 兜底超时：正常 1~3 秒就传完，给足 15 秒余量
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)((secs + 15.0) * NSEC_PER_SEC)),
                       dispatch_get_global_queue(0, 0), ^{
            if (gen != gGeneration) return;
            if (!gInjecting) return;
            InsVoiceStopRecording();
            InsVoiceFinishNow(NO, @"等微信回执超时（录音已停，可能已经发出去了，先看对方有没有收到）");
        });
    });
}

#pragma mark - 音色列表 / 体检

+ (NSString *)voiceListReport {
    InsConfig *cfg = [InsConfig shared];
    if (!InsVoiceKeysRaw().count) return @"还没配语音 Key，发「语音key <Key>」";
    NSString *base = cfg.voiceBaseURL.length ? cfg.voiceBaseURL : kInsVoiceFallbackBase;
    NSString *urlStr = [NSString stringWithFormat:@"%@/v1/voices?page_size=60", base];
    NSString *fail = nil, *used = nil;
    BOOL failover = NO;
    NSInteger status = 0;
    NSError *err = nil;
    NSData *body = InsVoiceSend(urlStr, @"GET", nil, @"application/json", NO,
                                &status, &err, &fail, &used, &failover);
    if (!body.length) return [NSString stringWithFormat:@"拉音色列表失败：%@", fail ?: @"无响应"];
    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSArray *voices = [json isKindOfClass:[NSDictionary class]] ? json[@"voices"] : nil;
    if (![voices isKindOfClass:[NSArray class]]) return @"音色列表格式不认识";
    NSMutableString *out = [NSMutableString stringWithFormat:@"可用音色（当前：%@）\n", cfg.voiceId];
    NSUInteger shown = 0;
    for (NSDictionary *v in voices) {
        if (![v isKindOfClass:[NSDictionary class]]) continue;
        NSString *vid = v[@"voice_id"];
        NSString *name = v[@"name"];
        if (![vid isKindOfClass:[NSString class]] || ![name isKindOfClass:[NSString class]]) continue;
        NSString *line = [NSString stringWithFormat:@"%@ %@%@", vid, name,
                          [vid isEqualToString:cfg.voiceId] ? @" ← 在用" : @""];
        [out appendFormat:@"%@\n", line];
        if (++shown >= 15) break;
    }
    if (failover && used.length) {
        [out appendFormat:@"（主 Key 不可用，本次用的是 %@）\n", InsVoiceKeyMask(used)];
    }
    [out appendString:@"换音色：语音 声 <voice_id>"];
    return out;
}

+ (NSString *)diagnosisForTalker:(NSString *)talker {
    InsConfig *cfg = [InsConfig shared];
    NSMutableString *out = [NSMutableString stringWithString:@"语音体检\n"];
    [out appendFormat:@"- 音色：%@ / %@\n", cfg.voiceId, cfg.voiceModel];
    [out appendFormat:@"- 接口：%@\n", cfg.voiceBaseURL];
    [out appendString:@"- Key 池：\n"];
    // 逐把探测，能一眼看出是哪把 Key 挂了、降级会不会生效
    for (NSString *line in [InsVoiceKeysReport(YES) componentsSeparatedByString:@"\n"]) {
        if (line.length) [out appendFormat:@"  %@\n", line];
    }

    NSDate *t0 = [NSDate date];
    NSString *err = nil;
    NSData *pcm = InsVoiceSynthesize(@"在的，听得见吗？", &err);
    double cost = -[t0 timeIntervalSinceNow];
    if (pcm.length) {
        [out appendFormat:@"- 合成：成功，%.0f ms / %.1f 秒音频\n", cost * 1000,
            (double)pcm.length / 48000.0];
    } else {
        [out appendFormat:@"- 合成：失败 — %@\n", err ?: @"未知"];
    }

    id sender = InsVoiceSender();
    [out appendFormat:@"- AudioSender：%@（%@）\n", sender ? @"拿得到" : @"拿不到", InsVoiceSenderDiag()];
    [out appendFormat:@"- 方法：StartRecordFrom %@｜StopRecord %@｜hook %@\n",
        (sender && [sender respondsToSelector:@selector(StartRecordFrom:ToUser:UserInfo:)]) ? @"有" : @"无",
        (sender && [sender respondsToSelector:@selector(StopRecord)]) ? @"有" : @"无",
        gHookInstalled ? @"已装" : @"没装"];
    [out appendFormat:@"- PCM 通道：AudioSender %@｜录音器 %@｜Silk %@｜MJSilk %@｜Opus %@｜录音文件 %@｜上传分片 %@｜临时音频 %@\n",
        gOrigOnPcm ? @"已挂" : @"没挂",
        gOrigOutputPcm ? @"已挂" : @"没挂",
        gOrigSilkEncode ? @"已挂" : @"没挂",
        gOrigMJSilkEncode ? @"已挂" : @"没挂",
        gOrigOpusEncode ? @"已挂" : @"没挂",
        gOrigAppendPcm ? @"已挂" : @"没挂",
        gOrigOnPart ? @"已挂" : @"没挂",
        gOrigGetTmpAudio ? @"已挂" : @"没挂"];
    [out appendFormat:@"  上次各通道命中：sender %lu / recorder %lu / silk %lu / mjsilk %lu / opus %lu / 录音文件 %lu\n",
        (unsigned long)gPcmHookCalls, (unsigned long)gRecPcmCalls,
        (unsigned long)gSilkCalls, (unsigned long)gMJSilkCalls, (unsigned long)gOpusCalls,
        (unsigned long)gAppendCalls];
    if (gSrcSamples) {
        [out appendFormat:@"  编码输入格式：%@ %@（%@）\n",
            (gInFmt == InsPcmFmtFloat32) ? @"float32" : (gInFmt == InsPcmFmtInt16 ? @"int16" : @"未判"),
            gFmtNote ?: @"",
            gForceFmt == 1 ? @"强制 int16" : (gForceFmt == 2 ? @"强制 float32" : @"自动")];
        [out appendFormat:@"  上次注入：%lu/%lu 采样（%.2f 秒）｜目标采样率 %lu（%@）｜录音文件 fileUseOpus=%d\n",
            (unsigned long)MIN(gCursor, (double)gSrcSamples), (unsigned long)gSrcSamples,
            (double)MIN(gCursor, (double)gSrcSamples) / 24000.0,
            (unsigned long)gTargetRate, gRateFrom ?: @"未定", (int)gAppendUseOpus];
        // 这两行是「有时长没声音」的判据：编码输出太少＝在编码这一环就变成静音了
        [out appendFormat:@"  编码输出：%lu 字节 / %lu 帧（平均 %.1f 字节）\n",
            (unsigned long)gEncBytes, (unsigned long)gEncFrames,
            gEncFrames ? (double)gEncBytes / (double)gEncFrames : 0.0];
        [out appendFormat:@"  上传分片：%lu 个 / %lu 字节（duration=%ums）｜证据文件 voice_last.wav / voice_enc.bin\n",
            (unsigned long)gPartCalls, (unsigned long)gPartBytes, gPartDuration];
    }
    NSString *why = nil;
    BOOL can = InsVoiceCanSend(InsSelfWxidShared(), talker, &why);
    [out appendFormat:@"- 注入通道：%@\n", InsVoiceChannelName(gForceChannel)];
    [out appendFormat:@"- 能否录音：%@\n", can ? @"可以" : (why ?: @"不行")];
    [out appendFormat:@"- 会话状态：%@\n", [InsSend isChatOpen:talker] ? @"已打开" : @"没打开（发语音时会先打开）"];
    [out appendString:@"（合成成功 + 能录音，就可以直接发「语音 <文本>」）"];
    return out;
}

#pragma mark - status / 测key

+ (NSString *)statusLine {
    InsConfig *cfg = [InsConfig shared];
    NSMutableString *out = [NSMutableString string];
    NSArray<NSString *> *keys = InsVoiceKeysRaw();
    if (!keys.count) {
        [out appendString:@"语音：Key 没配（语音key <Key>）"];
    } else {
        __block NSString *lastGood = nil;
        InsVoiceKeyLocked(^{ lastGood = gKeyLastGood; });
        [out appendFormat:@"语音：Key %lu 把%@｜录音 hook %@｜%@",
            (unsigned long)keys.count,
            lastGood ? [NSString stringWithFormat:@"（在用 %@）", InsVoiceKeyMask(lastGood)]
                     : @"（还没成功过）",
            gHookInstalled ? @"已装" : @"没装",
            cfg.voiceAuto ? @"模式 自动发语音" : @"模式 手动"];
    }
    if (gLastVoiceAt > 0) {
        NSString *when = [NSDateFormatter localizedStringFromDate:
            [NSDate dateWithTimeIntervalSince1970:gLastVoiceAt]
            dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle];
        [out appendFormat:@"\n  上次语音 %@：%@%@", when, gLastVoiceOK ? @"成功" : @"失败",
            gLastVoiceNote.length ? [NSString stringWithFormat:@"（%@）", gLastVoiceNote] : @""];
    } else {
        [out appendString:@"\n  还没发过语音：先「语音 试 你好」本机试听，再「语音 说早上好」真发"];
    }
    [out appendString:@"\n  排查：语音体检 / 语音key 测 / log 30"];
    return out;
}

+ (NSString *)keyProbeReport {
    NSMutableString *out = [NSMutableString stringWithString:@"语音通道\n"];
    [out appendString:InsVoiceKeysReport(YES)];
    [out appendString:@"\n合成："];
    NSString *err = nil;
    NSDate *t0 = [NSDate date];
    NSData *pcm = InsVoiceSynthesize(@"测一下，一二三", &err);
    if (pcm.length) {
        [out appendFormat:@"成功（%.0f ms，%.1f 秒音频）",
            -[t0 timeIntervalSinceNow] * 1000, (double)pcm.length / 48000.0];
    } else {
        [out appendFormat:@"失败 — %@", err ?: @"未知"];
    }
    [out appendFormat:@"\n录音 hook：%@｜真机试发：语音 说早上好", gHookInstalled ? @"已装" : @"没装"];
    return out;
}

#pragma mark - 命令

/// 「一首/一段/个/首诗/个笑话」这类是在跟我要东西，不是在给我台词
static BOOL InsVoiceLooksLikeRequest(NSString *s) {
    static NSArray<NSString *> *quant = nil;
    static NSArray<NSString *> *nouns = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        quant = @[@"一首", @"一句", @"一段", @"一篇", @"一个", @"一条", @"一首诗",
                  @"首", @"段", @"篇", @"个", @"句"];
        nouns = @[@"古诗", @"诗", @"词", @"笑话", @"故事", @"段子", @"绕口令", @"顺口溜",
                  @"成语", @"歇后语", @"谜语", @"脑筋急转弯", @"情话", @"祝福", @"歌词",
                  @"歌", @"新闻", @"天气预报"];
    });
    if (!s.length) return NO;
    for (NSString *q in quant) {
        if ([s rangeOfString:q].location != NSNotFound) return YES;
    }
    for (NSString *n in nouns) {
        if ([s rangeOfString:n].location != NSNotFound) return YES;
    }
    return NO;
}

/// 照读动词：后面跟的就是要念的原话（「说林健哥哥最帅了」）
static BOOL InsVoiceHasQuoteVerb(NSString *s) {
    static NSArray<NSString *> *verbs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // 长的排前面
        verbs = @[@"帮我念", @"帮我读", @"跟我说", @"给我说", @"说一句", @"念一句", @"念一段",
                  @"读一下", @"告诉我", @"对他说", @"对她说", @"跟他说", @"跟她说",
                  @"照读", @"原文", @"朗读", @"复述", @"念", @"读", @"说", @"讲"];
    });
    for (NSString *v in verbs) {
        if ([s hasPrefix:v]) return YES;
    }
    return NO;
}

/// 放行名单里的非主人也能发语音，但同一会话 10 秒只给一条，防刷屏、也防两个机器人互相触发成环
static BOOL InsVoiceGuestCanSpeak(NSString *talker) {
    static NSMutableDictionary<NSString *, NSNumber *> *last = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ last = [NSMutableDictionary dictionary]; });
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    @synchronized (last) {
        NSNumber *prev = last[talker ?: @""];
        if (prev && now - prev.doubleValue < 10.0) return NO;
        last[talker ?: @""] = @(now);
    }
    return YES;
}

/// 这些命令会改全局配置、打印 Key 池或换注入通道：只有账号主人能动
static BOOL InsVoiceIsOwnerCommand(NSString *s) {
    static NSArray<NSString *> *prefixes = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[@"语音体检", @"语音 体检", @"语音声", @"语音 声", @"语音 音色", @"语音音色",
                     @"语音key", @"语音 key", @"语音Key", @"语音 语气", @"语音语气",
                     @"语音 唱腔", @"语音唱腔", @"翻唱服务", @"语音 翻唱服务",
                     @"语音 格式", @"语音格式", @"语音 通道", @"语音通道",
                     @"语音 模式", @"语音模式", @"语音 试", @"语音试", @"试音"];
    });
    for (NSString *p in prefixes) {
        if ([s hasPrefix:p]) return YES;
    }
    return NO;
}

+ (InsVoiceAskMode)askModeForPayload:(NSString *)payload text:(NSString *__autoreleasing *)textOut {
    NSString *s = InsVoiceNormalize(InsVoiceClean(payload));
    if (![s hasPrefix:@"语音"]) return InsVoiceAskNone;
    NSString *body = [[s substringFromIndex:2]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!body.length) return InsVoiceAskNone;   // 光一个「语音」→ 交给 handlePayload 出用法

    // 参数类命令原样交给 handlePayload（体检/声/语气/模式/key/通道/格式/试听…）。
    // 这里必须按「语音 xxx」整串比前缀：「语音 生日快乐」不能被当成换音色。
    static NSArray<NSString *> *params = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        params = @[@"语音体检", @"语音 体检", @"语音声", @"语音 声", @"语音 音色",
                   @"语音语气", @"语音 语气", @"语音 唱腔", @"语音唱腔",
                   @"语音 模式", @"语音模式",
                   @"语音key", @"语音 key", @"语音Key", @"语音 通道", @"语音 格式",
                   @"语音 试音", @"语音 试 ", @"语音 列表", @"语音列表",
                   @"语音 help", @"语音 ？", @"语音 ?"];
    });
    for (NSString *p in params) {
        if ([s hasPrefix:p]) return InsVoiceAskNone;
    }

    // 「语音 原文 xxx」「语音 说林健哥哥最帅了」：用户就是给了台词，照读
    if (InsVoiceHasQuoteVerb(body) && !InsVoiceLooksLikeRequest(body)) {
        return InsVoiceAskNone;
    }

    if (textOut) *textOut = body;
    // 用户明确说了「发语音/用语音回复/语音回复…」就是要听语音回答，问句（「你认识XX吗」）
    // 也一样念出来；只有裸「语音 <问句>」才降级回文字（那种多是问插件怎么用，要显示步骤）。
    static NSArray *speakPrefixes = nil;
    static dispatch_once_t speakOnce;
    dispatch_once(&speakOnce, ^{
        speakPrefixes = @[@"发语音", @"用语音", @"语音回复", @"来条语音", @"来段语音",
                          @"发一条语音", @"发一段语音", @"发条语音", @"发个语音"];
    });
    NSString *raw = InsVoiceClean(payload);
    BOOL explicitSpeak = NO;
    for (NSString *p in speakPrefixes) {
        if ([raw hasPrefix:p]) { explicitSpeak = YES; break; }
    }
    if (explicitSpeak) return InsVoiceAskSpeak;

    // 裸「语音 <问句>」回文字更合适（「语音 怎么发不出去」这种要显示步骤/链接）
    BOOL question = [body rangeOfString:@"？"].location != NSNotFound ||
                    [body rangeOfString:@"?"].location != NSNotFound ||
                    [body hasSuffix:@"吗"] || [body hasPrefix:@"怎么"] ||
                    [body hasPrefix:@"为什么"] || [body hasPrefix:@"为啥"];
    if (question) return InsVoiceAskText;
    return InsVoiceAskSpeak;
}

+ (BOOL)handlesPayload:(NSString *)payload {
    NSString *s = InsVoiceNormalize(InsVoiceClean(payload));
    if (!s.length) return NO;
    // 「语音通话怎么用」这类问句放回大模型，不当命令
    BOOL question = [s containsString:@"怎么"] || [s containsString:@"为什么"] ||
                    [s containsString:@"吗"] || [s containsString:@"？"] || [s containsString:@"?"];
    if (question) return NO;
    if ([s hasPrefix:@"语音"]) return YES;
    if ([s hasPrefix:@"试音"]) return YES;
    if ([s hasPrefix:@"翻唱服务"]) return YES;
    return NO;
}

/// 歌名后面常跟着「给我听」「吧」「呢」这类客套尾巴：直接拿去搜就搜不到歌
/// （「晴天给我听」会当成歌名）。按长到短反复剥，剥到不再变化为止；剥空就退回原文。
static NSString *InsVoiceTrimSongTail(NSString *topic) {
    if (!topic.length) return topic;
    static NSArray<NSString *> *tails = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tails = @[@"唱给我听", @"给我听听", @"给我听", @"唱一下", @"听一下", @"你听听",
                  @"好不好听", @"好不好", @"行不行", @"可以吗", @"行吗", @"好吗",
                  @"听听", @"呗", @"吧", @"啊", @"呀", @"呢", @"嘛"];
    });
    NSString *s = topic;
    for (NSInteger guard = 0; guard < 6; guard++) {
        BOOL changed = NO;
        for (NSString *t in tails) {
            if (s.length > t.length && [s hasSuffix:t]) {
                s = InsVoiceClean([s substringToIndex:s.length - t.length]);
                changed = YES;
                break;
            }
        }
        if (!changed) break;
    }
    return s.length ? s : topic;
}

/// 从原始 payload 里抠出第一个完整 URL（抖音分享链接等）。
/// 必须吃原始串、不能过 InsVoiceClean/InsVoiceExtractSong：链接里的 ? & = % / 会被当标点处理。
/// 链接一般以参数结尾，后面可能跟中文标点或空格，遇到这些就停。
static NSString *InsVoiceExtractURL(NSString *payload) {
    if (![payload isKindOfClass:[NSString class]]) return nil;
    NSRange h = [payload rangeOfString:@"http"];
    if (h.location == NSNotFound) return nil;
    NSString *tail = [payload substringFromIndex:h.location];
    // URL 允许的字符：scheme/域名/路径/query 里的字母数字和 :/?&=%._~+-
    NSMutableString *u = [NSMutableString string];
    NSCharacterSet *ok = [NSCharacterSet characterSetWithCharactersInString:
                          @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
                          @"0123456789-._~:/?&=+%#@"];
    for (NSInteger i = 0; i < tail.length; i++) {
        unichar ch = [tail characterAtIndex:i];
        if (![ok characterIsMember:ch]) break;   // 遇到中文/空格/括号等即停
        [u appendFormat:@"%C", ch];
    }
    // 常见粘贴尾巴：结尾的标点清掉
    while (u.length && [[NSCharacterSet characterSetWithCharactersInString:@";,.!，。！"] characterIsMember:[u characterAtIndex:u.length - 1]]) {
        [u deleteCharactersInRange:NSMakeRange(u.length - 1, 1)];
    }
    // 至少要像个链接（含 :// 且有域名）
    if ([u rangeOfString:@"://"].location == NSNotFound || u.length < 12) return nil;
    return u;
}

/// 是不是「把这个链接的歌唱给我 / 唱一下这个链接 / 唱这个视频的歌」这类链接点歌。
/// 注意：判据走原始 payload，且必须在问句判断（含「吗/？」）之前——
/// 抖音链接的 query 里有 "?region=CN"，先做问句判断会把链接点歌误放给大模型。
static BOOL InsVoiceWantsLinkCover(NSString *payload) {
    if (![payload isKindOfClass:[NSString class]]) return NO;
    if (!InsVoiceExtractURL(payload)) return NO;
    static NSArray<NSString *> *marks = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        marks = @[@"这个链接", @"这条链接", @"这个视频", @"这条视频",
                  @"链接的歌", @"视频的歌", @"把这个链接", @"唱这个", @"唱一下这个"];
    });
    for (NSString *m in marks) {
        if ([payload rangeOfString:m].location != NSNotFound) return YES;
    }
    return NO;
}

/// 完整版意图：明确要求唱整首/不要片段时才开（避免把普通点歌都变成 5 分钟长音频）。
/// 关键词按自然语言写，命令里出现任意一个即判定。
static BOOL InsVoiceWantsFull(NSString *payload) {
    if (![payload isKindOfClass:[NSString class]]) return NO;
    static NSArray<NSString *> *marks = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        marks = @[@"完整版", @"一整首", @"整首", @"唱全", @"全曲", @"完整唱",
                  @"整首歌", @"不要片段", @"不只片段", @"唱完整"];
    });
    for (NSString *m in marks) {
        if ([payload rangeOfString:m].location != NSNotFound) return YES;
    }
    return NO;
}

/// 从「唱首<...>」的剩余串里提取真正的歌名：
/// 1) 有引号（"" "" ''）时只取引号内内容——最干净，能避开「给我听/要唱完整版」等尾巴；
/// 2) 没引号时在「给我听」「，要」「,要」「然后」等断点处截断；
/// 3) 最后统一走 InsVoiceTrimSongTail 剥语气词。
static NSString *InsVoiceExtractSong(NSString *rest) {
    if (!rest.length) return rest;
    NSString *s = rest;
    // 1) 引号优先：中文/英文双引号、单引号
    NSArray<NSArray<NSString *> *> *pairs = @[
        @[@"\"", @"\""], @[@"“", @"”"], @[@"‘", @"’"], @[@"'", @"'"]];
    for (NSArray<NSString *> *p in pairs) {
        NSRange a = [s rangeOfString:p[0]];
        if (a.location == NSNotFound) continue;
        NSUInteger from = a.location + a.length;
        NSRange b = [s rangeOfString:p[1]
                             options:0
                               range:NSMakeRange(from, s.length - from)];
        if (b.location != NSNotFound && b.location > from) {
            NSString *inside = [s substringWithRange:NSMakeRange(from, b.location - from)];
            if (inside.length) return InsVoiceTrimSongTail(InsVoiceClean(inside));
        }
    }
    // 2) 断点截断：删掉「给我听」及其后的所有要求
    NSArray<NSString *> *cuts = @[@"给我听", @"给我唱", @"我要听", @"，要", @",要",
                                  @"然后要", @"要唱", @"不要片段", @"完整版"];
    for (NSString *c in cuts) {
        NSRange r = [s rangeOfString:c];
        if (r.location != NSNotFound && r.location > 0) {
            s = [s substringToIndex:r.location];
            break;
        }
    }
    return InsVoiceTrimSongTail(InsVoiceClean(s));
}

/// 是不是唱歌请求：「唱歌 <歌名/要求>」「唱首…」「唱一段…」「来一首…」「语音 唱 <…>」。
/// 命中时 topicOut 带出要唱什么（可为空 = 自由发挥）；问句（「这首歌怎么唱」）不认，放回大模型
+ (BOOL)singRequestForPayload:(NSString *)payload topic:(NSString *__autoreleasing *)topicOut {
    NSString *s = InsVoiceNormalize(InsVoiceClean(payload));
    if (!s.length) return NO;
    // 【链接点歌】必须放在问句判断之前：抖音链接 query 里的 "?region=CN" 会被当成问号。
    // 从原始 payload 抠完整 URL 当 topic（歌名位），Mac 端识别出抖音链接走原声下载。
    if (InsVoiceWantsLinkCover(payload)) {
        NSString *url = InsVoiceExtractURL(payload);
        if (url.length) {
            if (topicOut) *topicOut = url;
            return YES;
        }
    }
    // 问句不是让我唱，放回大模型正常回答
    if ([s containsString:@"怎么"] || [s containsString:@"为什么"] ||
        [s containsString:@"吗"] || [s containsString:@"？"] || [s containsString:@"?"]) return NO;
    // 「语音 唱腔 <描述>」是设置项，不是唱歌
    if ([s hasPrefix:@"语音 唱腔"] || [s hasPrefix:@"语音唱腔"]) return NO;
    NSString *topic = nil;
    static NSArray<NSString *> *marks = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        marks = @[@"唱歌 ", @"唱歌", @"唱首", @"唱一", @"唱段", @"唱个", @"来一首", @"来首",
                  @"语音 唱", @"语音唱"];
    });
    for (NSString *m in marks) {
        if (![s hasPrefix:m]) continue;
        // 用原始串（未清洗标点）去提取，才能抓到引号里的歌名
        NSString *raw = [payload stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSUInteger mi = [raw rangeOfString:m].location;
        NSString *rest = (mi != NSNotFound && mi + m.length <= raw.length)
            ? [raw substringFromIndex:mi + m.length] : [s substringFromIndex:m.length];
        topic = InsVoiceExtractSong(rest);
        break;
    }
    if (topic == nil) return NO;
    if (topicOut) *topicOut = topic;
    return YES;
}

+ (BOOL)singFullRequested:(NSString *)payload {
    return InsVoiceWantsFull(payload);
}

+ (BOOL)autoEnabled {
    return [InsConfig shared].voiceAuto;
}

+ (void)sayAnswer:(NSString *)answer talker:(NSString *)talker
         fallback:(void (^)(NSString *))fallback {
    if (!answer.length) { if (fallback) fallback(answer); return; }
    [self speak:answer talker:talker reply:^(NSString *text) {
        // 成功时 text 是「已发语音…」，不该再发回会话；失败才需要让用户看到
        if ([text hasPrefix:@"已发语音"]) return;
        if (fallback) fallback([NSString stringWithFormat:@"%@\n%@", text, answer]);
    }];
}

+ (BOOL)handlePayload:(NSString *)payload
               talker:(NSString *)talker
                owner:(BOOL)owner
                reply:(void (^)(NSString *))reply {
    InsConfig *cfg = [InsConfig shared];
    // 「发条语音 说早上好」先归一成「语音 说早上好」，否则会落到大模型那边
    NSString *s = InsVoiceNormalize(InsVoiceClean(payload));
    if (!s.length) return NO;

    void (^say)(NSString *) = ^(NSString *t) { if (reply) reply(t); };

    // 放行名单里的人也能用了，但体检/换音色/改 Key/换通道这些仍然锁给主人
    if (!owner && InsVoiceIsOwnerCommand(s)) {
        [InsConfig log:[NSString stringWithFormat:@"语音：非主人想改设置被拒 %@（%@）", s, talker]];
        say([NSString stringWithFormat:@"这条只有账号主人能改。要用语音直接发：%@ 语音 <话>", cfg.trigger]);
        return YES;
    }

    // 语音体检
    if ([s hasPrefix:@"语音体检"] || [s hasPrefix:@"语音 体检"]) {
        [InsConfig log:@"语音：体检"];
        say([self diagnosisForTalker:talker]);
        return YES;
    }

    // 语音 声 / 语音音色
    if ([s hasPrefix:@"语音 声"] || [s hasPrefix:@"语音声"] || [s hasPrefix:@"语音 音色"]) {
        NSString *arg = s;
        for (NSString *p in @[@"语音 声", @"语音声", @"语音 音色"]) {
            if ([arg hasPrefix:p]) { arg = [arg substringFromIndex:p.length]; break; }
        }
        arg = InsVoiceClean(arg);
        if (!arg.length || [arg.lowercaseString isEqualToString:@"list"]) {
            say([self voiceListReport]);
            return YES;
        }
        if (![arg hasPrefix:@"voc_"]) {
            say(@"音色要填 voice_id（voc_ 开头），发「语音 声 list」看有哪些");
            return YES;
        }
        [cfg setConfigKeysPersisted:@{ @"voiceId": arg }];
        [cfg reload];
        say([NSString stringWithFormat:@"语音音色已换成 %@。发「语音 试 你好」听听看", arg]);
        return YES;
    }

    // 语音key / 语音key2：Key 池（主 Key 不通自动换备用）
    if ([s.lowercaseString hasPrefix:@"语音key"]) {
        NSString *rest = [[s substringFromIndex:5]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *low = rest.lowercaseString;

        if (!rest.length) {
            say([NSString stringWithFormat:
                 @"语音 Key 池现状：\n%@\n\n"
                 @"@insomnia 语音key <Key>     设主 Key\n"
                 @"@insomnia 语音key2 <Key>    设备用 Key（主 Key 401/402/403/429 时自动顶上）\n"
                 @"@insomnia 语音key 列表      看 Key 池（脱敏）\n"
                 @"@insomnia 语音key 测        逐把实测通不通\n"
                 @"一个字段里也能写多把：语音key brz_aaa,brz_bbb",
                 InsVoiceKeysReport(NO)]);
            return YES;
        }
        if ([low hasPrefix:@"列表"] || [low hasPrefix:@"状态"] || [low hasPrefix:@"list"]) {
            say(InsVoiceKeysReport(NO));
            return YES;
        }
        if ([low hasPrefix:@"测"] || [low hasPrefix:@"test"] || [low hasPrefix:@"probe"]) {
            [InsConfig log:@"语音：逐把测 Key"];
            say(InsVoiceKeysReport(YES));
            return YES;
        }

        // 语音key2 xxx / 语音key 2 xxx / 语音key 备用 xxx 都算设备用 Key
        BOOL backup = NO;
        for (NSString *p in @[@"key2", @"2", @"备用", @"次"]) {
            if ([low hasPrefix:p]) {
                backup = YES;
                rest = [[rest substringFromIndex:p.length]
                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                break;
            }
        }
        if (rest.length < 8) {
            say(backup ? @"用法：@insomnia 语音key2 <备用 Breeze API Key>"
                       : @"用法：@insomnia 语音key <Breeze API Key>");
            return YES;
        }
        [cfg setConfigKeysPersisted:@{ backup ? @"voiceApiKey2" : @"voiceApiKey": rest }];
        [cfg reload];
        NSUInteger n = InsVoiceKeysRaw().count;
        say([NSString stringWithFormat:
             @"%@已写入（%@，%lu 位）。现在 Key 池 %lu 把；主 Key 不通会自动换下一把。\n%@",
             backup ? @"备用语音 Key " : @"语音 Key ", InsVoiceKeyMask(rest),
             (unsigned long)rest.length, (unsigned long)n, InsVoiceKeysReport(NO)]);
        return YES;
    }

    // 语音 语气
    if ([s hasPrefix:@"语音 语气"] || [s hasPrefix:@"语音语气"]) {
        NSString *arg = [s hasPrefix:@"语音 语气"] ? [s substringFromIndex:5] : [s substringFromIndex:4];
        arg = InsVoiceClean(arg);
        if (!arg.length) { say(@"用法：@insomnia 语音 语气 说话懒散一点，尾音上扬"); return YES; }
        [cfg setConfigKeysPersisted:@{ @"voiceInstructions": arg }];
        [cfg reload];
        say([NSString stringWithFormat:@"语气已设置为「%@」", arg]);
        return YES;
    }

    // 语音 唱腔：设定唱歌演绎风格（「唱歌」命令合成时用）
    if ([s hasPrefix:@"语音 唱腔"] || [s hasPrefix:@"语音唱腔"]) {
        NSString *arg = [s hasPrefix:@"语音 唱腔"] ? [s substringFromIndex:6] : [s substringFromIndex:5];
        arg = InsVoiceClean(arg);
        if (!arg.length) {
            say([NSString stringWithFormat:
                 @"当前唱腔：%@（空 = 默认唱腔）\n用法：@insomnia 语音 唱腔 温柔的民谣唱腔，节奏舒缓\n恢复默认：@insomnia 语音 唱腔 清除",
                 cfg.singInstructions.length ? cfg.singInstructions : @"（默认）"]);
            return YES;
        }
        if ([arg isEqualToString:@"清"] || [arg isEqualToString:@"清除"] ||
            [arg isEqualToString:@"off"] || [arg isEqualToString:@"默认"]) {
            [cfg setConfigKeysPersisted:@{ @"singInstructions": @"" }];
            [cfg reload];
            say(@"唱腔已恢复默认。");
            return YES;
        }
        [cfg setConfigKeysPersisted:@{ @"singInstructions": arg }];
        [cfg reload];
        say([NSString stringWithFormat:@"唱腔已设置为「%@」。发「%@ 唱歌 <歌名>」听听效果", arg, cfg.trigger]);
        return YES;
    }

    // 翻唱服务：设定 Mac 翻唱服务地址（仅主人）。配置后「唱歌 <歌名>」走原曲翻唱
    if ([s hasPrefix:@"翻唱服务"] || [s hasPrefix:@"语音 翻唱服务"]) {
        if (!owner) {
            say(@"只有主人能改翻唱服务设置。");
            return YES;
        }
        NSString *arg = [s hasPrefix:@"语音 翻唱服务"]
            ? [s substringFromIndex:9] : [s substringFromIndex:4];
        arg = [[arg stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
               stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\"'"]];
        if (!arg.length) {
            say([NSString stringWithFormat:
                 @"当前翻唱服务：%@（空 = 点歌走 TTS 直唱）\n"
                 @"用法：@insomnia 翻唱服务 http://192.168.1.100:8777\n"
                 @"关闭：@insomnia 翻唱服务 关",
                 cfg.coverURL.length ? cfg.coverURL : @"（未配置）"]);
            return YES;
        }
        if ([arg isEqualToString:@"关"] || [arg isEqualToString:@"清除"] ||
            [arg isEqualToString:@"off"] || [arg isEqualToString:@"关掉"]) {
            [cfg setConfigKeysPersisted:@{ @"coverURL": @"" }];
            [cfg reload];
            say(@"翻唱服务已关闭，点歌恢复 TTS 直唱。");
            return YES;
        }
        if (![arg hasPrefix:@"http://"] && ![arg hasPrefix:@"https://"]) {
            say(@"地址要以 http:// 开头，比如 http://192.168.1.100:8777");
            return YES;
        }
        [cfg setConfigKeysPersisted:@{ @"coverURL": arg }];
        [cfg reload];
        say([NSString stringWithFormat:@"翻唱服务已设置为 %@。发「%@ 唱 <歌名>」试试原曲翻唱（全程要几分钟）", arg, cfg.trigger]);
        return YES;
    }

    // 语音 格式 [auto|int16|float32]：编码输入端的采样格式。
    // 写错格式时编码器会编出一串静音帧，表现就是「语音条有时长、但完全没声音」
    if ([s hasPrefix:@"语音 格式"] || [s hasPrefix:@"语音格式"]) {
        NSString *arg = [s hasPrefix:@"语音 格式"] ? [s substringFromIndex:5] : [s substringFromIndex:4];
        NSString *a = [InsVoiceClean(arg) lowercaseString];
        NSInteger pick = -1;
        if (!a.length || [a isEqualToString:@"auto"] || [a containsString:@"自动"]) pick = 0;
        else if ([a hasPrefix:@"int"] || [a isEqualToString:@"1"] || [a hasPrefix:@"16"]) pick = 1;
        else if ([a hasPrefix:@"float"] || [a isEqualToString:@"2"] || [a hasPrefix:@"32"]) pick = 2;
        if (pick < 0) {
            say([NSString stringWithFormat:
                 @"当前编码输入格式：%@\n"
                 @"上次编码输出 %lu 字节 / %lu 帧（静音帧只有 1~3 字节）\n"
                 @"发「语音 格式 float32」强制换一种写法；「语音 格式 auto」回自动\n"
                 @"两种都试过还没声，就把日志里「编码输出」「上传首片」两行发我",
                 gForceFmt == 1 ? @"强制 int16" : (gForceFmt == 2 ? @"强制 float32" : @"自动判定"),
                 (unsigned long)gEncBytes, (unsigned long)gEncFrames]);
            return YES;
        }
        gForceFmt = pick;
        [InsConfig log:[NSString stringWithFormat:@"语音：输入格式切到 %ld", (long)pick]];
        say([NSString stringWithFormat:@"输入格式改为%@。再发一条「语音 说一二三四五」，然后听有没有声",
             pick == 1 ? @"强制 int16" : (pick == 2 ? @"强制 float32" : @"自动判定")]);
        return YES;
    }

    // 语音 通道 [0-3]：声音通道实验
    if ([s hasPrefix:@"语音 通道"] || [s hasPrefix:@"语音通道"]) {
        NSString *arg = [s hasPrefix:@"语音 通道"] ? [s substringFromIndex:5] : [s substringFromIndex:4];
        arg = InsVoiceClean(arg);
        NSInteger pick = -1;
        for (NSInteger i = 0; i <= 3; i++) {
            if ([arg hasPrefix:[NSString stringWithFormat:@"%ld", (long)i]]) { pick = i; break; }
        }
        if (pick < 0) {
            if ([arg containsString:@"自动"] || [arg.lowercaseString isEqualToString:@"auto"]) pick = 0;
        }
        if (pick < 0) { say(InsVoiceChannelReport()); return YES; }
        gForceChannel = pick;
        [InsConfig log:[NSString stringWithFormat:@"语音：注入通道切到 %@", InsVoiceChannelName(pick)]];
        say([NSString stringWithFormat:@"%@\n发一条「语音 说早上好」听结果；不行就换下一条，0 回自动",
             InsVoiceChannelReport()]);
        return YES;
    }

    // 语音 模式 开/关
    if ([s hasPrefix:@"语音 模式"] || [s hasPrefix:@"语音模式"]) {
        NSString *arg = [s hasPrefix:@"语音 模式"] ? [s substringFromIndex:5] : [s substringFromIndex:4];
        arg = InsVoiceClean(arg);
        BOOL on = [arg containsString:@"开"] || [arg.lowercaseString isEqualToString:@"on"];
        BOOL off = [arg containsString:@"关"] || [arg.lowercaseString isEqualToString:@"off"];
        if (!on && !off) {
            say([NSString stringWithFormat:@"语音模式现在%@。发「语音 模式 开/关」切换",
                 cfg.voiceAuto ? @"开着（问答回复直接发语音）" : @"关着（只有 语音 <话> 才发）"]);
            return YES;
        }
        [cfg setConfigKeysPersisted:@{ @"voiceAuto": @(on) }];
        [cfg reload];
        say(on ? @"语音模式已开：以后问答回复直接发语音条（发失败会退回文字）"
               : @"语音模式已关：只有「语音 <文本>」才发语音");
        return YES;
    }

    // 语音 试 <文本>：只在手机本机播放，不发出去
    NSString *text = nil;
    for (NSString *p in @[@"语音 试", @"语音试", @"试音"]) {
        if ([s hasPrefix:p]) {
            text = InsVoiceStripVerb(InsVoiceClean([s substringFromIndex:p.length]));
            break;
        }
    }
    if (text) {
        if (!text.length) { say(@"用法：@insomnia 语音 试 今天早点睡"); return YES; }
        NSUInteger trimmed = 0, maxC = 0;
        NSString *spoken = InsVoiceClip(text, &trimmed, &maxC);
        NSString *err = nil;
        NSDate *t0 = [NSDate date];
        NSData *pcm = InsVoiceSynthesize(spoken, &err);
        if (!pcm.length) { say([NSString stringWithFormat:@"合成失败：%@", err ?: @"未知"]); return YES; }
        double secs = (double)pcm.length / 48000.0;
        BOOL played = InsVoicePlayPCM(pcm, 24000);
        [InsConfig log:[NSString stringWithFormat:@"语音：试听 %.1f 秒（合成 %.1f 秒）",
                        secs, -[t0 timeIntervalSinceNow]]];
        say([NSString stringWithFormat:@"%@%.1f 秒，正在本机播放：%@%@",
             played ? @"试听 " : @"合成好了但播放器没起来，音频 ",
             secs, spoken,
             trimmed ? [NSString stringWithFormat:@"\n（超长，后面 %lu 字没念）", (unsigned long)trimmed] : @""]);
        return YES;
    }

    // 语音 <文本>
    if ([s hasPrefix:@"语音"]) {
        text = InsVoiceStripVerb(InsVoiceClean([s substringFromIndex:2]));
        if (!text.length) {
            say(@"用法：\n"
                @"@insomnia 语音 <话>  先理解你的话，再把回答念成语音条（背诗/讲笑话也认）\n"
                @"@insomnia 唱歌 <歌名/要求>  现场编词开唱，发语音条\n"
                @"@insomnia 翻唱服务 <url>  设置 Mac 翻唱服务；配好后点歌走原曲翻唱（旋律是真的）\n"
                @"@insomnia 语音 原文 <话>  照读这句话本身\n"
                @"@insomnia 语音 试 <话>  只在本机试听，不发出去\n"
                @"@insomnia 语音体检  逐项检查 Key/合成/录音通道\n"
                @"@insomnia 语音 声 list  看可用音色；语音 声 <voc_id> 换音色\n"
                @"@insomnia 语音 语气 <描述>  设定语气\n"
                @"@insomnia 语音 唱腔 <描述>  设定唱歌风格（唱歌命令用）\n"
                @"@insomnia 语音 模式 开/关  问答回复自动发语音\n"
                @"@insomnia 语音 通道 [0-3]  切换语音注入通道（0 自动 / 1 旁路 / 2 录音文件 / 3 编码器）\n"
                @"@insomnia 语音 格式 [auto|int16|float32]  编码输入格式（没声音时换一种试）");
            return YES;
        }
        if (!owner && !InsVoiceGuestCanSpeak(talker)) {
            // 放行名单里的人可以发语音，但不能刷屏：同一会话 10 秒一条
            say(@"语音发得太快了，等 10 秒再发。");
            return YES;
        }
        [self speak:text talker:talker reply:reply];
        return YES;
    }
    return NO;
}

+ (void)installHook {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"AudioSender");
        if (!cls) {
            [InsConfig log:@"语音：找不到 AudioSender，注入不可用"];
            return;
        }
        MSHookMessageEx(cls, @selector(OnOutputPcmBuffer:UserData:),
                        (IMP)&InsVoiceOnPcmBuffer, (IMP *)&gOrigOnPcm);
        // 正常发语音真正喂编码器的是录音器底层输出，AudioSender 那条更像旁路
        Class silkCls = NSClassFromString(@"SilkAudioEncoder");
        if (silkCls && [silkCls instancesRespondToSelector:@selector(encodePcmBuffer:)]) {
            MSHookMessageEx(silkCls, @selector(encodePcmBuffer:),
                            (IMP)&InsVoiceOnSilkEncode, (IMP *)&gOrigSilkEncode);
        }
        Class mjSilkCls = NSClassFromString(@"MJSilkCodec");
        if (mjSilkCls && [mjSilkCls instancesRespondToSelector:@selector(encodeFromPCMData:)]) {
            MSHookMessageEx(mjSilkCls, @selector(encodeFromPCMData:),
                            (IMP)&InsVoiceOnMJSilkEncode, (IMP *)&gOrigMJSilkEncode);
        }
        Class opusCls = NSClassFromString(@"OpusAudioCodec");
        if (opusCls && [opusCls instancesRespondToSelector:@selector(encodePcmData:)]) {
            MSHookMessageEx(opusCls, @selector(encodePcmData:),
                            (IMP)&InsVoiceOnOpusEncode, (IMP *)&gOrigOpusEncode);
        }
        Class recCls = NSClassFromString(@"MJVoiceInputRecorder");
        if (recCls && [recCls instancesRespondToSelector:@selector(outputPcmBuffer:bufferSize:)]) {
            MSHookMessageEx(recCls, @selector(outputPcmBuffer:bufferSize:),
                            (IMP)&InsVoiceOnRecorderPcm, (IMP *)&gOrigOutputPcm);
        }
        Class svcCls = NSClassFromString(@"CommonVoiceRecordAudioService");
        if (svcCls) {
            if ([svcCls instancesRespondToSelector:@selector(appendPcmToRecordFile:)]) {
                MSHookMessageEx(svcCls, @selector(appendPcmToRecordFile:),
                                (IMP)&InsVoiceOnAppendPcm, (IMP *)&gOrigAppendPcm);
            }
            if ([svcCls instancesRespondToSelector:@selector(finishRecordFile)]) {
                MSHookMessageEx(svcCls, @selector(finishRecordFile),
                                (IMP)&InsVoiceOnFinishFile, (IMP *)&gOrigFinishFile);
            }
        }
        MSHookMessageEx(cls, @selector(OnPartSent:ErrNo:),
                        (IMP)&InsVoiceOnPartSent, (IMP *)&gOrigOnPartSent);
        if ([cls instancesRespondToSelector:@selector(OnRecorderPart:Offset:Len:EndFlag:ForceDelete:Duration:)]) {
            MSHookMessageEx(cls, @selector(OnRecorderPart:Offset:Len:EndFlag:ForceDelete:Duration:),
                            (IMP)&InsVoiceOnRecorderPart, (IMP *)&gOrigOnPart);
        }
        if ([cls instancesRespondToSelector:@selector(GetTmpAudio:)]) {
            MSHookMessageEx(cls, @selector(GetTmpAudio:),
                            (IMP)&InsVoiceOnGetTmpAudio, (IMP *)&gOrigGetTmpAudio);
        }
        if ([cls instancesRespondToSelector:@selector(OnRecorderEndRecording:)]) {
            MSHookMessageEx(cls, @selector(OnRecorderEndRecording:),
                            (IMP)&InsVoiceOnRecorderEnd, (IMP *)&gOrigOnRecorderEnd);
        }
        MSHookMessageEx(cls, @selector(onCdnUploadFail:),
                        (IMP)&InsVoiceOnUploadFail, (IMP *)&gOrigOnUploadFail);
        gHookInstalled = (gOrigOnPcm != NULL);
        [InsConfig log:[NSString stringWithFormat:
            @"语音：hook 装好（PCM %@ / 录音器 %@ / Silk %@ / MJSilk %@ / Opus %@ / 录音文件 %@ / PartSent %@ / UploadFail %@ / OnRecorderPart %@ / GetTmpAudio %@ / OnRecorderEnd %@）",
            gOrigOnPcm ? @"ok" : @"失败",
            gOrigOutputPcm ? @"ok" : @"无此类",
            gOrigSilkEncode ? @"ok" : @"无此类",
            gOrigMJSilkEncode ? @"ok" : @"无此类",
            gOrigOpusEncode ? @"ok" : @"无此类",
            gOrigAppendPcm ? @"ok" : @"无此类",
            gOrigOnPartSent ? @"ok" : @"失败",
            gOrigOnUploadFail ? @"ok" : @"失败",
            gOrigOnPart ? @"ok" : @"无此类",
            gOrigGetTmpAudio ? @"ok" : @"无此类",
            gOrigOnRecorderEnd ? @"ok" : @"无此类"]];
    });
}

@end
