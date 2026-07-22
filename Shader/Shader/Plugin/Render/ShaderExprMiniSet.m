/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ShaderExprMiniSet.h"

#import "ShaderOSCBlockRuntime.h"
#import <KeyframelessKit/KKResizeCursor.h>  // KKVisibilityShow/HideCursor
#import <KeyframelessKit/KKSnapEngine.h>    // Cmd-held point snapping (parity)
#import <KeyframelessKit/KeyframelessKit.h> // KKLane

@implementation ShaderExprMiniSet {
  __weak KKMiniViewerRenderer *_renderer;
  NSArray<ShaderOSCBlockRuntime *> *_runtimes;
  NSString *_syncedSource;
  NSString *_activeName; // block being dragged (nil = none)
  // Ring-drag press anchor: the bound value + the cursor's offset from the
  // centre (content-min-dim fractions) at mouse-down, for the runtime's shared
  // ring mechanic (cardinal-hold / linked factor).
  KKExprVal _dragPressBound;
  simd_float2 _dragPressOff;
  // The shared anchored-resize + body-move mechanic for `box` blocks (one
  // in-flight drag at a time, so one editor serves every box).
  KKMiniViewerCropEditor *_cropEditor;
  // Centred-box drag (`body = none`): the grabbed handle's classification for
  // the runtime's centred mechanic (the editor only mechanises crop-style
  // boxes).
  BOOL _dragBoxCentered, _dragBoxCorner, _dragBoxControlsX;
  // Cmd-held point snapping (parity with the viewer + osc=position): snaps the
  // dragged point handle onto the canvas anchors + the other point/position
  // handles. Snap-guide state is reported to the overlay while a point drags.
  KKSnapEngine *_snap;
  BOOL _snapDragging;        // a snapping point drag is live
  BOOL _snapHasX, _snapHasY; // an axis snapped this tick
  float _snapX, _snapY;      // snapped value (normalized 0..1)
  BOOL _snapXFromObj,
      _snapYFromObj; // matched a handle (blue) vs anchor (yellow)
}

// Handle classification for KKMiniViewerCropEditor's part order (1 + idx with
// idx: 0 TL, 1 top, 2 TR, 3 right, 4 BR, 5 bottom, 6 BL, 7 left).
static BOOL ShaderExprMiniBoxCorner(NSInteger idx) { return (idx % 2) == 0; }
static BOOL ShaderExprMiniBoxControlsX(NSInteger idx) {
  return (idx % 2) == 0 || idx == 3 || idx == 7;
}

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer {
  if ((self = [super init])) {
    _renderer = renderer;
    _runtimes = @[];
    _snap = [[KKSnapEngine alloc] init];
  }
  return self;
}

// Normalized value positions (0..1) of every point/position handle EXCEPT the
// one bound to `binds` - the shared snap target set (points snap onto positions
// and vice-versa). Geometry lives in ShaderOSCBlockRuntime (shared with the
// viewer); this supplies the mini's renderer lane values.
- (NSArray<NSValue *> *)_snapTargetsExcludingBinds:(NSString *)binds
                                       contentRect:(CGRect)cr {
  KKMiniViewerRenderer *r = _renderer;
  double aspect = cr.size.height > 0 ? cr.size.width / cr.size.height : 1.0;
  return [ShaderOSCBlockRuntime
      snapTargetsForRuntimes:_runtimes
              excludingBinds:binds
                      aspect:aspect
                  laneValues:^NSArray<NSNumber *> *(NSString *b) {
                    return [r valuesForLabel:b];
                  }];
}

- (NSArray<NSValue *> *)pointHandleValuePositionsForContentRect:(CGRect)cr {
  KKMiniViewerRenderer *r = _renderer;
  double aspect = cr.size.height > 0 ? cr.size.width / cr.size.height : 1.0;
  NSMutableArray<NSValue *> *out = [NSMutableArray array];
  for (ShaderOSCBlockRuntime *b in _runtimes) {
    if (![b.primitive isEqualToString:@"point"])
      continue;
    simd_float2 o = [ShaderOSCBlockRuntime
        handleObjectPointForRuntime:b
                         laneValues:[r valuesForLabel:b.binds]
                             aspect:aspect];
    [out addObject:[NSValue valueWithPoint:NSMakePoint(o.x, o.y)]];
  }
  return out;
}

