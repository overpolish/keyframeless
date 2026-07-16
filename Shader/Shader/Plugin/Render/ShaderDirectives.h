/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// CPU-side `// #` directive parsing, shared by the FCP render, the catalog that
// builds lanes from a shader's source, the transpiler and the mini-viewer. The
// plugin is Custom-only (runtime-compiled GLSL), so a shader's controls exist
// only as directives in its source, and every one of those callers has to agree
// on what a given source declares.
//
// This is the umbrella. Each directive kind owns a header, and anything needing
// only one kind can import that instead:
//
//   ShaderDirectiveCommon.h     attribute scraping, name prettifier, shared params
//   ShaderColorProps.h          // #color
//   ShaderAudioProps.h          // #audio
//   ShaderScalarProps.h         // #float, #choice, #point ... - the model
//   ShaderScalarOSC.h           ... their on-screen controls
//   ShaderScalarParse.h         ... reading them out of the source
//   ShaderDirectiveValidation.h whole-source checks (duplicates, bad OSC opt-ins)
//
// Not for Metal (uses libm); each header guards itself just in case.

#import "ShaderAudioProps.h"
#import "ShaderColorProps.h"
#import "ShaderDirectiveCommon.h"
#import "ShaderDirectiveValidation.h"
#import "ShaderScalarOSC.h"
#import "ShaderScalarParse.h"
#import "ShaderScalarProps.h"
