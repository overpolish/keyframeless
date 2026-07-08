/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC.h"
#import "Constants.h"
#import "OSC_Internal.h"
#import "MeshOSCRadiusMath.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

// Mirrors KKOSCGuideBridge's position-notification name (the bridge posts it);
// the plugin returns this as its help-guide refresh notification.
NSNotificationName const kMeshOSCPositionNotification =
    @"co.overpolish.kk.oscGuidePosition";

static MeshOSC *sCurrentOSC = nil;

// All OSC-guide affine / staleness / velocity-gate state now lives in the
// generic KKOSCGuideBridge (KeyframelessKit). One process-lifetime instance
// per XPC process - the inspector custom view and the OSC render run in the
// same process (pid confirmed identical). MRR: retained forever, no
// dispatch_once (autoreleased ObjC statics dangle under MRR).
static KKOSCGuideBridge *MeshGuideBridge(void) {
  static KKOSCGuideBridge *sBridge = nil;
  if (!sBridge)
    sBridge = [[KKOSCGuideBridge alloc] init];
  return sBridge;
}

// Same instance, exported so the inspector guide (same XPC process) can hand
// it to a KKJoyrideOSCSegment.
KKOSCGuideBridge *MeshSharedOSCGuideBridge(void) {
  return MeshGuideBridge();
}

// Re-anchor the bridge's screen↔canvas map by pairing a screen point with the
// OSC handle's current canvas position (the bridge supplies the live scale).
static BOOL MeshReanchor(MeshOSC *osc, NSPoint screenPt) {
  if (!osc)
    return NO;
  CGPoint handle = [osc oscPositionAtTime:kCMTimeZero];
  return [MeshGuideBridge() reanchorAtScreen:screenPt
                                handleCanvasPos:handle];
}

void MeshSetOSCGuideStep(NSInteger step) {
  MeshGuideBridge().guideStep = step;
}

BOOL MeshHasCanvasReference(void) {
  return [MeshGuideBridge() hasCanvasReference];
}

void MeshOSCCaptureGuideAnchorAtScreen(NSPoint screenPt) {
  MeshOSC *osc = sCurrentOSC;
  if (!osc) {
    KKLogWarn(@"[OSCGuide] capture anchor skipped: no current OSC");
    return;
  }
  if (!MeshReanchor(osc, screenPt))
    KKLogWarn(@"[OSCGuide] capture anchor skipped: no live scale yet "
              @"(drawOSC has not run)");
}

// Guide-scoped radius. The OSC cannot read the KKDataBlob from the drawOSC
// tick (FxParameterRetrievalAPI is nil there - see oscAPI2=nil in every
// drawOSC log). During the guide the blob-drag handler pushes the live radius
// here (same XPC process - pid confirmed identical) so the OSC handle tracks
// without the unreadable blob. Real (non-guide) OSC↔blob reads are Phase 10.
static double sGuideRadius = 20.0;

void MeshSetGuideRadius(double radius) { sGuideRadius = radius; }

// Point-OSC value mapping: invert the bridge's proportional viewer-rect map
// (screen → canvas), then the OSC's own radius math, so the drag tracks the
// cursor 1:1 like a native OSC drag. Falls back to the last guide radius
// until the bridge has cached usable geometry. This is the only OSC-shape-
// specific piece left in this file; a different OSC supplies its own.
double MeshGuideRadiusForScreenPoint(NSPoint screenPt) {
  KKOSCGuideBridge *b = MeshGuideBridge();
  NSRect vr = b.estimatedViewerScreenRect;
  CGPoint tr = b.currentCanvasTopRight, bl = b.currentCanvasBottomLeft;
  if (!b.geometryValid || NSIsEmptyRect(vr) || fabs(tr.x - bl.x) < 1e-3 ||
      fabs(tr.y - bl.y) < 1e-3)
    return sGuideRadius;
  double oscSize = sCurrentOSC ? sCurrentOSC.oscSize : 0.0;
  double minDim = fmin(fabs(tr.x - bl.x), fabs(tr.y - bl.y));
  // Inverse of the bridge's proportional viewer-rect map: screen → canvas.
  double cx = bl.x + (screenPt.x - NSMinX(vr)) / NSWidth(vr) * (tr.x - bl.x);
  double cy = bl.y + (screenPt.y - NSMinY(vr)) / NSHeight(vr) * (tr.y - bl.y);
  // Same as mouseDraggedAtPositionX:.
  double signX = (tr.x - bl.x) < 0 ? -1.0 : 1.0;
  double signY = (tr.y - bl.y) < 0 ? -1.0 : 1.0;
  double dx = cx - tr.x, dy = cy - tr.y;
  double mouseDist = (-dx * signX + -dy * signY) * 0.5 - oscSize;
  float lo = 0.0f, hi = 100.0f;
  for (int i = 0; i < 32; i++) {
    float mid = (lo + hi) * 0.5f;
    if (paddingForRadius(mid, (float)minDim) < mouseDist)
      lo = mid;
    else
      hi = mid;
  }
  return MAX(0.0, MIN(100.0, (lo + hi) * 0.5));
}

