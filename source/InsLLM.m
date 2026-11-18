#import "InsLLM.h"
#import "InsConfig.h"

/// 把中转站的英文错误翻译成「下一步该干什么」，别让用户对着 HTTP 403 猜
static NSString *InsLLMDescribeFailure(NSInteger status, NSString *raw) {
    NSString *body = raw ?: @"";
    NSString *lower = [body lowercaseString];
    if ([lower rangeOfString:@"group_deleted"].location != NSNotFound) {
        return @"这个 Key 所属的分组已被服务商删除，Key 跟着作废了（服务端原话：API Key 所属分组已删除）。\n"
                "换 Key 才能修：去 api2cn 控制台新建一个 Key，发「@insomnia key <新Key>」，再发「@insomnia 测key」验证。\n"
                "想以后不再被单个 Key 卡死：再配一个「@insomnia key2 <另一个Key>」，主 Key 失效会自动顶上。";
    }
    if (status == 401 || [lower rangeOfString:@"api_key_required"].location != NSNotFound ||
        [lower rangeOfString:@"invalid_api_key"].location != NSNotFound) {
        return @"Key 无效或已失效（401）。发「@insomnia key <新Key>」重写，再发「@insomnia 测key」确认。";
    }
    if (status == 402 || [lower rangeOfString:@"insufficient"].location != NSNotFound ||
        [body rangeOfString:@"余额"].location != NSNotFound) {
        return @"账户额度/余额不足（402）。去服务商控制台充值或换个 Key 后再试。";
    }
    if (status == 403) {
        return @"服务商拒绝这次请求（403）。常见原因：Key 被停用、所属分组被删、这个模型没开通权限。\n"
                "发「@insomnia 测key」看主/备 Key 各自的状态。";
    }
    if (status == 404) {
        return @"接口地址或模型名不对（404）。发「@insomnia model2 <模型名>」换模型，或检查 baseURL。";
    }
    if (status == 429) {
        return @"被限流了（429）。等一分钟再发，或者发「@insomnia model2 <更便宜的模型>」。";
    }
    if (status >= 500) {
        return [NSString stringWithFormat:@"服务商那边故障了（HTTP %ld）。过几分钟再试，跟本机配置无关。", (long)status];
    }
    return nil;
}

static BOOL InsLLMIsKeyFailure(NSError *error) {
    if (!error) return NO;
    NSInteger code = error.code;
    if (code == -30) return YES;                 // 本地判定：Key 为空
    return code == 401 || code == 402 || code == 403;
}

/// 网络层直接失败：超时、连接被重置、切网、没有网络。这类错误换条线路（备用 base）常常就通了
static BOOL InsLLMIsNetworkFailure(NSError *error) {
    if (!error) return NO;
    if ([error.domain isEqualToString:NSURLErrorDomain]) return YES;
    return error.code == -1;   // 本地信号量超时
}

/// 把 NSURLError 翻译成人能看懂的一句话，别再回一句「网络连接已中断」让人干瞪眼
static NSString *InsLLMDescribeNetwork(NSError *error) {
    if (!error) return @"未知错误";
    if (![error.domain isEqualToString:NSURLErrorDomain]) return error.localizedDescription;
    switch (error.code) {
        case NSURLErrorTimedOut:
            return @"请求超时（网络慢或服务商卡住），已自动重试仍然没通";
        case NSURLErrorNetworkConnectionLost:
            return @"网络连接被中断（切 Wi-Fi/蜂窝、锁屏常见），已自动重试仍然没通";
        case NSURLErrorNotConnectedToInternet:
            return @"手机当前没有网络";
        case NSURLErrorCannotFindHost:
        case NSURLErrorCannotConnectToHost:
            return @"接口地址连不上（域名解析或端口不通），检查是否开了代理/VPN";
        case NSURLErrorSecureConnectionFailed:
            return @"HTTPS 握手失败（可能是代理证书问题）";
        default:
            return error.localizedDescription;
    }
}

@implementation InsLLM

+ (NSString *)requestSync:(NSArray *)messages error:(NSError **)error {
    InsConfig *cfg = [InsConfig shared];
    return [self requestSync:messages base:cfg.baseURL key:cfg.apiKey model:cfg.chatModel error:error];
}

