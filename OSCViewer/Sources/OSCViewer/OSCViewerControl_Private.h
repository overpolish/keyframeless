/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "OSCViewerControl.h"

// Glyph style shared by the scale handles and the anchor square: they read as
// one control set, and a hovered or dragged glyph grows. The fill is a touch
// lighter than the border so the outline ring still reads.
static const simd_float4 OSCViewerGlyphFill = {1, 1, 1, 1};
static const simd_float4 OSCViewerGlyphStroke = {0.82f, 0.82f, 0.82f, 1};
static const float OSCViewerActiveGlyphGrowth = 1.5f;
static const float OSCViewerBorderHalfWidth = 1.0f;
static const float OSCViewerHandleOutline = 1.25f;

// Host access shared by the control's categories. Each element owns its own
// drawing and hit test, but they read the same geometry and arbitrate one
// cursor.
@interface OSCViewerControl ()
- (id<FxOnScreenControlAPI_v4>)oscAPI;
- (CGPoint)canvasFromObject:(CGPoint)object;
- (CGPoint)objectFromCanvas:(CGPoint)canvas;
- (CGPoint)pixelsFromCanvasX:(double)x y:(double)y imageSize:(CGSize)size;
// The render's pivot in canvas pixels: the position offset plus the anchor,
// which is the point every rotation and scale turns about.
- (CGPoint)pivotCanvasForPose:(OSCBoxPose)pose imageSize:(CGSize)imageSize;
- (BOOL)canvasCornersForPose:(OSCBoxPose)pose imageSize:(CGSize)imageSize corners:(CGPoint[4])corners;
// An element's saved visibility, cached so hover and exit callbacks that arrive
// without the retrieval API keep the last known value rather than flashing.
- (BOOL)elementVisible:(OSCViewerElement)element cached:(BOOL *)cached atTime:(CMTime)time;
- (void)applyCursorKind:(OSCCursorKind)kind;

@property(nonatomic) NSInteger hoveredHandle;
@property(nonatomic) NSInteger hoveredRing;
@property(nonatomic) BOOL hoveredAnchor;
@property(nonatomic) BOOL dragging;
@property(nonatomic) NSInteger dragPart;
@property(nonatomic) OSCCursorKind cursorKind;
@property(nonatomic) OSCCursorKind dragCursorKind;
@property(nonatomic) OSCBoxPose pressPose;
@property(nonatomic) CGPoint pressPixels;
@property(nonatomic) CGSize pressImageSize;
@property(nonatomic) OSCViewerRingDrag ringDrag;
@property(nonatomic) BOOL showBorder, showHandles, showRings, showAnchor;
@end
