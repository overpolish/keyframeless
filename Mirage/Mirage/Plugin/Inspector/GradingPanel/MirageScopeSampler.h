/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <Metal/Metal.h>

#import "MirageOklab.h" // the shared sRGB / Oklab maths

NS_ASSUME_NONNULL_BEGIN

/// What the user says the patch they picked IS.
///
/// The sampler used to assume one answer - "this ought to be grey" - which is
/// the only reference that needs no knowledge of the subject. But most frames
/// have no grey in them and every frame has something whose colour the audience
/// already knows, so a declaration turns those into references too: the error
/// is then the distance from where that thing BELONGS rather than from neutral.
typedef NS_ENUM(NSInteger, MirageMemoryColor) {
  /// The patch should be neutral. The original behaviour, and the default.
  MirageMemoryColorNeutral = 0,
  MirageMemoryColorSkin,
  MirageMemoryColorFoliage,
  MirageMemoryColorSky,
};

/// Where a memory colour lives in the Oklab a/b plane: a hue wedge crossed with
/// a band of colourfulness.
typedef struct {
  double hueLoDegrees;
  double hueHiDegrees;
  double chromaLo;
  double chromaHi;
} MirageMemoryColorRegion;

/// The target region for a declaration, or a zero region for Neutral - whose
/// target is the origin and needs no span.
///
/// DERIVED, not guessed: representative sRGB patches were run through the same
/// Oklab transform this file measures with, and the region is the span they
/// landed in.
///
///   Foliage, hue 112-148, measured chroma 0.059-0.137:
///     sunlit grass #7C9A3E h=125.0 C=0.125   olive drab #6B8E23 h=126.3
///     C=0.137 spring leaf  #8FB04A h=124.8 C=0.135   lawn mid   #5A7D36
///     h=131.0 C=0.107 fern green   #4F7942 h=138.6 C=0.095   dark grass
///     #3A5F2B h=137.4 C=0.090 deep shade   #253F1C h=138.2 C=0.066   pine
///     #2E4E33 h=148.2 C=0.059 dry summer grass #9AA050 h=112.7 C=0.104
///
///   Sky, hue 226-260, measured chroma 0.030-0.166:
///     zenith deep #1E5FC0 h=259.0 C=0.166    zenith      #2E6FC8 h=257.3
///     C=0.153 upper sky   #3A7BD5 h=257.2 C=0.153    mid sky     #5A99E0
///     h=252.7 C=0.125 lower sky   #7FB4E8 h=248.7 C=0.094    horizon pale
///     #B0D4F1 h=242.7 C=0.056 palest horizon #CBDDEE h=246.6 C=0.030 sky blue
///     #87CEEB h=225.8 C=0.082
///
/// Each band's TOP is then extended by about a quarter, and its centre left
/// where the measurements put it. Viewers reliably prefer memory colours a
/// little more colourful than accurate, so a slightly punchy sky is not an
/// error to report - while a washed-out one still is, which is why the bottom
/// is not moved with it.
static inline MirageMemoryColorRegion
MirageMemoryColorRegionFor(MirageMemoryColor kind) {
  switch (kind) {
  case MirageMemoryColorSkin:
    return (MirageMemoryColorRegion){46.0, 54.0, 0.050, 0.114};
  case MirageMemoryColorFoliage:
    return (MirageMemoryColorRegion){112.0, 148.0, 0.059, 0.171};
  case MirageMemoryColorSky:
    return (MirageMemoryColorRegion){226.0, 260.0, 0.030, 0.208};
  case MirageMemoryColorNeutral:
    break;
  }
  return (MirageMemoryColorRegion){0.0, 0.0, 0.0, 0.0};
}

/// The bearing the region is centred on, in degrees. The two words the readout
/// has for a declaration are the two ways off this line, so the sentence needs
/// it.
static inline double MirageMemoryColorMidHue(MirageMemoryColorRegion region) {
  return (region.hueLoDegrees + region.hueHiDegrees) * 0.5;
}

