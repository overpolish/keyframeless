/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPresets.h"

#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKPresets.h>
#import <KeyframelessKit/KKShape.h>
#import <KeyframelessKit/KKTimeline.h>
#import <simd/simd.h>

NSString *const kCanvasPresetPayloadKind = @"canvasLayers";
NSString *const kCanvasPresetPayloadKindAspectX = @"canvasLayers.aspectX";

// An animationJSON (per-layer KKTimeline, plain lane labels) that draws the
// stroke on left-to-right over the whole clip: "Draw On End" 0 -> 100%.
// "Draw On End" 0 -> 100% over the clip, with the given easing + intensity on
// the segment (intensity 1.0 = the curve at full strength; lower = gentler, no
// overshoot).
static NSString *CanvasDrawOnEndAnim(KKIntervalCurve curve, double intensity) {
  KKInterval *iv = [[KKInterval alloc] init];
  iv.curve = curve;
  iv.intensity = intensity;
  KKKeyPose *k0 = [KKKeyPose keyposeAtTime:0.0 values:@[ @0.0 ]];
  k0.outgoing = iv;
  KKKeyPose *k1 = [KKKeyPose keyposeAtTime:1.0 values:@[ @100.0 ]];
  KKLane *lane = [KKLane laneWithKey:@"Draw On End" label:@"Draw On End"];
  lane.enabled = YES; // animated
  lane.keyposes = @[ k0, k1 ];
  KKTimeline *tl = [KKTimeline timeline];
  tl.lanes = @[ lane ];
  return [KKTimeline jsonFromTimeline:tl] ?: @"";
}

// A straight 2-point arrow (object space, Y-up [0,1]) pointing right, ~40% of
// the canvas wide, centred. Annotation red, 12px, arrowhead on the end, drawing
// on over the clip.
static KKBezierPath *CanvasArrowLayer(void) {
  KKBezierPath *p = [[KKBezierPath alloc] init];
  p.name = @"Arrow";
  simd_float2 pts[2] = {simd_make_float2(0.3f, 0.5f),
                        simd_make_float2(0.7f, 0.5f)};
  [p setLinearPositions:pts count:2 closed:NO];
  p.strokeEnabled = YES;
  p.fillEnabled = NO;
  p.strokeColorMode = 0; // solid
  p.strokeWidth = 12.0f;
  p.endWidth = 12.0f;
  p.strokeR = 0.92f;
  p.strokeG = 0.16f;
  p.strokeB = 0.16f;
  p.startMarker = 0; // none
  p.endMarker = 1;   // arrow (filled triangle)
  p.startMarkerSize = 3.0f;
  p.endMarkerSize = 3.0f;
  p.drawOnStart = 0.0f;
  p.drawOnEnd = 1.0f; // flat fallback = whole stroke (static preview)
  p.animationJSON = CanvasDrawOnEndAnim(KKIntervalCurveLinear, 1.0);
  return p;
}

// A thick, translucent yellow bar that wipes in left-to-right (a highlighter).
// Implemented as a thick stroke with the same draw-on reveal - Canvas has no
// separate fill draw-on, and a thick horizontal stroke reads as a growing quad.
static KKBezierPath *CanvasHighlightLayer(void) {
  KKBezierPath *p = [[KKBezierPath alloc] init];
  p.name = @"Highlight";
  simd_float2 pts[2] = {simd_make_float2(0.3f, 0.5f),
                        simd_make_float2(0.7f, 0.5f)};
  [p setLinearPositions:pts count:2 closed:NO];
  p.strokeEnabled = YES;
  p.fillEnabled = NO;
  p.strokeColorMode = 0;
  p.strokeWidth = 52.0f; // a thick marker bar
  p.endWidth = 52.0f;
  p.strokeR = 1.0f;
  p.strokeG = 0.85f;
  p.strokeB = 0.1f; // highlighter yellow
  p.lineCap = 0;     // butt - flat ends like a real highlighter
  p.lineJoin = 1;
  p.startMarker = 0;
  p.endMarker = 0;
  p.opacity = 0.4f;       // translucent wash
  p.sketchEnabled = YES;  // hand-drawn marker edges
  p.sketchStrokes = 1;    // single stroke pass (no double overlay)
  p.sketchRoughness = kSketchRoughnessDefault;
  p.sketchBowing = kSketchBowingDefault;
  p.sketchSeed = 0x5151BEEF; // fixed so the jitter is stable
  p.drawOnStart = 0.0f;
  p.drawOnEnd = 1.0f;
  p.animationJSON = CanvasDrawOnEndAnim(KKIntervalCurveEaseOut, 0.5); // no overshoot
  return p;
}

