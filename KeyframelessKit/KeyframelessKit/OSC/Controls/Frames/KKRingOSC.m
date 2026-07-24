/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKRingOSC.h"
#import "KKOSCShaderTypes.h"
#import "KKResizeCursor.h"
#import "NSColor+KKColors.h"
#import <AppKit/NSCursor.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKRenderPrimitives.h>

// Ring palette + stroke widths come from the SHARED glyph style
// (KKOSCGlyphStyle.h) so the mini-viewer's ring encode and this viewer OSC
// can never drift apart.
#import "KKOSCGlyphStyle.h"

@implementation KKRingOSC {
  BOOL _cursorSet;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _ringRadius = 50.0f;
    _ringRadiusY = 50.0f;
    _fillWidth = 2.0f;
    _ringOutlineWidth = 1.5f;
    _ghostAlpha = 1.0f;
  }
  return self;
}

- (NSString *)pipelinePluginID {
  return @"co.overpolish.keyframelesskit.RingOSC";
}

- (NSString *)fragmentFunctionName {
  return @"KKRingOSCFragment";
}

- (float)hitRadius {
  return fmaxf(_ringRadius, _ringRadiusY) + _fillWidth / 2.0f +
         _ringOutlineWidth;
}

- (float)oscSize {
  return fmaxf(_ringRadius, _ringRadiusY) + _fillWidth / 2.0f +
         _ringOutlineWidth;
}

- (void)applyRadiusWidgetStyle {
  // Radius shared with the mini-viewer's radius-widget encode
  // (KKOSCGlyphStyle.h). _fillWidth / _ringOutlineWidth here only size the
  // hit/grab area (oscSize); the VISUAL stroke widths come from the emphasis
  // style in -drawAtCanvasPosition, the same on every ring.
  _ringRadius = KKOSCRadiusWidgetRadiusPx;
  _ringRadiusY = KKOSCRadiusWidgetRadiusPx;
  _fillWidth = 3.0f;
  _ringOutlineWidth = 1.5f;
  self.clearsOnDraw = NO;
}

- (void)clearCursorIfSet {
  if (!_cursorSet)
    return;
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  [oscAPI setCursor:[NSCursor arrowCursor]];
  _cursorSet = NO;
}

- (void)updateCursorForMouseX:(double)positionX positionY:(double)positionY {
  double dx = positionX - _center.x;
  double dy = positionY - _center.y;
  double angle = atan2(dy, dx);
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  [oscAPI setCursor:KKResizeCursorForAngle(angle)];
}

- (BOOL)hitTestAtMousePositionX:(double)positionX
                      positionY:(double)positionY
                         atTime:(CMTime)time {
  if (_ringRadius < 1.0f && _ringRadiusY < 1.0f)
    return NO;

  CGPoint pos = _center;
  double dx = positionX - pos.x;
  double dy = positionY - pos.y;
  double nx = (_ringRadius > 0) ? dx / _ringRadius : 0;
  double ny = (_ringRadiusY > 0) ? dy / _ringRadiusY : 0;
  double ellipseDist = sqrt(nx * nx + ny * ny);
  double meanRadius = (_ringRadius + _ringRadiusY) * 0.5;
  double ringDist = fabs(ellipseDist - 1.0) * meanRadius;
  float hitWidth = _fillWidth / 2.0f + _ringOutlineWidth + 4.0f;

  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];

  if (ringDist < hitWidth) {
    // Opt-hover hide/show affordance takes precedence: the eye cursor signals
    // that an Opt-click toggles visibility (not a resize/re-enable drag).
    if (_visibilityHint == 1 || _visibilityHint == 2) {
      [oscAPI setCursor:(_visibilityHint == 2 ? KKVisibilityShowCursor()
                                              : KKVisibilityHideCursor())];
      _cursorSet = YES;
      return YES;
    }
    // A dimmed ghost is a re-enable target (Opt-click), not a resize handle -
    // keep the plain arrow rather than the resize cursor, but still report the
    // hit so the Opt-click toggle resolves.
    if (_ghostAlpha < 0.999f) {
      if (_cursorSet) {
        [oscAPI setCursor:[NSCursor arrowCursor]];
        _cursorSet = NO;
      }
      return YES;
    }
    if (_hoverCursor)
      [oscAPI setCursor:_hoverCursor];
    else {
      double angle = atan2(dy, dx);
      [oscAPI setCursor:KKResizeCursorForAngle(angle)];
    }
    _cursorSet = YES;
    return YES;
  }

  if (_cursorSet) {
    [oscAPI setCursor:[NSCursor arrowCursor]];
    _cursorSet = NO;
  }
  return NO;
}

- (void)drawAtCanvasPosition:(CGPoint)canvasPosition
                   isHovered:(BOOL)isHovered
                    isActive:(BOOL)isActive
            destinationImage:(FxImageTile *)destinationImage
                      atTime:(CMTime)time {
  id<MTLRenderPipelineState> ps =
      [self pipelineStateForDestinationImage:destinationImage];
  if (!ps)
    return;

  // A dimmed ghost (Opt-hold reveal of a hidden ring) reads as idle, not
  // hovered/active - emphasis would make a re-enable target look interactive.
  if (_ghostAlpha < 0.999f) {
    isHovered = NO;
    isActive = NO;
  }

  // `solidStyle` (a host with no hover feedback) always uses the active/white
  // look, but never overrides a ghost's dim idle appearance.
  BOOL active = isActive || (_solidStyle && _ghostAlpha >= 0.999f);

  NSInteger emphasis = active ? 2 : (isHovered ? 1 : 0);
  KKOSCRingStyle style = KKOSCRingStyleForEmphasis(emphasis);
  float fillWidth = style.fillWidthPx;
  float outlineWidth = style.outlineWidthPx;
  float outerX = _ringRadius + fillWidth / 2.0f + outlineWidth;
  float outerY = _ringRadiusY + fillWidth / 2.0f + outlineWidth;
  float outerRadiusPixels = fmaxf(outerX, outerY);

  simd_float4 fillColor = style.fill;
  simd_float4 strokeColor = style.stroke;
  if (_tintColor) {
    // A tinted ring keeps the shared stroke but fills with the tint at the
    // shared per-emphasis opacity (KKOSCGlyphStyle) so the mini's tinted
    // corner ring matches this exactly.
    CGFloat r, g, b, a;
    NSColor *rgb =
        [_tintColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    [rgb getRed:&r green:&g blue:&b alpha:&a];
    fillColor = (simd_float4){(float)r, (float)g, (float)b,
                              KKOSCRingTintAlphaForEmphasis(emphasis)};
  }

  fillColor.w *= _ghostAlpha;
  strokeColor.w *= _ghostAlpha;

  KKRingOSCParams params = {.ringRadiusX = _ringRadius / outerRadiusPixels,
                            .ringRadiusY = _ringRadiusY / outerRadiusPixels,
                            .fillHalfWidth =
                                (fillWidth / 2.0f) / outerRadiusPixels,
                            .outlineWidth = outlineWidth / outerRadiusPixels,
                            .fillColor = fillColor,
                            .strokeColor = strokeColor};

  [self drawQuadForDestinationImage:destinationImage
                     canvasPosition:canvasPosition
                   clearDestination:NO
                      pipelineState:ps
                       fragmentData:&params
                   fragmentDataSize:sizeof(params)
                               size:outerRadiusPixels];
}

@end