/// The point of `region` nearest to the patch at `a`,`b`. Inside the region
/// that is the patch itself, so a correct colour reports no error at all.
///
/// Clamped in POLAR terms - hue into the wedge, chroma into the band - rather
/// than by true Euclidean distance to the sector. It keeps the two questions
/// separate: how far round the wheel the colour is wrong, and how colourful it
/// is, are what the wedge is drawn to show, and mixing them would put the
/// nearest point at a hue the region does not actually contain.
static inline void MirageMemoryColorNearest(MirageMemoryColorRegion region,
                                            double a, double b, double *outA,
                                            double *outB) {
  double chroma = hypot(a, b);
  double hue = atan2(b, a) * 180.0 / M_PI;
  if (hue < 0.0)
    hue += 360.0;
  double clampedChroma = fmin(fmax(chroma, region.chromaLo), region.chromaHi);
  // Hue is circular, so "outside the wedge" is decided by the shorter way round
  // to each edge - a patch at 5 degrees is nearer a wedge ending at 355 than a
  // plain comparison would ever say.
  double toLo = fmod(region.hueLoDegrees - hue + 540.0, 360.0) - 180.0;
  double toHi = fmod(region.hueHiDegrees - hue + 540.0, 360.0) - 180.0;
  double clampedHue = hue;
  if (toLo > 0.0 || toHi < 0.0)
    clampedHue =
        fabs(toLo) <= fabs(toHi) ? region.hueLoDegrees : region.hueHiDegrees;
  double radians = clampedHue * M_PI / 180.0;
  if (outA)
    *outA = clampedChroma * cos(radians);
  if (outB)
    *outB = clampedChroma * sin(radians);
}

/// Middle grey, the origin the tone bins are measured in stops around.
static const double kMiddleGrey = 0.18;
/// Vectorscope grid. Fine enough in angle that a hue cluster has shape, coarse
/// in radius because what matters is how far off neutral the mass sits.
static const NSUInteger kChromaAngleBins = 72;
static const NSUInteger kChromaRadiusBins = 12;
/// Oklab chroma at the rim.
///
/// Real footage sits around 0.02-0.12 here, so this is scaled to the range
/// images actually occupy. It was 0.32 - near-monochromatic-laser territory -
/// which crushed every frame into the innermost bands where near-neutral pixels
/// carry essentially arbitrary hue, and the scope read as a faint even donut
/// with the cast invisible.
static const double kChromaFullScale = 0.13;
/// Below this radius a pixel is neutral enough that its hue is noise. Excluded
/// from the cloud so the centre stays legible, but still counted in the
/// centroid, which is a question about the whole frame.
static const double kChromaNeutralFloor = 0.10;

static inline double MirageSrgbToLinear(double c) {
  return MirageSRGBDecode(c);
}

/// Linear Rec.709 to Oklab's a/b chroma plane, dropping the lightness the scope
/// has no axis for.
///
/// Oklab because its hue and chroma are near enough orthogonal that a cluster's
/// angle means one hue and its distance means one colourfulness. In raw RGB the
/// same cloud smears across the circle as brightness changes, which is exactly
/// the exposure dependence Resolve's chroma-based scope exists to avoid.
///
/// The SIGNED transform, because this measures whatever footage is on the
/// timeline rather than a colour known to be inside the display gamut.
static inline void MirageLinearToOklabAB(double r, double g, double b,
                                         double *outA, double *outB) {
  double L = 0.0;
  MirageLinearToOklabSigned(r, g, b, &L, outA, outB);
}

/// How far a visible-region rect may differ from the whole frame and still be
/// treated as the whole frame. An unzoomed mini viewer computes its rect
/// through a chain of float divisions, so an exact comparison would flip the
/// scope into its scoped drawing for a user who never touched the zoom.
static const double kMirageFullFrameTolerance = 0.002;

