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
static const CGFloat ICInspectorGroupSpacing = 14; // Suffix edge to next axis.
static const CGFloat ICInspectorLinkSize = 15;
// Every component reserves the same suffix slot, including degrees and empty
// suffixes. Keep scalar/vector rows on the same trailing content guides.
static const CGFloat ICInspectorSuffixWidth = 16;
static const CGFloat ICInspectorSuffixTrailingInset = 1;
static const CGFloat ICInspectorValueSuffixGap = 1;
static const CGFloat ICInspectorFieldTextInset = 2; // Borderless NSTextFieldCell.
static const CGFloat ICInspectorSliderValueSlotWidth = 70;
static const CGFloat ICInspectorSliderValueGap = 8;

typedef struct {
  NSRect value;
  NSRect suffix;
} ICInspectorValueLayout;

static inline ICInspectorValueLayout ICInspectorLayoutValue(CGFloat leading, CGFloat trailing) {
  CGFloat suffixEnd=MAX(leading,trailing-ICInspectorSuffixTrailingInset);
  CGFloat suffixStart=MAX(leading,suffixEnd-ICInspectorSuffixWidth);
  CGFloat valueEnd=MAX(leading,suffixStart-ICInspectorValueSuffixGap);
  return (ICInspectorValueLayout){
    NSMakeRect(leading,ICInspectorLabelY-ICInspectorValueDrop,valueEnd-leading,ICInspectorTextHeight),
    NSMakeRect(suffixStart,ICInspectorLabelY,suffixEnd-suffixStart,ICInspectorTextHeight)};
}

static inline CGFloat ICInspectorLabelColumnWidth(CGFloat width, CGFloat minimumContent) {
  CGFloat proposed=round((width<475 ? width*0.3670886076-11.860759 : width*0.3176696611+10.848616)*2)/2;
  return MIN(proposed,MAX(0,width-ICInspectorHostGutter-minimumContent));
}


// Shared gutter placement for property-link badges and section icons.
static inline NSRect ICInspectorGutterIconFrame(NSTextField *label) {
  CGFloat baseline=NSMaxY(label.frame)-label.firstBaselineOffsetFromTop;
  CGFloat center=baseline+label.font.capHeight/2;
  return NSMakeRect((ICInspectorLabelInset-ICInspectorLinkSize)/2+2,
      round((center-ICInspectorLinkSize/2)*2)/2,ICInspectorLinkSize,ICInspectorLinkSize);
}

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
// The product's amber. Marks the keypose being edited, and the same value is
// baked into the application icon and the header logo artwork, which no code
// path can read back: change those by hand when this changes.
@property(class, nonatomic, readonly) NSColor *brandAmber;
@property(class, nonatomic, readonly) NSColor *inactiveControlColor;
@property(class, nonatomic, readonly) NSColor *selectionColor;
@property(class, nonatomic, readonly) NSArray<NSColor *> *curveColors;
@property(class, nonatomic, readonly) NSArray<NSColor *> *linkGroupColors;
@property(class, nonatomic, readonly) NSColor *sliderTrackColor;
@property(class, nonatomic, readonly) NSColor *sliderKnobColor;
@property(class, nonatomic, readonly) NSColor *sliderKnobOutlineColor;
@end