// A rounded-rect outline (stroke only, red, 10px) that draws itself AROUND the
// loop over the clip - the classic "circle / box something" emphasis.
static KKBezierPath *CanvasDrawAroundLayer(void) {
  KKBezierPath *p = [[KKBezierPath alloc] init];
  p.name = @"Draw Around";
  // A closed 4-corner box as a POINTS path so each corner can carry a real
  // fillet radius (setCornerRadius - the same mechanism the corner widget uses;
  // setLinearPositions clears radii, so set them AFTER).
  simd_float2 pts[4] = {
      simd_make_float2(0.28f, 0.34f), simd_make_float2(0.72f, 0.34f),
      simd_make_float2(0.72f, 0.66f), simd_make_float2(0.28f, 0.66f)};
  [p setLinearPositions:pts count:4 closed:YES];
  for (NSUInteger i = 0; i < 4; i++)
    [p setCornerRadius:0.08f atIndex:i]; // object-Y units, all 4 corners
  p.closed = YES;
  p.strokeEnabled = YES;
  p.fillEnabled = NO;
  p.strokeColorMode = 0;
  p.strokeWidth = 10.0f;
  p.endWidth = 10.0f;
  p.strokeR = 0.92f;
  p.strokeG = 0.16f;
  p.strokeB = 0.16f;
  p.lineCap = 1;  // round
  p.lineJoin = 1; // round
  p.startMarker = 0;
  p.endMarker = 0;
  p.drawOnStart = 0.0f;
  p.drawOnEnd = 1.0f;
  p.animationJSON =
      CanvasDrawOnEndAnim(KKIntervalCurveLinear, 1.0); // around the loop
  return p;
}

// A green checkmark from the Lucide "check" icon. SVG path `M20 6 9 17 l-5-5` =
// points (20,6) (9,17) (4,12) in its 24x24 viewBox. Mapped straight to object
// space (x/24, y/24 - path points are Y-DOWN like the SVG; centred by +0.0208) in
// SQUARE aspect; the insert hook compresses X by the live canvas aspect (the
// kCanvasPresetPayloadKindAspectX kind) so the 45-degree arms stay square on any
// canvas. Drawn short-arm -> vertex -> long-arm so the draw-on writes naturally.
static KKBezierPath *CanvasCheckmarkLayer(void) {
  KKBezierPath *p = [[KKBezierPath alloc] init];
  p.name = @"Checkmark";
  simd_float2 pts[3] = {simd_make_float2(4.0f / 24.0f, 12.0f / 24.0f + 0.0208f),
                        simd_make_float2(9.0f / 24.0f, 17.0f / 24.0f + 0.0208f),
                        simd_make_float2(20.0f / 24.0f, 6.0f / 24.0f + 0.0208f)};
  [p setLinearPositions:pts count:3 closed:NO];
  p.strokeEnabled = YES;
  p.fillEnabled = NO;
  p.strokeColorMode = 0;
  p.strokeWidth = 14.0f;
  p.endWidth = 14.0f;
  p.strokeR = 0.2f;
  p.strokeG = 0.78f;
  p.strokeB = 0.35f; // green
  p.lineCap = 1;     // round
  p.lineJoin = 1;    // round
  p.startMarker = 0;
  p.endMarker = 0;
  p.drawOnStart = 0.0f;
  p.drawOnEnd = 1.0f;
  p.animationJSON =
      CanvasDrawOnEndAnim(KKIntervalCurveEaseInOut, 1.0); // s-spline
  return p;
}

static KKPreset *CanvasPresetKind(NSString *identifier, NSString *name,
                                  NSString *kind,
                                  NSArray<KKBezierPath *> *layers) {
  KKPreset *pr = [[KKPreset alloc] init];
  pr.identifier = identifier;
  pr.name = name; // localization key for built-ins (falls back to itself)
  pr.payloadKind = kind;
  NSData *blob = [KKBezierPath blobFromPaths:layers];
  pr.payloadJSON = blob ? [blob base64EncodedStringWithOptions:0] : @"";
  pr.builtin = YES;
  return pr;
}

static KKPreset *CanvasPreset(NSString *identifier, NSString *name,
                              NSArray<KKBezierPath *> *layers) {
  return CanvasPresetKind(identifier, name, kCanvasPresetPayloadKind, layers);
}

NSArray<KKPreset *> *CanvasBuiltinPresets(void) {
  return @[
    CanvasPreset(@"canvas.arrow", @"Arrow", @[ CanvasArrowLayer() ]),
    CanvasPreset(@"canvas.highlight", @"Highlight", @[ CanvasHighlightLayer() ]),
    CanvasPreset(@"canvas.drawAround", @"Draw Around",
                 @[ CanvasDrawAroundLayer() ]),
    CanvasPresetKind(@"canvas.checkmark", @"Checkmark",
                     kCanvasPresetPayloadKindAspectX,
                     @[ CanvasCheckmarkLayer() ]),
  ];
}
