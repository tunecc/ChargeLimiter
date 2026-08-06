#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLAppSettingsStore : NSObject

+ (instancetype)shared;

- (NSInteger)integerForKey:(NSString*)key defaultValue:(NSInteger)def;
- (BOOL)setIntegerForKey:(NSString*)key value:(NSInteger)value error:(NSError**)error;
- (BOOL)migrateIfNeeded:(NSError**)error;

@end

NS_ASSUME_NONNULL_END