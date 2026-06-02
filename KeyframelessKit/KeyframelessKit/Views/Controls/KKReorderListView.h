/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A compact vertical list of titled rows the user reorders by dragging a row
/// up or down. Backs the timeline's "property order" popover. Fires onReorder
/// with the new identifier order only when a drag actually changes it.
@interface KKReorderListView : NSView

/// itemIDs are stable identifiers (lane labels); titles are the parallel,
/// already-localized display strings shown in each row.
- (instancetype)initWithItemIDs:(NSArray<NSString *> *)itemIDs
                         titles:(NSArray<NSString *> *)titles;

@property(nonatomic, copy, nullable) void (^onReorder)
    (NSArray<NSString *> *newOrder);

@end

NS_ASSUME_NONNULL_END
