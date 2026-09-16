/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MagicMoveOSC.h"
#import "MagicMoveOSC+Rotation.h"
#import "Constants.h"
#import "Plugin.h"
#import "MMAnchorPose.h"
#import "MMCombinedPose.h"
#import "MMOSCCursor.h"
#import "MMOSCShaderTypes.h"
#import "MMRotationPose.h"
#import "MMScalePose.h"
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
@import OSCControls;
@import RenderSupport;

// Per-tick diagnostics sit in the draw and hit-test paths, so they stay off
// unless MM_OSC_LOG is set.
static BOOL MMOSCLogEnabled(void) {
  static BOOL enabled;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ enabled = getenv("MM_OSC_LOG") != NULL; });
  return enabled;
}
#define MMOSCLog(fmt, ...) do { if (MMOSCLogEnabled()) NSLog(@"MMOSC " fmt, ##__VA_ARGS__); } while (0)
// Numeric only: FCP redacts string arguments as <private> in the unified log.
static double MMOSCEffectStart(id<PROAPIAccessing> manager) {
  id<FxTimingAPI_v4> timing = [manager apiForProtocol:@protocol(FxTimingAPI_v4)];
  CMTime start = kCMTimeInvalid;
  if (timing) [timing startTimeForEffect:&start];
  return CMTimeGetSeconds(start);
}
#define MMOSCTimeString(manager, time) \
  [NSString stringWithFormat:@"t=%.4f start=%.4f", CMTimeGetSeconds(time), MMOSCEffectStart(manager)]

static const float MMOSCBorderHalfWidth = 1.0f;
static const float MMOSCHandleOutline = 1.25f;
static const float MMOSCActiveHandleGrowth = 1.5f;

// The undo entry a drag of this part writes, as the host displays it.
static NSString *MMOSCUndoName(NSInteger part) {
  if (part >= OSCBoxPartRingBase) return @"Rotate";
  return part == OSCBoxPartPosition ? @"Move" : @"Scale";
}

@implementation MagicMoveOSC {
  NSInteger _dragPart;
  BOOL _hasLastPose;
  OSCBoxPose _lastPose;
  MMOSCCursorKind _cursorKind;     // what the host is showing right now
  MMOSCCursorKind _dragCursorKind; // held for the length of a drag
  OSCBoxPose _pressPose;
  CGPoint _pressPixels;
  CGSize _pressImageSize;
  MMCombinedPoseCache *_combinedCache;
  MMScalePoseCache *_scaleCache;
  BOOL _showBorder, _showHandles;
  BOOL _tracedFirstDraw;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  if ((self = [super init])) {
    _apiManager = apiManager;
    _hoveredHandle = -1;
    _cursorKind = _dragCursorKind = MMOSCCursorArrow;
    self.hoveredRing = -1;
    self.ringDrag = (MMRingDrag){.axis = -1};
    // Registered defaults are on; a read on the first draw replaces these.
    _showBorder = _showHandles = YES;
    self.showRings = YES;
  }
  return self;
}

- (FxDrawingCoordinates)drawingCoordinates { return kFxDrawingCoordinates_CANVAS; }

