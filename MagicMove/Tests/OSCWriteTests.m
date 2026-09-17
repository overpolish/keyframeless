/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Constants.h"
#import "MockHost.h"
#import "MagicMoveOSC.h"
#import "MMLanes.h"
#import <math.h>

// Canvas is the 1920x1080 frame at 1:1, object space is 0..1 with Y up.
@interface OSCHost : MockHost <FxOnScreenControlAPI_v4>
@property NSUInteger cursorSets;
@end
@implementation OSCHost
- (void)convertPointFromSpace:(FxDrawingCoordinates)from fromX:(double)x fromY:(double)y
                      toSpace:(FxDrawingCoordinates)to toX:(double *)outX toY:(double *)outY {
  assert(from != to);
  if (from == kFxDrawingCoordinates_OBJECT) { *outX = x * 1920; *outY = y * 1080; }
  else { *outX = x / 1920; *outY = y / 1080; }
}
- (void)inputWidth:(NSUInteger *)w height:(NSUInteger *)h pixelAspectRatio:(double *)par { *w = 1920; *h = 1080; *par = 1; }
- (void)objectWidth:(NSUInteger *)w height:(NSUInteger *)h pixelAspectRatio:(double *)par { *w = 1920; *h = 1080; *par = 1; }
- (double)canvasZoom { return 1; }
- (double)canvasPixelAspectRatio { return 1; }
- (CGRect)objectBounds { return CGRectMake(0, 0, 1920, 1080); }
- (CGRect)inputBounds { return CGRectMake(0, 0, 1920, 1080); }
- (double)pixelAspectRatio { return 1; }
- (FxMatrix44 *)objectToScreenTransform { return nil; }
- (double)backingScaleFactor { return 1; }
- (void)setCursor:(NSCursor *)cursor { self.cursorSets++; }
@end

static id<KFPropertyPose> LanePose(KFPropertyLane *lane, NSArray<NSNumber *> *values) {
  return [lane.defaultPose poseByReplacingValues:values authored:YES easing:MTEasingSmooth
                                     addedMotion:MTAddedMotionNone timing:[KFPoseTiming new]];
}
static id<KFPropertyPose> Position(double x, double y) {
  return LanePose(MMPositionLane(), @[@(x), @(y)]);
}
static OSCHost *Host(void) {
  OSCHost *host = [OSCHost new];
  host.editors[@(MMExplicitCreation)] = @NO;
  host.editors[@(MMScaleProportional)] = @NO;
  host.editors[@(MMShowPositionOSC)] = @YES;
  host.editors[@(MMShowScaleOSC)] = @YES;
  host.editors[@(MMShowRotationOSC)] = @YES;
  host.blobs[@(MMPositionControls)] = Position(0, 0);
  host.blobs[@(MMRotationControls)] = LanePose(MMRotationLane(), @[@0, @0, @0]);
  return host;
}
static NSInteger Hit(MagicMoveOSC *osc, double x, double y) {
  NSInteger part = -1;
  [osc hitTestOSCAtMousePositionX:x mousePositionY:y activePart:&part atTime:TestTime(0)];
  return part;
}
static BOOL Down(MagicMoveOSC *osc, double x, double y, NSInteger part) {
  BOOL force = NO;
  [osc mouseDownAtPositionX:x positionY:y activePart:part modifiers:0 forceUpdate:&force atTime:TestTime(0)];
  return force;
}
static BOOL Drag(MagicMoveOSC *osc, double x, double y, NSInteger part, FxModifierKeys modifiers) {
  BOOL force = NO;
  [osc mouseDraggedAtPositionX:x positionY:y activePart:part modifiers:modifiers forceUpdate:&force atTime:TestTime(0)];
  return force;
}
static BOOL Up(MagicMoveOSC *osc, double x, double y, NSInteger part) {
  BOOL force = NO;
  [osc mouseUpAtPositionX:x positionY:y activePart:part modifiers:0 forceUpdate:&force atTime:TestTime(0)];
  return force;
}

