/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>

// Internal to the timing editor sources.

// Menu-item images use NSPopUpButton's native image support. Curve semantics
// stay in the plugin; InspectorControls remains independent of motion types.
NSImage *KFTimingMenuGlyph(BOOL addedMotion, NSInteger type);

// Evaluated motion preview. Plots one path per component over the plotted gaps
// and reports playhead scrubs back to its owner.
@interface KFGapGraph : NSView
@property(nonatomic, copy) NSArray<NSArray<NSNumber *> *> *points;
@property(nonatomic) double progress;
@property(nonatomic,copy) NSArray<NSNumber *> *startFractions;
@property(copy) NSArray<NSBezierPath *> *curvePaths;
@property(nonatomic, copy) NSArray<NSColor *> *componentColors;
@property NSRect curveBounds;
@property(nonatomic) BOOL scrubbing;
@property(copy) void (^onScrub)(double fraction);
@property(copy) void (^onScrubEnd)(void);
- (void)prepareCurves;
@end
