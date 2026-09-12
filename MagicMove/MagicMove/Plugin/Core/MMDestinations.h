/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <FxPlug/FxPlugSDK.h>
@import MotionTiming;

NS_ASSUME_NONNULL_BEGIN

// NSData contains MTDurationRecord entries sorted on the host's native clock.
NSData * _Nullable MMReadDestinations(id<PROAPIAccessing> api, UInt32 valueID, UInt32 dataID, NSError * _Nullable * _Nullable error);
NSData * _Nullable MMReadDestinationsFromPrevious(id<PROAPIAccessing> api, UInt32 valueID, NSData *previous, NSError * _Nullable * _Nullable error);
NSData * _Nullable MMReadSavedDestinations(id<PROAPIAccessing> api, UInt32 dataID, NSError * _Nullable * _Nullable error);
BOOL MMDestinationsEqual(NSData * _Nullable a, NSData * _Nullable b);
BOOL MMWriteDestinations(id<PROAPIAccessing> api, UInt32 dataID, NSData *records);
NSInteger MMKeyposeAtTime(NSData *records, CMTime time);
// Incoming timing target: exact destination or next arrival between keys.
// No target at/before the first pose or after the last.
NSInteger MMDestinationAtTime(NSData *records, CMTime time);

// Exact keys own their OUT; between keys, the previous key owns added motion.
NSInteger MMOriginAtTime(NSData *data, CMTime time);

NS_ASSUME_NONNULL_END