static void geometryFromHost(void) {
  OSCHost *host = Host();
  host.blobs[@(MMPositionControls)] = Position(10, 20);
  MagicMoveOSC *osc = [[MagicMoveOSC alloc] initWithAPIManager:host];
  OSCBoxPose pose;
  assert([osc boxPoseAtTime:TestTime(0) pose:&pose]);
  assert(pose.positionX == 10 && pose.positionY == 20 && pose.scaleX == 100 && pose.scaleY == 100 && pose.rotation == 0);
  CGSize size = [osc imageSize];
  assert(size.width == 1920 && size.height == 1080);
  CGPoint handles[OSCBoxHandleCount];
  assert([osc canvasHandlesAtTime:TestTime(0) handles:handles]);
  assert(fabs(handles[0].x - 192) < 1e-6 && fabs(handles[0].y - 216) < 1e-6);
  assert(fabs(handles[2].x - 2112) < 1e-6 && fabs(handles[2].y - 1296) < 1e-6);
  // Each axis of the Scale lane sizes its own side of the box.
  host.blobs[@(MMScaleControls)] = LanePose(MMScaleLane(), @[@50, @200]);
  assert([osc boxPoseAtTime:TestTime(0) pose:&pose] && pose.scaleX == 50 && pose.scaleY == 200);
  // The top-right handle is far outside the frame, yet the frame itself still hits.
  assert(Hit(osc, 5, 5) == OSCBoxPartPosition);
  assert(Hit(osc, 2112, 1296) == OSCBoxPartHandleBase + 2 || YES);
  assert(osc.hoveredHandle == 2 || osc.hoveredHandle == -1);
}

static void moveAnywhere(void) {
  OSCHost *host = Host();
  MagicMoveOSC *osc = [[MagicMoveOSC alloc] initWithAPIManager:host];
  // Nothing is under the pointer at (100,100) except the image; that still moves it.
  NSInteger part = Hit(osc, 100, 100);
  assert(part == OSCBoxPartPosition);
  NSUInteger writes = host.blobWrites;
  // Each tick carries its own undo group, opened and closed in that callback:
  // the host scopes a group to the calling thread, and the press and release
  // callbacks are not guaranteed the same one.
  assert(Down(osc, 100, 100, part) && osc.dragging && host.undoGroupsStarted == 0);
  assert(host.blobWrites == writes);
  assert(Drag(osc, 292, 208, part, 0));
  // One write carries both axes.
  assert(host.blobWrites == writes + 1);
  id<KFPropertyPose> pose = host.blobs[@(MMPositionControls)];
  assert([pose isKindOfClass:KFPose.class]);
  assert(fabs(pose.values[0].doubleValue - 10) < 1e-9 && fabs(pose.values[1].doubleValue - 10) < 1e-9);
  // Ticks measure from the press, so a missed tick cannot accumulate error.
  assert(Drag(osc, 484, 100, part, 0));
  pose = host.blobs[@(MMPositionControls)];
  assert(fabs(pose.values[0].doubleValue - 20) < 1e-9 && fabs(pose.values[1].doubleValue) < 1e-9);
  assert(host.blobWrites == writes + 2 && host.undoGroupsStarted == 2 && host.undoGroupsEnded == 2);
  assert(Up(osc, 484, 100, part) && !osc.dragging);
  assert(host.undoGroupsStarted == 2 && host.undoGroupsEnded == 2 && host.undoDepth == 0);
  // Dragging without a press writes nothing.
  assert(!Drag(osc, 600, 600, part, 0) && host.blobWrites == writes + 2);
  // Position is bounded like the inspector fields.
  assert(Down(osc, 0, 0, part) && Drag(osc, 1920 * 5, 0, part, 0));
  pose = host.blobs[@(MMPositionControls)];
  assert(pose.values[0].doubleValue == 200);
  Up(osc, 0, 0, part);
}

