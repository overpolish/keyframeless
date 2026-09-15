/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <FxPlug/FxPlugSDK.h>
#import "MMPoseTiming.h"
@import MotionTiming;

// Cached-snapshot editing shared by cross-property linking and endpoint
// matching. Every read uses the disposable inspector cache rather than native
// key enumeration, and callers own the host action and undo group.

// Metadata keeps the existing key times, linking may add keys but never
// removes or moves one, and structural edits verify the host key count first.
typedef NS_ENUM(NSUInteger, MMNativeEditKind) {
  MMNativeEditMetadata,
  MMNativeEditLink,
  MMNativeEditStructural
};

// Custom pose properties, in inspector order.
NSArray<NSNumber *> *MMProperties(void);
NSString *MMPropertyDisplayName(UInt32 parameter);

NSArray<NSDictionary *> *MMEntries(id<PROAPIAccessing> manager, UInt32 parameter);
CMTime MMTime(NSDictionary *entry);
BOOL MMSame(CMTime a, CMTime b);
NSDictionary *MMAt(NSArray *entries, CMTime time);
// Evaluated value at a time, with no key required there.
id MMSample(id<PROAPIAccessing> manager, UInt32 parameter, CMTime time);

// Rebuilds a pose of the same class, keeping its values and marking it authored.
id MMReplace(id old, MMPoseTiming *timing, MTEasing easing, MTAddedMotion motion);
// Editable components of a pose, excluding the scale the combined pose still
// carries for the superseded single-lane model.
NSArray<NSNumber *> *MMValues(id pose);
id MMPoseWithValues(id old, NSArray<NSNumber *> *values, MMPoseTiming *timing,
                    MTEasing easing, MTAddedMotion motion);
NSDictionary *MMEntry(id pose, CMTime time, NSDictionary *old);
NSArray *MMReplacing(NSArray *entries, NSDictionary *before, NSDictionary *after);

// Writes the prepared snapshots, recovering the touched lanes on failure.
BOOL MMApply(id<PROAPIAccessing> manager,
             NSDictionary<NSNumber *, NSArray *> *after, MMNativeEditKind kind);
