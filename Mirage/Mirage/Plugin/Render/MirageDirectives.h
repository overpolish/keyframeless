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
//   MirageDirectiveCommon.h     attribute scraping, name prettifier, shared params
//   MirageColorProps.h          // #color
//   MirageAudioProps.h          // #audio
//   MirageScalarProps.h         // #float, #choice, #point ... - the model
//   MirageScalarOSC.h           ... their on-screen controls
//   MirageScalarParse.h         ... reading them out of the source
//   MirageDirectiveValidation.h whole-source checks (duplicates, bad OSC opt-ins)
//
// Not for Metal (uses libm); each header guards itself just in case.

#import "MirageAudioProps.h"
#import "MirageColorProps.h"
#import "MirageDirectiveCommon.h"
#import "MirageDirectiveValidation.h"
#import "MirageScalarOSC.h"
#import "MirageScalarParse.h"
#import "MirageScalarProps.h"
#import "MirageShaderModel.h"
