/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasOSCConstraint.h"

#import <math.h>

// The shared Shift-axis-lock / Cmd-45deg-snap math, extracted verbatim from the
// (previously duplicated) -_constrainHandle:modifiers: in CanvasPenController.m
// and -_constrain:aspect:modifiers: in CanvasPathEditController.m.

simd_float2 CanvasConstrainHandleDelta(simd_float2 delta, float aspect,
                                       CanvasPenModifiers mods) {
  if (aspect <= 0)
    aspect = 1.0f;
  double px = delta.x * aspect, py = delta.y;
  if (mods & CanvasPenModShift) {
    if (fabs(px) >= fabs(py))
      py = 0;
    else
      px = 0;
  } else if (mods & CanvasPenModCmd) {
    double mag = hypot(px, py), step = M_PI / 4.0;
    double ang = round(atan2(py, px) / step) * step;
    px = mag * cos(ang);
    py = mag * sin(ang);
  }
  return simd_make_float2((float)(px / aspect), (float)py);
}
