/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageSurfaceCircleView_Internal.h"

@implementation MirageSurfacePuck

- (instancetype)init {
  if ((self = [super init])) {
    _name = @"";
    _position = NSZeroPoint;
  }
  return self;
}

@end

@implementation MirageSurfaceCircleView

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _chromaBins = @[];
    _toneBins = @[];
    _pucks = @[ [MirageSurfacePuck new] ];
    _xAxisLive = YES;
    _yAxisLive = YES;
  }
  return self;
}

- (BOOL)isOpaque {
  return NO;
}

// The panel this lives in never becomes key, so every click in it is a "first
// mouse". Without this the first press of each gesture would be spent asking for
// focus the window will not take, and the puck would need clicking twice.
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

// While dragging, the dragged puck follows the CURSOR and ignores derived updates.
//
// Deriving is a round trip - write the controls, re-apply the timeline, re-render,
// re-measure, re-derive - so a puck waiting for it always trails the pointer and
// reads as stutter. Direct manipulation has to track the hand. The derived
// position takes over the moment the drag ends, which is also when it earns its
// keep: if a control clamped, the puck visibly settles back to what the values
// actually support.
//
// The OTHER pucks still take their derived positions mid-drag: one gesture can move
// a control that another puck also reads, and that puck should show it.
- (void)setPucks:(NSArray<MirageSurfacePuck *> *)pucks {
  if (!pucks.count)
    pucks = @[ [MirageSurfacePuck new] ];
  if (_dragging && _dragIndex < _pucks.count && _dragIndex < pucks.count)
    pucks[_dragIndex].position = _pucks[_dragIndex].position;
  _pucks = [pucks copy];
  if (_activePuck >= _pucks.count)
    _activePuck = 0;
  [self setNeedsDisplay:YES];
}

- (void)setRing:(MirageColorSurfaceRing)ring {
  if (ring != _ring)
    _ringColors = nil;
  _ring = ring;
  [self setNeedsDisplay:YES];
}

- (void)setPolarAxes:(BOOL)polarAxes {
  _polarAxes = polarAxes;
  [self setNeedsDisplay:YES];
}

- (void)setChromaCast:(NSPoint)chromaCast {
  _chromaCast = chromaCast;
  [self setNeedsDisplay:YES];
}

- (void)setCastAvailable:(BOOL)castAvailable {
  _castAvailable = castAvailable;
  [self setNeedsDisplay:YES];
}

/// Peak EXCLUDING the innermost ring: near-neutral pixels dominate almost every
/// frame, and normalising to them would flatten the cast we are here to show.
static double MirageChromaPeak(NSArray<NSNumber *> *bins, NSUInteger angleBins,
                               NSUInteger radiusBins) {
  double peak = 0.0;
  for (NSUInteger a = 0; a < angleBins; a++)
    for (NSUInteger r = 1; r < radiusBins; r++)
      peak = MAX(peak, bins[a * radiusBins + r].doubleValue);
  return peak;
}

- (void)applyChromaCloud:(NSArray<NSNumber *> *)bins
                  region:(NSArray<NSNumber *> *)regionBins
               angleBins:(NSUInteger)angleBins
              radiusBins:(NSUInteger)radiusBins {
  if (bins.count != angleBins * radiusBins || !angleBins || !radiusBins) {
    _chromaBins = @[];
    _chromaPeak = 0.0;
    _chromaRegionBins = nil;
    _chromaRegionPeak = 0.0;
  } else {
    _chromaBins = [bins copy];
    if (angleBins != _chromaAngleBins || radiusBins != _chromaRadiusBins)
      _cloudColors = nil;
    _chromaAngleBins = angleBins;
    _chromaRadiusBins = radiusBins;
    _chromaPeak = MirageChromaPeak(_chromaBins, angleBins, radiusBins);
    BOOL sameShape = regionBins.count == angleBins * radiusBins;
    _chromaRegionBins = sameShape ? [regionBins copy] : nil;
    // Each layer is normalised to its OWN peak. Normalising the region to the
    // whole frame's would fade a small patch to nothing exactly when it is the
    // thing being read: alpha here means density WITHIN a distribution, and the
    // two layers are two distributions, told apart by their weight rather than by
    // a shared scale.
    _chromaRegionPeak =
        sameShape ? MirageChromaPeak(_chromaRegionBins, angleBins, radiusBins)
                  : 0.0;
  }
  [self setNeedsDisplay:YES];
}

static double MirageTonePeak(NSArray<NSNumber *> *bins) {
  double peak = 0.0;
  for (NSNumber *n in bins)
    peak = MAX(peak, n.doubleValue);
  return peak;
}

- (void)applyToneCloud:(NSArray<NSNumber *> *)bins
                region:(NSArray<NSNumber *> *)regionBins {
  _toneBins = [bins copy] ?: @[];
  _tonePeak = MirageTonePeak(_toneBins);
  BOOL sameShape = regionBins.count && regionBins.count == _toneBins.count;
  _toneRegionBins = sameShape ? [regionBins copy] : nil;
  _toneRegionPeak = sameShape ? MirageTonePeak(_toneRegionBins) : 0.0;
  [self setNeedsDisplay:YES];
}