- (BOOL)draggingSnapPoint {
  return _snapDragging;
}

- (void)snapGuideHasX:(out BOOL *)hasX
                    X:(out CGFloat *)outX
         fromKeyposeX:(out BOOL *)fromKeyposeX
                 hasY:(out BOOL *)hasY
                    Y:(out CGFloat *)outY
         fromKeyposeY:(out BOOL *)fromKeyposeY {
  if (hasX)
    *hasX = _snapHasX;
  if (outX)
    *outX = _snapX;
  if (fromKeyposeX)
    *fromKeyposeX = _snapXFromObj;
  if (hasY)
    *hasY = _snapHasY;
  if (outY)
    *outY = _snapY;
  if (fromKeyposeY)
    *fromKeyposeY = _snapYFromObj;
}

- (void)syncWithSource:(NSString *)src lanes:(NSArray<KKLane *> *)lanes {
  NSString *s = src ?: @"";
  if ([s isEqualToString:_syncedSource])
    return;
  _syncedSource = [s copy];
  _runtimes = [ShaderOSCBlockRuntime runtimesForSource:s lanes:lanes ?: @[]];
  // A referenced uniform (center = uOrigin, …) reads the mini's ROOT lane
  // value (un-link-resolved, matching the radial sets' centre handling).
  __weak KKMiniViewerRenderer *weakRenderer = _renderer;
  for (ShaderOSCBlockRuntime *b in _runtimes)
    b.laneValueProvider = ^NSArray<NSNumber *> *(NSString *label) {
      return [weakRenderer rootValuesForLabel:label];
    };
}

static BOOL ShaderExprMiniIsRing(ShaderOSCBlockRuntime *b) {
  return [b.primitive isEqualToString:@"ring"];
}

static BOOL ShaderExprMiniIsBox(ShaderOSCBlockRuntime *b) {
  return [b.primitive isEqualToString:@"box"];
}

// Rotate blocks (KKRotationOSCSet) and position blocks (KKPointOSCSet) are
// drawn/dragged by their own sets; they have NO forward expression, so
// letting them into the glyph path would paint a dead handle at object (0,0).
static BOOL ShaderExprMiniIsGlyph(ShaderOSCBlockRuntime *b) {
  return [b.primitive isEqualToString:@"point"];
}

- (KKMiniViewerCropEditor *)_boxEditor {
  if (!_cropEditor)
    _cropEditor = [KKMiniViewerCropEditor new];
  return _cropEditor;
}

// A box block's current geometry as the crop-model values the editor drives
// (the fixed rect <-> [w,h,x,y] bridge lives in the runtime).
- (NSArray<NSNumber *> *)_boxValuesForRuntime:(ShaderOSCBlockRuntime *)b
                                  contentRect:(CGRect)cr {
  KKMiniViewerRenderer *r = _renderer;
  KKExprVal bound = [b boundValueFromLaneValues:[r rootValuesForLabel:b.binds]];
  double aspect = cr.size.height > 0 ? cr.size.width / cr.size.height : 1.0;
  return [ShaderOSCBlockRuntime cropModelFromRect:[b boxRectForBound:bound
                                                              aspect:aspect]];
}

// Grab radius (overlay px) matching the viewer: the hollow ring is a touch
// larger than a dot.
static CGFloat ShaderExprMiniGrab(ShaderOSCBlockRuntime *b) {
  return [b.styleName isEqualToString:@"hollow"] ? 12.0 : 10.0;
}

