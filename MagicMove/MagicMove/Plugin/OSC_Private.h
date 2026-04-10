/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "Constants.h"
#import "OSC.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKSquarePointOSC.h>

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))
#define kPointCount 4

static const float kSnapThreshold = 8.0f;
static const float kPathHitThreshold = 10.0f;
static const float kPathPointHitRadius = 8.0f;
static const NSUInteger kPathDrawResolution = 20;

typedef struct {
  UInt32 pathParam;
  UInt32 startParam;
  UInt32 endParam;
  NSInteger pathIndex;
} PathSegConfig;

static inline NSInteger pathPartCurve(NSInteger idx) { return idx * 1000 + 50; }
static inline NSInteger pathPartPoint(NSInteger idx, NSUInteger i) {
  return idx * 1000 + 100 + (NSInteger)i;
}
static inline NSInteger pathPartInHandle(NSInteger idx, NSUInteger i) {
  return idx * 1000 + 200 + (NSInteger)i;
}
static inline NSInteger pathPartOutHandle(NSInteger idx, NSUInteger i) {
  return idx * 1000 + 300 + (NSInteger)i;
}
static inline BOOL isPathPart(NSInteger part) { return part >= 50; }
static inline NSInteger pathIndexFromPart(NSInteger part) {
  return part / 1000;
}
static inline NSInteger pathPartOffset(NSInteger part) { return part % 1000; }

NS_ASSUME_NONNULL_BEGIN

@interface MagicMoveOSC ()
@property(nonatomic, strong) NSArray<KKCompoundPointOSC *> *points;
@property(nonatomic, strong) KKSnapEngine *pointSnap;
@property(nonatomic, strong) KKSnapEngine *pathSnap;
@property(nonatomic, strong) KKSquarePointOSC *anchorOSC;
@property(nonatomic, strong) KKSnapEngine *anchorSnap;
@property(nonatomic) BOOL anchorHovered;
@property(nonatomic) BOOL anchorDragging;
@property(nonatomic, strong) KKPointOSC *pathPointOSC;
@property(nonatomic, strong) KKPointOSC *pathHandleOSC;
@property(nonatomic) NSInteger pathDragIndex;
@property(nonatomic) BOOL pathDragIsInHandle;
@property(nonatomic) BOOL pathDragIsOutHandle;
@property(nonatomic) simd_float2 pathDragStartObj;
@property(nonatomic) UInt32 pathActiveParam;
@property(nonatomic) NSTimeInterval pathLastClickTime;
@property(nonatomic) NSInteger pathLastClickIndex;
@end

@interface MagicMoveOSC (Draw)
- (void)drawPathSegment:(PathSegConfig)cfg
       destinationImage:(FxImageTile *)dest
                  color:(simd_float4)color
             startInset:(double)startInset
               endInset:(double)endInset
                 atTime:(CMTime)time;
@end

@interface MagicMoveOSC (HitTest)
- (BOOL)hitTestPathSegment:(PathSegConfig)cfg
                         x:(double)mx
                         y:(double)my
                activePart:(NSInteger *)activePart
                   optDown:(BOOL)optDown
                    oscAPI:(id<FxOnScreenControlAPI_v4>)oscAPI
                    atTime:(CMTime)time;
@end

@interface MagicMoveOSC (PathInteraction)
- (BOOL)mouseDownForPathWithPart:(NSInteger)activePart
                       positionX:(double)positionX
                       positionY:(double)positionY
                       modifiers:(NSUInteger)modifiers
                     forceUpdate:(BOOL *)forceUpdate
                          atTime:(CMTime)time;
- (BOOL)mouseDraggedForPathWithPart:(NSInteger)activePart
                          positionX:(double)positionX
                          positionY:(double)positionY
                             atTime:(CMTime)time;
@end

@interface MagicMoveOSC (Helpers)
- (BOOL)boolParam:(UInt32)paramID atTime:(CMTime)time;
- (KKBezierPath *)readPathParam:(UInt32)paramID;
- (void)writePathParam:(UInt32)paramID path:(KKBezierPath *)path;
- (PathSegConfig)configForPathIndex:(NSInteger)pi;
@end

NS_ASSUME_NONNULL_END
