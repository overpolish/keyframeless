/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFKeyposeEdits.h"
#import "KFCreationDefaults.h"
#import "KFMatchEndpoints.h"
#import "KFNativeEdits.h"
#import "KFNativeLinks_Private.h"

static BOOL KFKeyposeError(NSError **error, NSString *message) {
  if (error)
    *error = [NSError errorWithDomain:FxPlugErrorDomain
                                 code:kFxError_InvalidParameter
                             userInfo:@{NSLocalizedDescriptionKey : message}];
  return NO;
}

// Endpoints are positional, so adding, deleting or moving a first or last key
// can leave a matched property paired with the wrong ones.
static void KFRepairMatch(id<PROAPIAccessing> m,
                          NSMutableDictionary<NSNumber *, NSArray *> *after) {
  for (NSNumber *p in after.allKeys) {
    if (!KFPropertyMatchEnabled(m, p.unsignedIntValue))
      continue;
    NSArray *paired = KFMatchedEntries(m, p.unsignedIntValue, after[p]);
    if (paired)
      after[p] = paired;
  }
}
static BOOL KFHasCollision(NSArray *entries) {
  for (NSUInteger i = 1; i < entries.count; i++)
    if (KFSame(KFTime(entries[i - 1]), KFTime(entries[i])))
      return YES;
  return NO;
}

BOOL KFAddKeypose(id<PROAPIAccessing> m, UInt32 parameter, CMTime time,
                  NSError **error) {
  if (!CMTIME_IS_NUMERIC(time))
    return KFKeyposeError(error, @"There is no playhead time to add a keypose at");
  NSArray<NSDictionary *> *entries = KFEntries(m, parameter);
  if (!entries.count)
    return KFKeyposeError(error, @"That property has no value to add a keypose from");
  if (KFAt(entries, time))
    return KFKeyposeError(error, @"There is already a keypose here");
  id sample = KFSample(m, parameter, time);
  if (!sample)
    return KFKeyposeError(error, @"Unable to evaluate that property at the playhead");
  // The sample carries the curve's value with neutral timing, so the new key
  // takes the creation preferences every other new key receives.
  NSMutableDictionary *after = [@{
    @(parameter) : KFReplacing(entries, nil,
                               KFEntry(KFPoseWithCreationDefaults(sample), time, nil))
  } mutableCopy];
  KFRepairMatch(m, after);
  return KFApply(m, after, KFNativeEditStructural) ||
         KFKeyposeError(error, @"Unable to add the keypose");
}

BOOL KFDeleteKeypose(id<PROAPIAccessing> m, UInt32 parameter, CMTime time,
                     NSError **error) {
  NSArray<NSDictionary *> *entries = KFEntries(m, parameter);
  NSDictionary *entry = KFAt(entries, time);
  if (!entry)
    return KFKeyposeError(error, @"There is no keypose here to delete");
  if (entries.count < 2)
    return KFKeyposeError(
        error, @"A property keeps its last keypose; Reset Parameter clears it");
  NSMutableDictionary *after =
      [@{@(parameter) : KFReplacing(entries, entry, nil)} mutableCopy];
  KFRepairMatch(m, after);
  return KFApply(m, after, KFNativeEditStructural) ||
         KFKeyposeError(error, @"Unable to delete the keypose");
}

BOOL KFMoveKeypose(id<PROAPIAccessing> m, UInt32 parameter, CMTime from,
                   CMTime to, NSError **error) {
  if (!CMTIME_IS_NUMERIC(to))
    return KFKeyposeError(error, @"That is not a time a keypose can move to");
  NSArray<NSDictionary *> *entries = KFEntries(m, parameter);
  NSDictionary *entry = KFAt(entries, from);
  if (!entry)
    return KFKeyposeError(error, @"There is no keypose here to move");
  if (KFSame(from, to))
    return YES;
  NSMutableDictionary<NSNumber *, NSArray *> *after = [NSMutableDictionary new];
  after[@(parameter)] =
      KFReplacing(entries, entry, KFEntry(entry[@"pose"], to, entry));
  NSString *link = KFLink(entry[@"pose"]);
  if (link.length)
    for (NSDictionary *member in KFMembers(m, link)) {
      NSNumber *p = member[@"parameter"];
      if (p.unsignedIntValue == parameter)
        continue;
      NSArray *lane = after[p] ?: KFEntries(m, p.unsignedIntValue);
      NSDictionary *partner = KFAt(lane, KFTime(member[@"entry"]));
      if (!partner)
        continue;
      after[p] = KFReplacing(lane, partner, KFEntry(partner[@"pose"], to, partner));
    }
  for (NSNumber *p in after)
    if (KFHasCollision(after[p]))
      return KFKeyposeError(error, @"That would land on an existing keypose");
  KFRepairMatch(m, after);
  return KFApply(m, after, KFNativeEditStructural) ||
         KFKeyposeError(error, @"Unable to move the keypose");
}
