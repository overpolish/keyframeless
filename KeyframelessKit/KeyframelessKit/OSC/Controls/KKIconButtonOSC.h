/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

@class FxImageTile;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

typedef void (^KKIconButtonAction)(void);

@interface KKIconButtonOSC : NSObject

/// SF Symbol name to display. Changing this invalidates the cached texture.
@property(nonatomic, copy) NSString *iconName;

/// Logical size of the rendered icon in canvas units.
@property(nonatomic, readonly) CGSize size;

/// Called when the button is clicked.
@property(nonatomic, copy, nullable) KKIconButtonAction action;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;

/// Draw the icon centered at the given canvas position.
- (void)drawAtCanvasPosition:(CGPoint)canvasPosition
            destinationImage:(FxImageTile *)destinationImage;

/// Returns YES if the point is within the hit region centered at `center`.
- (BOOL)hitTestAtMousePositionX:(double)positionX
                      positionY:(double)positionY
                         center:(CGPoint)center;

@end

NS_ASSUME_NONNULL_END
