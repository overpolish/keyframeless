/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KKNumberField.h>

@interface KKNumberField ()

@property(nonatomic, readwrite) BOOL isFocused;

/// Shared focus entry point — called by both the field and its embedded text
/// view.
// TODO remove or keep?
// - (void)beginEditing;
/// Returns the current value formatted for editing — full precision for
/// non-integers.
- (NSString *)displayStringForEditing;

@end
