/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC.h"
#import "Constants.h"
#import "OSC_Internal.h"
#import "RoundedOSCRadiusMath.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KeyframelessKit.h>

// Mirrors KKOSCGuideBridge's position-notification name (the bridge posts it);
// the plugin returns this as its help-guide refresh notification.
NSNotificationName const kRoundedOSCPositionNotification =
    @"com.overpolish.kk.oscGuidePosition";

static RoundedOSC *sCurrentOSC = nil;

// All OSC-guide affine / staleness / velocity-gate state now lives in the
// generic KKOSCGuideBridge (KeyframelessKit). One process-lifetime instance
// per XPC process - the inspector custom view and the OSC render run in the
// same process (pid confirmed identical). MRR: retained forever, no
// dispatch_once (autoreleased ObjC statics dangle under MRR).
static KKOSCGuideBridge *RoundedGuideBridge(void) {
  static KKOSCGuideBridge *sBridge = nil;
  if (!sBridge)
    sBridge = [[KKOSCGuideBridge alloc] init];
  return sBridge;
}

// Same instance, exported so the inspector guide (same XPC process) can hand
// it to a KKJoyrideOSCSegment.
KKOSCGuideBridge *RoundedSharedOSCGuideBridge(void) {
  return RoundedGuideBridge();
}

// Re-anchor the bridge's screen↔canvas map by pairing a screen point with the
// OSC handle's current canvas position (the bridge supplies the live scale).
static BOOL RoundedReanchor(RoundedOSC *osc, NSPoint screenPt) {
  if (!osc)
    return NO;
  CGPoint handle = [osc oscPositionAtTime:kCMTimeZero];
  return [RoundedGuideBridge() reanchorAtScreen:screenPt
                                handleCanvasPos:handle];
}

void RoundedSetOSCGuideStep(NSInteger step) {
  RoundedGuideBridge().guideStep = step;
}

BOOL RoundedHasCanvasReference(void) {
  return [RoundedGuideBridge() hasCanvasReference];
}

void RoundedOSCCaptureGuideAnchorAtScreen(NSPoint screenPt) {
  RoundedOSC *osc = sCurrentOSC;
  if (!osc) {
    KKLogWarn(@"[OSCGuide] capture anchor skipped: no current OSC");
    return;
  }
  if (!RoundedReanchor(osc, screenPt))
    KKLogWarn(@"[OSCGuide] capture anchor skipped: no live scale yet "
              @"(drawOSC has not run)");
}

// Guide-scoped radius. The OSC cannot read the KKDataBlob from the drawOSC
// tick (FxParameterRetrievalAPI is nil there - see oscAPI2=nil in every
// drawOSC log). During the guide the blob-drag handler pushes the live radius
// here (same XPC process - pid confirmed identical) so the OSC handle tracks
// without the unreadable blob. Real (non-guide) OSC↔blob reads are Phase 10.
static double sGuideRadius = 20.0;

void RoundedSetGuideRadius(double radius) { sGuideRadius = radius; }

