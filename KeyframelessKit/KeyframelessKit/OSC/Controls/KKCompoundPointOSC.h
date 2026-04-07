/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KKArcOSC.h>
#import <KeyframelessKit/KKIconButtonOSC.h>
#import <KeyframelessKit/KKOSCLabel.h>
#import <KeyframelessKit/KKRingOSC.h>
#import <KeyframelessKit/KKRotationOSC.h>
#import <KeyframelessKit/KKSnapEngine.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKCompoundPointOSC : NSObject

/// FxPlug parameter IDs for this point.
@property(nonatomic) UInt32 pointParam;
@property(nonatomic) UInt32 rotParam;
@property(nonatomic) UInt32 rotXParam;
@property(nonatomic) UInt32 rotYParam;
@property(nonatomic) UInt32 scaleXParam;
@property(nonatomic) UInt32 scaleYParam;
@property(nonatomic) UInt32 previewParam;
@property(nonatomic) UInt32 opacityParam;

/// Part IDs for hit testing dispatch.
@property(nonatomic) NSInteger arcPart;
@property(nonatomic) NSInteger ringPart;
@property(nonatomic) NSInteger rotPart;
@property(nonatomic) NSInteger rotXRingPart;
@property(nonatomic) NSInteger rotYRingPart;
@property(nonatomic) NSInteger iconPart;
@property(nonatomic) NSInteger opacityIconPart;
@property(nonatomic) NSInteger scaleIconPart;

/// Child OSC controls.
@property(nonatomic, readonly) KKArcOSC *arc;
@property(nonatomic, readonly) KKOSCLabel *label;
@property(nonatomic, readonly) KKRingOSC *ring;
@property(nonatomic, readonly) KKRotationOSC *rot;
@property(nonatomic, readonly) KKRingOSC *rotXRing;
@property(nonatomic, readonly) KKRingOSC *rotYRing;
@property(nonatomic, readonly) KKIconButtonOSC *previewIcon;
@property(nonatomic, readonly) KKIconButtonOSC *opacityIcon;
@property(nonatomic, readonly) KKIconButtonOSC *scaleIcon;

/// Whether this point's arc is the primary (first/self) arc or a secondary.
@property(nonatomic, readonly) BOOL isPrimaryArc;

/// When YES, draw and hitTest are skipped for this compound point.
@property(nonatomic) BOOL hidden;

/// Drag state (exposed for mouseUp reset).
@property(nonatomic) BOOL arcDragging;
@property(nonatomic) BOOL ringDragging;
@property(nonatomic) BOOL rotDragging;
@property(nonatomic) BOOL rotXRingDragging;
@property(nonatomic) BOOL rotYRingDragging;

/// Create a compound point. If primaryArc is non-nil, it is used as the arc
/// (for point A which shares the parent OSC's arc). Otherwise a new arc is
/// created.
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                         labelText:(NSString *)labelText
                        primaryArc:(nullable KKArcOSC *)primaryArc;

/// Draw all sub-controls at the point's current parameter position.
- (void)drawWithParentOSC:(KKOnScreenControl *)parentOSC
         destinationImage:(FxImageTile *)dest
                   atTime:(CMTime)time;

/// Hit test all sub-controls. Sets activePart if hit.
- (void)hitTestWithParentOSC:(KKOnScreenControl *)parentOSC
                   positionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger *)activePart
                      atTime:(CMTime)time;

/// Handle mouse down. Returns YES if this point consumed the event.
- (BOOL)mouseDownWithParentOSC:(KKOnScreenControl *)parentOSC
                     positionX:(double)positionX
                     positionY:(double)positionY
                    activePart:(NSInteger)activePart
                   forceUpdate:(BOOL *)forceUpdate
                        atTime:(CMTime)time;

/// Handle mouse drag. Returns YES if this point consumed the event.
- (BOOL)mouseDraggedWithParentOSC:(KKOnScreenControl *)parentOSC
                       snapEngine:(KKSnapEngine *)snapEngine
                      snapTargets:(const CGPoint *)snapTargets
                        snapCount:(NSUInteger)snapCount
                        positionX:(double)positionX
                        positionY:(double)positionY
                       activePart:(NSInteger)activePart
                           atTime:(CMTime)time;

/// Reset all drag/hover state (call on mouseUp).
- (void)resetDragState;

@end

NS_ASSUME_NONNULL_END
