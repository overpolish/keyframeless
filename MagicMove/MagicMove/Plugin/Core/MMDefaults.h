/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "MMPoseTiming.h"
#import <CoreMedia/CoreMedia.h>

@import MotionTiming;
@import PluginPreferences;
PPDefaultStore *MMDefaultStore(void);
NSString *MMMotionDefaultKey(MTAddedMotion type);
NSDictionary *MMReadDefault(NSString *key);
BOOL MMSaveDefault(NSString *key, NSDictionary *value);
/// On-screen control visibility has no explicit default setting: a new effect
/// starts from whatever was toggled last, so toggling writes the preference.
BOOL MMReadOSCVisibilityDefault(UInt32 parameter);
BOOL MMSaveOSCVisibilityDefault(UInt32 parameter, BOOL visible);
/// Whether a parameter is one of the on-screen control visibility toggles, so
/// callers can persist the preference without repeating the list.
BOOL MMIsOSCVisibilityParameter(UInt32 parameter);
MMPoseTiming *MMTimingWithCreationDefaults(MMPoseTiming *timing);
/// Does not replace defaults during decoding, rendering, or existing-key edits.
BOOL MMIsNewKeyTime(NSArray<NSDictionary *> *entries, CMTime time);
/// Tracks observed snapshots so restored keys do not receive today's
/// preferences.
@interface MMDefaultKeyTracker : NSObject
- (NSArray<NSDictionary *> *)insertionsInEntries:
    (NSArray<NSDictionary *> *)entries;
@end
id MMPoseWithCreationDefaults(id pose);