// Point-OSC value mapping: invert the bridge's proportional viewer-rect map
// (screen → canvas), then the OSC's own radius math, so the drag tracks the
// cursor 1:1 like a native OSC drag. Falls back to the last guide radius
// until the bridge has cached usable geometry. This is the only OSC-shape-
// specific piece left in this file; a different OSC supplies its own.
double RoundedGuideRadiusForScreenPoint(NSPoint screenPt) {
  KKOSCGuideBridge *b = RoundedGuideBridge();
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

@implementation RoundedOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
    _dragCurrentRadius = 20.0;
    // Match the shared box-OSC handle size so the radius point and the crop
    // box's corner/edge handles are one size.
    self.oscRadius = 6.0f;
    // Blue, matching the mini canvas radius handle (accent color).
    self.fillColorOverride = [NSColor accent];

    // Crop OSC: model-agnostic block-based I/O. Reads from / writes to the
    // Rounded timeline-snapshot Crop lane (single instance per PLAN §"OSC
    // cache"). The OSC owns rendering + drag math; we own persistence.
    _cropOSC = [[KKCropOSC alloc] initWithAPIManager:apiManager];
    __weak typeof(self) weak = self;
    _cropOSC.valuesProvider = ^NSArray<NSNumber *> *(CMTime t) {
      __strong typeof(weak) strong = weak;
      double frac = strong ? [strong fractionAtTime:t] : 0.0;
      return RoundedSnapshotValuesForLabel(@"Crop", frac,
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
// the mini canvas's `_anchorRectForContentRect:` - the radius handle is
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
      RoundedSnapshotValuesForLabel(@"Crop", frac, @[ @1.0, @1.0, @0.0, @0.0 ]);
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
      (RoundedGuideBridge().guideStep > 0)
          ? sGuideRadius
          : (self.isDragging ? _dragCurrentRadius
                             : RoundedSnapshotRadiusAtFraction(frac));
  float padding = paddingForRadius(radius, minDim);
  float offsetX =
      flippedX ? -(self.oscSize + padding) : (self.oscSize + padding);
  float offsetY =
      flippedY ? -(self.oscSize + padding) : (self.oscSize + padding);
  return CGPointMake(corner.x - offsetX, corner.y - offsetY);
}

// Crop writeback. Same pattern as radius (RoundedOSC+MouseHandlers): open
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
  KKTimeline *snap = RoundedTimelineSnapshot();
  KKTimeline *tl = snap ? [snap copy] : [KKTimeline timeline];

  NSMutableArray *lanes = [NSMutableArray arrayWithArray:tl.lanes];
  NSInteger laneIdx = NSNotFound;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if ([((KKLane *)lanes[i]).label isEqualToString:@"Crop"]) {
      laneIdx = i;
      break;
    }
  }

  KKLane *cropLane;
  if (laneIdx == NSNotFound) {
    // Fresh constant - seed one keypose at t=0 with the new values.
    cropLane = [KKLane laneWithLabel:@"Crop"];
    cropLane.enabled = NO;
    cropLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:values] ];
    [lanes addObject:cropLane];
  } else {
    cropLane = [lanes[laneIdx] copy];
    NSArray<KKKeyPose *> *kps = cropLane.keyposes;
    if (kps.count == 0) {
      cropLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:values] ];
    } else {
      NSInteger best = 0;
      double bd = 1e9;
      for (NSInteger k = 0; k < (NSInteger)kps.count; k++) {
        double d = fabs(kps[k].time - frac);
        if (d < bd) {
          bd = d;
          best = k;
        }
      }
      NSMutableArray<KKKeyPose *> *out = [NSMutableArray arrayWithArray:kps];
      // MRR dangling-pointer guard (see project_mrr_array_dangling.md).
      double oldTime = out[best].time;
      KKInterval *oldOutgoing = out[best].outgoing;
      KKKeyPose *nk = [KKKeyPose keyposeAtTime:oldTime values:values];
      nk.outgoing = oldOutgoing;
      out[best] = nk;
      // Hold-link propagation (see RoundedOSC+MouseHandlers radius write).
      if (best + 1 < (NSInteger)out.count && nk.outgoing.endpointsLinked) {
        KKKeyPose *partner = out[best + 1];
        KKKeyPose *np = [KKKeyPose keyposeAtTime:partner.time values:values];
        np.outgoing = partner.outgoing;
        out[best + 1] = np;
      }
      if (best > 0) {
        KKKeyPose *prev = out[best - 1];
        if (prev.outgoing.endpointsLinked) {
          KKKeyPose *np = [KKKeyPose keyposeAtTime:prev.time values:values];
          np.outgoing = prev.outgoing;
          out[best - 1] = np;
        }
      }
      cropLane.keyposes = out;
    }
    lanes[laneIdx] = cropLane;
  }
  tl.lanes = lanes;

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