/// The one place the axis labels' typography lives. Sizing and drawing both come
/// through here: when the room reserved for a label was a constant and the drawing
/// used a font, the two drifted and "Punchy" rendered as "Punc".
///
/// Truncating rather than wrapping, so a label that still does not fit after the
/// circle has been clamped loses its tail to an ellipsis instead of running off the
/// edge or turning into two lines beside a circle sized for one.
NSDictionary *MirageAxisLabelAttributes(void) {
  NSMutableParagraphStyle *style =
      [NSMutableParagraphStyle.defaultParagraphStyle mutableCopy];
  style.lineBreakMode = NSLineBreakByTruncatingTail;
  return @{
    NSFontAttributeName : [NSFont systemFontOfSize:10.0],
    NSForegroundColorAttributeName : NSColor.secondaryLabelColor,
    NSParagraphStyleAttributeName : style
  };
}

/// The room the labels that will ACTUALLY be drawn need outside the circle, per
/// side. Measured, not assumed: a shader declaring no `xaxis=`/`yaxis=` reserves
/// nothing, and a shader declaring them reserves what its own strings measure at
/// the drawing font.
- (NSEdgeInsets)_axisLabelInsets {
  NSEdgeInsets insets = NSEdgeInsetsZero;
  NSDictionary *attrs = MirageAxisLabelAttributes();
  if (self.xAxisLabels.count == 2) {
    // The circle stays CENTRED, so both sides have to be as wide as the wider
    // label - reserving each side its own width would push the circle off centre.
    CGFloat width = MAX([self.xAxisLabels[0] sizeWithAttributes:attrs].width,
                        [self.xAxisLabels[1] sizeWithAttributes:attrs].width);
    insets.left = insets.right = width + kLabelGap;
  }
  if (self.yAxisLabels.count == 2) {
    CGFloat height = MAX([self.yAxisLabels[0] sizeWithAttributes:attrs].height,
                         [self.yAxisLabels[1] sizeWithAttributes:attrs].height);
    insets.top = insets.bottom = height + kLabelGap;
  }
  return insets;
}

- (NSRect)_circleRect {
  NSRect b = self.bounds;
  NSEdgeInsets insets = [self _axisLabelInsets];
  // MAX, not a sum: a labelled side's room is already larger than the margin and
  // adding one to the other would shrink the labelled wheels for nothing, while an
  // unlabelled side still gets its margin instead of the zero the labels left.
  CGFloat left = MAX(insets.left, kCircleMargin);
  CGFloat right = MAX(insets.right, kCircleMargin);
  CGFloat top = MAX(insets.top, kCircleMargin);
  CGFloat bottom = MAX(insets.bottom, kCircleMargin);
  CGFloat side = MIN(b.size.width - left - right,
                     b.size.height - top - bottom);
  // The floor cannot exceed the well itself, or a genuinely tiny view would get a
  // circle drawn outside its own bounds.
  side = MAX(side, MIN(kMinCircleDiameter, MIN(b.size.width, b.size.height)));
  side = MAX(side, 10.0);
  return NSMakeRect(NSMidX(b) - side / 2.0, NSMidY(b) - side / 2.0, side, side);
}

/// A point in the view mapped to -1..1 per axis, clamped INSIDE the unit disc so
/// the puck can never be dragged out past the ring it is bounded by.
- (NSPoint)_normalisedFromViewPoint:(NSPoint)p {
  NSRect circle = [self _circleRect];
  CGFloat travel = circle.size.width / 2.0 - kRingThickness - kPuckRadius;
  if (travel <= 0.0)
    return NSZeroPoint;
  double nx = (p.x - NSMidX(circle)) / travel;
  double ny = (p.y - NSMidY(circle)) / travel;
  double len = hypot(nx, ny);
  if (len > 1.0) {
    nx /= len;
    ny /= len;
  }
  return NSMakePoint(nx, ny);
}

/// Where a puck actually SITS, in -1..1. Hit-testing and drawing both go through
/// this, or a tracked handle would be grabbed from wherever the derive left it
/// rather than from the circle it is visibly riding.
///
/// Clamped to the DISC, not per axis. Clamping x and y separately let a derived
/// position of (1,1) sit at radius 1.41, i.e. in the corner outside the ring -
/// which happens as soon as a control is edited past full deflection by hand.
- (NSPoint)_drawnPositionForPuck:(MirageSurfacePuck *)puck
                          pinned:(BOOL *)outPinned {
  double px = self.xAxisLive ? puck.position.x : 0.0;
  double py = self.yAxisLive ? puck.position.y : 0.0;
  double len = hypot(px, py);
  BOOL pinned = len > 1.0001;
  if (puck.trackRadius > 0.0) {
    // A tracked puck's distance carries no meaning, so it is placed at the track
    // regardless of what the derive returned - and it can never be "past full
    // deflection", because there is no radial control to run out of room.
    pinned = NO;
    double bearing = len > 1e-9 ? atan2(py, px) : 0.0;
    px = cos(bearing) * puck.trackRadius;
    py = sin(bearing) * puck.trackRadius;
  } else if (pinned) {
    px /= len;
    py /= len;
  }
  if (outPinned)
    *outPinned = pinned;
  return NSMakePoint((CGFloat)px, (CGFloat)py);
}

- (void)dealloc {
  [self _removeDragMonitors];
}

@end