@implementation MeshOSC {
  // Radius handle glyph: the shared KKRingOSC, so it matches Canvas's corner
  // widget + Glow's radius ring. MeshOSC stays a KKPointOSC for hit-testing /
  // drag / guide logic; only the drawn glyph changes.
  KKRingOSC *_ringGlyph;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
    _dragCurrentRadius = 20.0;
    // Match the shared box-OSC handle size so the radius point and the crop
    // box's corner/edge handles are one size.
    self.oscRadius = 6.0f;
    // White for legibility on any background, matching the mini-viewer radius
    // handle + Canvas's corner ring.
    self.fillColorOverride = [NSColor whiteColor];
    // The radius handle draws as the shared ring glyph (see -drawAtCanvasPosition
    // override) - white, crisp ring shader. Sized to the old point's footprint
    // so hit-testing (still KKPointOSC) stays aligned.
    _ringGlyph = [[KKRingOSC alloc] initWithAPIManager:apiManager];
    [_ringGlyph applyRadiusWidgetStyle]; // shared style with Canvas's corner widget
    _ringGlyph.tintColor = [NSColor whiteColor];

    // Crop OSC: model-agnostic block-based I/O. Reads from / writes to the
    // Mesh timeline-snapshot Crop lane (single instance per PLAN §"OSC
    // cache"). The OSC owns rendering + drag math; we own persistence.
    _cropOSC = [[KKCropOSC alloc] initWithAPIManager:apiManager];
    __weak typeof(self) weak = self;
    _cropOSC.valuesProvider = ^NSArray<NSNumber *> *(CMTime t) {
      __strong typeof(weak) strong = weak;
      double frac = strong ? [strong fractionAtTime:t] : 0.0;
      return MeshSnapshotValuesForLabel(@"Crop", frac,
                                           @[ @1.0, @1.0, @0.0, @0.0 ]);
    };
    _cropOSC.valuesWriter = ^(NSArray<NSNumber *> *vals, CMTime t) {
      __strong typeof(weak) strong = weak;
      if (strong)
        [strong _writeCropValues:vals atTime:t];
    };

    sCurrentOSC = self;
  }
  return self;
}

- (void)dealloc {
  if (sCurrentOSC == self)
    sCurrentOSC = nil;
}

// Draw the radius handle as the shared ring glyph instead of the inherited
// KKPointOSC dot (hit-testing / drag / guide logic stay point-based above).
- (void)drawAtCanvasPosition:(CGPoint)canvasPosition
                   isHovered:(BOOL)isHovered
                    isActive:(BOOL)isActive
            destinationImage:(FxImageTile *)destinationImage
                      atTime:(CMTime)time {
  _ringGlyph.tintColor = self.fillColorOverride ?: [NSColor whiteColor];
  _ringGlyph.ghostAlpha = self.ghostAlpha;
  [_ringGlyph drawAtCanvasPosition:canvasPosition
                         isHovered:isHovered
                          isActive:isActive
                  destinationImage:destinationImage
                            atTime:time];
}

- (BOOL)getCanvasTopRight:(CGPoint *)outTopRight
               bottomLeft:(CGPoint *)outBottomLeft {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return NO;
  CGPoint tr = {0, 0}, bl = {0, 0};
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:1.0
                          fromY:1.0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&tr.x
                            toY:&tr.y];
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0.0
                          fromY:0.0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&bl.x
                            toY:&bl.y];
  if (outTopRight)
    *outTopRight = tr;
  if (outBottomLeft)
    *outBottomLeft = bl;
  return YES;
}

