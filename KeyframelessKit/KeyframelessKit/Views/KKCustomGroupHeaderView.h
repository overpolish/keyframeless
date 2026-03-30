/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Cocoa/Cocoa.h>
#import <KeyframelessKit/KKParameterRowView.h>

NS_ASSUME_NONNULL_BEGIN

@protocol PROAPIAccessing;

@interface KKCustomGroupHeaderView : KKParameterRowView

@property(nonatomic, assign) BOOL isEnabled;
@property(nonatomic, assign) BOOL isExpanded;
@property(nonatomic, copy, nullable) NSString *statusText;
@property(nonatomic, strong, nullable) NSColor *statusColor;

@property(nonatomic, copy, nullable) void (^onEnabledChanged)(BOOL isEnabled);
@property(nonatomic, copy, nullable) void (^onExpandedChanged)(BOOL isExpanded);

- (instancetype)initWithFrame:(NSRect)frame
                   apiManager:(id<PROAPIAccessing>)apiManager
                  parameterId:(UInt32)parameterId
                         text:(NSString *)text
                         icon:(nullable NSImage *)icon
                showsCheckbox:(BOOL)showsCheckbox;

@end

NS_ASSUME_NONNULL_END
