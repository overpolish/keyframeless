/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Reformat GLSL source to the house style (Allman braces, tab indent, spaced
/// operators - the SPIRV-Cross .clang-format translated to astyle options).
/// Pure and self-contained: returns a newly formatted string, or the original
/// text unchanged if astyle reports an error or the input is empty. Runs
/// synchronously; cheap for a button press, but call off the main thread on
/// very large input. Only compiled into the XPC service, where astyle is
/// linked (via libkktranspiler.a).
NSString *KKFormatGLSL(NSString *source);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