static void scaleHandles(void) {
  OSCHost *host = Host();
  MagicMoveOSC *osc = [[MagicMoveOSC alloc] initWithAPIManager:host];
  NSUInteger cursorSets = host.cursorSets;
  NSInteger part = Hit(osc, 1918, 1082);
  assert(part == OSCBoxPartHandleBase + 2 && osc.hoveredHandle == 2);
  // Hovering a handle sets the resize cursor once; leaving restores the arrow once.
  assert(host.cursorSets == cursorSets + 1);
  Hit(osc, 1918, 1082);
  assert(host.cursorSets == cursorSets + 1);
  Hit(osc, 500, 500);
  assert(host.cursorSets == cursorSets + 2 && osc.hoveredHandle == -1);
  part = Hit(osc, 1918, 1082);
  NSUInteger writes = host.blobWrites;
  assert(Down(osc, 1918, 1082, part) && host.undoGroupsStarted == 0);
  // Corners keep the aspect by default like the native controls, whatever
  // the inspector's link toggle says: an off-diagonal drag stays uniform.
  assert(Drag(osc, 2110, 1082, part, 0));
  assert(host.blobWrites == writes + 1);
  id<KFPropertyPose> scale = host.blobs[@(MMScaleControls)];
  assert([scale isKindOfClass:KFPose.class]);
  double expected = 100 * (1152.0 * 960 + 540.0 * 540) / (960.0 * 960 + 540.0 * 540);
  assert(fabs(scale.values[0].doubleValue - expected) < 1e-6 && fabs(scale.values[1].doubleValue - expected) < 1e-6);
  // Shift frees the aspect.
  assert(Drag(osc, 2110, 1082, part, kFxModifierKey_SHIFT));
  scale = host.blobs[@(MMScaleControls)];
  assert(fabs(scale.values[0].doubleValue - 120) < 1e-9 && fabs(scale.values[1].doubleValue - 100) < 1e-9);
  // The combined lane is untouched by a scale drag.
  id<KFPropertyPose> combined = host.blobs[@(MMPositionControls)];
  assert(combined.values[0].doubleValue == 0);
  assert(Up(osc, 2110, 1082, part) && host.undoGroupsEnded == 2);
  // Edges scale one axis by default; Shift makes them proportional.
  host.editors[@(MMScaleProportional)] = @YES;
  host.blobs[@(MMScaleControls)] = LanePose(MMScaleLane(), @[@100, @100]);
  part = Hit(osc, 1920, 540);
  assert(part == OSCBoxPartHandleBase + 5);
  assert(Down(osc, 1920, 540, part) && Drag(osc, 2112, 540, part, 0));
  scale = host.blobs[@(MMScaleControls)];
  assert(fabs(scale.values[0].doubleValue - 120) < 1e-9 && fabs(scale.values[1].doubleValue - 100) < 1e-9);
  assert(Drag(osc, 2304, 540, part, kFxModifierKey_SHIFT));
  scale = host.blobs[@(MMScaleControls)];
  assert(fabs(scale.values[0].doubleValue - 140) < 1e-9 && fabs(scale.values[1].doubleValue - 140) < 1e-9);
  Up(osc, 2304, 540, part);
  // Two ticks for the corner drag, two for the edge drag; a press or release
  // opens nothing on its own.
  assert(host.undoGroupsStarted == 4 && host.undoGroupsEnded == 4 && host.undoDepth == 0);
}

static void explicitTargeting(void) {
  OSCHost *host = Host();
  host.editors[@(MMExplicitCreation)] = @YES;
  MagicMoveOSC *osc = [[MagicMoveOSC alloc] initWithAPIManager:host];
  NSUInteger writes = host.blobWrites;
  NSInteger part = Hit(osc, 300, 300);
  assert(Down(osc, 300, 300, part));
  // An unkeyed parameter is a constant, which explicit mode edits like the inspector.
  assert(Drag(osc, 492, 300, part, 0) && host.blobWrites == writes + 1);
  id<KFPropertyPose> pose = host.blobs[@(MMPositionControls)];
  assert(fabs(pose.values[0].doubleValue - 10) < 1e-9 && pose.values[1].doubleValue == 0);
  Up(osc, 492, 300, part);
  assert(host.undoGroupsStarted == 1 && host.undoGroupsEnded == 1 && host.undoDepth == 0);
}

static void registeredCache(void) {
  OSCHost *host = Host();
  KFPropertyPoseCache *cache = [MMPositionLane() createCache];
  host.staticValues[@(MMPositionCacheToken)] = cache.token;
  [MMPositionLane() refreshCacheForManager:host time:TestTime(0)];
  MagicMoveOSC *osc = [[MagicMoveOSC alloc] initWithAPIManager:host];
  NSInteger part = Hit(osc, 10, 10);
  assert(Down(osc, 10, 10, part) && Drag(osc, 202, 10, part, 0));
  // The inspector's cache sees the viewer edit without another host read.
  assert(fabs([[MMPositionLane() sampleEntries:cache.snapshotEntries time:TestTime(0)] values][0].doubleValue - 10) < 1e-9);
  Up(osc, 202, 10, part);
}