/// `rect` clamped into the frame, with anything unusable answering "the WHOLE
/// frame".
///
/// The one funnel every region question goes through, because the alternative
/// is a HALF-scoped state: a rect that is degenerate, inverted, off the frame
/// or not a number is not a smaller region to measure, it is an absence of
/// information, and the honest reading of no information is the reading the
/// scope gives when nobody has zoomed. The first tick after a popover opens is
/// exactly that case - the mini viewer has no drawable and no laid-out bounds
/// yet.
static inline NSRect MirageScopeSanitisedVisibleRect(NSRect rect) {
  NSRect full = NSMakeRect(0.0, 0.0, 1.0, 1.0);
  if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) ||
      !isfinite(rect.size.width) || !isfinite(rect.size.height))
    return full;
  if (rect.size.width <= 0.0 || rect.size.height <= 0.0)
    return full;
  double minX = fmax(0.0, NSMinX(rect)), minY = fmax(0.0, NSMinY(rect));
  double maxX = fmin(1.0, NSMaxX(rect)), maxY = fmin(1.0, NSMaxY(rect));
  if (maxX <= minX || maxY <= minY)
    return full; // entirely outside the frame: nothing of it is on screen
  return NSMakeRect(minX, minY, maxX - minX, maxY - minY);
}

/// YES when `rect` covers the frame, so the scope has one region rather than
/// two and every consumer draws exactly what it drew before regions existed.
static inline BOOL MirageScopeRectIsFullFrame(NSRect rect) {
  NSRect r = MirageScopeSanitisedVisibleRect(rect);
  return NSMinX(r) <= kMirageFullFrameTolerance &&
         NSMinY(r) <= kMirageFullFrameTolerance &&
         NSMaxX(r) >= 1.0 - kMirageFullFrameTolerance &&
         NSMaxY(r) >= 1.0 - kMirageFullFrameTolerance;
}

/// The part of the frame on screen, from where the preview DRAWS the image
/// (`content`, which already honours zoom and pan) and the room it has to draw
/// in
/// (`visibleBounds`).
///
/// Pure, and taking both rects rather than a view, so the geometry can be
/// checked without a laid-out window - which is the state that has to be right
/// and is the hardest one to reach by hand.
static inline NSRect MirageScopeVisibleUVRect(CGRect content,
                                              CGRect visibleBounds) {
  NSRect full = NSMakeRect(0.0, 0.0, 1.0, 1.0);
  if (!isfinite(content.origin.x) || !isfinite(content.origin.y) ||
      !isfinite(content.size.width) || !isfinite(content.size.height) ||
      !isfinite(visibleBounds.origin.x) || !isfinite(visibleBounds.origin.y) ||
      !isfinite(visibleBounds.size.width) ||
      !isfinite(visibleBounds.size.height))
    return full;
  // A preview with no drawable yet, or a view that has not been laid out.
  // Neither is a zoom, and treating either as one is what a first tick would do
  // wrong.
  if (content.size.width <= 0.0 || content.size.height <= 0.0)
    return full;
  if (visibleBounds.size.width <= 0.0 || visibleBounds.size.height <= 0.0)
    return full;
  CGRect visible = CGRectIntersection(content, visibleBounds);
  if (CGRectIsNull(visible) || CGRectIsEmpty(visible))
    return full;
  return MirageScopeSanitisedVisibleRect(NSMakeRect(
      (CGRectGetMinX(visible) - CGRectGetMinX(content)) / content.size.width,
      (CGRectGetMinY(visible) - CGRectGetMinY(content)) / content.size.height,
      visible.size.width / content.size.width,
      visible.size.height / content.size.height));
}

static inline BOOL MirageScopeUVInRect(NSPoint uv, NSRect rect) {
  return uv.x >= NSMinX(rect) && uv.x <= NSMaxX(rect) && uv.y >= NSMinY(rect) &&
         uv.y <= NSMaxY(rect);
}

