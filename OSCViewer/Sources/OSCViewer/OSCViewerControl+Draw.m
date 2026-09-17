/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "OSCViewerControl+Draw.h"
#import "OSCViewerControl+Anchor.h"
#import "OSCViewerControl+Rotation.h"
#import "OSCViewerControl_Private.h"
#import <IOSurface/IOSurface.h>

@implementation OSCViewerControl (Draw)

// Whether this tick's playhead is moving, folding the tick into the motion
// state. Called on every draw tick, including while dragging, so the baseline
// it compares against is never stale.
- (BOOL)playheadMovingAtTime:(CMTime)time {
  OSCPlayheadMotion motion = self.playheadMotion;
  BOOL moving = OSCPlayheadMotionUpdate(&motion, CMTIME_IS_NUMERIC(time) ? CMTimeGetSeconds(time) : NAN,
                                        OSCPlayheadMotionNow());
  self.playheadMotion = motion;
  return moving;
}

- (BOOL)restoreAfterPointerActivity {
  OSCPlayheadMotion motion = self.playheadMotion;
  OSCPlayheadMotionReset(&motion);
  self.playheadMotion = motion;
  BOOL wasHidden = self.playheadSuppressed;
  self.playheadSuppressed = NO;
  return wasHidden;
}

// The elements for this tick, appended in draw order. Returns whether the ring
// gizmo is showing, which is drawn from its own quad rather than the buffer.
- (BOOL)appendElements:(NSMutableData *)vertices pose:(OSCBoxPose)pose imageSize:(CGSize)imageSize
               surface:(CGSize)surface ringQuad:(RSOSCVertex[6])ringQuad
                params:(RSOSCRingParams *)ringParams activePart:(NSInteger)activePart atTime:(CMTime)time {
  CGPoint corners[4];
  BOOL hasBox = [self canvasCornersForPose:pose imageSize:imageSize corners:corners];
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
  return [self ringQuad:ringQuad params:ringParams pose:pose imageSize:imageSize surface:surface
             activePart:activePart atTime:time];
}

- (void)drawOSCWithWidth:(NSInteger)width height:(NSInteger)height activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage atTime:(CMTime)time {
  CGSize imageSize = [self imageSize];
  OSCBoxPose pose;
  if (!destinationImage.ioSurface || ![self boxPoseAtTime:time pose:&pose]) return;
  // Canvas space is laid out on the surface, not on the host's reported size.
  CGSize surface = CGSizeMake(destinationImage.ioSurface.width, destinationImage.ioSurface.height);
  NSMutableData *vertices = [NSMutableData data];
  RSOSCVertex ringQuad[6];
  RSOSCRingParams ringParams = {0};
  // A moving playhead means playback or a scrub, where the controls strobe over
  // footage nobody is editing; the clear inside RSOSCDraw is then the whole
  // draw, so the previous tick's elements do not linger. It also skips every
  // element's saved-visibility read for those ticks. A live drag is exempt: the
  // pointer owns the control whatever the playhead does.
  BOOL suppressed = [self playheadMovingAtTime:time] && !self.dragging;
  self.playheadSuppressed = suppressed;
  BOOL showRings = NO;
  if (!suppressed)
    showRings = [self appendElements:vertices pose:pose imageSize:imageSize surface:surface ringQuad:ringQuad
                              params:&ringParams activePart:activePart atTime:time];
  id<MTLDevice> device = RSRenderDevice(destinationImage.deviceRegistryID);
  id<MTLTexture> texture = device ? [destinationImage metalTextureForDevice:device] : nil;
  RSOSCDraw(device, texture, RSRenderPixelFormat(destinationImage.ioSurface.pixelFormat),
            [NSBundle bundleForClass:self.class], vertices, showRings ? ringQuad : NULL, &ringParams,
            NSStringFromClass(self.class));
}
@end