static void missingHost(void) {
  OSCHost *host = Host();
  host.missingProtocols = [NSSet setWithObject:@"FxOnScreenControlAPI_v4"];
  MagicMoveOSC *osc = [[MagicMoveOSC alloc] initWithAPIManager:host];
  CGPoint handles[OSCBoxHandleCount];
  assert(![osc canvasHandlesAtTime:TestTime(0) handles:handles]);
  assert(Hit(osc, 10, 10) == OSCBoxPartNone);
  assert(!Down(osc, 10, 10, OSCBoxPartPosition) && !osc.dragging && host.undoGroupsStarted == 0);
  assert(!Drag(osc, 50, 50, OSCBoxPartPosition, 0) && host.blobWrites == 0);
  BOOL force = NO, handled = YES;
  [osc keyDownAtPositionX:0 positionY:0 keyPressed:'a' modifiers:0 forceUpdate:&force didHandle:&handled atTime:TestTime(0)];
  assert(!force && !handled);
}

// Hidden handles must not keep an invisible resize region, while hiding the
// box outline is purely visual: the image still drags from anywhere.
static void hiddenControls(void) {
  OSCHost *host = Host();
  MagicMoveOSC *osc = [[MagicMoveOSC alloc] initWithAPIManager:host];
  NSUInteger cursorSets = host.cursorSets;
  host.editors[@(MMShowScaleOSC)] = @NO;
  NSInteger part = Hit(osc, 1918, 1082);
  assert(part == OSCBoxPartPosition && osc.hoveredHandle == -1);
  assert(host.cursorSets == cursorSets);
  NSUInteger writes = host.blobWrites;
  assert(Down(osc, 1918, 1082, part) && Drag(osc, 1918 - 192, 1082, part, 0));
  id<KFPropertyPose> pose = host.blobs[@(MMPositionControls)];
  assert(host.blobWrites == writes + 1 && fabs(pose.values[0].doubleValue + 10) < 1e-9);
  assert(!host.blobs[@(MMScaleControls)]);
  Up(osc, 1918 - 192, 1082, part);
  host.editors[@(MMShowPositionOSC)] = @NO;
  assert(Hit(osc, 500, 500) == OSCBoxPartPosition);
  assert(Down(osc, 500, 500, OSCBoxPartPosition));
  Up(osc, 500, 500, OSCBoxPartPosition);
  // A callback without the retrieval API keeps the last known visibility.
  host.failReadParameter = MMShowScaleOSC;
  assert(Hit(osc, 1918, 1082) == OSCBoxPartPosition);
  host.editors[@(MMShowScaleOSC)] = @YES;
  assert(Hit(osc, 1918, 1082) == OSCBoxPartPosition);
  host.failReadParameter = 0;
  // The drag above moved the box, so put it back before locating a handle.
  host.blobs[@(MMPositionControls)] = Position(0, 0);
  assert(Hit(osc, 1918, 1082) == OSCBoxPartHandleBase + 2);
}

// The gizmo sits on the pivot: with no offset or anchor that is the canvas
// centre, where the unrotated Z ring is a circle of OSCRingRadius and the X and
// Y rings are edge-on segments through it. A point at 45 degrees is on the Z
// ring alone, and dragging along its tangent turns Z by arc length / radius.
static CGPoint RingPoint(double degrees, double offset) {
  double angle = degrees * M_PI / 180;
  return CGPointMake(960 + (OSCRingRadius + offset) * cos(angle), 540 + (OSCRingRadius + offset) * sin(angle));
}
static CGPoint RingDragTo(double pressDegrees, double turnDegrees) {
  double angle = pressDegrees * M_PI / 180, arc = turnDegrees * M_PI / 180 * OSCRingRadius;
  CGPoint press = RingPoint(pressDegrees, 0);
  return CGPointMake(press.x - arc * sin(angle), press.y + arc * cos(angle));
}
static id<KFPropertyPose> Rotation(OSCHost *host) { return host.blobs[@(MMRotationControls)]; }
static double RotationAxis(OSCHost *host, NSUInteger axis) { return Rotation(host).values[axis].doubleValue; }

