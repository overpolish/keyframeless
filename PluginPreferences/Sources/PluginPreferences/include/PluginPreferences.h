/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Preferences are separate from document values. Use a stable suite per
/// plugin.
@interface PPDefaultStore : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults
                       namespace:(NSString *)name;
/// The caller validates its schema. A rejected stored value falls back as a
/// whole.
- (NSDictionary *)valueForKey:(NSString *)key
                      factory:(NSDictionary *)factory
                     validate:(BOOL (^)(NSDictionary *value))validate;
/// Invalid values leave the saved preference untouched.
- (BOOL)setValue:(NSDictionary *)value
          forKey:(NSString *)key
        validate:(BOOL (^)(NSDictionary *value))validate;
- (void)restoreFactoryForKey:(NSString *)key;
@end
NS_ASSUME_NONNULL_END