static KKMiniHandleStyle ShaderExprMiniStyle(ShaderOSCBlockRuntime *b) {
  if ([b.styleName isEqualToString:@"hollow"])
    return KKMiniHandleStyleRing;
  if ([b.styleName isEqualToString:@"square"])
    return KKMiniHandleStyleSquare;
  if ([b.styleName isEqualToString:@"arc"])
    return KKMiniHandleStyleArc;
  return KKMiniHandleStylePoint;
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

// A ring block's overlay centre + per-axis pixel radii for the current value
// (the runtime returns min-dimension fractions).
- (BOOL)_ringGeomForRuntime:(ShaderOSCBlockRuntime *)b
                contentRect:(CGRect)cr
                     center:(out CGPoint *)outCenter
                    radiusX:(out CGFloat *)outRx
                    radiusY:(out CGFloat *)outRy {
  KKMiniViewerRenderer *r = _renderer;
  KKExprVal bound = [b boundValueFromLaneValues:[r rootValuesForLabel:b.binds]];
  double aspect = cr.size.height > 0 ? cr.size.width / cr.size.height : 1.0;
  simd_float2 oc = [b centerObjectForBound:bound aspect:aspect];
  KKExprVal radii = [b ringRadiiForBound:bound aspect:aspect];
  double minDim = MIN(cr.size.width, cr.size.height);
  if (outCenter)
    *outCenter = [r handlePointForContentRect:cr
                                     position:@[ @(oc.x), @(oc.y) ]];
  if (outRx)
    *outRx = (CGFloat)(radii.v[0] * minDim);
  if (outRy)
    *outRy = (CGFloat)((radii.n >= 2 ? radii.v[1] : radii.v[0]) * minDim);
  return YES;
}

- (nullable ShaderOSCBlockRuntime *)_runtimeAtPoint:(CGPoint)p
                                        contentRect:(CGRect)cr {
  // Pass 1: precise parts only (glyphs, ring strokes, box HANDLES). A box
  // interior claims in a second pass, so a large box never steals the click
  // from a smaller control inside it.
  for (ShaderOSCBlockRuntime *b in _runtimes) {
    if (![self _activeRuntime:b forContentRect:cr])
      continue;
    if (ShaderExprMiniIsBox(b)) {
      if ([[self _boxEditor] partAtPoint:p
                                  values:[self _boxValuesForRuntime:b
                                                        contentRect:cr]
                             contentRect:cr] > 0)
        return b;
      continue;
    }
    if (ShaderExprMiniIsRing(b)) {
      // Elliptical stroke distance, like KKRingOSCSet.
      CGPoint c = CGPointZero;
      CGFloat rx = 0, ry = 0;
      [self _ringGeomForRuntime:b
                    contentRect:cr
                         center:&c
                        radiusX:&rx
                        radiusY:&ry];
      if (rx < 1.0 && ry < 1.0)
        continue;
      double nx = rx > 0 ? (p.x - c.x) / rx : 0;
      double ny = ry > 0 ? (p.y - c.y) / ry : 0;
      double ringDist = fabs(sqrt(nx * nx + ny * ny) - 1.0) * ((rx + ry) * 0.5);
      if (ringDist < 6.0)
        return b;
      continue;
    }
    if (!ShaderExprMiniIsGlyph(b))
      continue; // rotate / position blocks belong to their own sets
    CGPoint c = [self _centerForRuntime:b contentRect:cr];
    if (hypot(p.x - c.x, p.y - c.y) <= ShaderExprMiniGrab(b))
      return b;
  }
  // Pass 2: box interiors (body-move only; a centred `body = none` box has an
  // inert interior).
  for (ShaderOSCBlockRuntime *b in _runtimes) {
    if (!ShaderExprMiniIsBox(b) || !b.bodyMove ||
        ![self _activeRuntime:b forContentRect:cr])
      continue;
    if ([[self _boxEditor] partAtPoint:p
                                values:[self _boxValuesForRuntime:b
                                                      contentRect:cr]
                           contentRect:cr] == 0)
      return b;
  }
  return nil;
}

- (NSArray<NSDictionary<NSString *, id> *> *)glyphBundlesForContentRect:
    (CGRect)cr {
  KKMiniViewerRenderer *r = _renderer;
  NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];
  for (ShaderOSCBlockRuntime *b in _runtimes) {
    if (!ShaderExprMiniIsGlyph(b) || ![self _activeRuntime:b forContentRect:cr])
      continue;
    CGPoint c = [self _centerForRuntime:b contentRect:cr];
    [out addObject:@{
      @"center" : [NSValue valueWithPoint:c],
      @"style" : @(ShaderExprMiniStyle(b)),
      @"alpha" : @([r ghostAlphaForLabel:b.name]),
      // The viewer's dot glyph (KKPointOSC) is WHITE; ask the mini to match
      // instead of its accent position-handle fill.
      @"white" : @YES,
    }];
  }
  return out;
}

