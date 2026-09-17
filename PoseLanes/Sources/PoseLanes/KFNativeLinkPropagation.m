/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFMatchEndpoints.h"
#import "KFNativeEdits.h"
#import "KFNativeLinks.h"
#import "KFNativeLinks_Private.h"

// A timing edit reaches its link partners and, for a matched property, the
// opposite endpoint, transitively. Each edge carries only the settings it owns,
// so values mirror across a match but never across a link.
typedef struct {
  BOOL duration, available, amount, speed, easing, motion, values;
} KFEditMask;
static const KFEditMask KFMaskAll = {YES, YES, YES, YES, YES, YES, YES};
static const KFEditMask KFMaskLink = {YES, YES, YES, YES, YES, YES, NO};
// Matching pairs the incoming transitions of K2 and Kn, and the values of K1
// and Kn. Added Motion belongs to the key preceding a gap, so it never crosses.
static const KFEditMask KFMaskMatchTransition = {YES, YES, NO, NO, YES, NO, NO};
static const KFEditMask KFMaskMatchValue = {NO, NO, NO, NO, NO, NO, YES};
static KFEditMask KFMaskIntersect(KFEditMask a, KFEditMask b) {
  return (KFEditMask){a.duration && b.duration, a.available && b.available,
                      a.amount && b.amount,     a.speed && b.speed,
                      a.easing && b.easing,     a.motion && b.motion,
                      a.values && b.values};
}
static BOOL KFMaskEmpty(KFEditMask m) {
  return !m.duration && !m.available && !m.amount && !m.speed && !m.easing &&
         !m.motion && !m.values;
}
@interface KFEditNode : NSObject
@property UInt32 parameter;
@property(strong) NSDictionary *entry;
@property KFEditMask mask;
@end
@implementation KFEditNode
@end
static KFEditNode *KFNode(UInt32 parameter, NSDictionary *entry,
                          KFEditMask mask) {
  KFEditNode *node = [KFEditNode new];
  node.parameter = parameter;
  node.entry = entry;
  node.mask = mask;
  return node;
}
static NSString *KFNodeKey(KFEditNode *node) {
  return [NSString stringWithFormat:@"%u@%.6f", node.parameter,
                                    CMTimeGetSeconds(KFTime(node.entry))];
}
// Adopts whatever the seed edit changed and this edge allows, leaving every
// other setting as this pose had it.
static id KFUpdatedPose(id old, id before, id after, KFEditMask mask) {
  KFPoseTiming *own = [old timing], *was = [before timing],
               *now = [after timing];
  KFPoseTiming *timing = [[[[KFPoseTiming alloc]
      initWithDuration:mask.duration && now.duration != was.duration
                           ? now.duration
                           : own.duration
             available:mask.available && now.available != was.available
                           ? now.available
                           : own.available
                amount:mask.amount && now.amount != was.amount ? now.amount
                                                               : own.amount
                 speed:mask.speed && now.speed != was.speed ? now.speed
                                                            : own.speed]
      timingByCopyingMotionOptionsFrom:own] timingByReplacingLinkID:KFLink(old)];
  MTEasing easing = mask.easing && [after easing] != [before easing]
                        ? [after easing]
                        : [old easing];
  MTAddedMotion motion =
      mask.motion && [after addedMotion] != [before addedMotion]
          ? [after addedMotion]
          : [old addedMotion];
  if (mask.values && ![KFValues(before) isEqual:KFValues(after)])
    return KFPoseWithValues(old, KFValues(after), timing, easing, motion);
  return KFReplace(old, timing, easing, motion);
}
// The keys this one pairs with while its property matches its endpoints.
static void KFEnqueueMatched(id<PROAPIAccessing> m, KFEditNode *node,
                             NSMutableArray<KFEditNode *> *queue) {
  if (!KFPropertyMatchEnabled(m, node.parameter))
    return;
  NSArray *entries = KFEntries(m, node.parameter);
  if (entries.count < 2 || !entries.firstObject[@"nativeTime"])
    return;
  CMTime time = KFTime(node.entry);
  NSDictionary *first = entries.firstObject, *last = entries.lastObject;
  KFEditMask values = KFMaskIntersect(node.mask, KFMaskMatchValue);
  if (!KFMaskEmpty(values)) {
    if (KFSame(time, KFTime(first)))
      [queue addObject:KFNode(node.parameter, last, values)];
    else if (KFSame(time, KFTime(last)))
      [queue addObject:KFNode(node.parameter, first, values)];
  }
  // Two keys share one incoming transition, so there is nothing to pair it with.
  if (entries.count < 3)
    return;
  KFEditMask transition = KFMaskIntersect(node.mask, KFMaskMatchTransition);
  if (KFMaskEmpty(transition))
    return;
  NSDictionary *second = entries[1];
  if (KFSame(time, KFTime(second)))
    [queue addObject:KFNode(node.parameter, last, transition)];
  else if (KFSame(time, KFTime(last)))
    [queue addObject:KFNode(node.parameter, second, transition)];
}
BOOL KFWriteNativeLinkedPose(id<PROAPIAccessing> m, UInt32 parameter,
                             CMTime time, id pose) {
  NSDictionary *entry = KFAt(KFEntries(m, parameter), time);
  if (!entry)
    return NO;
  id before = entry[@"pose"];
  NSMutableDictionary *after = [NSMutableDictionary new];
  NSMutableSet *seen = [NSMutableSet new];
  NSMutableArray<KFEditNode *> *queue =
      [NSMutableArray arrayWithObject:KFNode(parameter, entry, KFMaskAll)];
  while (queue.count) {
    KFEditNode *node = queue.lastObject;
    [queue removeLastObject];
    NSString *key = KFNodeKey(node);
    if ([seen containsObject:key])
      continue;
    [seen addObject:key];
    id updated = node.entry == entry && node.parameter == parameter
                     ? pose
                     : KFUpdatedPose(node.entry[@"pose"], before, pose,
                                     node.mask);
    NSArray *entries = after[@(node.parameter)] ?: KFEntries(m, node.parameter);
    after[@(node.parameter)] =
        KFReplacing(entries, node.entry,
                    KFEntry(updated, KFTime(node.entry), node.entry));
    KFEditMask linked = KFMaskIntersect(node.mask, KFMaskLink);
    if (!KFMaskEmpty(linked))
      for (NSDictionary *member in KFMembers(m, KFLink(node.entry[@"pose"])))
        [queue addObject:KFNode([member[@"parameter"] unsignedIntValue],
                                member[@"entry"], linked)];
    KFEnqueueMatched(m, node, queue);
  }
  return KFApply(m, after, KFNativeEditMetadata);
}
