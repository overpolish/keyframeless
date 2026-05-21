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
/// Bracket a click/drag-sweep so the consumer coalesces every per-pill
/// `onToggled` in between into a single undo entry. Fires once on mouseDown
/// and once on mouseUp (even for a plain click). Not used in radioMode.
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);
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

/// Screen rect of the pill at `index`. Used by joyride guides to cutout a
/// single segment of a grouped tab/radio bar. NSZeroRect if out of range or
/// not in a window.
- (NSRect)guidePillScreenRectAtIndex:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
