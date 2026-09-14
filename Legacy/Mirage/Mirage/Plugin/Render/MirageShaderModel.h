/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

#import "MirageAudioProps.h"
#import "MirageBuiltinProps.h"
#import "MirageColorProps.h"
#import "MirageGradientProps.h"
#import "MirageOSCBlock.h"
#import "MirageScalarProps.h"
#import "MirageSlots.h"

NS_ASSUME_NONNULL_BEGIN

/// The instance IDs of one `// #slots` group, in registry (display) order.
/// Supplied by whoever holds the timeline; the model turns them into lane keys
/// and pool positions, so element i of every array in the group is the instance
/// at position i of this list.
typedef NSArray<NSString *> *_Nonnull (^MirageSlotInstancesBlock)(
    NSString *groupName);

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
/// YES when the source declared more controls than fit (the prop cap, or the
/// shared vec4 pool). The extras were dropped; validation surfaces it.
@property(nonatomic, readonly) BOOL scalarTruncated;

@property(nonatomic, readonly) int audioCount;
- (const MirageAudioProp *)audioProps;
@property(nonatomic, readonly) int audioPoolUsed;

@property(nonatomic, readonly) int gradientCount;
- (const MirageGradientProp *)gradientProps;
@property(nonatomic, readonly) int gradientPoolUsed;

/// The `// #slots` groups the source declares, in declaration order, each
/// boxed as a MirageSlotsGroup. THE parse every slot consumer reads - the panel
/// stamping instances, the wrapper emitting arrays, and the pool fill below.
@property(nonatomic, readonly, copy) NSArray<NSValue *> *slotGroups;
/// First vec4 of the injected per-group instance counts, which occupy one vec4
/// each in group order and sit LAST in the pool, after the gradients - so
/// adding slots to a shader cannot move any earlier prop's offset.
@property(nonatomic, readonly) int slotCountPoolBase;
@property(nonatomic, readonly) int slotCountPoolUsed;

/// The opt-in built-in controls (`// #speed`, `// #seed`, `// #grain`). A
/// shader that declares none renders with them neutral: speed 1, offset 0, no
/// grain, and no lanes for any of them.
@property(nonatomic, readonly) MirageBuiltins builtins;

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
///
/// A prop inside a `// #slots` block writes one vec4 PER INSTANCE, in the order
/// `slotInstances` returns, reading each from that instance's lane key. Slots
/// past the live count stay zero, so a shader that loops past its count reads
/// nothing rather than a deleted instance's last colour. `slotInstances` may be
/// nil for a caller with no timeline; every group then has zero instances.
- (int)fillColorPool:(vector_float4 *)pool
      valuesForLabel:(NSArray<NSNumber *> * (^)(NSString *))valuesForLabel
       slotInstances:(MirageSlotInstancesBlock _Nullable)slotInstances;

/// Fill the scalar props into the pool (each = one vec4, value in .x) at their
/// canonical offsets. Returns the running total vec4 count (colours +
/// scalars). Slot props array per instance exactly as the colours do.
- (int)fillScalarPool:(vector_float4 *)pool
       valuesForLabel:(NSArray<NSNumber *> * (^)(NSString *))valuesForLabel
        slotInstances:(MirageSlotInstancesBlock _Nullable)slotInstances;

/// Fill the injected per-group instance counts (one vec4 each, count in .x,
/// clamped to the group's `max=`). LAST of the fills, since the counts sit last
/// in the pool. Returns the final vec4 count to bind.
- (int)fillSlotCountPool:(vector_float4 *)pool
           slotInstances:(MirageSlotInstancesBlock _Nullable)slotInstances;

/// Fill the `// #gradient` props into the pool at their canonical offsets
/// (LAST, after the audio bands): the stop array, the packed midpoints, and the
/// count meta. Lane values arrive as the flat `[position, r, g, b, midpoint]`
/// stop array and are sorted by position on the way in, so the shader's sampler
/// can assume monotonic stops. Returns the running total vec4 count.
- (int)fillGradientPool:(vector_float4 *)pool
         valuesForLabel:(NSArray<NSNumber *> * (^)(NSString *))valuesForLabel;

@end

/// Does `model` declare `label` as a `// #progress` uniform? Both render paths
/// (the FCP render and the mini preview) answer a missing Progress lane with
/// the clip fraction rather than the prop's parsed default of 0, and this is
/// the question they ask - the parsed directive, not a name convention.
static inline BOOL MirageProgressLabel(MirageShaderModel *model,
                                       NSString *label) {
  if (!model || !label.length)
    return NO;
  const MirageScalarProp *sp = model.scalarProps;
  for (int i = 0; i < model.scalarCount; i++)
    if (sp[i].isProgress && [label isEqualToString:@(sp[i].name)])
      return YES;
  return NO;
}

NS_ASSUME_NONNULL_END
