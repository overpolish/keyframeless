/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

// The multi-pass code sections ride in the plugin-state blob after the state
// sample(s), each as [uint32 nameLen][name UTF8][uint32 codeLen][code UTF8].
// Names identify the pass ("Image", "Common", "Buffer A"). This is the only
// channel from -pluginState: (where the parameter APIs resolve) to
// -renderDestinationImage: (where they do not), so both ends live here.

/// Append the shader's code sections for `timeline` to `data`: the "Mirage"
/// lane's codeString as "Image", plus each non-empty extra tab (Common /
/// Buffer A-D).
///
/// A present-but-empty codeString means the user explicitly cleared it =>
/// passthrough, so nothing is written. An ABSENT Mirage lane is different: the
/// timeline blob simply hasn't been persisted yet (a fresh instance writes it
/// only on the first param change / UI edit), and the editor already shows the
/// catalog default, so seed that same default here - otherwise the first render
/// falls to passthrough and the plasma only appears after the user nudges a
/// param.
void MirageAppendCodeSections(NSMutableData *data,
                              KKTimeline *_Nullable timeline);

/// Parse the sections back out, starting at `off`. Tolerates a truncated blob
/// (stops at the first section that would overrun).
NSDictionary<NSString *, NSString *> *MirageParseSections(NSData *data,
                                                          NSUInteger off);

NS_ASSUME_NONNULL_END
