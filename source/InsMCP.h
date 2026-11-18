#import <Foundation/Foundation.h>

@interface InsMCP : NSObject

+ (InsMCP *)shared;

- (NSDictionary *)callTool:(NSString *)name args:(NSDictionary *)args error:(NSError **)error;
- (NSString *)textOfTool:(NSString *)name args:(NSDictionary *)args error:(NSError **)error;
- (NSData *)imageOfTool:(NSString *)name args:(NSDictionary *)args error:(NSError **)error;
- (NSData *)download:(NSString *)path error:(NSError **)error;
- (NSDictionary *)uiElements;
- (NSString *)shell:(NSString *)command error:(NSError **)error;

@end