/// Both binnings of one frame, filled in a SINGLE pass over the pixels.
///
/// The visible-region set is not a second measurement: a pixel inside the rect
/// increments its bin in BOTH sets as it is read, so a zoomed scope costs the
/// same one texture readback an unzoomed one does. Reading the texture twice -
/// once windowed - was the obvious shape and doubles the per-frame blit the
/// panel is throttled to in the first place.
///
/// The visible pointers are NULL when the rect is the whole frame, which is
/// what collapses the two sets back into one.
typedef struct {
  double *_Nullable toneBins;
  double *_Nullable toneVisibleBins;
  NSUInteger binCount;
  double minStop;
  double maxStop;
  double *_Nullable chromaBins;
  double *_Nullable chromaVisibleBins;
  NSUInteger angleBins;
  NSUInteger radiusBins;
  /// The visible region in 0..1 frame coordinates, bottom-left origin.
  NSRect visibleRect;
  NSUInteger counted;
  NSUInteger over;
  NSUInteger visibleCounted;
} MirageScopeAccumulator;

/// The ONE place a bin is ever incremented, for either set.
///
/// A guard per call site is a guard that can be forgotten at the next call
/// site. Both sets go through here instead, so "the visible set may be absent"
/// is stated once, in the only code that can act on it. `full` and `visible`
/// are `_Nullable` on purpose: "the set may be absent" is a fact about this
/// API, so it is stated in the type rather than left to a comment a caller can
/// pass NULL past without being told.
static inline void MirageScopeBumpBin(double *_Nullable full,
                                      double *_Nullable visible,
                                      NSUInteger index, BOOL inside) {
  if (full)
    full[index] += 1.0;
  if (inside && visible)
    visible[index] += 1.0;
}

/// The ONE place a bin array is ever read back out, answering nil for an array
/// that does not exist.
///
/// It replaces hand-written boxing loops, and the reason it has to is a crash:
/// `[maybeNilArray addObject:@(bins[i])]` looks safe because the receiver is
/// nil, but C evaluates the ARGUMENT first, so `bins[i]` had already been read
/// through a NULL pointer before the message was ever sent to nothing. A nil
/// receiver cannot protect a dereference that happens before it.
static inline NSArray<NSNumber *> *_Nullable MirageScopeBoxBins(
    const double *_Nullable bins, NSUInteger count) {
  if (!bins || count == 0)
    return nil;
  NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger i = 0; i < count; i++)
    [out addObject:@(bins[i])];
  return out;
}

/// Bin one LIGHT-LINEAR pixel at frame position `u`,`v` into both sets.
///
/// Split out of the sampler's loop so the split can be checked without a GPU:
/// it is the one piece of this file whose correctness is a question about
/// arithmetic rather than about Metal.
static inline void MirageScopeAccumulatePixel(MirageScopeAccumulator *acc,
                                              double r, double g, double b,
                                              double u, double v) {
  if (!acc || !acc->toneBins || !acc->chromaBins || acc->binCount == 0)
    return;
  BOOL inside = acc->toneVisibleBins || acc->chromaVisibleBins
                    ? MirageScopeUVInRect(NSMakePoint(u, v), acc->visibleRect)
                    : NO;
  acc->counted++;
  if (inside)
    acc->visibleCounted++;

  double ca = 0.0, cb = 0.0;
  MirageLinearToOklabAB(r, g, b, &ca, &cb);
  double radius = hypot(ca, cb) / kChromaFullScale;
  if (radius > 1.0)
    radius = 1.0;
  if (radius >= kChromaNeutralFloor) {
    double angle = atan2(cb, ca);
    if (angle < 0.0)
      angle += 2.0 * M_PI;
    NSUInteger ai = (NSUInteger)(angle / (2.0 * M_PI) * (double)acc->angleBins);
    NSUInteger ri = (NSUInteger)(radius * (double)(acc->radiusBins - 1) + 0.5);
    NSUInteger idx = MIN(ai, acc->angleBins - 1) * acc->radiusBins +
                     MIN(ri, acc->radiusBins - 1);
    MirageScopeBumpBin(acc->chromaBins, acc->chromaVisibleBins, idx, inside);
  }

  // Rec.709 luma weights, matching the space the surface declares.
  double lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;
  NSUInteger tone;
  if (lum <= 0.0) {
    tone = 0; // true black has no logarithm, and belongs at the floor
  } else {
    double stop = log2(lum / kMiddleGrey);
    if (stop >= acc->maxStop) {
      acc->over++;
      tone = acc->binCount - 1;
    } else if (stop < acc->minStop) {
      tone = 0;
    } else {
      tone =
          (NSUInteger)((stop - acc->minStop) / (acc->maxStop - acc->minStop) *
                       (double)acc->binCount);
      tone = MIN(tone, acc->binCount - 1);
    }
  }
  MirageScopeBumpBin(acc->toneBins, acc->toneVisibleBins, tone, inside);
}

