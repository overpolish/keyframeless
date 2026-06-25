/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasAnchorSelectionSync.h" // cross-process selection sync
#import "CanvasLayerRender.h"         // CanvasProjectLayerPointsObj
#import "CanvasLayerTimeline.h"       // blob + UIState snapshots
#import "CanvasOSC_Private.h"
#import "CanvasPathMorph.h" // CanvasPathMorphedAtFraction
#import "CanvasPathOSC.h"   // CanvasDrawPathEditOSC
#import <KeyframelessKit/KKShape.h> // KKRectShape (image extent)
#import "CanvasPenController.h"
#import "CanvasPenCursors.h" // shared pen cursor set
#import "CanvasPenMarquee.h" // shared dashed-marquee perimeter walk
#import "Constants.h"        // kParamLayerData / kParamUIState
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/NSColor+KKColors.h>

// Preview colours: the Position OSC red core under the grid's dark halo, so the
// guide is consistent with the other OSCs AND legible over any footage.
static const simd_float4 kPenHalo = {0.0f, 0.0f, 0.0f, 0.55f};
static const simd_float4 kPenCore = {1.0f, 0.25f, 0.25f, 1.0f};
static const simd_float4 kPenHandleLine = {1.0f, 1.0f, 1.0f, 0.85f};
static const float kPenLineHaloHalfPx = 2.3f;
static const float kPenLineCoreHalfPx = 1.2f;

CanvasPenModifiers CanvasPenModsFromFxModifiers(NSUInteger m) {
  CanvasPenModifiers out = CanvasPenModNone;
  if (m & kFxModifierKey_SHIFT)
    out |= CanvasPenModShift;
  if (m & kFxModifierKey_COMMAND)
    out |= CanvasPenModCmd;
  if (m & kFxModifierKey_CONTROL)
    out |= CanvasPenModCtrl;
  if (m & kFxModifierKey_OPTION)
    out |= CanvasPenModOpt;
  return out;
}

#define PenModsFromFx CanvasPenModsFromFxModifiers

// This (Pen) category declares CanvasPenSurface conformance + holds the input
// forwarding, the cursor, the shared coordinate helper, and the draw-primitive
// half of the protocol; the coordinate/blob/selection half lives in
// +PenSurface.m and the overlay orchestration in +PenDraw.m. Silence the
// "incomplete protocol/implementation" warnings the split necessarily raises.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wincomplete-implementation"
#pragma clang diagnostic ignored "-Wprotocol"

@implementation CanvasOSC (Pen)

- (BOOL)_penToolActive {
  return [self _activeTool] == CanvasToolbarToolPen;
}

- (BOOL)_penMouseDownAtX:(double)x
                       y:(double)y
               modifiers:(NSUInteger)modifiers
                  atTime:(CMTime)time {
  // Opt-click an existing anchor removes it (with the auto-delete cascade);
  // only consumes the press if an anchor was actually under it, so Opt
  // elsewhere falls through to normal pen behaviour. Read the LIVE Option flag
  // too: FCP doesn't always surface it in the passed `modifiers`, and the hover
  // cursor (PenX) already uses [NSEvent modifierFlags], so they must agree or
  // the cursor shows delete but the click places a point.
  BOOL optHeld = (modifiers & kFxModifierKey_OPTION) ||
                 ([NSEvent modifierFlags] & NSEventModifierFlagOption);
  if (!self.penController.active && optHeld &&
      [self.pathEditController removeAnchorAtX:x y:y])
    return YES;
  // Context-sensitive: when NOT mid-drawing a new path, a click on the selected
  // path's segment inserts an anchor there (and begins dragging it). Empty
  // space / endpoints fall through to the pen's new-path machinery.
  if (!self.penController.active && [self.pathEditController penInsertAtX:x
                                                                        y:y])
    return YES;
  return [self.penController mouseDownAtX:x
                                        y:y
                                modifiers:PenModsFromFx(modifiers)];
}

- (void)_penMouseMovedAtX:(double)x y:(double)y {
  [self.penController mouseMovedAtX:x y:y];
}

- (void)_penMouseDraggedAtX:(double)x
                          y:(double)y
                  modifiers:(NSUInteger)modifiers {
  [self.penController mouseDraggedAtX:x y:y modifiers:PenModsFromFx(modifiers)];
}

- (void)_penMouseUp {
  [self.penController mouseUp];
}

- (BOOL)_penKeyDown:(unsigned short)asciiKey
          modifiers:(NSUInteger)modifiers
             atTime:(CMTime)time {
  return [self.penController keyDown:asciiKey];
}

- (void)_penConfirmIfContextLost {
  [self.penController confirmIfContextLost];
}

