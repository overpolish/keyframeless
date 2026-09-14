/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// `surface="x:+10 y:-14"`: how far a control moves when the Grading surface's
// puck is pulled to the edge of its circle, and the maths for reading the puck's
// position back out of the controls.
#pragma once

#ifndef __METAL_VERSION__

// The umbrella. The engine is split in two: what a shader may DECLARE and how it
// is read, and the MATHS that turns a reading into puck movement and back.
#import "MirageSurfaceGrammar.h"
#import "MirageSurfaceAxes.h"

// The puck writes the author's REAL controls. There is no hidden grading state:
// drag toward Brighter and Threshold and Bloom visibly move in the inspector, so
// what happened is inspectable, keyframable and undoable like any other edit.
//
//     // #percent label="Threshold" min=0 max=100 default=58 surface="y:-14"
//     // #percent label="Bloom"     min=0 max=150 default=45 surface="y:+30"
//
// Response is in the control's OWN units: at full upward deflection Threshold
// falls 14 percent and Bloom rises 30. A `#color` control's response is in
// DEGREES of hue rotation instead, which follows from its kind rather than
// needing its own syntax.
//
// The relationship is bi-directional, and the two directions are deliberately
// NOT symmetric:
//
//   puck -> controls  applies the CHANGE in puck position (`+= dx*rx + dy*ry`).
//   controls -> puck  DERIVES a position by least-squares fit.
//
// Deriving for display but applying deltas for edit is what keeps a hand-tuned
// control from being silently snapped onto the mapping the instant the puck is
// nudged. It also means the puck cannot lie: when a control clamps at its min or
// max and stops responding, the derived position lags the cursor, so running out
// of room is visible instead of being a dead drag.

#endif