- (double)fractionAtTime:(CMTime)time {
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!timingAPI)
    return 0.0;
  CMTime effectStart = kCMTimeZero, effectDur = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDur];
  double durSec = CMTimeGetSeconds(effectDur);
  if (durSec <= 0)
    return 0.0;
  return MAX(0.0,
             MIN(1.0, (CMTimeGetSeconds(time) - CMTimeGetSeconds(effectStart)) /
                          durSec));
}

// Compute the crop rect's top-right corner in canvas space (and the crop's
// min dimension in canvas pixels) for the current playhead fraction. With
// full crop (w=h=1, x=y=0) this collapses to the canvas top-right. Matches
// the mini viewer's `_anchorRectForContentRect:` - the radius handle is
// pinned to the crop, not the canvas.
- (BOOL)_cropAnchorCornerForFraction:(double)frac
                           outCorner:(CGPoint *)outCorner
                         outFlippedX:(BOOL *)outFlippedX
                         outFlippedY:(BOOL *)outFlippedY
                           outMinDim:(float *)outMinDim {
  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  if (![self getCanvasTopRight:&topRight bottomLeft:&bottomLeft])
    return NO;
  float canvasW = topRight.x - bottomLeft.x;
  float canvasH = topRight.y - bottomLeft.y;

  NSArray<NSNumber *> *cv =
      MeshSnapshotValuesForLabel(@"Crop", frac, @[ @1.0, @1.0, @0.0, @0.0 ]);
  double cw = cv[0].doubleValue, ch = cv[1].doubleValue;
  double cx = cv[2].doubleValue, cy = cv[3].doubleValue;

  // Empirically (verified in viewer with non-default crop): the FxPlug
  // OBJECT axis used by getCanvasTopRight has +y DOWN relative to the model
  // (where header docs +y up). User test: drag crop visually DOWN in mini
  // canvas → model cy increases → OSC must move down with it, so negate cy.
  double trU = 0.5 + cx + cw * 0.5;
  double trV = 0.5 - cy + ch * 0.5;
  *outCorner =
      CGPointMake(bottomLeft.x + trU * canvasW, bottomLeft.y + trV * canvasH);
  *outFlippedX = canvasW < 0;
  *outFlippedY = canvasH < 0;
  *outMinDim = (float)fmin(fabs(cw * canvasW), fabs(ch * canvasH));
  return YES;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  double frac = [self fractionAtTime:time];
  CGPoint corner;
  BOOL flippedX, flippedY;
  float minDim;
  if (![self _cropAnchorCornerForFraction:frac
                                outCorner:&corner
                              outFlippedX:&flippedX
                              outFlippedY:&flippedY
                                outMinDim:&minDim])
    return CGPointZero;

  double radius =
      (MeshGuideBridge().guideStep > 0)
          ? sGuideRadius
          : (self.isDragging ? _dragCurrentRadius
                             : MeshSnapshotRadiusAtFraction(frac));
  float padding = paddingForRadius(radius, minDim);
  float offsetX =
      flippedX ? -(self.oscSize + padding) : (self.oscSize + padding);
  float offsetY =
      flippedY ? -(self.oscSize + padding) : (self.oscSize + padding);
  return CGPointMake(corner.x - offsetX, corner.y - offsetY);
}

// Crop writeback. Same pattern as radius (MeshOSC+MouseHandlers): open
// an action scope, mutate the snapshot's Crop lane at the nearest keypose
// (preserving In/Hold/Out structure), write the blob.
- (void)_writeCropValues:(NSArray<NSNumber *> *)values atTime:(CMTime)time {
  if (values.count < 4)
    return;
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI)
    return;
  [actionAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!setAPI) {
    [actionAPI endAction:self];
    return;
  }

  double frac = [self fractionAtTime:time];
  KKTimeline *snap = MeshTimelineSnapshot();
  KKTimeline *tl =
      snap ? KKTimelineSettingValuesNearestFraction(snap, @"Crop", frac, values)
           : nil;
  if (!tl) {
    // No snapshot, or no Crop lane yet (fresh constant): seed one keypose at 0.
    tl = snap ? [snap copy] : [KKTimeline timeline];
    NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
    KKLane *cropLane = [KKLane laneWithLabel:@"Crop"];
    cropLane.enabled = NO;
    cropLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:values] ];
    [lanes addObject:cropLane];
    tl.lanes = lanes;
  }

  KKWriteCustomParamString(setAPI, [KKTimeline jsonFromTimeline:tl],
                           kKKParamTimelineData);
  [actionAPI endAction:self];
}

