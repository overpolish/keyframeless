/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

@class FxImageTile;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

@interface KKToolbarItem : NSObject
@property(nonatomic, copy) NSString *iconName;
@property(nonatomic, assign) NSInteger tag;
+ (instancetype)itemWithIcon:(NSString *)sfSymbolName tag:(NSInteger)tag;
@end

@interface KKToolbar : NSObject

/// Tag of the currently active item.
@property(nonatomic, assign) NSInteger activeTag;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                             items:(NSArray<KKToolbarItem *> *)items;

/// Draw the toolbar. Call every frame.
- (void)drawWithDestinationImage:(FxImageTile *)destinationImage;

/// Hit test. Returns the item tag or 0 if not hit.
- (NSInteger)hitTestAtX:(double)x y:(double)y;

@end

NS_ASSUME_NONNULL_END
