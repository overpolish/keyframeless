/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKOSCVisibilityModel.h"

const float kKKOSCGhostAlpha = 0.3f;

BOOL KKOSCVisibilityPeek(KKOSCVisibilityState s) {
  return s.masterOff && s.revealActive;
}

BOOL KKOSCVisibilityEnabled(KKOSCVisibilityState s, BOOL individuallyHidden) {
  return !s.masterOff && !individuallyHidden;
}

BOOL KKOSCVisibilityShown(KKOSCVisibilityState s, BOOL individuallyHidden) {
  if (s.locked)
    return NO;
  if (s.masterOff)
    return s.revealActive && !individuallyHidden;
  return !individuallyHidden || s.revealActive;
}

BOOL KKOSCVisibilityRevealEligible(KKOSCVisibilityState s,
                                   BOOL individuallyHidden) {
  return s.masterOff ? !individuallyHidden : individuallyHidden;
}

float KKOSCVisibilityGhostAlpha(KKOSCVisibilityState s, BOOL userHidden) {
  if (KKOSCVisibilityPeek(s))
    return 1.0f;
  return userHidden ? kKKOSCGhostAlpha : 1.0f;
}

BOOL KKOSCLabelHiddenInSet(NSSet<NSString *> *set, NSString *label) {
  if (!set || !label)
    return NO;
  if ([set containsObject:label])
    return YES;
  NSRange dot = [label rangeOfString:@"." options:NSBackwardsSearch];
  return dot.location != NSNotFound &&
         [set containsObject:[label substringToIndex:dot.location]];
}
