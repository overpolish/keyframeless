/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "OSCViewerControl+Input.h"
#import "OSCViewerControl+Anchor.h"
#import "OSCViewerControl+Draw.h"
#import "OSCViewerControl+Rotation.h"
#import "OSCViewerControl_Private.h"

// Per-tick diagnostics sit in the hit-test and drag paths, so they stay off
// unless the sentinel file exists. A sentinel rather than an environment
// variable because the host spawns this control as a launchd XPC service,
// which inherits nothing from the shell or the application, and re-checked
// periodically so it can be armed against a running host.
// Numeric arguments only: the host redacts strings as <private> in the log.
static BOOL OSCViewerLogEnabled(void) {
  static const NSTimeInterval recheck = 2.0;
  static BOOL enabled = NO;
  static NSTimeInterval checked = -1;
  NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
  if (checked < 0 || now - checked >= recheck) {
    checked = now;
    enabled = [NSFileManager.defaultManager fileExistsAtPath:@"/tmp/keyframeless-osc-log"];
  }
  return enabled;
}
#define OSCViewerLog(fmt, ...) do { if (OSCViewerLogEnabled()) NSLog(@"OSC " fmt, ##__VA_ARGS__); } while (0)

// The undo entry a drag of this part writes, as the host displays it.
static NSString *OSCViewerUndoName(NSInteger part) {
  switch (OSCBoxPartKind(part)) {
  case OSCBoxPartKindAnchor: return @"Move Anchor";
  case OSCBoxPartKindRing: return @"Rotate";
  case OSCBoxPartKindPosition: return @"Move";
  default: return @"Scale";
  }
}

@implementation OSCViewerControl (Input)

#pragma mark - Hit testing

// Show FCP's own cursor art over a part and restore the arrow off it. Only the
// transitions call the host, so hover ticks stay cheap.
- (void)applyCursorKind:(OSCCursorKind)kind {
  if (kind == self.cursorKind) return;
  id<FxOnScreenControlAPI_v4> osc = [self oscAPI];
  if (!osc) return;
  [osc setCursor:OSCCursorOfKind(kind)];
  self.cursorKind = kind;
}

// Precedence: the anchor square, then the scale handles, then the rotation
// rings, then the position drag that covers the rest of the canvas. A hidden
// element is not hit at all.
- (void)hitTestOSCAtMousePositionX:(double)x mousePositionY:(double)y activePart:(NSInteger *)activePart atTime:(CMTime)time {
  // The pointer is over the canvas, so the controls belong on screen whatever
  // the playhead is doing. This callback cannot demand a redraw; mouseMoved:,
  // which arrives with it, does.
  [self restoreAfterPointerActivity];
  self.hoveredHandle = -1;
  self.hoveredRing = -1;
  self.hoveredAnchor = NO;
  CGSize size = [self imageSize];
  OSCBoxPose pose;
  if (size.width <= 0 || size.height <= 0 || ![self boxPoseAtTime:time pose:&pose]) {
    *activePart = OSCBoxPartNone;
    [self applyCursorKind:OSCCursorArrow];
    return;
  }
  CGPoint corners[4];
  BOOL hasBox = [self canvasCornersForPose:pose imageSize:size corners:corners];
  OSCCursorKind kind = OSCCursorArrow;
  NSInteger part = OSCBoxPartNone;
  // The square sits on the pivot, which the position drag also covers, so it
  // wins first: it is the smallest target of the three.
  if ([self anchorAtX:x y:y pose:pose imageSize:size atTime:time]) {
    self.hoveredAnchor = YES;
    part = OSCBoxPartAnchor;
  } else {
    BOOL handles = self.showHandles;
    part = hasBox ? OSCBoxHitTest(corners, CGPointMake(x, y), OSCBoxHandleHitRadius,
                                  [self elementVisible:OSCViewerElementHandles cached:&handles atTime:time])
                  : OSCBoxPartNone;
    self.showHandles = handles;
    if (part >= OSCBoxPartHandleBase) {
      self.hoveredHandle = part - OSCBoxPartHandleBase;
      kind = OSCResizeCursorKindForBoxHandle(self.hoveredHandle);
    } else {
      OSCCursorKind ringKind = OSCCursorArrow;
      NSInteger ring = [self ringAtX:x y:y pose:pose imageSize:size cursor:&ringKind atTime:time];
      if (ring >= 0) {
        self.hoveredRing = ring;
        part = OSCBoxPartRingBase + ring;
        kind = ringKind;
      }
    }
  }
  // A drag keeps the cursor it started with, even when the pointer outruns the
  // glyph or ring it grabbed.
  [self applyCursorKind:self.dragging ? self.dragCursorKind : kind];
  *activePart = part;
  OSCViewerLog(@"hitTest (%.1f,%.1f) -> part %ld", x, y, (long)part);
}