- (CanvasPathEditHit)_pathEditHitAtX:(double)x y:(double)y {
  return [self.pathEditController hitTestAtX:x y:y];
}

- (BOOL)_pathEditMouseDownAtX:(double)x y:(double)y modifiers:(NSUInteger)mods {
  return [self.pathEditController mouseDownAtX:x
                                             y:y
                                     modifiers:PenModsFromFx(mods)];
}

- (void)_pathEditMouseDraggedAtX:(double)x
                               y:(double)y
                       modifiers:(NSUInteger)mods {
  [self.pathEditController mouseDraggedAtX:x y:y modifiers:PenModsFromFx(mods)];
}

- (void)_pathEditMouseUp {
  [self.pathEditController mouseUp];
}

- (BOOL)_pathEditDragging {
  return self.pathEditController.dragging;
}

- (NSCursor *)_penCursorForCanvasX:(double)x y:(double)y {
  if (!self.penController.active) {
    // Opt over an existing anchor -> "remove point" (matches the Opt-click).
    if (([NSEvent modifierFlags] & NSEventModifierFlagOption) &&
        [self.pathEditController hitTestAtX:x y:y] == CanvasPathEditHitAnchor)
      return CanvasPenCursorForRole(CanvasPenCursorRoleDelete);
    // Hovering the selected path's curve -> "add point".
    if ([self.pathEditController segmentHitAtX:x y:y])
      return CanvasPenCursorForRole(CanvasPenCursorRoleAdd);
  }
  return [self.penController cursorKindAtX:x y:y] == CanvasPenCursorClose
             ? CanvasPenCursorForRole(CanvasPenCursorRoleClose)
             : CanvasPenCursorForRole(CanvasPenCursorRolePen);
}

// render-object (Y-up) <-> CANVAS px. The coordinate helpers use FCP's OBJECT
// space (Y-down), so flip Y crossing the boundary (as in CanvasOSC+AutoSelect).
// Shared with the +PenSurface protocol methods + +PenDraw, hence declared in the
// private header.
- (CGPoint)_penCanvasFromObj:(CGPoint)objYUp {
  return [self
      canvasPointFromObjectPoint:simd_make_float2((float)objYUp.x,
                                                  1.0f - (float)objYUp.y)];
}

- (void)_penHaloStroke:(const CGPoint *)pts
                 count:(NSUInteger)n
      destinationImage:(FxImageTile *)dest {
  [self drawLineStripWithPoints:pts
                          count:n
                          color:kPenHalo
                      halfWidth:kPenLineHaloHalfPx
               destinationImage:dest];
  [self drawLineStripWithPoints:pts
                          count:n
                          color:kPenCore
                      halfWidth:kPenLineCoreHalfPx
               destinationImage:dest];
}

- (void)penDrawDotAtObj:(CGPoint)objYUp
                  ghost:(BOOL)ghost
                hovered:(BOOL)hovered
                 active:(BOOL)active {
  if (!self.penDrawDest)
    return;
  self.penAnchorOSC.ghostAlpha = ghost ? 0.4f : 1.0f;
  // Selected anchors fill in the host accent (KKPointOSC ignores isActive; the
  // fill override is the knob).
  self.penAnchorOSC.fillColorOverride =
      active ? [NSColor accentMatchingHost] : nil;
  [self.penAnchorOSC drawAtCanvasPosition:[self _penCanvasFromObj:objYUp]
                                isHovered:hovered
                                 isActive:active
                         destinationImage:self.penDrawDest
                                   atTime:self.penDrawTime];
  self.penAnchorOSC.fillColorOverride = nil;
  self.penAnchorOSC.ghostAlpha = 1.0f;
}

- (void)penDrawWarnDotAtObj:(CGPoint)objYUp {
  if (!self.penDrawDest)
    return;
  // Same glyph + outline/shadow as an anchor, filled in the warning colour -
  // the override is the only difference from a normal/accent dot.
  self.penAnchorOSC.fillColorOverride = [NSColor warning];
  [self.penAnchorOSC drawAtCanvasPosition:[self _penCanvasFromObj:objYUp]
                                isHovered:YES
                                 isActive:NO
                         destinationImage:self.penDrawDest
                                   atTime:self.penDrawTime];
  self.penAnchorOSC.fillColorOverride = nil;
}

