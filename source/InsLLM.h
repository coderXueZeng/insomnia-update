#import <Foundation/Foundation.h>

@interface InsLLM : NSObject

+ (NSString *)askSystem:(NSString *)system user:(NSString *)user error:(NSError **)error;
+ (NSString *)askMessages:(NSArray<NSDictionary<NSString *, NSString *> *> *)messages error:(NSError **)error;

/// 走视觉模型通道（MiMo）：image 非空时带图提问，为空时纯文本（链接分析）
+ (NSString *)askVision:(NSString *)question image:(NSData *)image error:(NSError **)error;

/// 多图版本：按数组顺序（＝发送顺序）一起喂给视觉模型，「分析上面这两张图」用
+ (NSString *)askVisionImages:(NSString *)question images:(NSArray<NSData *> *)images error:(NSError **)error;

/// Key 体检：主/备通道各发一句最小请求，报「可用/失败 + 耗时 + 服务端原话」
+ (NSString *)probeKeyReport;

@end