#pragma mark - Mouse

- (void)mouseDownAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)activePart
                   modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time {
  [self restoreAfterPointerActivity];
  [self finishDrag];
  CGSize size = [self imageSize];
  OSCBoxPose pressPose;
  if (activePart == OSCBoxPartNone || size.width <= 0 || size.height <= 0 ||
      ![self boxPoseAtTime:time pose:&pressPose]) {
    OSCViewerLog(@"mouseDown ignored part=%ld size=%.0fx%.0f", (long)activePart, size.width, size.height);
    return;
  }
  self.pressPose = pressPose;
  self.dragPart = activePart;
  self.dragCursorKind = self.cursorKind;
  self.pressImageSize = size;
  self.pressPixels = [self pixelsFromCanvasX:x y:y imageSize:size];
  if (OSCBoxPartKind(activePart) == OSCBoxPartKindRing &&
      ![self beginRingDragAtX:x y:y part:activePart pose:self.pressPose imageSize:size atTime:time]) {
    [self finishDrag];
    return;
  }
  [self beginDragOfKind:(OSCViewerElement)OSCBoxPartKind(activePart) atTime:time];
  self.dragging = YES;
  *forceUpdate = YES;
  OSCViewerLog(@"mouseDown canvas=(%.1f,%.1f) pixels=(%.1f,%.1f) part=%ld", x, y, self.pressPixels.x,
               self.pressPixels.y, (long)activePart);
}

// Each tick opens and closes its own undo group, inside one callback. FxPlug
// scopes the group to the calling thread: startUndoGroup pushes a live-thread
// scope keyed on pthread_self and endUndoGroup pops it. OSC callbacks arrive
// on a concurrent dispatch queue, so a group spanning mouseDown to mouseUp
// pops a scope on a thread that never pushed one, and the host faults reading
// that thread's empty scope stack.
- (void)mouseDraggedAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)activePart
                      modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time {
  if (!self.dragging) return;
  CGPoint current = [self pixelsFromCanvasX:x y:y imageSize:self.pressImageSize];
  // The host's API objects are per-callback proxies: never keep one across
  // callbacks (Motion crashed closing the group through a stale proxy).
  id<FxUndoAPI> undo = [self.apiManager apiForProtocol:@protocol(FxUndoAPI)];
  BOOL grouped = [undo startUndoGroup:OSCViewerUndoName(self.dragPart)];
  BOOL wrote = NO;
  @try {
    int kind = OSCBoxPartKind(self.dragPart);
    if (kind == OSCBoxPartKindRing) {
      wrote = [self dragRingAtX:x y:y modifiers:modifiers atTime:time];
    } else {
      OSCBoxPose pose = self.pressPose;
      CGPoint delta = CGPointMake(current.x - self.pressPixels.x, current.y - self.pressPixels.y);
      if (kind == OSCBoxPartKindPosition) {
        pose = OSCBoxPoseMovedBy(pose, delta, self.pressImageSize);
      } else if (kind == OSCBoxPartKindHandle) {
        // Match the native Transform controls, independent of the inspector's
        // link toggle: corners keep the aspect and Shift frees it; edges scale
        // one axis and Shift makes them proportional.
        NSInteger handle = self.dragPart - OSCBoxPartHandleBase;
        BOOL shift = (modifiers & kFxModifierKey_SHIFT) != 0;
        BOOL proportional = handle < 4 ? !shift : shift;
        pose = OSCBoxPoseScaledByHandle(pose, handle, self.pressPixels, current, self.pressImageSize, proportional);
      } else {
        // Anchor: the pointer's own displacement in image pixels, so the pivot
        // follows one to one however far off-centre the square was grabbed.
        pose = OSCBoxPoseWithAnchorMovedBy(pose, delta);
      }
      wrote = [self writePose:pose kind:(OSCViewerElement)kind modifiers:modifiers atTime:time];
    }
  } @finally {
    if (grouped) [undo endUndoGroup];
  }
  OSCViewerLog(@"mouseDragged canvas=(%.1f,%.1f) wrote=%d grouped=%d", x, y, wrote, grouped);
  if (wrote) *forceUpdate = YES;
}

