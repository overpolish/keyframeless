/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKGradientBarView.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKGradientFavoritesPopover : NSObject
@property(nonatomic, copy) NSArray<KKGradientStop *> *currentStops;
@property(nonatomic, copy, nullable) void (^onApplyFavorite)
    (NSArray<KKGradientStop *> *stops);
- (void)showRelativeToRect:(NSRect)rect ofView:(NSView *)view;
@end

NS_ASSUME_NONNULL_END
