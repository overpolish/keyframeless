/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The write/navigation surface a timing graph (Advanced or Basic) offers the
/// static-values popover host. The lanes view routes every popover-originated
/// graph write through `-_activeGraph` typed as this protocol, so both graphs
/// are forced to carry the same surface - a new popover write added for one
/// graph fails to compile until the other implements it, instead of silently
/// working on one tab only.
@protocol KKBoundaryEditingGraph <NSObject>

@optional
/// Live playhead fraction (< 0 before the first render tick pushes one).
/// Optional only because conformance is declared on the popover CATEGORY of
/// each graph while this property is synthesized in the main class - both
/// graphs do implement it.
@property(nonatomic) double playheadFraction;

@required

/// Rebuild + retarget the open value popover at `fraction` (keypose nav,
/// filmstrip cell click). The graph re-derives display lanes and calls back
/// into the in-place updater.
- (void)requestValuePopoverAtFraction:(double)fraction;
/// As above; `fireActivation` NO suppresses the layer-activation callback
/// (used by the timeline re-feed redrive so re-scoping the open popover can't
/// ping-pong the host selection).
- (void)requestValuePopoverAtFraction:(double)fraction
                       fireActivation:(BOOL)fireActivation;

- (void)writeSpatialSmoothForLabel:(NSString *)label
                            atFrac:(double)frac
                              isOn:(BOOL)on;
- (void)writeAspectLinkedForLabel:(NSString *)label isOn:(BOOL)on;
- (void)writeGradientTypeForLabel:(NSString *)label type:(NSInteger)type;

@end

NS_ASSUME_NONNULL_END
