/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <FxPlug/FxPlugSDK.h>
@import OSCControls;
@import RenderSupport;
#import "OSCCursor.h"

// The four viewer elements a control draws, each with its own visibility
// toggle and hit precedence. They map one-to-one onto OSCBoxPartKind.
typedef NS_ENUM(NSInteger, OSCViewerElement) {
  OSCViewerElementPosition = OSCBoxPartKindPosition,
  OSCViewerElementHandles = OSCBoxPartKindHandle,
  OSCViewerElementRings = OSCBoxPartKindRing,
  OSCViewerElementAnchor = OSCBoxPartKindAnchor,
};

// Ring drag state, captured at press so a tick stays consistent even if the
// pose moves under it. Euler angles are radians in X, Y, Z order; `last`
// anchors the next tick's decomposition so a long sweep stays continuous.
typedef struct {
  NSInteger axis; // OSCRingAxis*, or -1 when no ring is being dragged
  double press[3];
  double last[3];
  double tangentX, tangentY;
  CGPoint pressCanvas;
} OSCViewerRingDrag;

// A viewer control: the transformed image's outline with eight scale handles,
// rotation rings and an anchor square, driven by FxPlug on-screen-control
// callbacks. Dragging anywhere else in the viewer moves the image, so an image
// whose handles left the viewer can still be dragged back (like Transform in
// FCP). Every drag tick is ONE host write per lane, inside an undo group that
// opens and closes in that same callback: the host scopes a group to the
// calling thread, and OSC callbacks do not share one.
//
// A plugin subclass supplies the pose read, the visibility parameter for each
// element, and the lane writes; everything else (geometry, drawing, hit test,
// cursor and undo lifecycle) is shared here.
@interface OSCViewerControl : NSObject <FxOnScreenControl_v4>
@property(nonatomic, weak, readonly) id<PROAPIAccessing> apiManager;
@property(nonatomic, readonly) NSInteger hoveredHandle;
@property(nonatomic, readonly) BOOL dragging;
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;

#pragma mark - Subclass contract

// Rendered footprint at `time`; NO when the host cannot supply the parameters.
// Required: the control has nothing to draw or hit without it.
- (BOOL)boxPoseAtTime:(CMTime)time pose:(OSCBoxPose *)pose;
// One drag tick's write. `pose` is the press pose with the move, scale, ring
// or anchor delta already applied; `kind` selects which lanes to write.
// Return whether anything was written. Required for a control that edits.
- (BOOL)writePose:(OSCBoxPose)pose kind:(OSCViewerElement)kind
        modifiers:(FxModifierKeys)modifiers atTime:(CMTime)time;
// Captures per-drag editing caches at press, and releases them in `endDrag`.
- (void)beginDragOfKind:(OSCViewerElement)kind atTime:(CMTime)time;
- (void)endDrag;
// The saved visibility parameter for an element, or 0 when it is always shown.
- (UInt32)visibilityParameterForElement:(OSCViewerElement)element;
// Three ring colours in X, Y, Z axis order.
- (NSArray<NSColor *> *)ringColors;
// The classes the host decodes custom values through, matching the effect's.
- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID;

#pragma mark - Shared geometry

- (CGSize)imageSize;
// Canvas handles for the pose at `time`; NO when the host cannot supply it.
- (BOOL)canvasHandlesAtTime:(CMTime)time handles:(CGPoint[OSCBoxHandleCount])handles;
@end
