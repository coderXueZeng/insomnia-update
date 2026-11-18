#import <Foundation/Foundation.h>

@interface InsMemory : NSObject

+ (NSDictionary *)load:(NSString *)wxid;
+ (void)save:(NSDictionary *)memory for:(NSString *)wxid;
+ (void)reset:(NSString *)wxid;

/// 新消息实时落库（增量记忆）
+ (void)recordMessage:(NSString *)wxid text:(NSString *)text me:(BOOL)me time:(uint32_t)time name:(NSString *)name;

/// 回复时拼进上下文的记忆块
+ (NSString *)contextBlockForTalker:(NSString *)wxid;

/// —— 人称口径：所有喂给模型的聊天文本与提示词都走这里 ——
/// 账号主人在叙述里的称谓，默认「你」，可在 config.json 的 selfAlias 改成对方对自己的称呼
+ (NSString *)selfLabel;
/// 对方的称谓：优先会话备注/昵称，拿不到退回「对方」/「群里其他人」
+ (NSString *)partnerLabelForTalker:(NSString *)wxid;
/// 统一的第三人称叙述规则，注入所有涉及聊天内容的 system / user 提示词
+ (NSString *)roleRulesForTalker:(NSString *)wxid;
/// 一条消息的说话人标签；群聊可传逐条记下的发言人
+ (NSString *)speakerLabelForMe:(BOOL)me talker:(NSString *)wxid speakerName:(NSString *)speakerName;
/// 把旧口径的摘要/要点按新称谓重写，不重跑历史同步
+ (void)rewriteSummaryForTalker:(NSString *)wxid
                     completion:(void (^)(NSString *summary, NSError *error))completion;

+ (BOOL)isSyncing:(NSString *)wxid;
/// 定时进度汇报用：当前正在同步的会话数、所有会话的同步概况
+ (NSUInteger)syncingCount;
+ (NSArray<NSDictionary *> *)allSummaries;

/// 记忆索引：所有同步过的会话 → @{ @"wxid", @"name", @"scanned" }，用于「按备注名找会话」
+ (NSArray<NSDictionary *> *)nameIndex;

/// 问题里提到了别的联系人时，把那个会话的记忆也带上；没有命中返回空串
+ (NSString *)crossMemoryForQuestion:(NSString *)text excludeTalker:(NSString *)talker;

/// 全量同步该联系人的历史，进度与结果通过回调返回（回调在后台线程）
+ (void)syncTalker:(NSString *)wxid
              name:(NSString *)name
          progress:(void (^)(NSString *line))progress
        completion:(void (^)(NSString *result, NSError *error))completion;

@end
