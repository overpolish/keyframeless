/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Cocoa/Cocoa.h>
#import <KeyframelessKit/KKParameterRowView.h>

NS_ASSUME_NONNULL_BEGIN

@protocol PROAPIAccessing;

@interface KKCustomGroupHeaderView : KKParameterRowView

@property(nonatomic, assign) BOOL isEnabled;
@property(nonatomic, assign) BOOL isExpanded;
@property(nonatomic, assign) BOOL isInteractive;
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

/// Adds an icon button to the trailing edge. Only supported on headers created
/// with showsCheckbox:NO.
- (void)addTrailingButtonWithIcon:(NSImage *)icon action:(void (^)(void))action;

@end

NS_ASSUME_NONNULL_END
