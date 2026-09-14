/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <simd/simd.h>

#import "MirageShaderModel.h"

NS_ASSUME_NONNULL_BEGIN

/// Fills every `// #audio` property's pool slots from the Sonar source its lane
/// is bound to, sampled at `timelineSeconds`.
///
/// `timelineSeconds` must be TRUE timeline seconds
/// (`timelineTime:fromInputTime:`), the clock the spectrogram is keyed by.
/// Passing the render time instead reads the wrong row: in FCP that's the
/// input's native media clock, so a clip cut from the middle of a project
/// samples wherever it happens to sit in its source file.
///
/// An unbound lane ("None"), a missing file, or a time outside the published
/// range fills zeroes: a shader bound to nothing should render silence, not
/// garbage.
///
/// Returns the new pool count (colours + scalars + audio vec4s).
int MirageFillAudioPool(
    MirageShaderModel *model, vector_float4 *pool, double timelineSeconds,
    NSArray<NSNumber *> *_Nullable (^valuesForLabel)(NSString *label));

NS_ASSUME_NONNULL_END
