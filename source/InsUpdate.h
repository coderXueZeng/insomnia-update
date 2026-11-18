#import <Foundation/Foundation.h>

@interface InsUpdate : NSObject

/// 检查清单 → 下载 → sha256 校验 → sudo dpkg 安装 → 自动重启微信。
/// progress 用于过程播报；成功安装时进程会自行退出重启，completion 只在「已是最新/失败/需手动重启」时回调。
+ (void)runWithProgress:(void (^)(NSString *line))progress
             completion:(void (^)(NSString *result, NSError *error))completion;

/// 手动兜底：直接装一个 deb 直链（配置丢了、清单地址丢了也能自救）。
+ (void)installFromURL:(NSString *)url
              progress:(void (^)(NSString *line))progress
            completion:(void (^)(NSString *result, NSError *error))completion;

@end