// Override the base OSC-visibility hooks: Rounded hides the Radius handle and
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

  [RoundedGuideBridge()
      ingestDrawTickWithCanvasTopRight:trC
                            bottomLeft:blC
                           canvasScale:spC
                       handleCanvasPos:radiusPos
                       targetCanvasPos:[self _guideTargetCanvasPosition]
                             hasTarget:YES];

  // Visibility rule (matches mini canvas): show when the lane is a constant
  // (always), or when animated and the playhead is on a keypose. Mid-drag
  // the active OSC always draws so the handle tracks the cursor.
  BOOL inGuide = (RoundedGuideBridge().guideStep > 0);
  double frac = [self fractionAtTime:time];

  // Crop OSC (drawn before radius - its border + handles sit underneath the
  // radius handle visually if they overlap at the corner). Opt-reveal draws a
  // hidden crop as a dimmed ghost where it would normally appear.
  BOOL cropDragging = (_cropOSC.draggingIndex >= 0);
  BOOL cropShownHere = RoundedLaneVisibleAtFraction(@"Crop", frac);
  BOOL cropEnabled = [self kkOSCElementVisible:@"Crop"];
  BOOL cropVisible = cropDragging || (cropEnabled && cropShownHere);
  BOOL cropGhost =
      !cropVisible && self.optRevealActive && cropShownHere && !cropEnabled;
  if (cropVisible || cropGhost) {
    _cropOSC.ghostAlpha = cropGhost ? 0.3f : 1.0f;
    _cropOSC.hoveredIndex = (activePart >= kOSCCropPointBase &&
                             activePart < kOSCCropPointBase + KKCropPointCount)
                                ? (activePart - kOSCCropPointBase)
                                : -1;
    [_cropOSC drawWithDestinationImage:destinationImage atTime:time];
  }

  BOOL radiusShownHere = self.isDragging || inGuide ||
                         RoundedLaneVisibleAtFraction(@"Radius", frac);
  BOOL radiusEnabled = [self kkOSCElementVisible:@"Radius"];
  BOOL radiusVisible = radiusShownHere && radiusEnabled;
  BOOL radiusGhost = !radiusVisible && self.optRevealActive &&
                     radiusShownHere && !radiusEnabled;
  if (!radiusVisible && !radiusGhost)
    return;

  self.ghostAlpha = radiusGhost ? 0.3f : 1.0f;
  [self drawAtCanvasPosition:radiusPos
                   isHovered:(activePart == kOSCRadiusPart)
                    isActive:self.isDragging && (activePart == kOSCRadiusPart)
            destinationImage:destinationImage
                      atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;
  BOOL inGuide = (RoundedGuideBridge().guideStep > 0);
  double frac = [self fractionAtTime:time];
  // Opt-reveal makes a hidden control hit-testable so an opt-click re-shows it.
  BOOL radiusInteractive =
      ([self kkOSCElementVisible:@"Radius"] || self.optRevealActive) &&
      (inGuide || RoundedLaneVisibleAtFraction(@"Radius", frac));
  if (radiusInteractive && [self hitTestAtMousePositionX:positionX
                                               positionY:positionY
                                                  atTime:time]) {
    *activePart = kOSCRadiusPart;
  } else if (([self kkOSCElementVisible:@"Crop"] || self.optRevealActive) &&
             RoundedLaneVisibleAtFraction(@"Crop", frac)) {
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
  if (RoundedGuideBridge().guideStep > 0)
    handle = [self oscPositionAtTime:time];
  [RoundedGuideBridge() ingestHitTestAtScreen:NSEvent.mouseLocation
                                    canvasPos:CGPointMake(positionX, positionY)
                                  canvasScale:spC
                                     topRight:tr
                                   bottomLeft:bl
                                     onHandle:(*activePart == kOSCRadiusPart)
                              handleCanvasPos:handle];
}

@end