- (void)mouseUpAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)activePart
                 modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time {
  if (!self.dragging) return;
  OSCViewerLog(@"mouseUp canvas=(%.1f,%.1f) t=%.4f", x, y, CMTimeGetSeconds(time));
  [self finishDrag];
  *forceUpdate = YES;
}

- (void)finishDrag {
  self.dragging = NO;
  self.dragPart = OSCBoxPartNone;
  self.ringDrag = (OSCViewerRingDrag){.axis = -1};
  [self endDrag];
}

- (void)mouseExitedAtPositionX:(double)x positionY:(double)y modifiers:(FxModifierKeys)modifiers
                   forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time {
  [self applyCursorKind:OSCCursorArrow];
  if (self.hoveredHandle < 0 && self.hoveredRing < 0 && !self.hoveredAnchor) return;
  self.hoveredHandle = -1;
  self.hoveredRing = -1;
  self.hoveredAnchor = NO;
  *forceUpdate = YES;
}
// Entering the canvas brings a hidden control back for a pointer arriving from
// outside, the case plain movement inside the canvas does not cover.
- (void)mouseEnteredAtPositionX:(double)x positionY:(double)y modifiers:(FxModifierKeys)modifiers
                    forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time {
  if ([self restoreAfterPointerActivity]) *forceUpdate = YES;
}

// Plain movement inside the canvas is the common way back: the pointer is on
// the image, the playhead has stopped, and no other callback fires. Optional in
// the protocol, and only forced when something was actually hidden, so hover
// ticks stay as cheap as they were.
- (void)mouseMovedAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)activePart
                    modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time {
  if ([self restoreAfterPointerActivity]) *forceUpdate = YES;
}

#pragma mark - Keys

- (void)keyDownAtPositionX:(double)x positionY:(double)y keyPressed:(unsigned short)key modifiers:(FxModifierKeys)modifiers
               forceUpdate:(BOOL *)forceUpdate didHandle:(BOOL *)didHandle atTime:(CMTime)time {
  *forceUpdate = NO;
  *didHandle = NO;
}
// Transport is driven from the keyboard as much as the toolbar, and a key
// release over the canvas is the only other callback that can demand a redraw:
// stopping with the space bar brings the controls straight back, without
// waiting for the pointer to move. The key itself is still the host's.
- (void)keyUpAtPositionX:(double)x positionY:(double)y keyPressed:(unsigned short)key modifiers:(FxModifierKeys)modifiers
             forceUpdate:(BOOL *)forceUpdate didHandle:(BOOL *)didHandle atTime:(CMTime)time {
  if ([self restoreAfterPointerActivity]) *forceUpdate = YES;
  *didHandle = NO;
}

@end
