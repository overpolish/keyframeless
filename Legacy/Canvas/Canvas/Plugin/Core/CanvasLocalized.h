/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The bundle that carries Canvas's compiled string catalog
/// (CanvasUI.xcstrings). Look strings up against this bundle - never +[NSBundle
/// mainBundle] - because the inspector + panels run in FCP's shared ViewBridge
/// process, where the main bundle is not the plugin.
FOUNDATION_EXPORT NSBundle *CanvasLocalizationBundle(void);

NS_ASSUME_NONNULL_END

/// Localize a user-visible Canvas string from the CanvasUI table, resolved
/// against the plugin bundle. Never wrap layer/lane keys, KKLog messages, or
/// NSError developer strings.
#define CLoc(key, comment)                                                     \
  NSLocalizedStringFromTableInBundle((key), @"CanvasUI",                       \
                                     CanvasLocalizationBundle(), (comment))
