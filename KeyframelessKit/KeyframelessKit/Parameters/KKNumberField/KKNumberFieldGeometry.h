/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <CoreGraphics/CoreGraphics.h>

// Height of the editable field area
static const CGFloat KKNumberFieldInputHeight = 17.0;
// Width of the editable field area
static const CGFloat KKNumberFieldInputWidth = 54.0;
/// Width reserved for the 1-character prefix label zone (e.g. "X", "Y").
static const CGFloat KKNumberFieldPrefixWidth = 6.0;
/// Width reserved for the 1–2 character suffix label zone (e.g. "px", "%").
static const CGFloat KKNumberFieldSuffixWidth = 13.0;
/// Extra padding added to all sides of the focus ring panel so the ring stroke
/// is never clipped by the window server at the panel boundary.
static const CGFloat KKFocusRingPanelPadding = 18.0;
/// Additional offset to match prefix/suffix height in Motion/FCP
static const CGFloat KKDecorationVerticalOffset = 0.25;