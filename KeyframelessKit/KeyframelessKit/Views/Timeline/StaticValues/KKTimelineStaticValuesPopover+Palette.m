/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Palette generation for the colour rows: which colour lanes are visible (and
// how they group), the current / locked colours, generating or refining a
// palette, and committing the result back through the value callback. Split out
// of KKTimelineStaticValuesPopover.m; reaches popover state via the @package
// ivars in KKTimelineStaticValuesPopover_Private.h.

#import "KKMiniViewerView.h" // canvasDelegate + KKMiniViewerDelegate
#import "KKPaletteGenerator.h"
#import "KKTimelineStaticValuesPopover_Private.h"
#import "KKTimingStage.h" // KKConditionalVisibleLaneLabels
#import "NSColor+KKColors.h"

@interface _KKStaticValuesPopoverView (PalettePrivate)
- (NSArray<NSString *> *)_visiblePaletteLabels;
- (NSArray<NSArray<NSString *> *> *)_visiblePaletteGroups;
- (NSColor *)_currentColorForLabel:(NSString *)label;
- (NSArray *)_lockedArrayForLabels:(NSArray<NSString *> *)labels;
- (void)_commitPaletteColors:(NSArray<NSColor *> *)colors
                   forLabels:(NSArray<NSString *> *)labels;
@end

@implementation _KKStaticValuesPopoverView (Palette)

- (NSArray<NSString *> *)_visiblePaletteLabels {
  NSSet<NSString *> *visible =
      KKConditionalVisibleLaneLabels(_lanes, _currentValuesByLabel);
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  for (KKLane *lane in _lanes)
    if (lane.valueType == KKLaneValueTypeColor && lane.paletteLockable &&
        [visible containsObject:lane.label])
      [labels addObject:lane.label];
  return labels;
}

// The visible lockable colour labels split into INDEPENDENT palette journeys by
// `paletteGroup` (in first-seen row order). Lanes with a nil group share one
// journey (legacy). A host with several distinct colour properties gives each a
// group so they reroll as separate cohesive palettes.
- (NSArray<NSArray<NSString *> *> *)_visiblePaletteGroups {
  NSSet<NSString *> *visible =
      KKConditionalVisibleLaneLabels(_lanes, _currentValuesByLabel);
  NSMutableArray<NSMutableArray<NSString *> *> *groups = [NSMutableArray array];
  NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *byGroup =
      [NSMutableDictionary dictionary];
  NSMutableArray<NSString *> *legacy = nil;
  for (KKLane *lane in _lanes) {
    if (lane.valueType != KKLaneValueTypeColor || !lane.paletteLockable ||
        ![visible containsObject:lane.label])
      continue;
    if (lane.paletteGroup.length) {
      NSMutableArray<NSString *> *g = byGroup[lane.paletteGroup];
      if (!g) {
        g = [NSMutableArray array];
        byGroup[lane.paletteGroup] = g;
        [groups addObject:g];
      }
      [g addObject:lane.label];
    } else {
      if (!legacy) {
        legacy = [NSMutableArray array];
        [groups addObject:legacy];
      }
      [legacy addObject:lane.label];
    }
  }
  return groups;
}

- (NSColor *)_currentColorForLabel:(NSString *)label {
  NSArray<NSNumber *> *v = _currentValuesByLabel[label];
  if (v.count < 3)
    return [NSColor whiteColor];
  return [NSColor colorWithSRGBRed:v[0].doubleValue
                             green:v[1].doubleValue
                              blue:v[2].doubleValue
                             alpha:v.count > 3 ? v[3].doubleValue : 1.0];
}

// Parallel to `labels`: the locked colour (NSColor) or NSNull for each.
- (NSArray *)_lockedArrayForLabels:(NSArray<NSString *> *)labels {
  NSMutableArray *locked = [NSMutableArray arrayWithCapacity:labels.count];
  for (NSString *label in labels)
    [locked addObject:([_lockedColorLabels containsObject:label]
                           ? (id)[self _currentColorForLabel:label]
                           : (id)[NSNull null])];
  return locked;
}

// Write `colors[i]` into `labels[i]` (skipping locked labels): preview + row
// swatch now, then persist every changed swatch as ONE undo entry. The per-lane
// drag path can't be used - it defers to a single pending label per bracket, so
// only the last write would survive; the batch committer exists for this.
- (void)_commitPaletteColors:(NSArray<NSColor *> *)colors
                   forLabels:(NSArray<NSString *> *)labels {
  id<KKMiniViewerDelegate> del = _miniViewer.canvasDelegate;
  BOOL previews = [del
      respondsToSelector:@selector(miniViewer:applyConstantValues:forLabel:)];
  NSMutableArray<NSString *> *changed = [NSMutableArray array];
  NSMutableArray<NSArray<NSNumber *> *> *changedVals = [NSMutableArray array];
  for (NSInteger i = 0; i < (NSInteger)labels.count; i++) {
    NSString *label = labels[i];
    if ([_lockedColorLabels containsObject:label])
      continue;
    NSColor *c = [colors[i] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]]
                     ?: colors[i];
    CGFloat r = 0, g = 0, b = 0, a = 1;
    [c getRed:&r green:&g blue:&b alpha:&a];
    NSArray<NSNumber *> *vals = @[ @(r), @(g), @(b), @(a) ];
    _currentValuesByLabel[label] = vals;
    [_rowsByLabel[label] applyValues:vals];
    if (previews)
      [del miniViewer:_miniViewer applyConstantValues:vals forLabel:label];
    [changed addObject:label];
    [changedVals addObject:vals];
  }
  if (previews) {
    [_miniViewer setNeedsDisplay:YES];
    [_miniViewer setHandlesNeedDisplay];
  }
  if (changed.count == 0)
    return;
  if (self.onCommitBatch)
    self.onCommitBatch(changed, changedVals);
  else if (_onHandleValue)
    for (NSInteger i = 0; i < (NSInteger)changed.count; i++)
      _onHandleValue(changed[i], changedVals[i]);
}

