/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "KFPoseTiming.h"
#import <CoreMedia/CoreMedia.h>
@import MotionTiming;

// Creation and Added Motion preferences. The plugin owns the store, the
// validation and the factory values; this model only reads a saved value or
// writes one back, keyed by the names below.
@protocol KFDefaults <NSObject>
- (nullable NSDictionary *)defaultForKey:(nonnull NSString *)key;
- (BOOL)setDefault:(nonnull NSDictionary *)value forKey:(nonnull NSString *)key;
- (BOOL)restoreFactoryDefaultForKey:(nonnull NSString *)key;
@end

NS_ASSUME_NONNULL_BEGIN
void KFSetDefaults(id<KFDefaults> defaults);
FOUNDATION_EXPORT NSString *const KFDurationDefaultKey;
FOUNDATION_EXPORT NSString *const KFEasingDefaultKey;
NSString *KFMotionDefaultKey(MTAddedMotion type);
NSDictionary *KFReadDefault(NSString *key);
BOOL KFSaveDefault(NSString *key, NSDictionary *value);
BOOL KFRestoreFactoryDefault(NSString *key);

KFPoseTiming *KFTimingWithCreationDefaults(KFPoseTiming *timing);
/// Does not replace defaults during decoding, rendering, or existing-key edits.
BOOL KFIsNewKeyTime(NSArray<NSDictionary *> *entries, CMTime time);
/// Tracks observed snapshots so restored keys do not receive today's
/// preferences.
@interface KFDefaultKeyTracker : NSObject
- (NSArray<NSDictionary *> *)insertionsInEntries:(NSArray<NSDictionary *> *)entries;
@end
id KFPoseWithCreationDefaults(id pose);
NS_ASSUME_NONNULL_END
