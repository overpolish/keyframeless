/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "Constants.h"
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KeyframelessKit.h>

@class FxImageTile;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

@interface CanvasToolbar : NSObject

@property(nonatomic, assign) CanvasToolMode activeToolMode;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;

/// Draw the toolbar. Call every frame.
- (void)drawWithWidth:(NSInteger)width
               height:(NSInteger)height
     destinationImage:(FxImageTile *)destinationImage;

/// Hit test. Returns the tool part ID or 0 if not hit.
- (NSInteger)hitTestAtX:(double)x y:(double)y;

@end

NS_ASSUME_NONNULL_END