// Reroll the visible palette in `mode`. Locked swatches act as anchors that the
// regenerated colours interpolate between (see KKPaletteGenerator).
- (void)_generatePaletteWithMode:(NSInteger)mode {
  NSMutableArray<NSString *> *allLabels = [NSMutableArray array];
  NSMutableArray<NSColor *> *allColors = [NSMutableArray array];
  for (NSArray<NSString *> *labels in [self _visiblePaletteGroups]) {
    if (labels.count == 0)
      continue;
    // Each group is its own independent journey.
    NSArray<NSColor *> *palette = [KKPaletteGenerator
        paletteWithMode:(KKPaletteMode)mode
                  count:(NSInteger)labels.count
                 locked:[self _lockedArrayForLabels:labels]];
    [allLabels addObjectsFromArray:labels];
    [allColors addObjectsFromArray:palette];
  }
  if (allLabels.count)
    [self _commitPaletteColors:allColors forLabels:allLabels];
}

// Nudge the current visible palette instead of rerolling (locked kept). Per
// group, so each colour property stays its own palette.
- (void)_refinePalette {
  NSMutableArray<NSString *> *allLabels = [NSMutableArray array];
  NSMutableArray<NSColor *> *allColors = [NSMutableArray array];
  for (NSArray<NSString *> *labels in [self _visiblePaletteGroups]) {
    if (labels.count == 0)
      continue;
    NSMutableArray<NSColor *> *current = [NSMutableArray array];
    for (NSString *label in labels)
      [current addObject:[self _currentColorForLabel:label]];
    NSArray<NSColor *> *palette = [KKPaletteGenerator
        refinedPaletteFrom:current
                    locked:[self _lockedArrayForLabels:labels]];
    [allLabels addObjectsFromArray:labels];
    [allColors addObjectsFromArray:palette];
  }
  if (allLabels.count)
    [self _commitPaletteColors:allColors forLabels:allLabels];
}

@end