- (NSArray<KKMiniBox *> *)boxesForContentRect:(CGRect)cr
                                    mediaSize:(CGSize)mediaSize {
  KKMiniViewerRenderer *r = _renderer;
  NSMutableArray<KKMiniBox *> *out = [NSMutableArray array];
  KKMiniViewerCropEditor *editor = [self _boxEditor];
  for (ShaderOSCBlockRuntime *b in _runtimes) {
    if (!ShaderExprMiniIsBox(b) || ![self _activeRuntime:b forContentRect:cr])
      continue;
    NSArray<NSNumber *> *values = [self _boxValuesForRuntime:b contentRect:cr];
    // Value-model boxes (1-2 fields) show their lane value like the old
    // inline boxes; a crop-style vec4 shows its rect in SOURCE PIXELS,
    // matching the viewer's crop readout.
    NSString *readout = nil;
    if (b.fieldCount <= 2) {
      readout = KKBoxOSCReadoutString([r rootValuesForLabel:b.binds],
                                      b.divisor == 100.0, b.isInt);
    } else {
      // A crop-style vec4 box shows its W x H in the BOUND LANE's display
      // units (px only for a "px" component, else the raw fraction), matching
      // the lane fields instead of always forcing source pixels.
      readout = [ShaderOSCBlockRuntime
          boxReadoutForValues:[r rootValuesForLabel:b.binds]
                        units:b.boundComponentUnits
              scalesWithMedia:b.boundScalesWithMedia
                    mediaSize:mediaSize];
    }
    [out addObject:[KKMiniBox boxWithRect:[editor cropRectForValues:values
                                                        contentRect:cr]
                            handleCenters:[editor handleCentersForValues:values
                                                             contentRect:cr]
                                  readout:readout
                               ghostAlpha:[r ghostAlphaForLabel:b.name]]];
  }
  return out;
}

- (NSArray<NSDictionary<NSString *, id> *> *)ringBundlesForContentRect:
    (CGRect)cr {
  KKMiniViewerRenderer *r = _renderer;
  NSMutableArray<NSDictionary<NSString *, id> *> *out = [NSMutableArray array];
  for (ShaderOSCBlockRuntime *b in _runtimes) {
    if (!ShaderExprMiniIsRing(b) || ![self _activeRuntime:b forContentRect:cr])
      continue;
    CGPoint c = CGPointZero;
    CGFloat rx = 0, ry = 0;
    [self _ringGeomForRuntime:b
                  contentRect:cr
                       center:&c
                      radiusX:&rx
                      radiusY:&ry];
    if (rx <= 0.5 && ry <= 0.5)
      continue;
    // A thin ring's ghost is barely visible at the base 0.3 dim; lift it to
    // 0.6 (peek mode returns 1.0, so it stays fully interactive there).
    CGFloat alpha = [r ghostAlphaForLabel:b.name] < 1.0 ? 0.6 : 1.0;
    BOOL ghost = alpha < 0.999;
    NSInteger emphasis =
        ghost ? 0 : ([_activeName isEqualToString:b.name] ? 2 : 0);
    [out addObject:@{
      @"center" : [NSValue valueWithPoint:c],
      @"radiusX" : @(rx),
      @"radiusY" : @(ry),
      @"emphasis" : @(emphasis),
      @"alpha" : @(alpha),
    }];
  }
  return out;
}

- (BOOL)handleHitAtPoint:(CGPoint)p contentRect:(CGRect)cr {
  return [self _runtimeAtPoint:p contentRect:cr] != nil;
}

// The lane's persisted aspect lock when it carries aspect metadata, else the
// template's directive default (mirrors KKRadialOSCSet's laneLinkedForLabel).
- (BOOL)_laneLinkedForLabel:(NSString *)label {
  KKMiniViewerRenderer *r = _renderer;
  for (KKLane *l in r.timeline.lanes)
    if ([l.label isEqualToString:label]) {
      if (l.aspectLinkable)
        return l.aspectLinked;
      break;
    }
  KKLane *tmpl = [r templateLaneForLabel:label];
  return tmpl ? tmpl.aspectLinked : YES;
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
  if (ShaderExprMiniIsRing(hit)) {
    CGPoint c = CGPointZero;
    [self _ringGeomForRuntime:hit
                  contentRect:cr
                       center:&c
                      radiusX:NULL
                      radiusY:NULL];
    return KKResizeCursorForAngle(atan2(p.y - c.y, p.x - c.x));
  }
  if (ShaderExprMiniIsBox(hit)) {
    NSArray<NSNumber *> *values = [self _boxValuesForRuntime:hit
                                                 contentRect:cr];
    KKMiniViewerCropEditor *editor = [self _boxEditor];
    NSInteger part = [editor partAtPoint:p values:values contentRect:cr];
    if (part <= 0)
      return KKPointMoveCursor(); // the body moves the whole box
    CGRect R = [editor cropRectForValues:values contentRect:cr];
    return KKResizeCursorForAngle(
        atan2(p.y - CGRectGetMidY(R), p.x - CGRectGetMidX(R)));
  }
  return ShaderOSCCursorForName(hit.cursorName);
}