/// One measurement of a rendered frame, for the Grading panel's surfaces.
@interface MirageScopeReading : NSObject
/// Luminance bin counts, low stop to high.
@property(nonatomic, copy) NSArray<NSNumber *> *toneBins;
/// Fraction of sampled pixels above the plotted range, 0..1.
@property(nonatomic) double overRange;
/// How many pixels the reading is based on, 0 when nothing could be measured.
@property(nonatomic) NSUInteger sampleCount;

/// The frame's chroma as a POLAR density grid - a vectorscope. Counts indexed
/// `angle * radiusBins + radius`, angle running anticlockwise from the +a axis.
/// This is the scope that belongs inside a colour wheel: it puts every pixel in
/// the same space as the puck, so a cast reads as a lopsided cloud you pull
/// against, rather than as a number you have to interpret.
@property(nonatomic, copy) NSArray<NSNumber *> *chromaBins;
@property(nonatomic) NSUInteger chromaAngleBins;
@property(nonatomic) NSUInteger chromaRadiusBins;

/// The same two grids binned from the pixels inside `visibleUVRect` alone, or
/// nil when the mini viewer is showing the whole frame. Same shape as the pair
/// above, so a consumer draws one on top of the other without re-deriving
/// anything.
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *chromaBinsVisible;
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *toneBinsVisible;

/// YES when the reading carries a visible-region set. NO restores every
/// consumer to exactly the single-region behaviour, which is what an unzoomed
/// preview has to keep getting.
@property(nonatomic) BOOL regionScoped;

/// How far the USER-PICKED reference patch is from where it belongs, in the
/// same -1..1 space as the puck. Under Neutral - the default - "where it
/// belongs" is the origin, so this is simply the patch's own tint.
///
/// Picked rather than estimated. Which pixels "should" be grey is not
/// recoverable from pixel statistics: a mean cancels when a frame holds
/// opposing colours, a near-neutral threshold gets recruited by whatever the
/// cast pushes toward grey, and a median splits the difference between two
/// colour clusters and reads neutral when neither is. All three were measured
/// on real footage and all three failed. The information is in the user's head,
/// so the user supplies it.
@property(nonatomic) NSPoint chromaCast;

/// NO when no reference has been picked, or the pick lies outside the frame.
/// The marker is then hidden rather than parked at the centre, which would read
/// as "balanced".
@property(nonatomic) BOOL castAvailable;

/// The colour of the patch under `probeUV` as three 0..1 components, or nil
/// when nothing was probed. DISPLAY-ENCODED, unlike the cast above: the cast is
/// a chromaticity measured in Oklab and needs light-linear values, while this
/// is written straight into an author's control and drawn as a swatch, so it
/// has to be the colour that is on the screen. A `#color` default is a hex
/// swatch, which is the same encoding.
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *probedRGB;
@end

/// Measures the mini viewer's rendered output for the Grading surfaces.
///
/// It reads `KKMiniViewerView.processedTexture` - the effect's OWN output, the
/// same pixels the preview is showing - so the surfaces reflect the grade
/// rather than the untouched source.
///
/// Two honest limitations, both worth knowing before trusting a number:
/// the texture is BGRA8 display-encoded, so values are decoded back to linear
/// here and anything beyond 0..1 was already clipped upstream; and it carries
/// the trial watermark when one is being drawn, which contributes its own
/// pixels.
@interface MirageScopeSampler : NSObject

