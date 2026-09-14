/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

@class FxImageTile;
@class KKOSCLabel;
@class KKPointOSC;
@class KKRectBorderOSC;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

enum {
  KKBoxPartNone = 0,
  KKBoxPartRect = 1,
  KKBoxPartHandleBase = 2, // + index 0..7
};

#define KKBoxHandleCount 8

/// A reusable rectangular on-screen control: a border, 8 grab handles (4
/// corners + 4 edge midpoints), and a trailing-bottom size readout. It owns the
/// rendering, the handle geometry, and the hit-test - everything that is common
/// to a "box with handles" gizmo - but is deliberately unaware of what the box
/// *means*. Owners (a crop OSC, a scale OSC, ...) compute the box's two corners
/// however they like and supply the readout string; the value math (how a
/// handle drag maps to new parameter values) stays in the owner.
///
/// Canonical handle index order, shared by draw + hit-test so they always
/// agree:
///   0-3 corners: bottom-left, bottom-right, top-right, top-left
///   4-7 edges:   bottom-mid, right-mid, top-mid, left-mid
@interface KKBoxOSC : NSObject

@property(nonatomic, weak) id<PROAPIAccessing> apiManager;

@property(nonatomic, strong, readonly) NSArray<KKPointOSC *> *pointOSCs;
@property(nonatomic, strong, readonly) KKRectBorderOSC *borderOSC;
@property(nonatomic, strong, readonly) KKOSCLabel *sizeLabel;

/// Last hit-tested handle (-1 = none) and the one currently grabbed for a drag.
@property(nonatomic) NSInteger hoveredIndex;
@property(nonatomic) NSInteger draggingIndex;

/// Multiplier on the whole box's alpha (border + handles), default 1.0. Draw at
/// < 1.0 to render the box as a dimmed "ghost" during opt-reveal.
@property(nonatomic) float ghostAlpha;

/// Opt-hover visibility affordance (like KKRingOSC): 0 = none (normal resize
/// cursor), 1 = "hide" (eye.slash over a visible box), 2 = "show" (eye over a
/// revealed ghost). Set by the owner when Opt is held over a toggleable box;
/// the hovered handle then shows the eye cursor instead of a resize cursor.
@property(nonatomic) NSInteger visibilityHint;

/// Extra grab slack added to each handle's hitRadius, default 0. Set > 0 for a
/// more forgiving hit target (the scale box uses this).
@property(nonatomic) double hitPadding;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;

/// Canonical handle position for a box spanning the two opposite corners.
+ (CGPoint)handlePositionForIndex:(NSInteger)index
                         topRight:(CGPoint)topRight
                       bottomLeft:(CGPoint)bottomLeft;

/// Draws the border, the 8 handles, and (when non-nil) the readout label below
/// the box's lower-right corner. `activeHandle` (-1 = none) is drawn hovered.
- (void)drawWithTopRight:(CGPoint)topRight
              bottomLeft:(CGPoint)bottomLeft
                 readout:(nullable NSString *)readout
            activeHandle:(NSInteger)activeHandle
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time;

/// Hit-tests the rect interior and the 8 handles. Returns a KKBoxPart value and
/// sets `hoveredIndex` to the matched handle (or -1).
- (NSInteger)hitTestAtX:(double)x
                      y:(double)y
               topRight:(CGPoint)topRight
             bottomLeft:(CGPoint)bottomLeft;

/// Clears hovered + dragging state (call on mouse up).
- (void)resetHover;

@end

NS_ASSUME_NONNULL_END
