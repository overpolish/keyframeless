/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKPillToggleRowView : NSView

@property(nonatomic, copy) NSArray<NSNumber *> *states;
@property(nonatomic, copy, nullable) void (^onToggled)
    (NSInteger index, BOOL isOn);
/// When YES, clicking the already-active pill is a no-op (radio group
/// behaviour).
@property(nonatomic) BOOL radioMode;
/// When YES, draws a single track background across all pills so they read as
/// one grouped control (segmented-control style). Active pill renders as an
/// inset highlight inside the track.
@property(nonatomic) BOOL grouped;

- (instancetype)initWithLabels:(NSArray<NSString *> *)labels;
- (instancetype)initWithIcons:(NSArray<NSImage *> *)icons;
- (instancetype)initWithLabels:(NSArray<NSString *> *)labels
                         icons:(NSArray<NSImage *> *)icons;

- (void)setState:(BOOL)on atIndex:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
