/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniCanvasRenderer.h"

#import "KKMiniCanvasCropEditor.h"
#import <KeyframelessKit/KKTimingEvaluation.h>
#import <KeyframelessKit/KKTimingStage.h>

@implementation KKMiniCanvasRenderer {
  KKMiniCanvasCropEditor *_cropEditor;
  BOOL _pointGrabbed;
}

- (instancetype)init {
  self = [super init];
  if (self)
    _cropEditor = [[KKMiniCanvasCropEditor alloc] init];
  return self;
}

#pragma mark - Subclass vocabulary (defaults)

- (NSString *)cropLabel {
  return @"Crop";
}
- (NSString *)pointLabel {
  return nil;
}
- (NSInteger)valueTypeForLabel:(NSString *)label {
  return KKLaneValueTypeFloat;
}
- (NSArray<NSNumber *> *)defaultValuesForLabel:(NSString *)label {
  return @[ @0 ];
}

#pragma mark - Subclass effect + point handle (defaults)

- (BOOL)encodeEffectFromSource:(id<MTLTexture>)source
                          into:(id<MTLTexture>)dest
                 commandBuffer:(id<MTLCommandBuffer>)cb {
  return NO;
}
- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
           forContentRect:(CGRect)contentRect {
  return NO;
}
- (BOOL)pointHandleCenter:(out CGPoint *)outCenter
                 forValue:(double)value
           forContentRect:(CGRect)contentRect {
  return NO;
}
- (BOOL)pointHandleHitAtPoint:(CGPoint)p contentRect:(CGRect)contentRect {
  return NO;
}
- (void)applyPointDragToPoint:(CGPoint)p
                  contentRect:(CGRect)contentRect
                       canvas:(KKMiniCanvasView *)canvas {
}

#pragma mark - Provided to subclasses

// The mini canvas is the *constants* editor: a property's handle shows only
// while it's a constant. Every property always has a lane; `enabled` means
// animatable (dropdown-controlled). Constant == the lane is absent or not
// enabled. Editing a value preserves `enabled`, so the handle stays put
// through a drag — no mid-drag exemption needed.
- (BOOL)isConstantLabel:(NSString *)label {
  for (KKLane *lane in self.timeline.lanes)
    if ([lane.label isEqualToString:label])
      return !lane.enabled;
  return YES;
}

- (NSArray<NSNumber *> *)valuesForLabel:(NSString *)label {
  for (KKLane *lane in self.timeline.lanes) {
    if (![lane.label isEqualToString:label])
      continue;
    NSArray<NSNumber *> *v = KKTimelineLaneValueAtFraction(lane, 0.0);
    if (v.count > 0)
      return v;
  }
  return [self defaultValuesForLabel:label];
}

- (CGRect)cropRectForContentRect:(CGRect)cr {
  NSString *label = self.cropLabel;
  if (!label)
    return CGRectZero;
  return [_cropEditor cropRectForValues:[self valuesForLabel:label]
                            contentRect:cr];
}

- (KKTimeline *)_timelineBySettingValues:(NSArray<NSNumber *> *)values
                                forLabel:(NSString *)label {
  KKTimeline *updated = [self.timeline copy] ?: [KKTimeline timeline];
  KKLane *lane = [KKLane laneWithLabel:label];
  lane.valueType = (KKLaneValueType)[self valueTypeForLabel:label];
  lane.enabled = NO; // a value edit must not opt the property in
  [lane insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:values]];
  NSMutableArray<KKLane *> *lanes = [updated.lanes mutableCopy];
  BOOL replaced = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if ([lanes[i].label isEqualToString:label]) {
      lane.enabled = lanes[i].enabled; // preserve animatable status
      lane.componentMin = lanes[i].componentMin;
      lane.componentMax = lanes[i].componentMax;
      lanes[i] = lane;
      replaced = YES;
      break;
    }
  }
  if (!replaced)
    [lanes addObject:lane];
  updated.lanes = lanes;
  return updated;
}

- (void)commitValues:(NSArray<NSNumber *> *)values
            forLabel:(NSString *)label
              canvas:(KKMiniCanvasView *)canvas {
  self.timeline = [self _timelineBySettingValues:values forLabel:label];
  [canvas reportHandleValueForLabel:label values:values];
  [canvas setNeedsDisplay:YES];
  [canvas setHandlesNeedDisplay];
}

#pragma mark - KKMiniCanvasDelegate

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    processSourceTexture:(id<MTLTexture>)source
             intoTexture:(id<MTLTexture>)dest
           commandBuffer:(id<MTLCommandBuffer>)cb {
  if (!source || !dest || !cb)
    return NO;
  return [self encodeEffectFromSource:source into:dest commandBuffer:cb];
}

