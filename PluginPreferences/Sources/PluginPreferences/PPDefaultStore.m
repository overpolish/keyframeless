/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "PluginPreferences.h"
@implementation PPDefaultStore {
  NSUserDefaults *_defaults;
  NSString *_namespace;
}
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults
                       namespace:(NSString *)name {
  NSParameterAssert(defaults && name.length);
  if ((self = [super init])) {
    _defaults = defaults;
    _namespace = [name copy];
  }
  return self;
}
- (NSString *)storageKey:(NSString *)key {
  return [_namespace stringByAppendingFormat:@".%@", key];
}
- (NSDictionary *)valueForKey:(NSString *)key
                      factory:(NSDictionary *)factory
                     validate:(BOOL (^)(NSDictionary *))validate {
  id stored = [_defaults objectForKey:[self storageKey:key]];
  return [stored isKindOfClass:NSDictionary.class] && validate(stored)
             ? stored
             : [factory copy];
}
- (BOOL)setValue:(NSDictionary *)value
          forKey:(NSString *)key
        validate:(BOOL (^)(NSDictionary *))validate {
  if (![value isKindOfClass:NSDictionary.class] || !validate(value) ||
      ![NSPropertyListSerialization
              propertyList:value
          isValidForFormat:NSPropertyListBinaryFormat_v1_0])
    return NO;
  [_defaults setObject:value forKey:[self storageKey:key]];
  return YES;
}
- (void)restoreFactoryForKey:(NSString *)key {
  [_defaults removeObjectForKey:[self storageKey:key]];
}
@end
