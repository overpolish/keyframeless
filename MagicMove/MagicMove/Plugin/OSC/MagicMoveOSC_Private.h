/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "MMOSCCursor.h"
#import "MagicMoveOSC.h"
#include <simd/simd.h>

// Glyph style shared by the scale handles and the anchor square: they read as
// one control set, and a hovered or dragged glyph grows. The fill is a touch
// lighter than the border so the outline ring still reads.
static const simd_float4 MMOSCGlyphFill = {1, 1, 1, 1};
static const simd_float4 MMOSCGlyphStroke = {0.82f, 0.82f, 0.82f, 1};
static const float MMOSCActiveGlyphGrowth = 1.5f;

// Host access shared by the control's categories. Each category owns its own
// drawing, hit test and write path, but they read the same geometry and
// arbitrate one cursor.
@interface MagicMoveOSC ()
- (CGPoint)canvasFromObject:(CGPoint)object;
- (BOOL)visible:(UInt32)parameter cached:(BOOL *)cached atTime:(CMTime)time;
- (void)applyCursorKind:(MMOSCCursorKind)kind;
// The render's pivot in canvas pixels: the position offset plus the anchor,
// which is the point every rotation and scale turns about.
- (CGPoint)pivotCanvasForPose:(OSCBoxPose)pose imageSize:(CGSize)imageSize;
@end
