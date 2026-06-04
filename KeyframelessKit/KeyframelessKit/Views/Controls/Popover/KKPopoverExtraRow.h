/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Optional protocol popover hosts use to refresh extras rows after an
/// external mutation (cmd-Z, parameter sync etc.) without closing and
/// reopening the popover. Any extras view returned from
/// `KKTimelineInspectorView.gapPopoverExtraRows` (or any other host that
/// supports the same pattern) may conform; rows that don't implement it
/// are simply skipped.
@protocol KKPopoverExtraRow <NSObject>
@optional
- (void)popoverDidRefresh;
@end

NS_ASSUME_NONNULL_END
