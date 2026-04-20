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
@property(nonatomic, copy, nullable) NSString *shortcutLabel;
@property(nonatomic, assign) NSInteger tag;
+ (instancetype)itemWithIcon:(NSString *)sfSymbolName
                         tag:(NSInteger)tag
               shortcutLabel:(nullable NSString *)shortcutLabel;
@end

@interface KKToolbar : NSObject

/// Tag of the currently active item (0 = no highlight).
@property(nonatomic, assign) NSInteger activeTag;

/// Extra margin from the bottom edge in points (default 8).
@property(nonatomic, assign) CGFloat bottomMargin;

/// When >= 0, align the toolbar to the right edge with this margin (default -1
/// = centered).
@property(nonatomic, assign) CGFloat rightMargin;

/// Frame of the toolbar after the last draw (ioSurface coords, Y-down).
@property(nonatomic, readonly) NSRect toolbarFrame;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                             items:(NSArray<KKToolbarItem *> *)items;

/// Draw the toolbar. Call every frame.
- (void)drawWithDestinationImage:(FxImageTile *)destinationImage;

/// Hit test. Returns the item tag or 0 if not hit.
- (NSInteger)hitTestAtX:(double)x y:(double)y;

@end

NS_ASSUME_NONNULL_END
