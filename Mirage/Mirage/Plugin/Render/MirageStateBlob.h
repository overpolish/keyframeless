/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMotionBlur.h>
#import <KeyframelessKit/KKTimeline.h>

#import "MirageTypes.h"

NS_ASSUME_NONNULL_BEGIN

// The -pluginState: blob is the ONLY channel from -pluginState: (where the
// parameter APIs resolve) to -renderDestinationImage: (where they do not).
// Layout: [uint32 sampleCount][KKMotionBlurState][MiragePluginState x count]
// [code sections], each section as [uint32 nameLen][name UTF8][uint32
// codeLen][code UTF8], names identifying the pass ("Image", "Common",
// "Buffer A"...). Encode and decode both live in this file so the byte layout
// has exactly one owner - nothing outside it may assume offsets.
//
// SHADER RACK: a rack of two or more entries wraps that body once per entry
// (see MirageStateBlobEncodeRack). The wrapper opens with a magic word no
// legacy blob can begin with, so the two layouts tell themselves apart from
// their first four bytes, and a rack of exactly the implicit sentinel entry
// emits the pre-rack bytes verbatim - the same writer produces both.
//
// The blob is TRANSIENT: it is built in -pluginState:atTime: and consumed by
// the render on the same tick (FCP's callback order is pluginState ->
// scheduleInputs -> render), never persisted and never carried across a
// process. So the layout may change freely - there is no compatibility window
// to honour, only the one build's two ends.

/// Pack the full render state. `states` holds `sampleCount` motion-blur
/// sub-frame samples (sample 0 = the render time); the shader source sections
/// come from `timeline`'s code lane (absent lane => the baked default seeds
/// "Image", present-but-empty => passthrough, nothing written).
NSData *MirageStateBlobEncode(const KKMotionBlurState *mbState,
                              const MiragePluginState *states,
                              NSInteger sampleCount,
                              KKTimeline *_Nullable timeline);

/// One rack entry's contribution: its id, its per-sample states, and its
/// per-sample enabled flags. The code sections are NOT carried here - they are
/// read from the timeline by entry id at encode time, so "what a code lane
/// contributes to the blob" keeps one implementation.
@interface MirageStateBlobEntry : NSObject
/// The rack entry id (`kMirageRackSentinelEntryID` for the legacy entry).
@property(nonatomic, copy) NSString *entryID;
/// `MiragePluginState * sampleCount`, sample 0 = the render time.
@property(nonatomic, strong) NSData *states;
/// One `uint8` per sample, non-zero = enabled. Shorter than the sample count
/// (or empty) reads as the last flag it does carry, then as enabled.
@property(nonatomic, strong) NSData *enabled;
@end

/// Pack a whole rack. `entries` is in RENDER order. A single entry whose id is
/// the sentinel emits `MirageStateBlobEncode`'s bytes exactly - so a project
/// that has never been racked hands the render the blob it always did.
NSData *MirageStateBlobEncodeRack(const KKMotionBlurState *mbState,
                                  NSArray<MirageStateBlobEntry *> *entries,
                                  KKTimeline *_Nullable timeline);

/// Header + base sample (state@0). A nil/short blob decodes as motion blur
/// disabled with one default sample, so render falls back gracefully.
typedef struct MirageStateBlobHeader {
  KKMotionBlurState mbState;
  MiragePluginState base;
  NSInteger sampleCount;
} MirageStateBlobHeader;

MirageStateBlobHeader MirageStateBlobReadHeader(NSData *_Nullable data);

/// Copy all `count` samples (the header's sampleCount) into caller-allocated
/// `outStates`. NO when the blob is shorter than it claims.
BOOL MirageStateBlobReadStates(NSData *data, MiragePluginState *outStates,
                               NSInteger count);

/// The code-sections tail; empty when absent or truncated.
NSDictionary<NSString *, NSString *> *MirageStateBlobReadSections(NSData *data);

/// How many entries the blob carries. 1 for every legacy blob (and for a rack
/// of one), which is what the render branches on: > 1 is the chain.
NSInteger MirageStateBlobEntryCount(NSData *_Nullable data);

/// Entry `index`'s id, or the sentinel for a legacy blob.
NSString *MirageStateBlobEntryIDAtIndex(NSData *_Nullable data,
                                        NSInteger index);

/// Whether entry `index` is enabled at sub-frame sample `sampleIndex`. A legacy
/// blob - and any entry that carries no flags - is enabled, matching
/// `MirageRackEntryEnabledDefault`.
BOOL MirageStateBlobEntryEnabled(NSData *_Nullable data, NSInteger index,
                                 NSInteger sampleIndex);

/// The three readers above, per entry. Index 0 IS the unindexed reader, so a
/// caller that has not been taught about the rack keeps reading entry 0.
MirageStateBlobHeader MirageStateBlobReadHeaderAtIndex(NSData *_Nullable data,
                                                       NSInteger index);
BOOL MirageStateBlobReadStatesAtIndex(NSData *data, NSInteger index,
                                      MiragePluginState *outStates,
                                      NSInteger count);
NSDictionary<NSString *, NSString *> *
MirageStateBlobReadSectionsAtIndex(NSData *data, NSInteger index);

NS_ASSUME_NONNULL_END
