/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef CGFloat (^KKCurvePillValueBlock)(NSInteger pillIndex, CGFloat t);

@interface KKCurvePillView : NSView

@property(nonatomic) NSInteger pillCount;
@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic, copy, nullable) void (^onSelectionChanged)(NSInteger index)
    ;

/// Block that evaluates the curve for a given pill index and normalized t.
/// Used to render the mini curve icon in each pill.
@property(nonatomic, copy, nullable) KKCurvePillValueBlock valueBlock;

/// When YES the curve is plotted against [fixedMin, fixedMax] instead of each
/// pill's own auto-fitted min/max. Needed for hold-effect pills, where
/// intensity is a pure amplitude scale around 1.0 — auto-fit would normalise
/// that scaling right back out, so the preview wouldn't react to intensity.
@property(nonatomic) BOOL usesFixedRange;
@property(nonatomic) CGFloat fixedMin;
@property(nonatomic) CGFloat fixedMax;

/// Accent colour used for the selected pill border and its curve glyph.
/// Defaults to `[NSColor accentMatchingHost]`. Transition-kind popovers
/// override to `[NSColor warning]` so the glyph colour matches the curve
/// the user will see drawn in the lane.
@property(nonatomic, strong, nullable) NSColor *accentColor;

- (void)redraw;

/// View-space rect of pill `index` (0..pillCount-1). NSZeroRect if pillCount
/// is 0. Used by guide code that needs to spotlight a specific pill.
- (NSRect)pillRectForIndex:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