- (BOOL)_cropActiveForContentRect:(CGRect)cr {
  return !CGRectIsEmpty(cr) && self.cropLabel &&
         [self isConstantLabel:self.cropLabel];
}

- (NSArray<NSValue *> *)miniCanvas:(KKMiniCanvasView *)canvas
    extraHandleCentersForContentRect:(CGRect)cr {
  if (![self _cropActiveForContentRect:cr])
    return nil;
  return
      [_cropEditor handleCentersForValues:[self valuesForLabel:self.cropLabel]
                              contentRect:cr];
}

- (NSArray<NSValue *> *)miniCanvas:(KKMiniCanvasView *)canvas
        cropHandleCentersForValues:(NSArray<NSNumber *> *)values
                       contentRect:(CGRect)cr {
  if (![self _cropActiveForContentRect:cr])
    return nil;
  return [_cropEditor handleCentersForValues:values contentRect:cr];
}

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
        borderRect:(out CGRect *)outRect
    forContentRect:(CGRect)cr {
  if (![self _cropActiveForContentRect:cr])
    return NO;
  *outRect = [self cropRectForContentRect:cr];
  return YES;
}

- (BOOL)_pointActiveForContentRect:(CGRect)cr {
  return !CGRectIsEmpty(cr) && self.pointLabel &&
         [self isConstantLabel:self.pointLabel];
}

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    pointHandleCenter:(out CGPoint *)outCenter
          contentRect:(CGRect)cr {
  if (![self _pointActiveForContentRect:cr])
    return NO;
  return [self pointHandleCenter:outCenter forContentRect:cr];
}

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    pointHandleCenter:(out CGPoint *)outCenter
             forValue:(double)value
          contentRect:(CGRect)cr {
  if (![self _pointActiveForContentRect:cr])
    return NO;
  return [self pointHandleCenter:outCenter forValue:value forContentRect:cr];
}

- (BOOL)miniCanvas:(KKMiniCanvasView *)canvas
    handleHitAtPoint:(CGPoint)p
         contentRect:(CGRect)cr {
  if (CGRectIsEmpty(cr))
    return NO;
  if ([self _pointActiveForContentRect:cr] && [self pointHandleHitAtPoint:p
                                                              contentRect:cr])
    return YES;
  return [self _cropActiveForContentRect:cr] &&
         [_cropEditor partAtPoint:p
                           values:[self valuesForLabel:self.cropLabel]
                      contentRect:cr] >= 0;
}

- (void)miniCanvas:(KKMiniCanvasView *)canvas
    beginHandleDragAtPoint:(CGPoint)p
               contentRect:(CGRect)cr {
  _pointGrabbed = NO;
  [_cropEditor endDrag];
  if (CGRectIsEmpty(cr))
    return;
  // Point handle wins on overlap (it's the smaller target); else crop.
  if ([self _pointActiveForContentRect:cr] && [self pointHandleHitAtPoint:p
                                                              contentRect:cr]) {
    _pointGrabbed = YES;
    [self applyPointDragToPoint:p contentRect:cr canvas:canvas];
    return;
  }
  if (![self _cropActiveForContentRect:cr])
    return;
  if ([_cropEditor beginDragAtPoint:p
                             values:[self valuesForLabel:self.cropLabel]
                        contentRect:cr] >= 0) {
    NSArray<NSNumber *> *v = [_cropEditor valuesForDragToPoint:p
                                                   contentRect:cr];
    if (v)
      [self commitValues:v forLabel:self.cropLabel canvas:canvas];
  }
}

- (void)miniCanvas:(KKMiniCanvasView *)canvas
    dragHandleToPoint:(CGPoint)p
          contentRect:(CGRect)cr {
  if (_pointGrabbed) {
    [self applyPointDragToPoint:p contentRect:cr canvas:canvas];
  } else if (_cropEditor.activePart >= 0) {
    NSArray<NSNumber *> *v = [_cropEditor valuesForDragToPoint:p
                                                   contentRect:cr];
    if (v)
      [self commitValues:v forLabel:self.cropLabel canvas:canvas];
  }
}

- (void)miniCanvasEndHandleDrag:(KKMiniCanvasView *)canvas {
  _pointGrabbed = NO;
  [_cropEditor endDrag];
}

// Slider/field edits in the constants popover — mirror into the preview
// timeline so the mini canvas tracks live (persist stays coalesced
// upstream).
- (void)miniCanvas:(KKMiniCanvasView *)canvas
    applyConstantValues:(NSArray<NSNumber *> *)values
               forLabel:(NSString *)label {
  if (values.count)
    self.timeline = [self _timelineBySettingValues:values forLabel:label];
}

@end
