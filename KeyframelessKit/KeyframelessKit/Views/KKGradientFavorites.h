/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKGradientBarView.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKGradientFavorite : NSObject
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSArray<KKGradientStop *> *stops;
+ (instancetype)favoriteWithName:(NSString *)name
                           stops:(NSArray<KKGradientStop *> *)stops;
@end

@interface KKGradientFavorites : NSObject
+ (instancetype)shared;
@property(nonatomic, readonly) NSArray<KKGradientFavorite *> *favorites;
- (void)addFavoriteWithName:(NSString *)name
                      stops:(NSArray<KKGradientStop *> *)stops;
- (void)removeFavoriteWithIdentifier:(NSString *)identifier;
- (void)renameFavoriteWithIdentifier:(NSString *)identifier
                              toName:(NSString *)name;
@end

NS_ASSUME_NONNULL_END
