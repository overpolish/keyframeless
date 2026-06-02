/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The bundle that carries MagicMove's compiled string catalog
/// (MagicMoveUI.xcstrings). Look strings up against this bundle - never
/// +[NSBundle mainBundle] - because the inspector runs in FCP's shared
/// ViewBridge process, where the main bundle is not the plugin.
FOUNDATION_EXPORT NSBundle *MagicMoveLocalizationBundle(void);

NS_ASSUME_NONNULL_END

/// Localize a user-visible MagicMove string from the MagicMoveUI table. Use
/// for inspector chrome, gap-popover extras, help text. Never wrap lane keys
/// (@"Position"/@"Scale" etc - those go through KKLocalizedParamName), KKLog
/// messages, or NSError developer strings.
#define MMLoc(key, comment)                                                    \
  NSLocalizedStringFromTableInBundle((key), @"MagicMoveUI",                    \
                                     MagicMoveLocalizationBundle(), (comment))
