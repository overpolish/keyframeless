/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, CanvasPenCursorRole) {
  CanvasPenCursorRolePen = 0, // free pen (place / draw)
  CanvasPenCursorRoleClose,   // over the first / last anchor (close / finish)
  CanvasPenCursorRoleAdd,     // over a segment (insert anchor)
  CanvasPenCursorRoleDelete,  // Opt over an anchor (remove anchor)
};

/// The shared pen-tool cursor set: the resource name + hotspot for each role is
/// defined once here so the viewer OSC and the inspector mini stay in lockstep
/// (a hotspot tweak hits both surfaces at once). Cached; falls back to the
/// crosshair if a resource is missing.
NSCursor *CanvasPenCursorForRole(CanvasPenCursorRole role);

NS_ASSUME_NONNULL_END
