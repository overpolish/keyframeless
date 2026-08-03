/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The bundle that carries Mirage's compiled string catalog
/// (MirageUI.xcstrings). Look strings up against this bundle - never
/// +[NSBundle mainBundle] - because the inspector and joyride guides run in
/// FCP's shared ViewBridge process, where the main bundle is not the plugin.
FOUNDATION_EXPORT NSBundle *MirageLocalizationBundle(void);

NS_ASSUME_NONNULL_END

/// Localize a user-visible Mirage string from the MirageUI table, resolved
/// against the plugin bundle. Use for guide steps, help titles, subtitles, and
/// any other text shown to the user. Never wrap lane keys (@"Speed"/@"Origin"),
/// KKLog messages, AppleScript, or NSError developer strings.
#define RLoc(key, comment)                                                     \
  NSLocalizedStringFromTableInBundle((key), @"MirageUI",                      \
                                     MirageLocalizationBundle(), (comment))
