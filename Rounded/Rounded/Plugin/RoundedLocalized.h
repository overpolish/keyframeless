/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The bundle that carries Rounded's compiled string catalog
/// (RoundedUI.xcstrings). Look strings up against this bundle - never
/// +[NSBundle mainBundle] - because the inspector and joyride guides run in
/// FCP's shared ViewBridge process, where the main bundle is not the plugin.
FOUNDATION_EXPORT NSBundle *RoundedLocalizationBundle(void);

NS_ASSUME_NONNULL_END

/// Localize a user-visible Rounded string from the RoundedUI table, resolved
/// against the plugin bundle. Use for guide steps, help titles, subtitles, and
/// any other text shown to the user. Never wrap lane keys (@"Radius"/@"Crop"),
/// KKLog messages, AppleScript, or NSError developer strings.
#define RLoc(key, comment)                                                     \
  NSLocalizedStringFromTableInBundle((key), @"RoundedUI",                      \
                                     RoundedLocalizationBundle(), (comment))