- (BOOL)beginDragAtPoint:(CGPoint)p
             contentRect:(CGRect)cr
                  canvas:(KKMiniViewerView *)canvas {
  ShaderOSCBlockRuntime *hit = [self _runtimeAtPoint:p contentRect:cr];
  if (!hit)
    return NO;
  _activeName = hit.name;
  if (ShaderExprMiniIsRing(hit)) {
    KKMiniViewerRenderer *r = _renderer;
    _dragPressBound =
        [hit boundValueFromLaneValues:[r rootValuesForLabel:hit.binds]];
    CGPoint c = CGPointZero;
    [self _ringGeomForRuntime:hit
                  contentRect:cr
                       center:&c
                      radiusX:NULL
                      radiusY:NULL];
    double minDim = MAX(1.0, MIN(cr.size.width, cr.size.height));
    _dragPressOff = (simd_float2){(float)((p.x - c.x) / minDim),
                                  (float)((p.y - c.y) / minDim)};
  } else if (ShaderExprMiniIsBox(hit)) {
    NSInteger part = [[self _boxEditor]
        beginDragAtPoint:p
                  values:[self _boxValuesForRuntime:hit contentRect:cr]
             contentRect:cr];
    if (part < 0 || (part == 0 && !hit.bodyMove)) {
      [_cropEditor endDrag];
      _activeName = nil;
      return NO;
    }
    // Centred box (`body = none`): the runtime owns the drag; latch the
    // grabbed handle's classification + the press bound.
    _dragBoxCentered = !hit.bodyMove;
    if (_dragBoxCentered) {
      [_cropEditor endDrag]; // the editor only mechanises crop-style boxes
      NSInteger idx = part - 1;
      _dragBoxCorner = ShaderExprMiniBoxCorner(idx);
      _dragBoxControlsX = ShaderExprMiniBoxControlsX(idx);
      KKMiniViewerRenderer *r = _renderer;
      _dragPressBound =
          [hit boundValueFromLaneValues:[r rootValuesForLabel:hit.binds]];
    }
  }
  [canvas setNeedsDisplay:YES];
  return YES;
}