+ (NSString *)requestSync:(NSArray *)messages
                     base:(NSString *)base
                      key:(NSString *)key
                    model:(NSString *)model
                    error:(NSError **)error {
    // 没 Key 就别发请求：中转站只会回 401 API_KEY_REQUIRED，用户看不懂是配置问题
    if (!key.length) {
        if (error) *error = [NSError errorWithDomain:@"Insomnia" code:-30
                                            userInfo:@{NSLocalizedDescriptionKey:
            @"聊天 Key 未配置：发 @insomnia setup <恢复串>，或 @insomnia key <sk-...> 单独写"}];
        return nil;
    }
    NSDictionary *body = @{
        @"model": model,
        @"messages": messages,
        @"temperature": @0.7,
        @"stream": @NO,
        // 不显式给上限时部分中转站默认值很小，记忆 JSON 会被拦腰截断导致解析失败
        @"max_tokens": @4096,
    };
    NSString *endpoint = base.length ? base : @"https://api.api2cn.com/v1";
    if ([endpoint hasSuffix:@"/"]) endpoint = [endpoint substringToIndex:endpoint.length - 1];
    if ([endpoint rangeOfString:@"/chat/completions"].location == NSNotFound) {
        endpoint = [endpoint stringByAppendingString:@"/chat/completions"];
    }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 60;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (key.length) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
    }
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:error];
    if (!req.HTTPBody) return nil;

    __block NSData *data = nil;
    __block NSURLResponse *response = nil;
    __block NSError *requestError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        data = d; response = r; requestError = e;
        dispatch_semaphore_signal(sem);
    }] resume];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(70 * NSEC_PER_SEC)))) {
        if (error) *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut
                                            userInfo:@{NSLocalizedDescriptionKey: @"请求超时"}];
        return nil;
    }
    if (requestError) {
        if (error) *error = requestError;
        return nil;
    }
    NSInteger status = [(NSHTTPURLResponse *)response statusCode];
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (status < 200 || status >= 300 || ![json isKindOfClass:[NSDictionary class]]) {
        NSString *detail = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"空响应";
        if (detail.length > 400) detail = [[detail substringToIndex:400] stringByAppendingString:@"…"];
        NSString *friendly = InsLLMDescribeFailure(status, detail);
        if (friendly) {
            [InsConfig log:[NSString stringWithFormat:@"LLM HTTP %ld：%@", (long)status,
                            detail.length > 160 ? [[detail substringToIndex:160] stringByAppendingString:@"…"] : detail]];
        }
        if (error) *error = [NSError errorWithDomain:@"Insomnia" code:status
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                friendly ?: [NSString stringWithFormat:@"HTTP %ld: %@", (long)status, detail]}];
        return nil;
    }
    NSArray *choices = json[@"choices"];
    NSString *content = [choices isKindOfClass:[NSArray class]] && choices.count
        ? choices[0][@"message"][@"content"] : nil;
    if (![content isKindOfClass:[NSString class]] || !content.length) {
        NSString *msg = [json[@"error"][@"message"] isKindOfClass:[NSString class]]
            ? json[@"error"][@"message"] : [json description];
        if (error) *error = [NSError errorWithDomain:@"Insomnia" code:-2
                                            userInfo:@{NSLocalizedDescriptionKey: msg}];
        return nil;
    }
    return [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

+ (NSString *)askSystem:(NSString *)system user:(NSString *)user error:(NSError **)error {
    NSMutableArray *messages = [NSMutableArray array];
    if (system.length) [messages addObject:@{@"role": @"system", @"content": system}];
    [messages addObject:@{@"role": @"user", @"content": user ?: @""}];
    return [self askMessages:messages error:error];
}

+ (NSString *)askMessages:(NSArray *)messages error:(NSError **)error {
    InsConfig *cfg = [InsConfig shared];
    NSError *first = nil;
    NSString *result = [self requestSync:messages error:&first];
    if (result) return result;
    [InsConfig log:[NSString stringWithFormat:@"LLM 首次失败: %@", InsLLMDescribeNetwork(first)]];

    BOOL keyProblem = InsLLMIsKeyFailure(first);
    BOOL networkProblem = InsLLMIsNetworkFailure(first);

    // 备用通道：主 Key 报废（分组被删/停用/欠费）时顶上；
    // 网络层直接断了也顶上——备用通道往往是另一条线路/域名，主域名不通时它能通
    if ((keyProblem || networkProblem) && cfg.apiKey2.length) {
        NSError *backupError = nil;
        NSString *backup = [self requestSync:messages
                                        base:cfg.baseURL2
                                         key:cfg.apiKey2
                                       model:(cfg.chatModel2.length ? cfg.chatModel2 : cfg.chatModel)
                                       error:&backupError];
        if (backup) {
            [InsConfig log:keyProblem ? @"主 Key 失效，已自动切到备用 Key"
                                      : @"主通道网络不通，已自动切到备用通道"];
            return backup;
        }
        [InsConfig log:[NSString stringWithFormat:@"备用通道也失败: %@", InsLLMDescribeNetwork(backupError)]];
    }
    // Key 有问题重试也没用，直接回给用户，省掉几次空等
    if (keyProblem) { if (error) *error = first; return nil; }

    // 手机切网、锁屏、Wi-Fi 抖动都会让请求直接断（NSURLErrorNetworkConnectionLost）。
    // 之前是 1.2s / 2.4s 两次，实测 8 秒内连断三次——退避太短，系统还没重新选好网就又发了。
    // 现在 4 次、1.5 / 4 / 8 / 12 秒，够它把网切回来。
    NSArray<NSNumber *> *waits = @[@1.5, @4.0, @8.0, @12.0];
    NSError *last = first;
    for (NSUInteger i = 0; i < waits.count; i++) {
        usleep((useconds_t)(waits[i].doubleValue * 1000000));
        NSError *next = nil;
        result = [self requestSync:messages error:&next];
        if (result) {
            [InsConfig log:[NSString stringWithFormat:@"LLM 第 %lu 次重试成功", (unsigned long)(i + 2)]];
            return result;
        }
        last = next ?: last;
        [InsConfig log:[NSString stringWithFormat:@"LLM 第 %lu 次重试失败: %@",
                        (unsigned long)(i + 2), InsLLMDescribeNetwork(last)]];
        // 重试过程中又变成 Key/额度问题（比如换了出口 IP 被风控），别继续无意义重试
        if (InsLLMIsKeyFailure(last)) break;
    }
    if (error) {
        // 网络类错误给一句能行动的说明，而不是「网络连接已中断」
        if (InsLLMIsNetworkFailure(last)) {
            *error = [NSError errorWithDomain:last.domain code:last.code
                                     userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"%@。检查网络后再发一次；如果一直这样，发「@insomnia 测key」看主/备通道谁通。",
                 InsLLMDescribeNetwork(last)]}];
        } else {
            *error = last ?: first;
        }
    }
    return nil;
}

