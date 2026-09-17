/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "OSCViewerControl.h"
#import "OSCViewerControl+Draw.h"
#import "OSCViewerControl+Input.h"
#import "OSCViewerControl_Private.h"

@implementation OSCViewerControl

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  if ((self = [super init])) {
    _apiManager = apiManager;
    self.hoveredHandle = -1;
    self.cursorKind = self.dragCursorKind = OSCCursorArrow;
    self.hoveredRing = -1;
    self.ringDrag = (OSCViewerRingDrag){.axis = -1};
    // Elements without a saved visibility parameter stay visible; a plugin that
    // registers one starts from its default, read on the first draw.
    self.showBorder = self.showHandles = self.showRings = YES;
    self.showAnchor = NO;
  }
  return self;
}

- (FxDrawingCoordinates)drawingCoordinates { return kFxDrawingCoordinates_CANVAS; }

// Defaults for the subclass contract: no custom classes, elements always on,
// no writes, white rings.
- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID { return [NSSet set]; }
- (UInt32)visibilityParameterForElement:(OSCViewerElement)element { return 0; }
- (BOOL)boxPoseAtTime:(CMTime)time pose:(OSCBoxPose *)pose { return NO; }
- (BOOL)writePose:(OSCBoxPose)pose kind:(OSCViewerElement)kind modifiers:(FxModifierKeys)modifiers atTime:(CMTime)time {
  return NO;
}
- (void)beginDragOfKind:(OSCViewerElement)kind atTime:(CMTime)time {}
- (void)endDrag {}
- (NSArray<NSColor *> *)ringColors {
  return @[NSColor.whiteColor, NSColor.whiteColor, NSColor.whiteColor];
}

#pragma mark - Host geometry

- (id<FxOnScreenControlAPI_v4>)oscAPI {
  return [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
}
- (CGSize)imageSize {
  id<FxOnScreenControlAPI_v4> osc = [self oscAPI];
  if (!osc) return CGSizeZero;
  NSUInteger width = 0, height = 0;
  double aspect = 1;
  [osc inputWidth:&width height:&height pixelAspectRatio:&aspect];
  if (!width || !height) [osc objectWidth:&width height:&height pixelAspectRatio:&aspect];
  return CGSizeMake(width, height);
}
- (CGPoint)canvasFromObject:(CGPoint)object {
  CGPoint canvas = CGPointZero;
  id<FxOnScreenControlAPI_v4> osc = [self oscAPI];
  if (!osc) return canvas;
  [osc convertPointFromSpace:kFxDrawingCoordinates_OBJECT fromX:object.x fromY:object.y
                     toSpace:kFxDrawingCoordinates_CANVAS toX:&canvas.x toY:&canvas.y];
  return canvas;
}
- (CGPoint)objectFromCanvas:(CGPoint)canvas {
  CGPoint object = CGPointZero;
  id<FxOnScreenControlAPI_v4> osc = [self oscAPI];
  if (!osc) return object;
  [osc convertPointFromSpace:kFxDrawingCoordinates_CANVAS fromX:canvas.x fromY:canvas.y
                     toSpace:kFxDrawingCoordinates_OBJECT toX:&object.x toY:&object.y];
  return object;
}
- (CGPoint)pixelsFromCanvasX:(double)x y:(double)y imageSize:(CGSize)size {
  return OSCBoxPixelFromObject([self objectFromCanvas:CGPointMake(x, y)], size);
}
- (CGPoint)pivotCanvasForPose:(OSCBoxPose)pose imageSize:(CGSize)imageSize {
  CGPoint pivot = OSCBoxPivotPixels(pose, imageSize);
  return [self canvasFromObject:OSCBoxObjectFromPixel(pivot, imageSize)];
}

#pragma mark - Parameters

// An element is hidden when its saved parameter reads NO; hidden elements are
// neither drawn nor hit-tested, except the position drag, which covers the
// whole canvas and is the same everywhere.
- (BOOL)elementVisible:(OSCViewerElement)element cached:(BOOL *)cached atTime:(CMTime)time {
  UInt32 parameter = [self visibilityParameterForElement:element];
  if (parameter == 0) { *cached = YES; return YES; }
  id<FxParameterRetrievalAPI_v6> get = [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL value = NO;
  if (get && CMTIME_IS_NUMERIC(time) && [get getBoolValue:&value fromParameter:parameter atTime:time]) *cached = value;
  return *cached;
}

// Canvas corners for a pose already read this tick. NO when the plane is
// edge-on, where the render draws nothing and no box part is reachable; the
// rotation rings and anchor stay usable there, since the pivot still exists.
- (BOOL)canvasCornersForPose:(OSCBoxPose)pose imageSize:(CGSize)imageSize corners:(CGPoint[4])corners {
  CGPoint object[4];
  if (imageSize.width <= 0 || imageSize.height <= 0 || !OSCBoxCorners(pose, imageSize, object)) return NO;
  for (NSInteger i = 0; i < 4; ++i) corners[i] = [self canvasFromObject:object[i]];
  return YES;
}
- (BOOL)canvasHandlesAtTime:(CMTime)time handles:(CGPoint[OSCBoxHandleCount])handles {
  CGSize size = [self imageSize];
  OSCBoxPose pose;
  if (size.width <= 0 || size.height <= 0 || ![self boxPoseAtTime:time pose:&pose]) return NO;
  CGPoint corners[4];
  if (![self canvasCornersForPose:pose imageSize:size corners:corners]) return NO;
  for (NSInteger i = 0; i < OSCBoxHandleCount; ++i) handles[i] = OSCBoxHandlePoint(corners, i);
  return YES;
}

@end
