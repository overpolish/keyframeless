/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// THE canonical OSC glyph palette + metrics, consumed by BOTH the viewer OSC
// classes (KKPointOSC / KKRingOSC / ...) and the mini-viewer's Metal encodes,
// so the two surfaces read identically BY CONSTRUCTION - a color or width
// changed here changes everywhere, and neither side carries its own copy to
// drift. (The draw passes themselves stay separate - FxPlug tile pass vs
// MTKView - but every parameter fed to the shared shaders comes from here.)

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTokens.h>
#import <simd/simd.h>

// --- Point dot (KKPointOSCFragment) --------------------------------------

/// Viewer point-dot outer radius in canvas px (fill + outline). Macro, not a
/// static const, so it can seed other file-scope constants under C99 rules.
#define KKOSCPointOuterPx ((float)(KKRadiusMD + KKBorderWidthXS)) // 9
/// The mini draws every glyph at HALF the viewer's size (the mini's
/// deliberate proportion rule - see viewer/mini parity), scaled by its canvas
/// ratio.
#define KKOSCMiniGlyphRatio 0.5f
/// Outline width as a fraction of the outer radius - the ONE proportion both
/// surfaces feed KKPointOSCParams.outlineWidth, so mini dots aren't
/// proportionally thicker-ringed than viewer dots.
static inline float KKOSCPointOutlineRatio(void) {
  return (float)(KKBorderWidthXS / (KKRadiusMD + KKBorderWidthXS));
}
static inline simd_float4 KKOSCPointFill(void) {
  return (simd_float4){1.0f, 1.0f, 1.0f, 1.0f};
}
static inline simd_float4 KKOSCPointStroke(void) {
  return (simd_float4){0.0f, 0.0f, 0.0f, 0.75f};
}

// --- Glyph family size ratios (relative to the standard handle glyph) ----

/// Motion-path / path-edit anchor dots. Canvas's Position handle matches
/// this so path anchors and the transform handle read as one family.
static const CGFloat KKOSCAnchorDotScale __attribute__((unused)) = 0.6;
/// Tangent-handle end dots.
static const CGFloat KKOSCTangentDotScale __attribute__((unused)) = 0.5;

// --- Ring stroke (KKRingOSCFragment) -------------------------------------

/// Fill + stroke colors and stroke widths (viewer canvas px) for a ring OSC
/// at one emphasis level. The mini scales the widths by its
/// preview-pt-over-source-px factor; the viewer uses them directly.
typedef struct {
  simd_float4 fill;
  simd_float4 stroke;
  float fillWidthPx;
  float outlineWidthPx;
} KKOSCRingStyle;

/// 0 = idle (warm gray), 1 = hovered, 2 = active (white). THE ring palette -
/// previously duplicated verbatim between KKRingOSC.m and the mini draw loop.
static inline KKOSCRingStyle KKOSCRingStyleForEmphasis(NSInteger emphasis) {
  KKOSCRingStyle s;
  if (emphasis >= 2) { // active
    s.fill = (simd_float4){1.0f, 1.0f, 1.0f, 1.0f};
    s.stroke = (simd_float4){0.0f, 0.0f, 0.0f, 1.0f};
    s.fillWidthPx = 2.5f;
    s.outlineWidthPx = 1.5f;
  } else if (emphasis >= 1) { // hover
    s.fill = (simd_float4){0xD0 / 255.0f, 0xCA / 255.0f, 0xCD / 255.0f,
                           0xB2 / 255.0f};
    s.stroke = (simd_float4){0x09 / 255.0f, 0x07 / 255.0f, 0x0A / 255.0f,
                             0xAD / 255.0f};
    s.fillWidthPx = 2.5f;
    s.outlineWidthPx = 1.5f;
  } else { // idle
    s.fill = (simd_float4){0xCE / 255.0f, 0xCB / 255.0f, 0xCE / 255.0f,
                           0xB1 / 255.0f};
    s.stroke = (simd_float4){0x1B / 255.0f, 0x18 / 255.0f, 0x1D / 255.0f,
                             0x9F / 255.0f};
    s.fillWidthPx = 2.0f;
    s.outlineWidthPx = 1.0f;
  }
  return s;
}

// --- Radius-widget ring (corner-radius / hollow handle) ------------------
// The small ring glyph shared by corner-radius widgets and `osc=hollow`
// handles. ONLY the RADIUS is special (7 canvas px vs a regular ring's ~50) -
// the STROKE widths are the standard idle ring widths
// (KKOSCRingStyleForEmphasis), because stroke thickness is ABSOLUTE (a big ring
// and a small ring stroke the same). The viewer draws in canvas px; the mini
// draws in points and the ring encode multiplies by backingScale (~2), so the
// mini radius is the viewer's times KKOSCMiniGlyphRatio (0.5) and the mini
// widths are the idle emphasis widths times the same ratio - keeping both
// surfaces pixel-identical.
#define KKOSCRadiusWidgetRadiusPx 7.0f
#define KKOSCMiniRadiusWidgetRadiusPt                                          \
  (KKOSCRadiusWidgetRadiusPx * KKOSCMiniGlyphRatio) // 3.5

/// Fill opacity for a TINTED ring (a corner-radius widget drawn in white, or
/// error red at a clamp) per emphasis: idle 0.7 (reads as a soft gray-white),
/// hover 0.85, active 1.0. THE ramp both the viewer's KKRingOSC tint branch
/// and the mini-viewer's pen corner-ring encode read, so a tinted ring is the
/// same translucency on both surfaces (they were 0.7 vs a hardcoded 1.0 -
/// gray in the viewer, pure white in the mini).
static inline float KKOSCRingTintAlphaForEmphasis(NSInteger emphasis) {
  return emphasis >= 2 ? 1.0f : (emphasis >= 1 ? 0.85f : 0.7f);
}

static inline NSColor *KKOSCColorFromSimd(simd_float4 c) {
  return [NSColor colorWithRed:c.x green:c.y blue:c.z alpha:c.w];
}