- (void)penDrawRingAtObj:(CGPoint)objYUp maxed:(BOOL)maxed {
  if (!self.penDrawDest)
    return;
  // The shared KKRingOSC glyph (same control as the Glow radius ring), tinted
  // accent - or error at the clamp. The ring shader is crisp by construction
  // (no line-strip anti-alias washout), so no manual pixel-snap is needed.
  self.penCornerRingOSC.tintColor =
      maxed ? [NSColor error] : [NSColor accentMatchingHost];
  [self.penCornerRingOSC drawAtCanvasPosition:[self _penCanvasFromObj:objYUp]
                                    isHovered:NO
                                     isActive:NO
                             destinationImage:self.penDrawDest
                                       atTime:self.penDrawTime];
}

- (void)penDrawMarqueeRect:(CGRect)r {
  if (!self.penDrawDest)
    return;
  // Surface points == canvas px for the viewer. A two-tone dashed rectangle
  // (light dash over dark gap) so it reads on any background; the pixel-snapped
  // perimeter walk is shared with the mini (CanvasPenMarqueeWalk). Accumulate
  // the on / off segments, then batch each colour into one draw.
  simd_float4 lightColor = {1.0f, 1.0f, 1.0f, 0.9f};
  simd_float4 darkColor = {0.0f, 0.0f, 0.0f, 0.6f};
  NSUInteger cap = kCanvasPenMarqueeMaxSegments * 2;
  CGPoint *lightPts = malloc(sizeof(CGPoint) * cap);
  CGPoint *darkPts = malloc(sizeof(CGPoint) * cap);
  __block NSUInteger lightCount = 0, darkCount = 0;
  CanvasPenMarqueeWalk(r, 8.0, 5.0, ^(CGPoint from, CGPoint to, BOOL light) {
    if (light) {
      lightPts[lightCount++] = from;
      lightPts[lightCount++] = to;
    } else {
      darkPts[darkCount++] = from;
      darkPts[darkCount++] = to;
    }
  });
  [self drawLineSegmentsWithPoints:lightPts
                             count:lightCount
                             color:lightColor
                         halfWidth:1.5f
                  destinationImage:self.penDrawDest];
  [self drawLineSegmentsWithPoints:darkPts
                             count:darkCount
                             color:darkColor
                         halfWidth:1.5f
                  destinationImage:self.penDrawDest];
  free(lightPts);
  free(darkPts);
}

- (void)penDrawCurveObjPoints:(const CGPoint *)objPts count:(NSUInteger)count {
  if (!self.penDrawDest || count < 2)
    return;
  CGPoint *pts = malloc(sizeof(CGPoint) * count);
  for (NSUInteger i = 0; i < count; i++)
    pts[i] = [self _penCanvasFromObj:objPts[i]];
  [self _penHaloStroke:pts count:count destinationImage:self.penDrawDest];
  free(pts);
}

- (void)penDrawColoredCurveObjPoints:(const CGPoint *)objPts
                               count:(NSUInteger)count
                               color:(simd_float4)color {
  if (!self.penDrawDest || count < 2)
    return;
  CGPoint *pts = malloc(sizeof(CGPoint) * count);
  for (NSUInteger i = 0; i < count; i++)
    pts[i] = [self _penCanvasFromObj:objPts[i]];
  [self drawLineStripWithPoints:pts
                          count:count
                          color:color
                      halfWidth:1.5f
               destinationImage:self.penDrawDest];
  free(pts);
}

- (void)penDrawSnappedLoopObjPoints:(const CGPoint *)objPts
                              count:(NSUInteger)count
                              color:(simd_float4)color {
  if (!self.penDrawDest || count < 2)
    return;
  CGPoint *pts = malloc(sizeof(CGPoint) * count);
  for (NSUInteger i = 0; i < count; i++) {
    CGPoint c = [self _penCanvasFromObj:objPts[i]];
    // Snap to a pixel centre (floor + 0.5), exactly like the grid lines, so the
    // 1px box edges land crisp on the destination raster instead of soft.
    pts[i] = CGPointMake(floor(c.x) + 0.5, floor(c.y) + 0.5);
  }
  [self drawLineStripWithPoints:pts
                          count:count
                          color:color
                      halfWidth:1.5f
               destinationImage:self.penDrawDest];
  free(pts);
}

- (void)penDrawHandleFromObj:(CGPoint)aObj toObj:(CGPoint)bObj {
  if (!self.penDrawDest)
    return;
  CGPoint line[2] = {[self _penCanvasFromObj:aObj],
                     [self _penCanvasFromObj:bObj]};
  [self drawLineStripWithPoints:line
                          count:2
                          color:kPenHandleLine
                      halfWidth:1.5f
               destinationImage:self.penDrawDest];
  [self.penHandleOSC drawAtCanvasPosition:line[1]
                                isHovered:NO
                                 isActive:NO
                         destinationImage:self.penDrawDest
                                   atTime:self.penDrawTime];
}

@end

#pragma clang diagnostic pop