+ (NSString *)maskedKey:(NSString *)key {
    if (!key.length) return @"未配置";
    if (key.length <= 12) return [NSString stringWithFormat:@"%@…（%lu 位）",
                                  [key substringToIndex:MIN((NSUInteger)4, key.length)], (unsigned long)key.length];
    return [NSString stringWithFormat:@"%@…%@（%lu 位）",
            [key substringToIndex:6], [key substringFromIndex:key.length - 4], (unsigned long)key.length];
}

+ (NSString *)probeOne:(NSArray *)messages base:(NSString *)base key:(NSString *)key model:(NSString *)model {
    if (!key.length) return @"未配置";
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    NSError *error = nil;
    NSString *answer = [self requestSync:messages base:base key:key model:model error:&error];
    double ms = (CFAbsoluteTimeGetCurrent() - start) * 1000.0;
    if (answer.length) {
        NSString *head = answer.length > 12 ? [[answer substringToIndex:12] stringByAppendingString:@"…"] : answer;
        return [NSString stringWithFormat:@"可用（%.0f ms，回「%@」）", ms, head];
    }
    return [NSString stringWithFormat:@"失败（%.0f ms）\n  %@", ms, error.localizedDescription];
}

+ (NSString *)probeKeyReport {
    InsConfig *cfg = [InsConfig shared];
    NSArray *messages = @[@{ @"role": @"user", @"content": @"只回两个字：在的" }];
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"Key 体检 · 模型 %@\n", cfg.chatModel];
    [out appendFormat:@"- 主 Key %@：%@\n", [self maskedKey:cfg.apiKey],
     [self probeOne:messages base:cfg.baseURL key:cfg.apiKey model:cfg.chatModel]];
    if (cfg.apiKey2.length) {
        NSString *backupModel = cfg.chatModel2.length ? cfg.chatModel2 : cfg.chatModel;
        [out appendFormat:@"- 备用 Key %@：%@\n", [self maskedKey:cfg.apiKey2],
         [self probeOne:messages base:cfg.baseURL2 key:cfg.apiKey2 model:backupModel]];
    } else {
        [out appendString:@"- 备用 Key：未配置（「@insomnia key2 <Key>」可加，主 Key 失效时自动顶上）\n"];
    }
    // 日志里只记结论，不记 Key 本身
    [InsConfig log:@"Key 体检已完成（结果只回给用户）"];
    return out;
}

