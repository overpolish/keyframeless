/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ShaderPresets.h"
#import <KeyframelessKit/KKPresets.h>

// The built-in "look" presets were Type + palette blobs for the retired 12
// built-in Types. The plugin is Custom-only now (the look lives in the shader
// source), so there are no built-in presets until shaders ship their own.
NSArray<KKPreset *> *ShaderBuiltinPresets(void) { return @[]; }