- (CGPoint)_guideTargetCanvasPosition {
  CGPoint corner;
  BOOL flippedX, flippedY;
  float minDim;
  if (![self _cropAnchorCornerForFraction:0.0
                                outCorner:&corner
                              outFlippedX:&flippedX
                              outFlippedY:&flippedY
                                outMinDim:&minDim])
    return CGPointZero;
  float padding = paddingForRadius(kOSCGuideTargetRadius, minDim);
  float offsetX =
      flippedX ? -(self.oscSize + padding) : (self.oscSize + padding);
  float offsetY =
      flippedY ? -(self.oscSize + padding) : (self.oscSize + padding);
  return CGPointMake(corner.x - offsetX, corner.y - offsetY);
}

// Override the base OSC-visibility hooks: Mesh hides the Radius handle and
// the Crop box (all 8 corner parts + the rect map to one @"Crop" element).
- (NSArray<NSString *> *)oscElementKeys {
  return @[ @"Radius", @"Crop" ];
}

- (nullable NSString *)oscElementKeyForActivePart:(NSInteger)activePart {
  if (activePart == kOSCRadiusPart)
    return @"Radius";
  if (activePart == kOSCCropRectPart ||
      (activePart >= kOSCCropPointBase &&
       activePart < kOSCCropPointBase + KKCropPointCount))
    return @"Crop";
  return nil;
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];

  CGPoint radiusPos = [self oscPositionAtTime:time];

  // Pull the live geometry FCP only exposes from this tick and feed it to the
  // generic bridge - it owns the zoom-invariant CANVAS→screen affine, the
  // viewer-rect recompute (never stale vs corners), and the position
  // notifications. spC=0 means "no scale this tick" (bridge keeps the last).
  CGPoint trC = {0, 0}, blC = {0, 0};
  [self getCanvasTopRight:&trC bottomLeft:&blC];
  id<FxOnScreenControlAPI_v2> oscAPI2 =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v2)];
  double rawZoom = oscAPI2 ? ([oscAPI2 canvasZoom] / 100.0) : 0.0;
  double displayScale = [[NSScreen mainScreen] backingScaleFactor];
  double spC =
      (rawZoom > 0.0 && displayScale > 0.0) ? rawZoom / displayScale : 0.0;

  [MeshGuideBridge()
      ingestDrawTickWithCanvasTopRight:trC
                            bottomLeft:blC
                           canvasScale:spC
                       handleCanvasPos:radiusPos
                       targetCanvasPos:[self _guideTargetCanvasPosition]
                             hasTarget:YES];

  // Visibility rule (matches mini viewer): show when the lane is a constant
  // (always), or when animated and the playhead is on a keypose. Mid-drag
  // the active OSC always draws so the handle tracks the cursor.
  BOOL inGuide = (MeshGuideBridge().guideStep > 0);
  double frac = [self fractionAtTime:time];

  // Crop OSC (drawn before radius - its border + handles sit underneath the
  // radius handle visually if they overlap at the corner). Opt-reveal draws a
  // hidden crop as a dimmed ghost where it would normally appear.
  BOOL cropDragging = (_cropOSC.draggingIndex >= 0);
  BOOL cropShownHere = MeshLaneVisibleAtFraction(@"Crop", frac);
  BOOL cropEnabled = [self kkOSCElementVisible:@"Crop"];
  BOOL cropVisible = cropDragging || (cropEnabled && cropShownHere);
  BOOL cropGhost = !cropVisible && self.optRevealActive && cropShownHere &&
                   [self kkOSCRevealEligible:@"Crop"];
  if (cropVisible || cropGhost) {
    _cropOSC.ghostAlpha = cropGhost ? [self kkRevealGhostAlpha] : 1.0f;
    _cropOSC.hoveredIndex = (activePart >= kOSCCropPointBase &&
                             activePart < kOSCCropPointBase + KKCropPointCount)
                                ? (activePart - kOSCCropPointBase)
                                : -1;
    [_cropOSC drawWithDestinationImage:destinationImage atTime:time];
  }

  BOOL radiusShownHere = self.isDragging || inGuide ||
                         MeshLaneVisibleAtFraction(@"Radius", frac);
  BOOL radiusEnabled = [self kkOSCElementVisible:@"Radius"];
  BOOL radiusVisible = radiusShownHere && radiusEnabled;
  BOOL radiusGhost = !radiusVisible && self.optRevealActive &&
                     radiusShownHere && [self kkOSCRevealEligible:@"Radius"];
  if (!radiusVisible && !radiusGhost)
    return;

  self.ghostAlpha = radiusGhost ? [self kkRevealGhostAlpha] : 1.0f;
  // During a guide, FCP doesn't run its own hover hitTest (the guide panel is
  // frontmost), so take the hover emphasis from the bridge.
  BOOL guideHover = inGuide && MeshGuideBridge().handleHovered;
  [self drawAtCanvasPosition:radiusPos
                   isHovered:(activePart == kOSCRadiusPart || guideHover)
                    isActive:self.isDragging && (activePart == kOSCRadiusPart)
            destinationImage:destinationImage
                      atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  BOOL inGuide = (MeshGuideBridge().guideStep > 0);
  double frac = [self fractionAtTime:time];
  // Opt-reveal makes a hidden control hit-testable so an opt-click re-shows it.
  BOOL radiusInteractive =
      ([self kkOSCElementVisible:@"Radius"] ||
       (self.optRevealActive && [self kkOSCRevealEligible:@"Radius"])) &&
      (inGuide || MeshLaneVisibleAtFraction(@"Radius", frac));
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (radiusInteractive && [self hitTestAtMousePositionX:positionX
                                               positionY:positionY
                                                  atTime:time]) {
    *activePart = kOSCRadiusPart;
    // The radius is a draggable point → FCP's move cursor, or the Opt-hover
    // eye/eye.slash when an Opt-click would toggle its visibility.
    [oscAPI setCursor:([self kkVisibilityCursorForLabel:@"Radius"]
                           ?: KKPointMoveCursor())];
    _radiusCursorSet = YES;
  } else {
    // Off the radius point: drop our forced move cursor; the crop box's
    // hitTest (below) then sets its own resize cursor, or leaves the arrow.
    if (_radiusCursorSet) {
      [oscAPI setCursor:[NSCursor arrowCursor]];
      _radiusCursorSet = NO;
    }
    if (([self kkOSCElementVisible:@"Crop"] ||
         (self.optRevealActive && [self kkOSCRevealEligible:@"Crop"])) &&
        MeshLaneVisibleAtFraction(@"Crop", frac)) {
      // Opt-hover hide/show affordance on the crop handles (eye/eye.slash when
      // an Opt-click would toggle the Crop OSC, i.e. master on - not peek
      // mode).
      BOOL cropToggle = self.optRevealActive && ![self kkOSCMasterOff];
      BOOL cropRevealOnly = ![self kkOSCElementVisible:@"Crop"] &&
                            self.optRevealActive &&
                            [self kkOSCRevealEligible:@"Crop"];
      _cropOSC.visibilityHint = cropToggle ? (cropRevealOnly ? 2 : 1) : 0;
      // Radius didn't catch it → try crop handles / rect.
      NSInteger cropPart = [_cropOSC hitTestAtMousePositionX:positionX
                                                   positionY:positionY
                                                      atTime:time];
      if (cropPart == KKCropPartRect) {
        *activePart = kOSCCropRectPart;
      } else if (cropPart >= KKCropPartPointBase) {
        *activePart = kOSCCropPointBase + (cropPart - KKCropPartPointBase);
      }
    }
  }
  // The only place screen + canvas coords arrive together. Hand it to the
  // bridge: it velocity-gates the sample, re-anchors the screen↔canvas map,
  // recomputes the viewer rect, and posts the position notification. The
  // handle position is only needed while a guide step is active.
  CGPoint tr = {0, 0}, bl = {0, 0};
  if (![self getCanvasTopRight:&tr bottomLeft:&bl])
    return;
  id<FxOnScreenControlAPI_v2> oscAPI2 =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v2)];
  double rawZoom = oscAPI2 ? ([oscAPI2 canvasZoom] / 100.0) : 1.0;
  double displayScale = [[NSScreen mainScreen] backingScaleFactor];
  double spC = rawZoom / displayScale;
  CGPoint handle = CGPointZero;
  if (MeshGuideBridge().guideStep > 0)
    handle = [self oscPositionAtTime:time];
  [MeshGuideBridge() ingestHitTestAtScreen:NSEvent.mouseLocation
                                    canvasPos:CGPointMake(positionX, positionY)
                                  canvasScale:spC
                                     topRight:tr
                                   bottomLeft:bl
                                     onHandle:(*activePart == kOSCRadiusPart)
                              handleCanvasPos:handle];
}

@end
