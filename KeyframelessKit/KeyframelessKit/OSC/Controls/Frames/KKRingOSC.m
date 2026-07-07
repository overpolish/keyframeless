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

static NSColor *ringIdleFillColor(void) {
  return [NSColor colorWithRed:0xCE / 255.0
                         green:0xCB / 255.0
                          blue:0xCE / 255.0
                         alpha:0xB1 / 255.0];
}
static NSColor *ringIdleStrokeColor(void) {
  return [NSColor colorWithRed:0x1B / 255.0
                         green:0x18 / 255.0
                          blue:0x1D / 255.0
                         alpha:0x9F / 255.0];
}
static NSColor *ringHoverFillColor(void) {
  return [NSColor colorWithRed:0xD0 / 255.0
                         green:0xCA / 255.0
                          blue:0xCD / 255.0
                         alpha:0xB2 / 255.0];
}
static NSColor *ringHoverStrokeColor(void) {
  return [NSColor colorWithRed:0x09 / 255.0
                         green:0x07 / 255.0
                          blue:0x0A / 255.0
                         alpha:0xAD / 255.0];
}
static NSColor *ringActiveFillColor(void) {
  return [NSColor colorWithRed:0xFF / 255.0
                         green:0xFF / 255.0
                          blue:0xFF / 255.0
                         alpha:1.0f];
}
static NSColor *ringActiveStrokeColor(void) {
  return [NSColor colorWithRed:0x00 / 255.0
                         green:0x00 / 255.0
                          blue:0x00 / 255.0
                         alpha:1.0f];
}

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
  _ringRadius = 7.0f;
  _ringRadiusY = 7.0f;
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

  float fillWidth = (isHovered || isActive) ? 2.5f : 2.0f;
  float outlineWidth = (isHovered || isActive) ? 1.5f : 1.0f;
  float outerX = _ringRadius + fillWidth / 2.0f + outlineWidth;
  float outerY = _ringRadiusY + fillWidth / 2.0f + outlineWidth;
  float outerRadiusPixels = fmaxf(outerX, outerY);

  simd_float4 fillColor;
  simd_float4 strokeColor;
  if (_tintColor) {
    CGFloat r, g, b, a;
    NSColor *rgb =
        [_tintColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    [rgb getRed:&r green:&g blue:&b alpha:&a];
    if (isActive) {
      fillColor = (simd_float4){(float)r, (float)g, (float)b, 1.0f};
      strokeColor = [ringActiveStrokeColor() simdFloat4];
    } else if (isHovered) {
      fillColor = (simd_float4){(float)r, (float)g, (float)b, 0.85f};
      strokeColor = [ringHoverStrokeColor() simdFloat4];
    } else {
      fillColor = (simd_float4){(float)r, (float)g, (float)b, 0.7f};
      strokeColor = [ringIdleStrokeColor() simdFloat4];
    }
  } else if (isActive) {
    fillColor = [ringActiveFillColor() simdFloat4];
    strokeColor = [ringActiveStrokeColor() simdFloat4];
  } else if (isHovered) {
    fillColor = [ringHoverFillColor() simdFloat4];
    strokeColor = [ringHoverStrokeColor() simdFloat4];
  } else {
    fillColor = [ringIdleFillColor() simdFloat4];
    strokeColor = [ringIdleStrokeColor() simdFloat4];
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
