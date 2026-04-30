/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKPopupSelectView : NSView

@property(nonatomic, readonly) NSPopUpButton *popup;
@property(nonatomic, copy, nullable) void (^onSelectionChanged)
    (NSInteger selectedIndex);

- (instancetype)initWithTitles:(NSArray<NSString *> *)titles;

- (void)selectIndex:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