// The host decodes custom values through the object it calls back, so the
// control must expose the same classes as the effect.
- (NSSet<Class> *)classesForCustomParameterID:(UInt32)parameterID {
  return MMClassesForCustomParameter(parameterID);
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
  CGRect ob = [osc objectBounds], ib = [osc inputBounds];
  MMOSCLog(@"imageSize input=%lux%lu par=%.3f objectBounds=(%.1f,%.1f %.1fx%.1f) inputBounds=(%.1f,%.1f %.1fx%.1f) zoom=%.3f", (unsigned long)width, (unsigned long)height, aspect,
           ob.origin.x, ob.origin.y, ob.size.width, ob.size.height, ib.origin.x, ib.origin.y, ib.size.width, ib.size.height, [osc canvasZoom]);
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

// Visibility is a saved per-effect toggle, so hover and exit callbacks that
// arrive without the retrieval API keep the last known value rather than
// flashing the elements back on.
- (BOOL)visible:(UInt32)parameter cached:(BOOL *)cached atTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> get = [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL value = NO;
  if (get && CMTIME_IS_NUMERIC(time) && [get getBoolValue:&value fromParameter:parameter atTime:time]) *cached = value;
  return *cached;
}

#pragma mark - Parameters

- (BOOL)boxPoseAtTime:(CMTime)time pose:(OSCBoxPose *)pose {
  id<FxParameterRetrievalAPI_v6> get = [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!get || !CMTIME_IS_NUMERIC(time)) return NO;
  OSCBoxPose result = {0, 0, 100, 100, 0, 0, 0};
  // Hover and exit callbacks arrive without the keyframe API; reading there
  // fails and would disturb the shared caches, so keep the last footprint.
  if (![self.apiManager apiForProtocol:@protocol(FxKeyframeAPI_v3)]) {
    if (_hasLastPose) { *pose = _lastPose; return YES; }
    return NO;
  }
  BOOL combinedActive = NO;
  NSError *error = nil;
  MMCombinedPose *combined = MMReadCombinedPose(self.apiManager, time, &combinedActive, &error);
  if (!combined) {
    id<FxKeyframeAPI_v3> keys = [self.apiManager apiForProtocol:@protocol(FxKeyframeAPI_v3)];
    NSUInteger count = 0;
    NSError *countError = keys ? [keys keyframeCount:&count forParameter:MMCustomControls andChannel:0] : nil;
    NSObject<NSSecureCoding, NSCopying> *value = nil;
    BOOL valueOK = [get getCustomParameterValue:&value fromParameter:MMCustomControls atTime:time];
    MMOSCLog(@"boxPose combined read failed code=%ld t=%.4f keysAPI=%d count=%lu countErr=%ld valueRead=%d pose=%d nil=%d data=%d number=%d string=%d lastPose=%d",
             (long)error.code, CMTimeGetSeconds(time), keys != nil, (unsigned long)count, (long)countError.code, valueOK,
             [value isKindOfClass:MMCombinedPose.class], value == nil, [value isKindOfClass:NSData.class],
             [value isKindOfClass:NSNumber.class], [value isKindOfClass:NSString.class], _hasLastPose);
    // A transient host gap (keyframe API absent in some callbacks) keeps the last footprint.
    if (_hasLastPose) { *pose = _lastPose; return YES; }
    return NO;
  }
  if (combinedActive) {
    result.positionX = combined.positionX;
    result.positionY = combined.positionY;
    result.scaleX = result.scaleY = combined.scale;
  } else {
    // Older effects without a combined key still drive the scalar lanes.
    double value = 0;
    if ([get getFloatValue:&value fromParameter:MMPositionX atTime:time]) result.positionX = value;
    if ([get getFloatValue:&value fromParameter:MMScale atTime:time]) result.scaleX = result.scaleY = value;
  }
  BOOL scaleActive = NO;
  MMScalePose *scale = MMReadScalePose(self.apiManager, time, &scaleActive, &error);
  if (!scale) { MMOSCLog(@"boxPose scale read failed %@", error); return NO; }
  if (scaleActive) { result.scaleX = scale.x; result.scaleY = scale.y; }
  NSArray<NSValue *> *times = @[[NSValue valueWithBytes:&time objCType:@encode(CMTime)]];
  NSArray<NSNumber *> *angles = [MMRotationLane() readSamples:self.apiManager times:times error:nil].firstObject.values;
  if (angles.count > 2) {
    result.rotation = angles[2].doubleValue;
    result.rotationX = angles[0].doubleValue;
    result.rotationY = angles[1].doubleValue;
  }
  NSArray<NSNumber *> *anchor = [MMAnchorLane() readSamples:self.apiManager times:times error:nil].firstObject.values;
  if (anchor.count > 1) { result.anchorX = anchor[0].doubleValue; result.anchorY = anchor[1].doubleValue; }
  *pose = result;
  _lastPose = result;
  _hasLastPose = YES;
  MMOSCLog(@"boxPose t=%.4f start=%.4f combinedActive=%d scaleActive=%d pos=(%.2f,%.2f) scale=(%.2f,%.2f) rot=(%.2f,%.2f,%.2f) anchor=(%.1f,%.1f)",
           CMTimeGetSeconds(time), MMOSCEffectStart(self.apiManager), combinedActive, scaleActive, result.positionX, result.positionY,
           result.scaleX, result.scaleY, result.rotationX, result.rotationY, result.rotation, result.anchorX, result.anchorY);
  return YES;
}

// Canvas corners for a pose already read this tick. NO when the plane is
// edge-on, where the render draws nothing and no box part is reachable; the
// rotation rings stay usable there, since the pivot and pose still exist.
- (BOOL)canvasCornersForPose:(OSCBoxPose)pose imageSize:(CGSize)imageSize corners:(CGPoint[4])corners {
  CGPoint object[4];
  if (imageSize.width <= 0 || imageSize.height <= 0 || !OSCBoxCorners(pose, imageSize, object)) return NO;
  for (NSInteger i = 0; i < 4; ++i) corners[i] = [self canvasFromObject:object[i]];
  return YES;
}
- (BOOL)canvasCornersAtTime:(CMTime)time corners:(CGPoint[4])corners {
  CGSize size = [self imageSize];
  OSCBoxPose pose;
  if (size.width <= 0 || size.height <= 0 || ![self boxPoseAtTime:time pose:&pose]) return NO;
  return [self canvasCornersForPose:pose imageSize:size corners:corners];
}
- (BOOL)canvasHandlesAtTime:(CMTime)time handles:(CGPoint[OSCBoxHandleCount])handles {
  CGPoint corners[4];
  if (![self canvasCornersAtTime:time corners:corners]) return NO;
  for (NSInteger i = 0; i < OSCBoxHandleCount; ++i) handles[i] = OSCBoxHandlePoint(corners, i);
  return YES;
}

#pragma mark - Drawing

// A border line as an anti-aliased capsule: same SDF the glyphs use, but a
// solid fill with no outline ring or inner gradient. Padded like a glyph so
// the fwidth-based edge has room to fall off.
static void MMOSCAppendLine(NSMutableData *data, simd_float2 from, simd_float2 to, float halfWidth, simd_float4 color) {
  simd_float2 delta = to - from;
  float length = simd_length(delta);
  if (length < 1e-3f) return;
  simd_float2 u = delta / length, n = (simd_float2){-u.y, u.x};
  float halfLength = length * 0.5f;
  simd_float2 centre = (from + to) * 0.5f;
  float padX = halfLength + halfWidth + 1.5f, padY = halfWidth + 1.5f;
  const float sx[4] = {-padX, padX, -padX, padX}, sy[4] = {-padY, -padY, padY, padY};
  MMOSCVertex quad[4];
  for (int i = 0; i < 4; ++i) {
    simd_float2 offset = u * sx[i] + n * sy[i];
    quad[i] = (MMOSCVertex){.position = centre + offset, .local = {sx[i], sy[i]}, .kind = 2,
                            .shape = {halfLength, halfWidth, 0, 0}, .fill = color};
  }
  MMOSCVertex vertices[6] = {quad[0], quad[1], quad[2], quad[1], quad[3], quad[2]};
  [data appendBytes:vertices length:sizeof(vertices)];
}
// A capsule glyph centred at `centre` whose long axis follows `axis` (Metal
// space). halfLength 0 is the legacy point glyph; edges use a pill.
static void MMOSCAppendGlyph(NSMutableData *data, simd_float2 centre, simd_float2 axis, float halfLength, float radius,
                             float outline, simd_float4 fill, simd_float4 stroke) {
  simd_float2 u = axis, n = (simd_float2){-axis.y, axis.x};
  float padX = halfLength + radius + 1.5f, padY = radius + 1.5f;
  MMOSCVertex quad[4];
  const float sx[4] = {-padX, padX, -padX, padX}, sy[4] = {-padY, -padY, padY, padY};
  for (int i = 0; i < 4; ++i) {
    simd_float2 offset = u * sx[i] + n * sy[i];
    quad[i] = (MMOSCVertex){.position = centre + offset, .local = {sx[i], sy[i]}, .shade = offset.y, .kind = 1,
                            .shape = {halfLength, radius, outline, 0}, .fill = fill, .stroke = stroke};
  }
  MMOSCVertex vertices[6] = {quad[0], quad[1], quad[2], quad[1], quad[3], quad[2]};
  [data appendBytes:vertices length:sizeof(vertices)];
}
static MTLPixelFormat MMOSCPixelFormat(FxImageTile *image) {
  switch (image.ioSurface.pixelFormat) {
  case kCVPixelFormatType_128RGBAFloat: return MTLPixelFormatRGBA32Float;
  case kCVPixelFormatType_32BGRA: return MTLPixelFormatBGRA8Unorm;
  default: return MTLPixelFormatRGBA16Float;
  }
}

- (void)drawOSCWithWidth:(NSInteger)width height:(NSInteger)height activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage atTime:(CMTime)time {
  MMOSCLog(@"draw width=%ld height=%ld activePart=%ld surface=%lux%lu format=%u", (long)width, (long)height, (long)activePart,
           (unsigned long)destinationImage.ioSurface.width, (unsigned long)destinationImage.ioSurface.height,
           (unsigned)destinationImage.ioSurface.pixelFormat);
  CGSize imageSize = [self imageSize];
  OSCBoxPose pose;
  if (!destinationImage.ioSurface || ![self boxPoseAtTime:time pose:&pose]) { MMOSCLog(@"draw: no surface or pose"); return; }
  // Canvas space is laid out on the surface, not on the host's reported size.
  float surfaceWidth = (float)destinationImage.ioSurface.width;
  float surfaceHeight = (float)destinationImage.ioSurface.height;
  CGPoint corners[4];
  BOOL hasBox = [self canvasCornersForPose:pose imageSize:imageSize corners:corners];
  NSMutableData *vertices = [NSMutableData data];
  // Handles share the border colour; the fill is a touch lighter so the ring still reads.
  const simd_float4 border = {0.9f, 0.9f, 0.9f, 0.9f}, fill = {1, 1, 1, 1}, stroke = {0.82f, 0.82f, 0.82f, 1};
  BOOL showBorder = hasBox && [self visible:MMShowPositionOSC cached:&_showBorder atTime:time];
  BOOL showHandles = hasBox && [self visible:MMShowScaleOSC cached:&_showHandles atTime:time];
  simd_float2 metal[4];
  for (NSInteger i = 0; hasBox && i < 4; ++i)
    metal[i] = (simd_float2){(float)corners[i].x - surfaceWidth / 2, surfaceHeight / 2 - (float)corners[i].y};
  for (NSInteger i = 0; showBorder && i < 4; ++i)
    MMOSCAppendLine(vertices, metal[i], metal[(i + 1) % 4], MMOSCBorderHalfWidth, border);
  NSInteger active = activePart >= OSCBoxPartHandleBase && activePart < OSCBoxPartRingBase
                         ? activePart - OSCBoxPartHandleBase : _hoveredHandle;
  for (NSInteger i = 0; showHandles && i < OSCBoxHandleCount; ++i) {
    CGPoint centre = OSCBoxHandlePoint(corners, i), axis = OSCBoxHandleAxis(corners, i);
    simd_float2 metalCentre = {(float)centre.x - surfaceWidth / 2, surfaceHeight / 2 - (float)centre.y};
    simd_float2 metalAxis = i < 4 ? (simd_float2){1, 0} : (simd_float2){(float)axis.x, -(float)axis.y};
    float radius = OSCBoxHandleRadius + (i == active ? MMOSCActiveHandleGrowth : 0);
    MMOSCAppendGlyph(vertices, metalCentre, metalAxis, i < 4 ? 0 : OSCBoxPillHalfLength, radius, MMOSCHandleOutline, fill, stroke);
  }
  MMOSCVertex ringQuad[6];
  MMOSCRingParams ringParams = {0};
  BOOL showRings = [self ringQuad:ringQuad params:&ringParams pose:pose imageSize:imageSize
                          surface:CGSizeMake(surfaceWidth, surfaceHeight) activePart:activePart atTime:time];
  id<MTLDevice> device = RSRenderDevice(destinationImage.deviceRegistryID);
  NSBundle *bundle = [NSBundle bundleForClass:MagicMoveOSC.class];
  MTLPixelFormat format = MMOSCPixelFormat(destinationImage);
  id<MTLRenderPipelineState> pipeline = RSRenderPipeline(device, bundle, format, @"MMOSCVertexShader", @"MMOSCFragmentShader");
  // The rings need their own fragment stage, so they are a second pipeline in
  // the same encoder, drawn first: the scale handles stay on top of them.
  id<MTLRenderPipelineState> ringPipeline = showRings
      ? RSRenderPipeline(device, bundle, format, @"MMOSCVertexShader", @"MMOSCRingFragment") : nil;
  id<MTLCommandQueue> queue = pipeline ? RSRenderCheckoutQueue(device) : nil;
  if (!queue) { MMOSCLog(@"draw: device=%@ pipeline=%@ queue=nil", device, pipeline); return; }
  @try {
    id<MTLTexture> texture = [destinationImage metalTextureForDevice:device];
    id<MTLCommandBuffer> buffer = texture ? [queue commandBuffer] : nil;
    if (!buffer) { MMOSCLog(@"draw: texture=%@ buffer=nil", texture); return; }
    buffer.label = @"MagicMove OSC";
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return;
    [encoder setViewport:(MTLViewport){0, 0, surfaceWidth, surfaceHeight, -1, 1}];
    simd_uint2 viewport = {(uint)surfaceWidth, (uint)surfaceHeight};
    if (ringPipeline) {
      [encoder setRenderPipelineState:ringPipeline];
      [encoder setVertexBytes:ringQuad length:sizeof(ringQuad) atIndex:MMOSCVertexIndexVertices];
      [encoder setVertexBytes:&viewport length:sizeof(viewport) atIndex:MMOSCVertexIndexViewportSize];
      [encoder setFragmentBytes:&ringParams length:sizeof(ringParams) atIndex:MMOSCFragmentIndexRingParams];
      [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    }
    // With every element hidden the clear alone is the draw: an empty vertex
    // buffer is nil and a zero-count draw is invalid.
    if (vertices.length) {
      [encoder setRenderPipelineState:pipeline];
      id<MTLBuffer> vertexBuffer = [device newBufferWithBytes:vertices.bytes length:vertices.length options:MTLResourceStorageModeShared];
      [encoder setVertexBuffer:vertexBuffer offset:0 atIndex:MMOSCVertexIndexVertices];
      [encoder setVertexBytes:&viewport length:sizeof(viewport) atIndex:MMOSCVertexIndexViewportSize];
      [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertices.length / sizeof(MMOSCVertex)];
    }
    [encoder endEncoding];
    [buffer commit];
    [buffer waitUntilCompleted];
    MMOSCLog(@"draw: %lu vertices rings=%d status=%ld error=%@ texture=%lux%lu", (unsigned long)(vertices.length / sizeof(MMOSCVertex)),
             ringPipeline != nil, (long)buffer.status, buffer.error, (unsigned long)texture.width, (unsigned long)texture.height);
  } @finally {
    RSRenderReturnQueue(queue);
  }
}

#pragma mark - Hit testing

// Show FCP's own cursor art over a part and restore the arrow off it. Only the
// transitions call the host, so hover ticks stay cheap.
- (void)applyCursorKind:(MMOSCCursorKind)kind {
  if (kind == _cursorKind) return;
  id<FxOnScreenControlAPI_v4> osc = [self oscAPI];
  if (!osc) return;
  [osc setCursor:MMCursorOfKind(kind)];
  _cursorKind = kind;
}

// Precedence: scale handles, then the rotation rings, then the position drag
// that covers the rest of the canvas. A hidden element is not hit at all.
- (void)hitTestOSCAtMousePositionX:(double)x mousePositionY:(double)y activePart:(NSInteger *)activePart atTime:(CMTime)time {
  _hoveredHandle = -1;
  self.hoveredRing = -1;
  CGSize size = [self imageSize];
  OSCBoxPose pose;
  if (size.width <= 0 || size.height <= 0 || ![self boxPoseAtTime:time pose:&pose]) {
    *activePart = OSCBoxPartNone;
    [self applyCursorKind:MMOSCCursorArrow];
    return;
  }
  CGPoint corners[4];
  BOOL hasBox = [self canvasCornersForPose:pose imageSize:size corners:corners];
  NSInteger part = hasBox ? OSCBoxHitTest(corners, CGPointMake(x, y), OSCBoxHandleHitRadius,
                                          [self visible:MMShowScaleOSC cached:&_showHandles atTime:time])
                          : OSCBoxPartNone;
  MMOSCCursorKind kind = MMOSCCursorArrow;
  if (part >= OSCBoxPartHandleBase) {
    _hoveredHandle = part - OSCBoxPartHandleBase;
    kind = MMResizeCursorKindForBoxHandle(_hoveredHandle);
  } else {
    MMOSCCursorKind ringKind = MMOSCCursorArrow;
    NSInteger ring = [self ringAtX:x y:y pose:pose imageSize:size cursor:&ringKind atTime:time];
    if (ring >= 0) {
      self.hoveredRing = ring;
      part = OSCBoxPartRingBase + ring;
      kind = ringKind;
    }
  }
  // A drag keeps the cursor it started with, even when the pointer outruns the
  // glyph or ring it grabbed.
  [self applyCursorKind:_dragging ? _dragCursorKind : kind];
  *activePart = part;
  MMOSCLog(@"hitTest (%.1f,%.1f) -> part %ld", x, y, (long)part);
}

#pragma mark - Mouse

- (void)mouseDownAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)activePart
                   modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time {
  [self finishDrag];
  CGSize size = [self imageSize];
  if (activePart == OSCBoxPartNone || size.width <= 0 || size.height <= 0 || ![self boxPoseAtTime:time pose:&_pressPose]) {
    MMOSCLog(@"mouseDown ignored part=%ld size=%@", (long)activePart, NSStringFromSize(NSSizeFromCGSize(size)));
    return;
  }
  _dragPart = activePart;
  _dragCursorKind = _cursorKind;
  _pressImageSize = size;
  _pressPixels = [self pixelsFromCanvasX:x y:y imageSize:size];
  BOOL ring = activePart >= OSCBoxPartRingBase;
  if (ring && ![self beginRingDragAtX:x y:y part:activePart pose:_pressPose imageSize:size atTime:time]) {
    [self finishDrag];
    return;
  }
  if (!ring) {
    _combinedCache = MMCombinedEditingCache(self.apiManager, time);
    _scaleCache = MMScaleEditingCache(self.apiManager, time);
  }
  _dragging = YES;
  *forceUpdate = YES;
  CGPoint object = [self objectFromCanvas:CGPointMake(x, y)];
  MMOSCLog(@"mouseDown canvas=(%.1f,%.1f) object=(%.4f,%.4f) pixels=(%.1f,%.1f) part=%ld size=%@ registeredCache=%d t=%.4f start=%.4f", x, y, object.x, object.y,
           _pressPixels.x, _pressPixels.y, (long)activePart, NSStringFromSize(NSSizeFromCGSize(size)),
           MMCombinedCacheForManager(self.apiManager) != nil, CMTimeGetSeconds(time), MMOSCEffectStart(self.apiManager));
}

// Each tick opens and closes its own undo group, inside one callback. FxPlug
// scopes the group to the calling thread: startUndoGroup pushes a live-thread
// scope keyed on pthread_self and endUndoGroup pops it. OSC callbacks arrive
// on a concurrent dispatch queue, so a group spanning mouseDown to mouseUp
// pops a scope on a thread that never pushed one, and the host faults reading
// that thread's empty scope stack.
- (void)mouseDraggedAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)activePart
                      modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time {
  if (!_dragging) return;
  CGPoint current = [self pixelsFromCanvasX:x y:y imageSize:_pressImageSize];
  // The host's API objects are per-callback proxies: never keep one across
  // callbacks (Motion crashed closing the group through a stale proxy).
  id<FxUndoAPI> undo = [self.apiManager apiForProtocol:@protocol(FxUndoAPI)];
  BOOL grouped = [undo startUndoGroup:MMOSCUndoName(_dragPart)];
  BOOL wrote = NO;
  @try {
    if (_dragPart >= OSCBoxPartRingBase) {
      wrote = [self dragRingAtX:x y:y modifiers:modifiers atTime:time];
    } else if (_dragPart == OSCBoxPartPosition) {
      OSCBoxPose pose = OSCBoxPoseMovedBy(_pressPose, CGPointMake(current.x - _pressPixels.x, current.y - _pressPixels.y), _pressImageSize);
      wrote = MMWriteCombinedValues(self.apiManager, _combinedCache, @(MAX(-200, MIN(200, pose.positionX))),
                                    @(MAX(-200, MIN(200, pose.positionY))), nil, time);
    } else {
      // Match the native Transform controls, independent of the inspector's
      // link toggle: corners keep the aspect and Shift frees it; edges scale
      // one axis and Shift makes them proportional.
      NSInteger handle = _dragPart - OSCBoxPartHandleBase;
      BOOL shift = (modifiers & kFxModifierKey_SHIFT) != 0;
      BOOL proportional = handle < 4 ? !shift : shift;
      OSCBoxPose pose = OSCBoxPoseScaledByHandle(_pressPose, handle, _pressPixels, current,
                                               _pressImageSize, proportional);
      wrote = MMWriteScaleValues(self.apiManager, _scaleCache, pose.scaleX, pose.scaleY, time);
    }
  } @finally {
    if (grouped) [undo endUndoGroup];
  }
  MMOSCLog(@"mouseDragged canvas=(%.1f,%.1f) pixels=(%.1f,%.1f) delta=(%.1f,%.1f) wrote=%d grouped=%d t=%.4f start=%.4f", x, y, current.x, current.y,
           current.x - _pressPixels.x, current.y - _pressPixels.y, wrote, grouped, CMTimeGetSeconds(time), MMOSCEffectStart(self.apiManager));
  if (wrote) *forceUpdate = YES;
}

- (void)mouseUpAtPositionX:(double)x positionY:(double)y activePart:(NSInteger)activePart
                 modifiers:(FxModifierKeys)modifiers forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time {
  if (!_dragging) return;
  MMOSCLog(@"mouseUp canvas=(%.1f,%.1f) t=%.4f", x, y, CMTimeGetSeconds(time));
  [self finishDrag];
  *forceUpdate = YES;
}

- (void)finishDrag {
  _dragging = NO;
  _dragPart = OSCBoxPartNone;
  _combinedCache = nil;
  _scaleCache = nil;
  [self clearRingDrag];
}

- (void)mouseExitedAtPositionX:(double)x positionY:(double)y modifiers:(FxModifierKeys)modifiers
                   forceUpdate:(BOOL *)forceUpdate atTime:(CMTime)time {
  [self applyCursorKind:MMOSCCursorArrow];
  if (_hoveredHandle < 0 && self.hoveredRing < 0) return;
  _hoveredHandle = -1;
  self.hoveredRing = -1;
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