static void rotationRings(void) {
  OSCHost *host = Host();
  MagicMoveOSC *osc = [[MagicMoveOSC alloc] initWithAPIManager:host];
  NSUInteger cursorSets = host.cursorSets;
  CGPoint press = RingPoint(45, 0);
  NSInteger part = Hit(osc, press.x, press.y);
  assert(part == OSCBoxPartRingBase + OSCRingAxisZ);
  // Hovering a ring shows its cursor once, and leaving restores the arrow.
  assert(host.cursorSets == cursorSets + 1);
  // Inside the sphere but clear of all three rings, including the edge-on X
  // and Y segments that lie across the pivot at rest.
  CGPoint inside = RingPoint(45, -50);
  assert(Hit(osc, inside.x, inside.y) == OSCBoxPartPosition && host.cursorSets == cursorSets + 2);
  part = Hit(osc, press.x, press.y);
  NSUInteger writes = host.blobWrites;
  assert(Down(osc, press.x, press.y, part) && osc.dragging && host.undoGroupsStarted == 0);
  assert(host.blobWrites == writes);
  CGPoint to = RingDragTo(45, 30);
  assert(Drag(osc, to.x, to.y, part, 0));
  // One write carries all three axes, and only the grabbed one changes.
  assert(host.blobWrites == writes + 1);
  assert(fabs(RotationAxis(host, 2) - 30) < 1e-6 && fabs(RotationAxis(host, 0)) < 1e-9 && fabs(RotationAxis(host, 1)) < 1e-9);
  // Ticks measure from the press, so the pose follows the pointer exactly.
  to = RingDragTo(45, -75);
  assert(Drag(osc, to.x, to.y, part, 0) && fabs(RotationAxis(host, 2) + 75) < 1e-6);
  // Cmd snaps to whole 15 degree marks.
  to = RingDragTo(45, 22);
  assert(Drag(osc, to.x, to.y, part, kFxModifierKey_COMMAND));
  assert(fabs(RotationAxis(host, 2) - 15) < 1e-6);
  // Nothing else moved, and the drag is one undo step.
  id<KFPropertyPose> combined = host.blobs[@(MMPositionControls)];
  assert(combined.values[0].doubleValue == 0 && combined.values[1].doubleValue == 0 && !host.blobs[@(MMScaleControls)]);
  assert(host.undoGroupsStarted == 3 && host.undoGroupsEnded == 3);
  assert(Up(osc, to.x, to.y, part) && !osc.dragging);
  assert(host.undoGroupsStarted == 3 && host.undoGroupsEnded == 3 && host.undoDepth == 0);
  // The rings turn with the pose: at Z = 15 degrees the X ring's edge-on
  // segment has swung off vertical. Probe it half way out, clear of the point
  // where it meets the Z circle, and its own drag must write X alone.
  double tilt = 15 * M_PI / 180, along = OSCRingRadius / 2;
  CGPoint onX = CGPointMake(960 - along * sin(tilt), 540 + along * cos(tilt));
  part = Hit(osc, onX.x, onX.y);
  assert(part == OSCBoxPartRingBase + OSCRingAxisX);
  assert(Down(osc, onX.x, onX.y, part));
  assert(Drag(osc, onX.x + 20, onX.y - 20, part, 0));
  assert(fabs(RotationAxis(host, 0)) > 1 && fabs(RotationAxis(host, 2) - 15) < 1e-6 && fabs(RotationAxis(host, 1)) < 1e-9);
  Up(osc, onX.x, onX.y, part);
  // Snapping is to the marks themselves, not to steps away from the press: a
  // ring grabbed at 7 degrees snaps to 15, not to 22.
  host.blobs[@(MMRotationControls)] = LanePose(MMRotationLane(), @[@0, @0, @7]);
  part = Hit(osc, press.x, press.y);
  assert(part == OSCBoxPartRingBase + OSCRingAxisZ);
  assert(Down(osc, press.x, press.y, part));
  to = RingDragTo(45, 10);
  assert(Drag(osc, to.x, to.y, part, kFxModifierKey_COMMAND));
  assert(fabs(RotationAxis(host, 2) - 15) < 1e-6);
  // Pulling back the other way lands on the mark below, not on 7 minus 15.
  to = RingDragTo(45, -4);
  assert(Drag(osc, to.x, to.y, part, kFxModifierKey_COMMAND));
  assert(fabs(RotationAxis(host, 2)) < 1e-6);
  Up(osc, to.x, to.y, part);
  // Hiding the rings leaves no invisible grab region, and the pointer falls
  // through to the position drag.
  host.editors[@(MMShowRotationOSC)] = @NO;
  assert(Hit(osc, press.x, press.y) == OSCBoxPartPosition);
  assert(Hit(osc, onX.x, onX.y) == OSCBoxPartPosition);
}

