/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The scalar directive model: what one `// #float` / `#choice` / `#point` /
// ... declaration parses into. The parsing itself lives in
// MirageScalarParse.h, the on-screen-control layer in MirageScalarOSC.h.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <ctype.h>
#import <math.h>
#import <string.h>

#import "MirageDirectiveCommon.h"
#import "MirageScalarKinds.h"
#import "MirageTypes.h"

// --- Scalar properties (`// #float`, `// #choice`) -----------------------
// Same declaration-annotated pattern as `// #color`, but for a `uniform float`
// (slider lane) or `uniform int` (choice-pill lane). Each occupies ONE vec4 in
// the pool (value in .x), appended AFTER the colour props so the colour path is
// unchanged. The transpiler folds them into the block with `#define <name>
// (<name>_kk.x)` (float) / `(int(<name>_kk.x))` (choice).
#define KK_SHADER_MAX_SCALAR_PROPS 12
typedef struct MirageScalarProp {
    // Which directive keyword declared this prop (registry row). Behaviour
    // chains switch on this; the is* flags below are the stamped template
    // (kept because they COMPOSE: a `#multi percent` sets isMulti + isPercent).
    MirageScalarKind kind;
    int isChoice;       // 0 = float slider, 1 = choice (int pills)
    int choiceDropdown; // `dropdown` on a #choice: searchable list, not pills
    int isPercent;      // float shown as % (0..100 lane); pool gets value / 100
    // Transition progress: a percent field whose lane defaults to the identity
    // RAMP (0% at the start, 100% at the end, linear) rather than a constant,
    // so it ties into the timing engine and the user can shape the curve. Left
    // alone it matches the built-in iProgress exactly.
    int isProgress;
    int isSeed;     // random-seed field (dice, integer, non-animatable)
    int isPoint;    // 2D point (vec2 uniform; xy of the pool vec4)
    int isBool;     // on/off checkbox (bool uniform; .x > 0.5)
    int isInt;      // integer slider (int uniform)
    int isAngle;    // rotation knob, degrees lane; uniform gets radians
    int hasMax;     // `max=` was specified (else the field is unbounded above)
    int hasMin;     // `min=` was specified (else the field is unbounded below)
    char name[64];  // GLSL uniform name
    char label[80]; // display label
    int poolOffset; // vec4 index in the pool (value in .x, or xy for a point)
    double fmin, fmax,
        fdefault;        // float (percent: in 0..100); fmax = nominal when
                         // !hasMax (slider cap; the field is unbounded)
    double sliderLo,     // the slider's visible span (its ends). Defaults to the
        sliderHi;        // field bound (or the nominal 0/cap when unbounded);
                         // `slidermin=`/`slidermax=` override it independently.
    double pdefx, pdefy; // point default (normalized 0..1)
    char options[256];   // choice: comma-separated pill labels
    int choiceCount;     // number of options
    int cdefault;        // choice default index
    // On-screen control opt-in (`osc` attribute) - PARSE-SIDE ONLY. These raw
    // fields feed the model's block synthesis (every opt-in becomes a standard
    // `@osc` block) and directive validation; runtime consumers query
    // -[MirageShaderModel oscBlockForUniform:] instead of reading them.
    // oscKind: "" = none, "point"
    // (position handle, #point), "ring"/"box" (radial-extent OSC editing the
    // normalized value as an ellipse ring or a rectangle box,
    // #float/#percent/#int/#multi), "scale", "rotate" (#angle / vec2|vec3 #multi
    // osc). oscAxis: 'x'/'y'/'z' ring plane for a legacy single-axis rotate
    // (default 'z'). oscAxes/oscAxisCount: the ORDERED active-axis set for a
    // multi-axis rotate (`osc={z}`/`osc={y,x}`/`osc={z,x,y}`) - the Nth listed
    // axis drives value component N, so order is meaningful.
    char oscKind[16];
    int skipSnapping; // `skipsnapping` on the osc directive: opt this handle out
                      // of the default Cmd-held snap (point + position sugar)
    char oscAxis;
    char oscAxes[4]; // ordered axis chars ("z"/"yx"/"zxy"), NUL-terminated
    int oscAxisCount;
    char uniformType[8];       // declared GLSL type: float/int/vec2/vec3/vec4/bool
    double rcenterx, rcentery; // ring OSC center, object space 0..1 (default 0.5)
    char linkName[64];         // ring OSC: `link=<uniform>` -> centre follows that
                               // #point's live value (empty = fixed `center=`)
    int isMulti;               // `#multi`: an N-component numeric field (vec2/vec3)
    int fieldCount;            // number of components (from fields={} / arity)
    char fieldLabels[256];     // comma-separated per-component field names
    int aspectLinked;          // `lockaspect` flag: components aspect-linkable (+
                               // locked by default) so an OSC drag keeps their ratio
    double mdef[4];            // per-component defaults (#multi)
    // Per-component HARD bounds for a #multi, from `min={a,b,c,d}` /
    // `max={a,b,c,d}` (partial: an empty slot falls back to the scalar
    // `min=`/`max=`, else unbounded). Lets one control mix ranges - e.g. a crop
    // with W,H clamped 0..100 and X,Y free to go off-frame. mhasMin/mhasMax say
    // whether that component ended up bounded; mmin/mmax hold the value if so.
    double mmin[4], mmax[4];
    int mhasMin[4], mhasMax[4];
    // Per-component display units for a #multi, from `units={%,px,...}`. Each is
    // '%' (literal percent - the lane shows a "%" and the SHADER divides by 100),
    // 'p' (media pixels - stored normalised 0..1, shown in px, scaled by media),
    // or 0 (raw / unitless). A #multi is delivered RAW, so the shader owns the
    // conversion; a px field is a 0..1 fraction, a % field is 0..100.
    char fieldUnit[4];
} MirageScalarProp;

#endif // __METAL_VERSION__
