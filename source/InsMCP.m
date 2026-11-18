#import "InsMCP.h"
#import "InsConfig.h"

static InsMCP *gInstance = nil;

@implementation InsMCP {
    NSString *_sid;
    NSURLSession *_http;
    NSLock *_lock;
}

+ (InsMCP *)shared {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gInstance = [[InsMCP alloc] init];
        gInstance->_lock = [NSLock new];
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 30;
        gInstance->_http = [NSURLSession sessionWithConfiguration:config];
    });
    return gInstance;
}

- (NSURL *)endpoint {
    NSString *url = [InsConfig shared].mcpURL;
    return [NSURL URLWithString:(url.length ? url : @"http://127.0.0.1:8090/mcp")];
}

/// 单次请求，返回 body JSON + 响应头
- (NSDictionary *)post:(NSDictionary *)body withSession:(BOOL)useSession error:(NSError **)error {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[self endpoint]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json, text/event-stream" forHTTPHeaderField:@"Accept"];
    if (useSession && _sid) {
        [request setValue:_sid forHTTPHeaderField:@"Mcp-Session-Id"];
    }
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    __block NSData *data = nil;
    __block NSHTTPURLResponse *response = nil;
    __block NSError *failure = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [[_http dataTaskWithRequest:request
                  completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            data = d; response = (id)r; failure = e;
            dispatch_semaphore_signal(semaphore);
        }] resume];
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(35 * NSEC_PER_SEC))) != 0) {
        if (error) *error = [NSError errorWithDomain:@"Insomnia" code:-1
                                            userInfo:@{NSLocalizedDescriptionKey: @"MCP 请求超时"}];
        return nil;
    }
    if (failure) {
        if (error) *error = failure;
        return nil;
    }

    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *payload = text;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"data: "]) payload = [line substringFromIndex:6];
    }
    id json = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding]
                                              options:0 error:nil];
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"json"] = json ?: (id)@{};
    result[@"status"] = @(response.statusCode);
    result[@"session"] = response.allHeaderFields[@"Mcp-Session-Id"] ?: @"";
    return result;
}

- (BOOL)handshake:(NSError **)error {
    NSDictionary *init = [self post:@{@"jsonrpc": @"2.0", @"id": @(1), @"method": @"initialize",
                                      @"params": @{@"protocolVersion": @"2025-06-18",
                                                   @"capabilities": @{},
                                                   @"clientInfo": @{@"name": @"Insomnia",
                                                                   @"version": @"1"}}}
                          withSession:NO error:error];
    if (!init) return NO;
    NSString *sid = init[@"session"];
    if (!sid.length) {
        if (error) *error = [NSError errorWithDomain:@"Insomnia" code:-2
                                            userInfo:@{NSLocalizedDescriptionKey: @"MCP 未返回会话 ID"}];
        return NO;
    }
    _sid = sid;
    [self post:@{@"jsonrpc": @"2.0", @"method": @"notifications/initialized"}
        withSession:YES error:NULL];
    return YES;
}

- (NSDictionary *)callTool:(NSString *)name args:(NSDictionary *)args error:(NSError **)error {
    [_lock lock];
    if (!_sid) {
        if (![self handshake:error]) { [_lock unlock]; return nil; }
    }
    NSDictionary *wrapper = [self post:@{@"jsonrpc": @"2.0", @"id": @(9), @"method": @"tools/call",
                                        @"params": @{@"name": name, @"arguments": args ?: @{}}}
                        withSession:YES error:error];
    if (!wrapper) { [_lock unlock]; return nil; }

    // 会话过期时重建一次
    NSDictionary *json = wrapper[@"json"];
    if ([wrapper[@"status"] integerValue] == 404 || [json[@"error"] isKindOfClass:[NSDictionary class]]) {
        _sid = nil;
        if ([self handshake:error]) {
            wrapper = [self post:@{@"jsonrpc": @"2.0", @"id": @(9), @"method": @"tools/call",
                                   @"params": @{@"name": name, @"arguments": args ?: @{}}}
                    withSession:YES error:error];
            json = wrapper[@"json"];
        }
    }
    [_lock unlock];

    id result = json[@"result"];
    if (![result isKindOfClass:[NSDictionary class]]) {
        NSString *reason = [json[@"error"][@"message"] description] ?: @"无结果";
        if (error) *error = [NSError errorWithDomain:@"Insomnia" code:-3
                                            userInfo:@{NSLocalizedDescriptionKey: reason}];
        return nil;
    }
    NSMutableArray *contents = [NSMutableArray array];
    for (id item in result[@"content"]) {
        if ([item isKindOfClass:[NSDictionary class]]) [contents addObject:item];
    }
    return @{@"content": contents, @"isError": result[@"isError"] ?: @NO};
}

- (NSString *)textOfTool:(NSString *)name args:(NSDictionary *)args error:(NSError **)error {
    NSDictionary *result = [self callTool:name args:args error:error];
    for (NSDictionary *item in result[@"content"]) {
        if ([item[@"type"] isEqual:@"text"]) return item[@"text"];
    }
    return nil;
}

- (NSData *)imageOfTool:(NSString *)name args:(NSDictionary *)args error:(NSError **)error {
    NSDictionary *result = [self callTool:name args:args error:error];
    for (NSDictionary *item in result[@"content"]) {
        if ([item[@"type"] isEqual:@"image"]) {
            return [[NSData alloc] initWithBase64EncodedString:item[@"data"] ?: @"" options:0];
        }
    }
    return nil;
}

- (NSString *)shell:(NSString *)command error:(NSError **)error {
    NSString *text = [self textOfTool:@"run_command" args:@{@"command": command, @"timeout": @25} error:error];
    id json = text.length ? [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
                                                             options:0 error:nil] : nil;
    if ([json isKindOfClass:[NSDictionary class]] && [json[@"output"] isKindOfClass:[NSString class]]) {
        return json[@"output"];
    }
    return text;
}

- (NSDictionary *)uiElements {
    NSString *text = [self textOfTool:@"get_ui_elements" args:@{@"max_elements": @120} error:NULL];
    id json = text.length ? [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding]
                                                            options:0 error:nil] : nil;
    NSArray *elements = [json isKindOfClass:[NSDictionary class]] ? json[@"elements"] : nil;
    return elements ? @{@"elements": elements} : nil;
}

/// 大文件走原始 HTTP 下载接口，避免 base64 体积上限
- (NSData *)download:(NSString *)path error:(NSError **)error {
    NSString *base = [InsConfig shared].mcpURL ?: @"";
    NSRange cut = [base rangeOfString:@"/mcp"];
    NSString *root = cut.location != NSNotFound ? [base substringToIndex:cut.location] : base;
    NSString *encoded = [path stringByAddingPercentEncodingWithAllowedCharacters:
                         [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/download_file?path=%@", root, encoded]];

    __block NSData *data = nil;
    __block NSError *failure = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [[_http dataTaskWithURL:url completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
            data = d; failure = e;
            dispatch_semaphore_signal(semaphore);
        }] resume];
    if (dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC))) != 0) {
        if (error) *error = [NSError errorWithDomain:@"Insomnia" code:-4
                                            userInfo:@{NSLocalizedDescriptionKey: @"下载超时"}];
        return nil;
    }
    if (failure || data.length < 1024) {
        if (error) *error = failure ?: [NSError errorWithDomain:@"Insomnia" code:-5
                                                       userInfo:@{NSLocalizedDescriptionKey: @"下载内容过小"}];
        return nil;
    }
    return data;
}

@end