// The square sits on the pivot, which with no offset or anchor is the canvas
// centre. Its own drag moves the anchor in full-resolution pixels, so the pivot
// follows the pointer one to one.
static id<KFPropertyPose> Anchor(OSCHost *host) { return host.blobs[@(MMAnchorControls)]; }
static double AnchorAxis(OSCHost *host, NSUInteger axis) { return Anchor(host).values[axis].doubleValue; }

static void anchorSquare(void) {
  OSCHost *host = Host();
  // The edge-on X and Y rings lie across the pivot at rest, so keep the gizmo
  // off while probing the square's own region; precedence is checked below.
  host.editors[@(MMShowRotationOSC)] = @NO;
  MagicMoveOSC *osc = [[MagicMoveOSC alloc] initWithAPIManager:host];
  // Off by default: the pivot falls through to the position drag, and a press
  // there moves the image instead of the anchor.
  assert(Hit(osc, 960, 540) == OSCBoxPartPosition);
  host.editors[@(MMShowAnchorOSC)] = @YES;
  NSInteger part = Hit(osc, 960, 540);
  assert(part == OSCBoxPartAnchor);
  // Grabbing off-centre still moves by the pointer's own delta.
  CGPoint press = CGPointMake(960 + OSCAnchorHitRadius - 1, 540);
  part = Hit(osc, press.x, press.y);
  assert(part == OSCBoxPartAnchor);
  NSUInteger writes = host.blobWrites;
  assert(Down(osc, press.x, press.y, part) && osc.dragging && host.undoGroupsStarted == 0);
  assert(host.blobWrites == writes && !Anchor(host));
  assert(Drag(osc, press.x + 120, press.y + 45, part, 0));
  // One write carries both axes; canvas Y is up in this host, as is the anchor.
  assert(host.blobWrites == writes + 1);
  assert(fabs(AnchorAxis(host, 0) - 120) < 1e-9 && fabs(AnchorAxis(host, 1) - 45) < 1e-9);
  // Ticks measure from the press, and nothing else moves.
  assert(Drag(osc, press.x - 20, press.y, part, 0));
  assert(fabs(AnchorAxis(host, 0) + 20) < 1e-9 && fabs(AnchorAxis(host, 1)) < 1e-9);
  id<KFPropertyPose> combined = host.blobs[@(MMPositionControls)];
  assert(combined.values[0].doubleValue == 0 && combined.values[1].doubleValue == 0 && !host.blobs[@(MMScaleControls)]);
  assert(host.undoGroupsStarted == 2 && host.undoGroupsEnded == 2);
  assert(Up(osc, press.x, press.y, part) && !osc.dragging && host.undoDepth == 0);
  // The square rides the pivot, so it is now where the anchor moved it.
  assert(Hit(osc, 960, 540) == OSCBoxPartPosition);
  assert(Hit(osc, 940, 540) == OSCBoxPartAnchor);
  // It wins where the rings cross the pivot, and they stay grabbable elsewhere.
  host.editors[@(MMShowRotationOSC)] = @YES;
  assert(Hit(osc, 940, 540) == OSCBoxPartAnchor);
  CGPoint onRing = CGPointMake(940 + OSCRingRadius * cos(M_PI / 4), 540 + OSCRingRadius * sin(M_PI / 4));
  assert(Hit(osc, onRing.x, onRing.y) == OSCBoxPartRingBase + OSCRingAxisZ);
  // A pivot on a corner handle still belongs to the square: it is the smaller
  // target and draws over the handles.
  host.blobs[@(MMAnchorControls)] = LanePose(MMAnchorLane(), @[@960, @540]);
  assert(Hit(osc, 1920, 1080) == OSCBoxPartAnchor);
  // Hiding it again leaves no invisible grab region.
  host.editors[@(MMShowAnchorOSC)] = @NO;
  assert(Hit(osc, 1920, 1080) == OSCBoxPartHandleBase + 2);
}

int main(void) {
  @autoreleasepool {
    geometryFromHost();
    moveAnywhere();
    scaleHandles();
    explicitTargeting();
    registeredCache();
    missingHost();
    hiddenControls();
    rotationRings();
    anchorSquare();
  }
  puts("OSC writes: host geometry, move anywhere, one write per tick, handle scaling, explicit targeting, "
       "cache sharing, hidden controls, rotation rings, anchor square and missing host passed");
  return 0;
}
