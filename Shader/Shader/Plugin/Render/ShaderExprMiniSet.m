/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ShaderExprMiniSet.h"

#import "ShaderOSCBlockRuntime.h"
#import <KeyframelessKit/KKResizeCursor.h>  // KKVisibilityShow/HideCursor
#import <KeyframelessKit/KeyframelessKit.h> // KKLane

@implementation ShaderExprMiniSet {
  __weak KKMiniViewerRenderer *_renderer;
  NSArray<ShaderOSCBlockRuntime *> *_runtimes;
  NSString *_syncedSource;
  NSString *_activeName; // block being dragged (nil = none)
}

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer {
  if ((self = [super init])) {
    _renderer = renderer;
    _runtimes = @[];
  }
  return self;
}

- (void)syncWithSource:(NSString *)src lanes:(NSArray<KKLane *> *)lanes {
  NSString *s = src ?: @"";
  if ([s isEqualToString:_syncedSource])
    return;
  _syncedSource = [s copy];
  _runtimes = [ShaderOSCBlockRuntime runtimesForSource:s lanes:lanes ?: @[]];
}

// Grab radius (overlay px) matching the viewer: the hollow ring is a touch
// larger than a dot.
static CGFloat ShaderExprMiniGrab(ShaderOSCBlockRuntime *b) {
  return [b.styleName isEqualToString:@"hollow"] ? 12.0 : 10.0;
}

static KKMiniHandleStyle ShaderExprMiniStyle(ShaderOSCBlockRuntime *b) {
  return [b.styleName isEqualToString:@"hollow"] ? KKMiniHandleStyleRing
                                                 : KKMiniHandleStylePoint;
}

// A handle is drawn / hit-tested this frame when its lane is constant here
// (matching the ring set) and its checklist element is visible (or Opt-reveal
// is peeking it). The element key is the block NAME; the lane is `binds`.
- (BOOL)_activeRuntime:(ShaderOSCBlockRuntime *)b forContentRect:(CGRect)cr {
  KKMiniViewerRenderer *r = _renderer;
  return r && !CGRectIsEmpty(cr) && b.name.length &&
         ![r.suppressedHandleLabels containsObject:b.name] &&
         [r isConstantLabel:b.binds] && [r labelVisibleOrRevealing:b.name];
}

// The handle's overlay centre for the current lane value: bound -> forward
// (object) -> overlay via the renderer's clip-space mapping.
- (CGPoint)_centerForRuntime:(ShaderOSCBlockRuntime *)b contentRect:(CGRect)cr {
  KKMiniViewerRenderer *r = _renderer;
  KKExprVal bound = [b boundValueFromLaneValues:[r valuesForLabel:b.binds]];
  double aspect = cr.size.height > 0 ? cr.size.width / cr.size.height : 1.0;
  simd_float2 o = [b objectPointForBound:bound
                                  aspect:aspect
                                   mouse:(simd_float2){0, 0}
                               haveMouse:NO];
  return [r handlePointForContentRect:cr position:@[ @(o.x), @(o.y) ]];
}

- (nullable ShaderOSCBlockRuntime *)_runtimeAtPoint:(CGPoint)p
                                        contentRect:(CGRect)cr {
  for (ShaderOSCBlockRuntime *b in _runtimes) {
    if (![self _activeRuntime:b forContentRect:cr])
      continue;
    CGPoint c = [self _centerForRuntime:b contentRect:cr];
    if (hypot(p.x - c.x, p.y - c.y) <= ShaderExprMiniGrab(b))
      return b;
  }
  return nil;
}

- (NSArray<NSDictionary<NSString *, id> *> *)glyphBundlesForContentRect:
    (CGRect)cr {
  KKMiniViewerRenderer *r = _renderer;
  NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];
  for (ShaderOSCBlockRuntime *b in _runtimes) {
    if (![self _activeRuntime:b forContentRect:cr])
      continue;
    CGPoint c = [self _centerForRuntime:b contentRect:cr];
    [out addObject:@{
      @"center" : [NSValue valueWithPoint:c],
      @"style" : @(ShaderExprMiniStyle(b)),
      @"alpha" : @([r ghostAlphaForLabel:b.name]),
    }];
  }
  return out;
}

- (BOOL)handleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  return [self _runtimeAtPoint:p contentRect:cr] != nil;
}

- (NSCursor *)cursorAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  ShaderOSCBlockRuntime *hit = [self _runtimeAtPoint:p contentRect:cr];
  if (!hit)
    return nil;
  KKMiniViewerRenderer *r = _renderer;
  // Opt-hover hide/show affordance: only when an Opt-click would toggle.
  BOOL optToggle =
      r.revealHidden && !r.handlesHidden && r.onHandleVisibilityToggled != nil;
  if (optToggle)
    return ([r ghostAlphaForLabel:hit.name] < 1.0) ? KKVisibilityShowCursor()
                                                   : KKVisibilityHideCursor();
  if ([r ghostAlphaForLabel:hit.name] < 1.0)
    return nil; // a re-enable ghost keeps the arrow
  return ShaderOSCCursorForName(hit.cursorName);
}

- (BOOL)beginDragAtPoint:(CGPoint)p
             contentRect:(CGRect)cr
                  canvas:(KKMiniViewerView *)canvas {
  ShaderOSCBlockRuntime *hit = [self _runtimeAtPoint:p contentRect:cr];
  if (!hit)
    return NO;
  _activeName = hit.name;
  [canvas setNeedsDisplay:YES];
  return YES;
}

- (BOOL)dragToPoint:(CGPoint)p
        contentRect:(CGRect)cr
             canvas:(KKMiniViewerView *)canvas {
  if (!_activeName)
    return NO;
  ShaderOSCBlockRuntime *b = nil;
  for (ShaderOSCBlockRuntime *r in _runtimes)
    if ([r.name isEqualToString:_activeName]) {
      b = r;
      break;
    }
  if (!b)
    return YES;
  KKMiniViewerRenderer *r = _renderer;
  double aspect = cr.size.height > 0 ? cr.size.width / cr.size.height : 1.0;
  simd_float2 om = {
      cr.size.width > 0 ? (float)((p.x - CGRectGetMinX(cr)) / cr.size.width)
                        : 0,
      cr.size.height > 0 ? (float)((p.y - CGRectGetMinY(cr)) / cr.size.height)
                         : 0};
  KKExprVal nv;
  if (b.hasInverse) {
    KKExprVal bound = [b boundValueFromLaneValues:[r valuesForLabel:b.binds]];
    nv = [b inverseBoundForObjectMouse:om boundNow:bound aspect:aspect];
  } else {
    nv = [b invertBoundForObjectPoint:om aspect:aspect];
  }
  [r commitValues:[b laneValuesFromBound:nv] forLabel:b.binds canvas:canvas];
  [canvas setNeedsDisplay:YES];
  return YES;
}

- (BOOL)endDragOnCanvas:(KKMiniViewerView *)canvas {
  if (!_activeName)
    return NO;
  _activeName = nil;
  [canvas setNeedsDisplay:YES];
  return YES;
}

- (BOOL)optClickAtPoint:(CGPoint)p
            contentRect:(CGRect)cr
                 canvas:(KKMiniViewerView *)canvas {
  ShaderOSCBlockRuntime *hit = [self _runtimeAtPoint:p contentRect:cr];
  if (!hit)
    return NO;
  KKMiniViewerRenderer *r = _renderer;
  if (r.onHandleVisibilityToggled)
    r.onHandleVisibilityToggled(hit.name);
  [canvas setNeedsDisplay:YES];
  return YES;
}

@end