+ (NSString *)askVision:(NSString *)question image:(NSData *)image error:(NSError **)error {
    return [self askVisionImages:question images:(image.length ? @[image] : @[]) error:error];
}

+ (NSString *)askVisionImages:(NSString *)question images:(NSArray<NSData *> *)images error:(NSError **)error {
    InsConfig *cfg = [InsConfig shared];
    if (!cfg.visionApiKey.length) {
        if (error) *error = [NSError errorWithDomain:@"Insomnia" code:-3
                                            userInfo:@{NSLocalizedDescriptionKey: @"视觉模型 Key 未配置"}];
        return nil;
    }
    NSMutableArray *pics = [NSMutableArray array];
    for (id one in images ?: @[]) {
        if ([one isKindOfClass:[NSData class]] && [one length]) [pics addObject:one];
    }
    NSString *head = question.length ? question : @"描述这张图片的内容";
    if (pics.count > 1) {
        head = [NSString stringWithFormat:@"（共 %lu 张图，按发送顺序排列，第 1 张最早）\n%@",
                (unsigned long)pics.count, head];
    }
    NSMutableArray *content = [NSMutableArray arrayWithObject:@{@"type": @"text", @"text": head}];
    for (NSData *img in pics) {
        NSString *b64 = [img base64EncodedStringWithOptions:0];
        [content addObject:@{@"type": @"image_url",
                             @"image_url": @{@"url": [@"data:image/jpeg;base64," stringByAppendingString:b64]}}];
    }
    NSArray *messages = @[
        @{@"role": @"system", @"content": @"你是微信里的分析助手，用简短口语化中文回答，不要说自己是 AI。"},
        @{@"role": @"user", @"content": content},
    ];
    // 视觉这条也是网络请求，跟主通道一样容易被切网打断；按 1.5 / 4 / 8 秒退避重试三次
    NSArray<NSNumber *> *waits = @[@0.0, @1.5, @4.0, @8.0];
    NSError *last = nil;
    for (NSUInteger i = 0; i < waits.count; i++) {
        if (waits[i].doubleValue > 0) usleep((useconds_t)(waits[i].doubleValue * 1000000));
        NSError *err = nil;
        NSString *result = [self requestSync:messages base:cfg.visionBaseURL key:cfg.visionApiKey
                                       model:cfg.visionModel error:&err];
        if (result) return result;
        last = err ?: last;
        [InsConfig log:[NSString stringWithFormat:@"视觉模型第 %lu 次尝试失败: %@",
                        (unsigned long)(i + 1), InsLLMDescribeNetwork(last)]];
        if (InsLLMIsKeyFailure(last)) break;   // Key/额度问题重试无意义
    }
    if (error) *error = last ?: [NSError errorWithDomain:@"Insomnia" code:-3
                                                userInfo:@{NSLocalizedDescriptionKey: @"视觉模型没有返回内容"}];
    return nil;
}

@end
