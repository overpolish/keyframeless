/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFNativeLinks.h"
#import "KFNativeLinks_Private.h"

@implementation KFNativeLinkState
- (instancetype)init {
  if ((self = [super init])) {
    _observed = [NSMutableDictionary new];
    _defaultTrackers=[NSMutableDictionary new];
    _defaultInsertions=[NSMutableArray new];
    _moves = [NSMutableDictionary new];
    _copies = [NSMutableArray new];
    _matchCandidates = [NSMutableSet new];
    _colorSlots = [NSMutableDictionary new];
  }
  return self;
}
@end
KFNativeLinkState *KFState(id manager) {
  static NSMapTable *states;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    states = [NSMapTable weakToStrongObjectsMapTable];
  });
  @synchronized(states) {
    KFNativeLinkState *s = [states objectForKey:manager];
    if (!s) {
      s = [KFNativeLinkState new];
      [states setObject:s forKey:manager];
    }
    return s;
  }
}
void KFPrimeDefaultKeyTracker(id<PROAPIAccessing> manager,UInt32 parameter) {
  KFNativeLinkState *state=KFState(manager);
  @synchronized(state) {
    if (state.defaultTrackers[@(parameter)]) return;
    NSArray *entries=KFEntries(manager,parameter);
    if (!entries) return;
    KFDefaultKeyTracker *tracker=[KFDefaultKeyTracker new];
    [tracker insertionsInEntries:entries];
    state.defaultTrackers[@(parameter)]=tracker;
  }
}