/// Measure `texture` on `device`, binning luminance into `binCount` bins
/// spanning `minStop`..`maxStop` around middle grey. Returns nil when the
/// texture cannot be read. Synchronous and main-thread: the preview textures
/// are small, and the caller throttles. The reference patch to measure, in 0..1
/// frame coordinates with a bottom-left origin, or a negative point for none.
/// Held as a POSITION, not a colour, so the patch is re-measured every frame:
/// correct the grade and the picked pixel's tint visibly walks toward neutral,
/// which is the whole feedback loop.
@property(nonatomic) NSPoint pickUV;

/// What the picked patch was declared to be. Neutral unless the user chose
/// otherwise, and it decides what `chromaCast` is measured AGAINST - nothing
/// else about the reading changes.
@property(nonatomic) MirageMemoryColor pickDeclaration;

/// Where the `pick=` eyedropper last clicked, in the same 0..1 bottom-left
/// frame coordinates, or a negative point for none. Separate from `pickUV`
/// because the two picks answer different questions and must not evict each
/// other: setting a colour target is not a statement about what should be grey.
@property(nonatomic) NSPoint probeUV;

/// The part of the frame the mini viewer is actually showing, in the same 0..1
/// bottom-left coordinates, defaulting to the whole frame.
///
/// The scope answers a question about what the user is looking at, so a zoomed
/// preview has to narrow it: a cast in a face fills the frame once you have
/// zoomed into the face, and a scope still averaging the sky behind it is
/// measuring a picture nobody is grading. Everything the reading carries
/// switches together - the clouds, the cast and therefore the readout - because
/// two regions reported on one circle is worse than either alone.
@property(nonatomic) NSRect visibleUVRect;

/// The DISPLAY-ENCODED colour of the patch at `uv` in `texture`, or nil when
/// the point is outside the frame or the format cannot be read. Same patch
/// average and same encoding as `probedRGB`, so a caller can hand the result
/// straight to the eyedropper's write path.
///
/// Separate from -readTexture: because it is asked of a DIFFERENT texture - the
/// clip's own untouched source - and answers a one-off click rather than a
/// per-frame measurement.
- (nullable NSArray<NSNumber *> *)probeTexture:(id<MTLTexture>)texture
                                        device:(id<MTLDevice>)device
                                          atUV:(NSPoint)uv;

- (nullable MirageScopeReading *)readTexture:(id<MTLTexture>)texture
                                      device:(id<MTLDevice>)device
                                    binCount:(NSUInteger)binCount
                                     minStop:(double)minStop
                                     maxStop:(double)maxStop;

/// The same measurement, without occupying the main thread for it.
///
/// The synchronous form waits on the blit and then walks tens of thousands of
/// pixels, all of it on the thread the popover and its preview are drawn from -
/// and it is driven by the preview's own frame callback, so a measured panel
/// spends a slice of every frame there. This commits the blit without waiting,
/// copies out on the completion handler and does the binning on a private
/// serial queue. `completion` is always called on the MAIN thread, with nil for
/// a texture that could not be read or a measurement dropped because one was
/// already in flight.
///
/// Call it on the main thread: the reading's inputs (`pickUV`, `probeUV`, the
/// declaration, the visible rect) are snapshotted at call time, so a property
/// changed while a measurement is out affects the next one rather than
/// retroactively describing this one.
- (void)readTextureAsync:(id<MTLTexture>)texture
                  device:(id<MTLDevice>)device
                binCount:(NSUInteger)binCount
                 minStop:(double)minStop
                 maxStop:(double)maxStop
              completion:(void (^)(MirageScopeReading *_Nullable))completion;

@end

NS_ASSUME_NONNULL_END
