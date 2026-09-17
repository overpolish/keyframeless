/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <FxPlug/FxPlugSDK.h>
#import "KFPropertyLane.h"
@import MotionTiming;

// Cached-snapshot editing shared by cross-property linking and endpoint
// matching. Every read uses the disposable inspector cache rather than native
// key enumeration, and callers own the host action and undo group.

// Metadata keeps the existing key times, linking may add keys but never
// removes or moves one, and structural edits verify the host key count first.
typedef NS_ENUM(NSUInteger, KFNativeEditKind) {
  KFNativeEditMetadata,
  KFNativeEditLink,
  KFNativeEditStructural
};


NSArray<NSDictionary *> *KFEntries(id<PROAPIAccessing> manager, UInt32 parameter);
CMTime KFTime(NSDictionary *entry);
BOOL KFSame(CMTime a, CMTime b);
NSDictionary *KFAt(NSArray *entries, CMTime time);
// Evaluated value at a time, with no key required there.
id KFSample(id<PROAPIAccessing> manager, UInt32 parameter, CMTime time);

// Rebuilds a pose with its own values, marking it authored.
id KFReplace(id old, KFPoseTiming *timing, MTEasing easing, MTAddedMotion motion);
// Editable components of a pose.
NSArray<NSNumber *> *KFValues(id pose);
id KFPoseWithValues(id old, NSArray<NSNumber *> *values, KFPoseTiming *timing,
                    MTEasing easing, MTAddedMotion motion);
NSDictionary *KFEntry(id pose, CMTime time, NSDictionary *old);
NSArray *KFReplacing(NSArray *entries, NSDictionary *before, NSDictionary *after);

// Writes the prepared snapshots, recovering the touched lanes on failure.
BOOL KFApply(id<PROAPIAccessing> manager,
             NSDictionary<NSNumber *, NSArray *> *after, KFNativeEditKind kind);
