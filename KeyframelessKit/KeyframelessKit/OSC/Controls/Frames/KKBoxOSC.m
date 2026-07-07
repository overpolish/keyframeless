/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKBoxOSC.h"
#import "KKResizeCursor.h"
#import <AppKit/NSCursor.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKOSCLabel.h>
#import <KeyframelessKit/KKPointOSC.h>
#import <KeyframelessKit/KKRectBorderOSC.h>

@implementation KKBoxOSC {
  BOOL _cursorSet;
}

// Show the FCP resize cursor for the hovered handle (corner -> diagonal, edge
// -> horizontal/vertical), matching the viewer ring; reset to the arrow when
// off the handles. Mirrors KKRingOSC's cursor handling.
- (void)_applyResizeCursorForHandle:(NSInteger)handleIndex {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return;
  NSCursor *cursor = nil;
  if (handleIndex >= 0) {
    // Opt-hover hide/show takes precedence over the resize cursor.
    if (_visibilityHint == 1)
      cursor = KKVisibilityHideCursor();
    else if (_visibilityHint == 2)
      cursor = KKVisibilityShowCursor();
    else
      cursor = KKResizeCursorForBoxHandle(handleIndex);
  }
  if (cursor) {
    [oscAPI setCursor:cursor];
    _cursorSet = YES;
  } else if (_cursorSet) {
    [oscAPI setCursor:[NSCursor arrowCursor]];
    _cursorSet = NO;
  }
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super init];
  if (self) {
    _apiManager = apiManager;
    _hoveredIndex = -1;
    _draggingIndex = -1;
    _ghostAlpha = 1.0f;
    _hitPadding = 0.0;

    NSMutableArray *points =
        [NSMutableArray arrayWithCapacity:KKBoxHandleCount];
    for (int i = 0; i < KKBoxHandleCount; i++) {
      KKPointOSC *pt = [[KKPointOSC alloc] initWithAPIManager:apiManager];
      pt.clearsOnDraw = NO;
      // One handle size shared by every box OSC (crop, scale, ...). Slightly
      // smaller than the default point glyph so the dense 8-handle box does not
      // feel chunky; hitPadding gives back grab slack where a box needs it.
      pt.oscRadius = 6.0f;
      pt.outlineWidth = 2.0f;
      [points addObject:pt];
    }
    _pointOSCs = points;

    _borderOSC = [[KKRectBorderOSC alloc] initWithAPIManager:apiManager];
    _borderOSC.clearsOnDraw = NO;
    _sizeLabel = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    _sizeLabel.monospaced = YES;
  }
  return self;
}

+ (CGPoint)handlePositionForIndex:(NSInteger)index
                         topRight:(CGPoint)topRight
                       bottomLeft:(CGPoint)bottomLeft {
  double l = bottomLeft.x, r = topRight.x;
  double b = bottomLeft.y, t = topRight.y;
  double mx = (l + r) * 0.5, my = (b + t) * 0.5;
  switch (index) {
  case 0:
    return (CGPoint){l, b}; // bottom-left
  case 1:
    return (CGPoint){r, b}; // bottom-right
  case 2:
    return (CGPoint){r, t}; // top-right
  case 3:
    return (CGPoint){l, t}; // top-left
  case 4:
    return (CGPoint){mx, b}; // bottom-mid
  case 5:
    return (CGPoint){r, my}; // right-mid
  case 6:
    return (CGPoint){mx, t}; // top-mid
  case 7:
    return (CGPoint){l, my}; // left-mid
  default:
    return CGPointZero;
  }
}

- (void)drawWithTopRight:(CGPoint)topRight
              bottomLeft:(CGPoint)bottomLeft
                 readout:(NSString *)readout
            activeHandle:(NSInteger)activeHandle
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  // Fan the ghost dim out to the border + handles (opt-reveal preview).
  self.borderOSC.ghostAlpha = _ghostAlpha;
  [self.borderOSC drawWithTopRight:topRight
                        bottomLeft:bottomLeft
                  destinationImage:destinationImage];

  if (readout.length) {
    self.sizeLabel.text = readout;
    CGSize ls = self.sizeLabel.size;
    // Trailing edge to the box's right edge, just below the bottom edge.
    BOOL flippedY = topRight.y > bottomLeft.y;
    CGPoint labelPos =
        CGPointMake(topRight.x - ls.width / 2.0,
                    bottomLeft.y + (flippedY ? -(ls.height / 2.0 + 4.0)
                                             : (ls.height / 2.0 + 4.0)));
    [self.sizeLabel drawAtCanvasPosition:labelPos
                        destinationImage:destinationImage];
  }

  for (int i = 0; i < KKBoxHandleCount; i++) {
    CGPoint pos = [KKBoxOSC handlePositionForIndex:i
                                          topRight:topRight
                                        bottomLeft:bottomLeft];
    self.pointOSCs[i].ghostAlpha = _ghostAlpha;
    BOOL active = (i == activeHandle);
    [self.pointOSCs[i] drawAtCanvasPosition:pos
                                  isHovered:active
                                   isActive:active
                           destinationImage:destinationImage
                                     atTime:time];
  }
}

- (NSInteger)hitTestAtX:(double)x
                      y:(double)y
               topRight:(CGPoint)topRight
             bottomLeft:(CGPoint)bottomLeft {
  self.hoveredIndex = -1;
  NSInteger result = KKBoxPartNone;

  double minX = fmin(bottomLeft.x, topRight.x);
  double maxX = fmax(bottomLeft.x, topRight.x);
  double minY = fmin(bottomLeft.y, topRight.y);
  double maxY = fmax(bottomLeft.y, topRight.y);
  if (x >= minX && x <= maxX && y >= minY && y <= maxY)
    result = KKBoxPartRect;

  // Nearest handle wins, so corners take priority over the edges that share
  // their coordinate.
  NSInteger best = -1;
  double bestD = INFINITY;
  for (int i = 0; i < KKBoxHandleCount; i++) {
    CGPoint pos = [KKBoxOSC handlePositionForIndex:i
                                          topRight:topRight
                                        bottomLeft:bottomLeft];
    double d = hypot(x - pos.x, y - pos.y);
    if (d < self.pointOSCs[i].hitRadius + self.hitPadding && d < bestD) {
      bestD = d;
      best = i;
    }
  }
  if (best >= 0) {
    self.hoveredIndex = best;
    result = KKBoxPartHandleBase + best;
  }
  [self _applyResizeCursorForHandle:self.hoveredIndex];
  return result;
}

- (void)resetHover {
  self.hoveredIndex = -1;
  self.draggingIndex = -1;
  [self _applyResizeCursorForHandle:-1];
}

@end
