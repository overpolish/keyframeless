/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKRadialOSCSet.h"

NS_ASSUME_NONNULL_BEGIN

/// Protected surface for KKRadialOSCSet subclasses (KKRingOSCSet /
/// KKBoxOSCSet): the spec store plus the value / normalized-value / centre /
/// aspect-lock reads a ring and a box share.
@interface KKRadialOSCSet ()

/// The host renderer (weak). Subclasses read its value / centre / visibility
/// hooks.
@property(nonatomic, weak, readonly) KKMiniViewerRenderer *renderer;
/// The specs. Setting rebuilds the label index and drops a drag whose spec
/// vanished; each subclass exposes its own named setter (setRings: / setBoxes:)
/// forwarding here.
@property(nonatomic, copy) NSArray<NSDictionary<NSString *, id> *> *specs;
/// The label currently being dragged (nil = none); subclass drag code owns it.
@property(nonatomic, copy, nullable) NSString *activeLabel;

/// The spec for a label, or nil.
- (nullable NSDictionary<NSString *, id> *)specForLabel:(NSString *)label;
/// The shared show gate: a constant, visible (or Opt-revealed) lane that isn't
/// suppressed, in a non-empty content rect.
- (BOOL)isActiveLabel:(NSString *)label forContentRect:(CGRect)cr;
/// The lane's raw component values (per-component spec defaults when absent).
- (NSArray<NSNumber *> *)valuesForLabel:(NSString *)label;
/// Per-component normalized values ((value-min)/(max-min), floored at 0, NO
/// upper clamp so an unbounded field grows past its nominal range).
- (NSArray<NSNumber *> *)normsForLabel:(NSString *)label;
/// Whether the lane is currently aspect-linked, with a template fallback for
/// the mini's usually-sparse timeline (so it honours the directive default and
/// matches the main viewer).
- (BOOL)laneLinkedForLabel:(NSString *)label;
/// The centre in overlay points: the linked #point's live value when the spec's
/// `linkLabel` is set, else the fixed `centerX`/`centerY`, mapped through the
/// same clip-space helper the point handles use.
- (CGPoint)centerForSpec:(NSDictionary<NSString *, id> *)s
             contentRect:(CGRect)cr;
/// Draw alpha for the label. Default = the renderer's; a subclass may dim it
/// (the ring lifts a thin stroke's ghost so it stays visible).
- (CGFloat)ghostAlphaForLabel:(NSString *)label;

@end

NS_ASSUME_NONNULL_END
