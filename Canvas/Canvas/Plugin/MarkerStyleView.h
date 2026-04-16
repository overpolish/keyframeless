/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Radio-style pill selector for stroke markers (none, arrow, circle, square).
/// Each pill renders a mini preview of the marker shape.
@interface KKMarkerStyleView : NSView

@property(nonatomic) NSInteger selectedIndex; // 0=none, 1=arrow, 2=circle,
                                              // 3=square, 4=arrowhead, 5=line
@property(nonatomic) BOOL isStart; // YES = start marker (arrow points left)
@property(nonatomic, copy, nullable) void (^onSelectionChanged)(NSInteger index)
    ;

@end

NS_ASSUME_NONNULL_END
