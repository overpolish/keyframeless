/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Unified playhead overlay: draws the knob and its vertical line as one
/// continuous element stretching from the top of the ruler down through the
/// lane area. Overlays the KKStageSequencerView container and passes all
/// mouse events through to the views beneath.
@interface KKStagePlayheadView : NSView

@property(nonatomic, assign) double playheadFraction;
@property(nonatomic, assign) CGFloat zoom;
@property(nonatomic, assign) CGFloat panOffset;

/// Height of the ruler region (measured from the top of this view, after the
/// top padding). Line runs from the bottom of the ruler to the bottom of the
/// view; knob sits at the top of the ruler.
@property(nonatomic, assign) CGFloat rulerHeight;

/// Padding between the top of this view and the top of the ruler.
@property(nonatomic, assign) CGFloat topPadding;

@end

NS_ASSUME_NONNULL_END
