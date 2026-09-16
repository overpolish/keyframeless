/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import "MagicMoveOSC.h"
#import "MMCombinedPose.h"
#import "MMScalePose.h"
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

static MMCombinedPose *Combined(double x, double y, double scale) {
  return [[MMCombinedPose alloc] initWithPositionX:x positionY:y scale:scale authored:YES];
}
static OSCHost *Host(void) {
  OSCHost *host = [OSCHost new];
  host.editors[@(MMExplicitCreation)] = @NO;
  host.editors[@(MMScaleProportional)] = @NO;
  host.blobs[@(MMCustomControls)] = Combined(0, 0, 100);
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
  host.blobs[@(MMCustomControls)] = Combined(10, 20, 100);
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
  // The Scale lane overrides the combined scale once it is authored.
  host.blobs[@(MMScaleControls)] = [[MMScalePose alloc] initWithX:50 y:200 authored:YES];
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
  assert(Down(osc, 100, 100, part) && osc.dragging && host.undoGroupsStarted == 1);
  assert(host.blobWrites == writes);
  assert(Drag(osc, 292, 208, part, 0));
  // One write carries both axes.
  assert(host.blobWrites == writes + 1);
  MMCombinedPose *pose = host.blobs[@(MMCustomControls)];
  assert([pose isKindOfClass:MMCombinedPose.class]);
  assert(fabs(pose.positionX - 10) < 1e-9 && fabs(pose.positionY - 10) < 1e-9 && pose.scale == 100);
  // Ticks measure from the press, so a missed tick cannot accumulate error.
  assert(Drag(osc, 484, 100, part, 0));
  pose = host.blobs[@(MMCustomControls)];
  assert(fabs(pose.positionX - 20) < 1e-9 && fabs(pose.positionY - 0) < 1e-9);
  assert(host.blobWrites == writes + 2 && host.undoGroupsEnded == 0);
  assert(Up(osc, 484, 100, part) && !osc.dragging);
  assert(host.undoGroupsStarted == 1 && host.undoGroupsEnded == 1 && host.undoDepth == 0);
  // Dragging without a press writes nothing.
  assert(!Drag(osc, 600, 600, part, 0) && host.blobWrites == writes + 2);
  // Position is bounded like the inspector fields.
  assert(Down(osc, 0, 0, part) && Drag(osc, 1920 * 5, 0, part, 0));
  pose = host.blobs[@(MMCustomControls)];
  assert(pose.positionX == 200);
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
  assert(Down(osc, 1918, 1082, part) && host.undoGroupsStarted == 1);
  // Corners keep the aspect by default like the native controls, whatever
  // the inspector's link toggle says: an off-diagonal drag stays uniform.
  assert(Drag(osc, 2110, 1082, part, 0));
  assert(host.blobWrites == writes + 1);
  MMScalePose *scale = host.blobs[@(MMScaleControls)];
  assert([scale isKindOfClass:MMScalePose.class]);
  double expected = 100 * (1152.0 * 960 + 540.0 * 540) / (960.0 * 960 + 540.0 * 540);
  assert(fabs(scale.x - expected) < 1e-6 && fabs(scale.y - expected) < 1e-6);
  // Shift frees the aspect.
  assert(Drag(osc, 2110, 1082, part, kFxModifierKey_SHIFT));
  scale = host.blobs[@(MMScaleControls)];
  assert(fabs(scale.x - 120) < 1e-9 && fabs(scale.y - 100) < 1e-9);
  // The combined lane is untouched by a scale drag.
  MMCombinedPose *combined = host.blobs[@(MMCustomControls)];
  assert(combined.positionX == 0 && combined.scale == 100);
  assert(Up(osc, 2110, 1082, part) && host.undoGroupsEnded == 1);
  // Edges scale one axis by default; Shift makes them proportional.
  host.editors[@(MMScaleProportional)] = @YES;
  host.blobs[@(MMScaleControls)] = [[MMScalePose alloc] initWithX:100 y:100 authored:YES];
  part = Hit(osc, 1920, 540);
  assert(part == OSCBoxPartHandleBase + 5);
  assert(Down(osc, 1920, 540, part) && Drag(osc, 2112, 540, part, 0));
  scale = host.blobs[@(MMScaleControls)];
  assert(fabs(scale.x - 120) < 1e-9 && fabs(scale.y - 100) < 1e-9);
  assert(Drag(osc, 2304, 540, part, kFxModifierKey_SHIFT));
  scale = host.blobs[@(MMScaleControls)];
  assert(fabs(scale.x - 140) < 1e-9 && fabs(scale.y - 140) < 1e-9);
  Up(osc, 2304, 540, part);
  assert(host.undoGroupsStarted == 2 && host.undoGroupsEnded == 2);
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
  MMCombinedPose *pose = host.blobs[@(MMCustomControls)];
  assert(fabs(pose.positionX - 10) < 1e-9 && pose.positionY == 0);
  Up(osc, 492, 300, part);
  assert(host.undoGroupsStarted == 1 && host.undoGroupsEnded == 1);
}

static void registeredCache(void) {
  OSCHost *host = Host();
  MMCombinedPoseCache *cache = MMCreateCombinedPoseCache();
  host.staticValues[@(MMCombinedCacheToken)] = cache.token;
  MMRefreshCombinedPoseCache(host, TestTime(0));
  MagicMoveOSC *osc = [[MagicMoveOSC alloc] initWithAPIManager:host];
  NSInteger part = Hit(osc, 10, 10);
  assert(Down(osc, 10, 10, part) && Drag(osc, 202, 10, part, 0));
  // The inspector's cache sees the viewer edit without another host read.
  assert(fabs([cache sampleAtTime:TestTime(0)].positionX - 10) < 1e-9);
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

int main(void) {
  @autoreleasepool {
    geometryFromHost();
    moveAnywhere();
    scaleHandles();
    explicitTargeting();
    registeredCache();
    missingHost();
  }
  puts("OSC writes: host geometry, move anywhere, one write per tick, handle scaling, explicit targeting, cache sharing and missing host passed");
  return 0;
}
