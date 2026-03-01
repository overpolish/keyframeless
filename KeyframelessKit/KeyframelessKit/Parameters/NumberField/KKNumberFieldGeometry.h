//
//  KKNumberFieldGeometry.h
//  KeyframelessKit
//
//  Shared layout constants used by both KKNumberField and KKFocusRingOverlay.
//  These define structural geometry that both files must agree on — prefix zone width,
//  suffix zone width, and the focus ring panel padding.
//

#pragma once

#import <CoreGraphics/CoreGraphics.h>

/// Width reserved for the 1-character prefix label zone (e.g. "X", "Y").
static const CGFloat KKNumberFieldPrefixWidth = 12.0;
/// Width reserved for the 1–2 character suffix label zone (e.g. "px", "%").
static const CGFloat KKNumberFieldSuffixWidth = 18.0;
/// Extra padding added to all sides of the focus ring panel so the ring stroke
/// is never clipped by the window server at the panel boundary.
static const CGFloat KKFocusRingPanelPadding = 18.0;
