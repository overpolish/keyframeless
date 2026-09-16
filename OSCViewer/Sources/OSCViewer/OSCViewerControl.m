/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "OSCViewerControl.h"
#import "OSCViewerControl+Anchor.h"
#import "OSCViewerControl+Rotation.h"
#import "OSCViewerControl_Private.h"
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>

// Per-tick diagnostics sit in the draw and hit-test paths, so they stay off
// unless OSC_LOG is set. Numeric only: FCP redacts string arguments as
// <private> in the unified log.
static BOOL OSCViewerLogEnabled(void) {
  static BOOL enabled;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ enabled = getenv("OSC_LOG") != NULL; });
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

#pragma mark - Drawing

- (void)drawOSCWithWidth:(NSInteger)width height:(NSInteger)height activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage atTime:(CMTime)time {
  CGSize imageSize = [self imageSize];
  OSCBoxPose pose;
  if (!destinationImage.ioSurface || ![self boxPoseAtTime:time pose:&pose]) return;
  // Canvas space is laid out on the surface, not on the host's reported size.
  CGSize surface = CGSizeMake(destinationImage.ioSurface.width, destinationImage.ioSurface.height);
  CGPoint corners[4];
  BOOL hasBox = [self canvasCornersForPose:pose imageSize:imageSize corners:corners];
  NSMutableData *vertices = [NSMutableData data];
  const simd_float4 border = {0.9f, 0.9f, 0.9f, 0.9f};
  BOOL showBorder = self.showBorder, showHandles = self.showHandles;
  showBorder = hasBox && [self elementVisible:OSCViewerElementPosition cached:&showBorder atTime:time];
  showHandles = hasBox && [self elementVisible:OSCViewerElementHandles cached:&showHandles atTime:time];
  self.showBorder = showBorder;
  self.showHandles = showHandles;
  simd_float2 metal[4];
  for (NSInteger i = 0; hasBox && i < 4; ++i) metal[i] = RSOSCMetalPoint(corners[i], surface);
  for (NSInteger i = 0; showBorder && i < 4; ++i)
    RSOSCAppendLine(vertices, metal[i], metal[(i + 1) % 4], OSCViewerBorderHalfWidth, border);
  NSInteger active = activePart >= OSCBoxPartHandleBase && activePart < OSCBoxPartRingBase
                         ? activePart - OSCBoxPartHandleBase : self.hoveredHandle;
  for (NSInteger i = 0; showHandles && i < OSCBoxHandleCount; ++i) {
    CGPoint axis = OSCBoxHandleAxis(corners, i);
    simd_float2 metalAxis = i < 4 ? (simd_float2){1, 0} : (simd_float2){(float)axis.x, -(float)axis.y};
    float radius = OSCBoxHandleRadius + (i == active ? OSCViewerActiveGlyphGrowth : 0);
    RSOSCAppendGlyph(vertices, RSOSCMetalPoint(OSCBoxHandlePoint(corners, i), surface), metalAxis,
                     i < 4 ? 0 : OSCBoxPillHalfLength, radius, OSCViewerHandleOutline, OSCViewerGlyphFill,
                     OSCViewerGlyphStroke);
  }
  // Last in the buffer, so the pivot square sits over the border and handles;
  // it needs no box, because the pivot exists even edge-on.
  [self appendAnchorSquare:vertices pose:pose imageSize:imageSize surface:surface activePart:activePart atTime:time];
  RSOSCVertex ringQuad[6];
  RSOSCRingParams ringParams = {0};
  BOOL showRings = [self ringQuad:ringQuad params:&ringParams pose:pose imageSize:imageSize
                          surface:surface activePart:activePart atTime:time];
  id<MTLDevice> device = RSRenderDevice(destinationImage.deviceRegistryID);
  id<MTLTexture> texture = device ? [destinationImage metalTextureForDevice:device] : nil;
  RSOSCDraw(device, texture, RSRenderPixelFormat(destinationImage.ioSurface.pixelFormat),
            [NSBundle bundleForClass:self.class], vertices, showRings ? ringQuad : NULL, &ringParams,
            NSStringFromClass(self.class));
}

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
    part = hasBox ? OSCBoxHitTest(corners, CGPointMake(x, y), OSCBoxHandleHitRadius,
                                  [self elementVisible:OSCViewerElementHandles cached:&self->_showHandles atTime:time])
                  : OSCBoxPartNone;
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
  [self finishDrag];
  CGSize size = [self imageSize];
  if (activePart == OSCBoxPartNone || size.width <= 0 || size.height <= 0 ||
      ![self boxPoseAtTime:time pose:&self->_pressPose]) {
    OSCViewerLog(@"mouseDown ignored part=%ld size=%@", (long)activePart, NSStringFromSize(NSSizeFromCGSize(size)));
    return;
  }
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
- (void)mouseEnteredAtPositionX:(double)x positionY:(double)y modifiers:(FxModifierKeys)modifiers
                    forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time {}

#pragma mark - Keys

- (void)keyDownAtPositionX:(double)x positionY:(double)y keyPressed:(unsigned short)key modifiers:(FxModifierKeys)modifiers
               forceUpdate:(BOOL *)forceUpdate didHandle:(BOOL *)didHandle atTime:(CMTime)time {
  *forceUpdate = NO;
  *didHandle = NO;
}
- (void)keyUpAtPositionX:(double)x positionY:(double)y keyPressed:(unsigned short)key modifiers:(FxModifierKeys)modifiers
             forceUpdate:(BOOL *)forceUpdate didHandle:(BOOL *)didHandle atTime:(CMTime)time {
  *forceUpdate = NO;
  *didHandle = NO;
}

@end
