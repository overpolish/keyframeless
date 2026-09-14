/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "PluginPreferences.h"
#import <assert.h>
int main(void) {
  @autoreleasepool {
    NSString *suite = [@"co.overpolish.preferences.tests."
        stringByAppendingString:NSUUID.UUID.UUIDString];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    @try {
      PPDefaultStore *a = [[PPDefaultStore alloc] initWithDefaults:defaults
                                                         namespace:@"one"];
      PPDefaultStore *b = [[PPDefaultStore alloc] initWithDefaults:defaults
                                                         namespace:@"two"];
      NSDictionary *factory = @{@"amount" : @1, @"speed" : @1};
      BOOL (^valid)(NSDictionary *) = ^BOOL(NSDictionary *v) {
        return v.count == 2 && [v[@"amount"] isKindOfClass:NSNumber.class] &&
               [v[@"speed"] isKindOfClass:NSNumber.class] &&
               [v[@"speed"] doubleValue] > 0;
      };
      assert([[a valueForKey:@"wave" factory:factory
                    validate:valid] isEqual:factory]);
      NSDictionary *chosen = @{@"amount" : @2, @"speed" : @3};
      assert([a setValue:chosen forKey:@"wave" validate:valid]);
      assert([[b valueForKey:@"wave" factory:factory
                    validate:valid] isEqual:factory]);
      assert([[a valueForKey:@"wiggle" factory:factory
                    validate:valid] isEqual:factory]);
      PPDefaultStore *reopened = [[PPDefaultStore alloc]
          initWithDefaults:[[NSUserDefaults alloc] initWithSuiteName:suite]
                 namespace:@"one"];
      assert([[reopened valueForKey:@"wave" factory:factory
                           validate:valid] isEqual:chosen]);
      assert(![a setValue:@{@"speed" : @0} forKey:@"wave" validate:valid]);
      assert([[a valueForKey:@"wave" factory:factory
                    validate:valid] isEqual:chosen]);
      [a restoreFactoryForKey:@"wave"];
      assert([[reopened valueForKey:@"wave" factory:factory
                           validate:valid] isEqual:factory]);
      [defaults setObject:@"broken" forKey:@"one.wave"];
      assert([[a valueForKey:@"wave" factory:factory
                    validate:valid] isEqual:factory]);
    } @finally {
      [defaults removePersistentDomainForName:suite];
    }
    puts("DefaultStoreTests passed");
  }
  return 0;
}
