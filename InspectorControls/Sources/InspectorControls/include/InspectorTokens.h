/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#pragma once
#import <AppKit/AppKit.h>

// Shared AppKit-only inspector presentation tokens.
// Geometry uses AppKit points; numeric readout offsets are separate from labels.
static const CGFloat ICInspectorRowHeight = 24;
static const CGFloat ICInspectorLabelInset = 21;
static const CGFloat ICInspectorHostGutter = 75;
static const CGFloat ICInspectorTextHeight = 18;
static const CGFloat ICInspectorLabelY = 3;
static const CGFloat ICInspectorValueDrop = 1;
static const CGFloat ICInspectorGroupSpacing = 12;
static const CGFloat ICInspectorLinkSize = 15;

@interface ICInspectorTokens : NSObject
@property(class, nonatomic, readonly) NSFont *labelFont;
@property(class, nonatomic, readonly) NSFont *selectedLabelFont;
@property(class, nonatomic, readonly) NSFont *decorationFont;
@property(class, nonatomic, readonly) NSFont *valueFont;
@property(class, nonatomic, readonly) NSColor *labelColor;
@property(class, nonatomic, readonly) NSColor *decorationColor;
@property(class, nonatomic, readonly) NSColor *valueColor;
@property(class, nonatomic, readonly) NSColor *disabledTextColor;
@property(class, nonatomic, readonly) NSColor *accentMatchingHost;
@property(class, nonatomic, readonly) NSColor *inactiveControlColor;
@property(class, nonatomic, readonly) NSColor *selectionColor;
@property(class, nonatomic, readonly) NSArray<NSColor *> *curveColors;
@property(class, nonatomic, readonly) NSArray<NSColor *> *linkGroupColors;
@property(class, nonatomic, readonly) NSColor *sliderTrackColor;
@property(class, nonatomic, readonly) NSColor *sliderKnobColor;
@property(class, nonatomic, readonly) NSColor *sliderKnobOutlineColor;
@end
