/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

#import "MirageAudioProps.h"
#import "MirageColorProps.h"
#import "MirageOSCBlock.h"
#import "MirageScalarProps.h"

NS_ASSUME_NONNULL_BEGIN

/// The single parse of a shader source. Every directive consumer (lane
/// catalog, transpiler wrapper, render pool fill, OSC, mini viewer,
/// validation, inspector) reads this model instead of re-scanning the source;
/// instances are immutable and cached by source (bounded LRU), so asking for
/// the same source twice is a dictionary hit, not a regex pass.
///
/// Pool offsets are CANONICAL: colours first, then scalars, then audio -
/// exactly the layout of the transpiled uniform block. Consumers that only
/// need names / labels / defaults read the same structs and ignore the
/// offsets.
@interface MirageShaderModel : NSObject

+ (instancetype)modelForSource:(NSString *_Nullable)source;

@property(nonatomic, readonly, copy) NSString *source;

@property(nonatomic, readonly) int colorCount;
- (const MirageColorProp *)colorProps;
/// vec4s the colour props occupy = the scalars' pool base.
@property(nonatomic, readonly) int colorPoolUsed;

@property(nonatomic, readonly) int scalarCount;
- (const MirageScalarProp *)scalarProps;
@property(nonatomic, readonly) int scalarPoolUsed;

@property(nonatomic, readonly) int audioCount;
- (const MirageAudioProp *)audioProps;
@property(nonatomic, readonly) int audioPoolUsed;

/// The unified OSC declaration list: every inline `osc=` directive opt-in
/// expanded to a standard `@osc` block (sugar first, mirroring the checklist's
/// source order), then the authored `// @osc` blocks. An authored block that
/// binds a uniform wins over that uniform's inline sugar. This is the ONLY
/// place either syntax becomes an OSC declaration - consumers read blocks,
/// never re-derive from the prop fields.
@property(nonatomic, readonly) int oscBlockCount;
- (const MirageOSCBlock *)oscBlocks;

/// The unified OSC declaration bound to `uniformName` (sugar or authored), or
/// NULL when the uniform declares none. THE runtime authority for a uniform's
/// on-screen control - never re-read the directive's raw `osc=` parse fields
/// outside the model/validation.
- (const MirageOSCBlock *)oscBlockForUniform:(const char *)uniformName;

/// Fill the colour pool (the transpiled block's std140 tail) from the model's
/// `// #color` properties, reading lane values via `valuesForLabel` (label ->
/// [r,g,b,a] or nil). Single props write one vec4; array props write N
/// swatches (fallback: default palette) + a count-meta vec4 (fallback:
/// directive default). Zeroes the whole pool first, so call it before the
/// other fills. Returns the vec4 count written; `pool` must hold
/// KK_SHADER_COLOR_POOL vec4s.
- (int)fillColorPool:(vector_float4 *)pool
      valuesForLabel:(NSArray<NSNumber *> * (^)(NSString *))valuesForLabel;

/// Fill the scalar props into the pool (each = one vec4, value in .x) at their
/// canonical offsets. Returns the running total vec4 count (colours +
/// scalars).
- (int)fillScalarPool:(vector_float4 *)pool
       valuesForLabel:(NSArray<NSNumber *> * (^)(NSString *))valuesForLabel;

@end

NS_ASSUME_NONNULL_END
