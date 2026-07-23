/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KeyframelessKit.h>

#import "MirageTypes.h"

NS_ASSUME_NONNULL_BEGIN

// The -pluginState: blob is the ONLY channel from -pluginState: (where the
// parameter APIs resolve) to -renderDestinationImage: (where they do not).
// Layout: [uint32 sampleCount][KKMotionBlurState][MiragePluginState x count]
// [code sections], each section as [uint32 nameLen][name UTF8][uint32
// codeLen][code UTF8], names identifying the pass ("Image", "Common",
// "Buffer A"...). Encode and decode both live in this file so the byte layout
// has exactly one owner - nothing outside it may assume offsets.

/// Pack the full render state. `states` holds `sampleCount` motion-blur
/// sub-frame samples (sample 0 = the render time); the shader source sections
/// come from `timeline`'s code lane (absent lane => the baked default seeds
/// "Image", present-but-empty => passthrough, nothing written).
NSData *MirageStateBlobEncode(const KKMotionBlurState *mbState,
                              const MiragePluginState *states,
                              NSInteger sampleCount,
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

NS_ASSUME_NONNULL_END