- (BOOL)dragToPoint:(CGPoint)p
        contentRect:(CGRect)cr
             canvas:(KKMiniViewerView *)canvas
          modifiers:(NSEventModifierFlags)modifiers {
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
  if (ShaderExprMiniIsBox(b)) {
    if (_dragBoxCentered) {
      // Centred box: the runtime's mechanic (grow AND shrink from the fixed
      // centre, aspect-lock coupling), cursor converted to object space.
      simd_float2 mObj = {
          cr.size.width > 0 ? (float)((p.x - CGRectGetMinX(cr)) / cr.size.width)
                            : 0,
          cr.size.height > 0
              ? (float)((p.y - CGRectGetMinY(cr)) / cr.size.height)
              : 0};
      BOOL shift = (modifiers & NSEventModifierFlagShift) != 0;
      BOOL laneLinked = b.linked && [self _laneLinkedForLabel:b.binds];
      BOOL effLinked = b.linked ? (laneLinked ^ shift) : NO;
      KKExprVal nv = [b boxCenteredBoundForObjectMouse:mObj
                                                corner:_dragBoxCorner
                                             controlsX:_dragBoxControlsX
                                            pressBound:_dragPressBound
                                       linkedEffective:effLinked
                                                aspect:aspect];
      [r commitValues:[b laneValuesFromBound:nv]
             forLabel:b.binds
               canvas:canvas];
      [canvas setNeedsDisplay:YES];
      return YES;
    }
    // Crop-style box: the editor owns the anchored-resize + body-move
    // mechanic; its new [w,h,x,y] bridges back through fromRect.
    NSArray<NSNumber *> *values = [[self _boxEditor] valuesForDragToPoint:p
                                                              contentRect:cr];
    if (!values)
      return YES;
    KKExprVal rect = [ShaderOSCBlockRuntime rectFromCropModel:values];
    KKExprVal boundNow =
        [b boundValueFromLaneValues:[r rootValuesForLabel:b.binds]];
    KKExprVal nv = [b boxBoundForRect:rect boundNow:boundNow aspect:aspect];
    [r commitValues:[b laneValuesFromBound:nv] forLabel:b.binds canvas:canvas];
    [canvas setNeedsDisplay:YES];
    return YES;
  }
  if (ShaderExprMiniIsRing(b)) {
    // The runtime's shared ring mechanic, offsets in min-dim fractions - the
    // identical math the viewer runs, so both drags feel the same.
    CGPoint c = CGPointZero;
    [self _ringGeomForRuntime:b
                  contentRect:cr
                       center:&c
                      radiusX:NULL
                      radiusY:NULL];
    double minDim = MAX(1.0, MIN(cr.size.width, cr.size.height));
    simd_float2 off = {(float)((p.x - c.x) / minDim),
                       (float)((p.y - c.y) / minDim)};
    BOOL shift = (modifiers & NSEventModifierFlagShift) != 0;
    BOOL laneLinked = b.linked && [self _laneLinkedForLabel:b.binds];
    BOOL effLinked = b.linked ? (laneLinked ^ shift) : NO;
    KKExprVal nv = [b ringBoundForDragOffset:off
                                 pressOffset:_dragPressOff
                                  pressBound:_dragPressBound
                             linkedEffective:effLinked
                                      aspect:aspect];
    [r commitValues:[b laneValuesFromBound:nv] forLabel:b.binds canvas:canvas];
    [canvas setNeedsDisplay:YES];
    return YES;
  }
  simd_float2 om = {
      cr.size.width > 0 ? (float)((p.x - CGRectGetMinX(cr)) / cr.size.width)
                        : 0,
      cr.size.height > 0 ? (float)((p.y - CGRectGetMinY(cr)) / cr.size.height)
                         : 0};
  // Cmd-held snapping (parity with the viewer + osc=position): snap the cursor
  // onto the canvas anchors + the other point/position handles, in normalized
  // value space. `skipsnapping` blocks (b.snaps == NO) opt out.
  _snapDragging = YES;
  _snapHasX = _snapHasY = NO;
  if (b.snaps && (modifiers & NSEventModifierFlagCommand)) {
    static const float anchors[] = {0.0f, 0.25f, 0.5f, 0.75f, 1.0f};
    NSArray<NSValue *> *targets = [self _snapTargetsExcludingBinds:b.binds
                                                       contentRect:cr];
    NSUInteger n = targets.count;
    simd_float2 *objs = n ? malloc(n * sizeof(simd_float2)) : NULL;
    for (NSUInteger i = 0; i < n; i++) {
      NSPoint tp = targets[i].pointValue;
      objs[i] = (simd_float2){(float)tp.x, (float)tp.y};
    }
    float thrX = cr.size.width > 0 ? 6.0f / (float)cr.size.width : 0.01f;
    float thrY = cr.size.height > 0 ? 6.0f / (float)cr.size.height : 0.01f;
    om = [_snap snapPoint:om
           canvasAnchorsX:anchors
                   countX:5
           canvasAnchorsY:anchors
                   countY:5
            objectTargets:objs
                    count:n
               thresholdX:thrX
               thresholdY:thrY];
    if (objs)
      free(objs);
    _snapHasX = _snap.snappedX;
    _snapHasY = _snap.snappedY;
    _snapX = om.x;
    _snapY = om.y;
    _snapXFromObj = _snap.snapXFromObject;
    _snapYFromObj = _snap.snapYFromObject;
  } else {
    [_snap reset];
  }
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
  _dragBoxCentered = NO;
  _snapDragging = NO;
  _snapHasX = _snapHasY = NO;
  [_snap reset];
  [_cropEditor endDrag];
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
