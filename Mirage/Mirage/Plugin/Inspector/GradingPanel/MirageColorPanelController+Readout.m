/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageColorPanelController.h"

#import <KeyframelessKit/KKFloatingPanel.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMiniViewerRenderer.h>
#import <KeyframelessKit/KKPaddedScrollView.h>
#import <KeyframelessKit/KKPopoverKeepAlive.h>
#import <KeyframelessKit/KKTimingEvaluation.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

#import "MirageColorPanelController_Internal.h"
#import "MirageColorSurfaceProps.h"
#import "MirageLocalized.h"
#import "MirageScopeSampler.h"
#import "MirageSurfaceCircleView.h"
#import "MirageSurfaceResponse.h"
#import "Plugin_Private.h" // +shaderSourceFromTimeline:

/// The ring's name for a readout heading, used only where two rings would
/// otherwise be indistinguishable.
static NSString *MirageRingLabel(MirageColorSurfaceRing ring) {
  switch (ring) {
  case MirageColorSurfaceRingHue:
    return RLoc(@"Hue",
                @"Color panel readout heading naming the hue ring, when "
                @"a shader declares both rings.");
  case MirageColorSurfaceRingLight:
    return RLoc(@"Light", @"Color panel readout heading naming the light ring, "
                          @"when a shader declares both rings.");
  case MirageColorSurfaceRingPlain:
    break;
  }
  return RLoc(@"Surface", @"Color panel readout heading naming an unpainted "
                          @"grading circle.");
}

/// Error size, in the cast's own -1..1 space, at which the readout stops saying
/// "slightly" and says "clearly". 0.35 of full scale is about 0.028 in Oklab
/// a/b - the point where a cast stops being something you have to look for.
static const double kDeclarationClearError = 0.35;

/// What the readout says about a declared patch, in words anybody can act on.
///
/// Deliberately not a number and never an angle: the reading exists so that
/// someone who does not know what a hue is can tell that the faces are wrong
/// and which way. Each declaration therefore gets the two words that describe
/// the two ways off its own line, and one of two strengths.
///
/// The word comes from the side of the region's centre line the error falls on.
/// An error that is purely a matter of colourfulness leans neither way and
/// takes whichever word its residual suggests, which is the honest limit of a
/// deliberately hue-only vocabulary.
NSString *MirageDeclarationSentence(MirageMemoryColor kind, NSPoint cast) {
  double size = hypot(cast.x, cast.y);
  MirageMemoryColorRegion region = MirageMemoryColorRegionFor(kind);
  double mid = MirageMemoryColorMidHue(region) * M_PI / 180.0;
  // The tangent at the centre of the wedge, pointing the way the hue increases.
  BOOL forward = (-sin(mid) * cast.x + cos(mid) * cast.y) >= 0.0;
  BOOL clearly = size >= kDeclarationClearError;
  switch (kind) {
  case MirageMemoryColorSkin:
    if (size < 1e-9)
      return RLoc(
          @"Skin looks right.",
          @"Color panel readout: the sampled skin needs no correction.");
    if (forward)
      return clearly
                 ? RLoc(@"Skin is clearly too yellow.",
                        @"Color panel readout: the sampled skin is well too "
                        @"yellow.")
                 : RLoc(@"Skin is slightly too yellow.",
                        @"Color panel readout: the sampled skin is a little "
                        @"too yellow.");
    return clearly
               ? RLoc(@"Skin is clearly too pink.",
                      @"Color panel readout: the sampled skin is well too "
                      @"pink.")
               : RLoc(@"Skin is slightly too pink.",
                      @"Color panel readout: the sampled skin is a little too "
                      @"pink.");
  case MirageMemoryColorFoliage:
    if (size < 1e-9)
      return RLoc(@"Foliage looks right.",
                  @"Color panel readout: the sampled grass or leaves need no "
                  @"correction.");
    if (forward)
      return clearly
                 ? RLoc(@"Foliage is clearly too blue.",
                        @"Color panel readout: the sampled grass or leaves are "
                        @"well too blue.")
                 : RLoc(@"Foliage is slightly too blue.",
                        @"Color panel readout: the sampled grass or leaves are "
                        @"a little too blue.");
    return clearly
               ? RLoc(@"Foliage is clearly too yellow.",
                      @"Color panel readout: the sampled grass or leaves are "
                      @"well too yellow.")
               : RLoc(@"Foliage is slightly too yellow.",
                      @"Color panel readout: the sampled grass or leaves are a "
                      @"little too yellow.");
  case MirageMemoryColorSky:
    if (size < 1e-9)
      return RLoc(@"Sky looks right.",
                  @"Color panel readout: the sampled sky needs no correction.");
    if (forward)
      return clearly
                 ? RLoc(@"Sky is clearly too purple.",
                        @"Color panel readout: the sampled sky is well too "
                        @"purple.")
                 : RLoc(@"Sky is slightly too purple.",
                        @"Color panel readout: the sampled sky is a little too "
                        @"purple.");
    return clearly
               ? RLoc(@"Sky is clearly too green.",
                      @"Color panel readout: the sampled sky is well too "
                      @"green.")
               : RLoc(@"Sky is slightly too green.",
                      @"Color panel readout: the sampled sky is a little too "
                      @"green.");
  case MirageMemoryColorNeutral:
    break;
  }
  return nil;
}

/// What the readout says with nothing measured and no gesture made.
NSString *MirageReadoutPlaceholder(void) {
  return RLoc(@"The controls this puck drives are listed here.",
              @"Placeholder in the Color panel's readout, shown "
              @"when no puck controls are listed.");
}

/// A number in the units of the control it belongs to. Precision follows the
/// control's declared range: `%.0f` is right for a 0-150 percent and useless
/// for a -1..1 float, where every row would read `0 → 0`.
static NSString *MirageReadoutNumber(double value, MirageSurfaceResponse r) {
  double span = r.hasLimits ? fabs(r.maxValue - r.minValue) : 0.0;
  if (span >= 50.0 || span == 0.0)
    return [NSString stringWithFormat:@"%.0f", value];
  return [NSString stringWithFormat:span >= 5.0 ? @"%.1f" : @"%.2f", value];
}

/// One line of the readout: the control's name on the left, its current value
/// on the right, so the value column lines up down the list instead of ragging
/// with the length of each name. A row with no value is a heading - the puck
/// the list belongs to.
@interface _MirageReadoutRow : NSView
- (void)setName:(NSString *)name value:(nullable NSString *)value;
@end

@implementation _MirageReadoutRow {
  NSTextField *_name;
  NSTextField *_value;
}

- (instancetype)init {
  if ((self = [super initWithFrame:NSZeroRect])) {
    _name = [NSTextField labelWithString:@""];
    _name.font = [NSFont systemFontOfSize:kReadoutFontSize];
    _name.textColor = NSColor.secondaryLabelColor;
    _name.lineBreakMode = NSLineBreakByTruncatingTail;
    _name.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_name];

    _value = [NSTextField labelWithString:@""];
    // Monospaced digits so the numbers do not jitter sideways as they change
    // under a live drag, which is the whole time this readout is being read.
    _value.font = [NSFont monospacedDigitSystemFontOfSize:kReadoutFontSize
                                                   weight:NSFontWeightRegular];
    _value.alignment = NSTextAlignmentRight;
    _value.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_value];

    [NSLayoutConstraint activateConstraints:@[
      [_name.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_name.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_name.topAnchor constraintEqualToAnchor:self.topAnchor],
      [_name.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      [_value.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [_value.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_name.trailingAnchor
          constraintLessThanOrEqualToAnchor:_value.leadingAnchor
                                   constant:-KKPaddingSM],
    ]];
  }
  return self;
}

- (void)setName:(NSString *)name value:(NSString *)value {
  _name.stringValue = name ?: @"";
  // A heading carries the puck's name and no number, and is set apart by weight
  // rather than by a separator: at 11pt in a 56pt box, a rule costs more room
  // than it earns.
  BOOL heading = value == nil;
  _name.font = heading ? [NSFont systemFontOfSize:kReadoutFontSize
                                           weight:NSFontWeightSemibold]
                       : [NSFont systemFontOfSize:kReadoutFontSize];
  _name.textColor =
      heading ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor;
  _value.stringValue = value ?: @"";
  _value.textColor = NSColor.accentMatchingHost;
}

@end

@implementation MirageColorPanelController (Readout)

// One row per control the gesture moved. Rows are reused across ticks rather
// than rebuilt: this runs on every drag event, and tearing down a stack view's
// children at that rate makes the readout flicker as it re-lays out.
- (void)_setReadoutRows:
    (NSArray<NSDictionary<NSString *, NSString *> *> *)rows {
  if (!_readoutStack)
    return;
  _readoutHint.hidden = rows.count > 0;
  while (_readoutStack.views.count > rows.count)
    [_readoutStack removeView:_readoutStack.views.lastObject];
  while (_readoutStack.views.count < rows.count) {
    _MirageReadoutRow *row = [_MirageReadoutRow new];
    [_readoutStack addView:row inGravity:NSStackViewGravityTop];
    // Full width, so the value column lands on the same right edge in every row
    // instead of each row shrinking to its own content.
    [row.widthAnchor constraintEqualToAnchor:_readoutStack.widthAnchor
                                    constant:-2 * KKPaddingSM]
        .active = YES;
  }
  [rows enumerateObjectsUsingBlock:^(NSDictionary<NSString *, NSString *> *r,
                                     NSUInteger i, BOOL *stop) {
    [(_MirageReadoutRow *)self->_readoutStack.views[i] setName:r[@"name"]
                                                         value:r[@"value"]];
  }];
}

/// Put the declaration's reading in the readout's empty state, or take it back
/// out.
///
/// The empty state rather than a row of its own: it is a sentence about the
/// frame, not a control the puck drives, and the readout is only ever empty
/// when there is no gesture to describe - which is exactly when a measurement
/// is worth reading.
- (void)_setDeclarationSentence:(NSString *)sentence {
  if (sentence == _declarationSentence ||
      [sentence isEqualToString:_declarationSentence])
    return;
  _declarationSentence = [sentence copy];
  _readoutHint.stringValue = sentence ?: MirageReadoutPlaceholder();
}

// The active puck's controls and what they currently read.
//
// Not a record of the last gesture: the puck writes absolute values now and the
// inspector's own sliders track it live, so a before/after was showing one
// number you could already see beside a baseline that was only ever "whatever
// it held when you grabbed it". What the sliders cannot say is WHICH controls
// the handle you are holding drives - they may be in a collapsed group, or
// belong to the other puck - and that is what this answers.
- (void)_refreshReadout {
  KKTimeline *timeline = _lanesView.currentTimeline;
  NSString *source =
      timeline ? [MiragePlugin shaderSourceFromTimeline:timeline] : nil;
  if (!source.length) {
    [self _setReadoutRows:@[]];
    return;
  }
  NSUInteger ringCount = MIN([self _ringCount], _circles.count);
  double frac = [self _editFraction];
  NSSet<NSString *> *drivable = [self _drivableKeysIn:timeline fraction:frac];
  // The active puck of each ring, so the names can be compared before anything
  // is written: with one ring, or with two whose handles are named differently,
  // the names already say which value is which and a ring heading would be
  // clutter. It is only when they do not that the ring has to be spelled out.
  NSMutableArray<NSString *> *puckNames = [NSMutableArray array];
  for (NSUInteger i = 0; i < ringCount; i++)
    [puckNames addObject:[self _puckNameAtIndex:_circles[i].activePuck
                                           ring:i
                                         source:source]
                             ?: @""];
  BOOL nameRings = NO;
  for (NSUInteger i = 0; i < puckNames.count && ringCount > 1; i++) {
    if (!puckNames[i].length)
      nameRings = YES;
    for (NSUInteger j = i + 1; j < puckNames.count; j++)
      if ([puckNames[i] isEqualToString:puckNames[j]])
        nameRings = YES;
  }
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *rows =
      [NSMutableArray array];
  for (NSUInteger i = 0; i < ringCount; i++) {
    NSDictionary<NSString *, NSValue *> *responses =
        [self _responsesForRing:i source:source];
    NSString *puckName = puckNames[i];
    if (!responses.count)
      continue;
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *block =
        [NSMutableArray array];
    for (KKLane *lane in timeline.lanes) {
      NSValue *boxed = lane.key.length ? responses[lane.key] : nil;
      if (!boxed || ![drivable containsObject:lane.key])
        continue;
      MirageSurfaceResponse r;
      [boxed getValue:&r];
      if (!r.hasBase || !MirageResponseBelongsToPuck(r, puckName))
        continue;
      NSArray<NSNumber *> *values = [self _valuesForLane:lane fraction:frac];
      if (!values.count)
        continue;
      // A colour control has no single number to print - its response is a hue
      // rotation, and the swatch in the inspector says it better than a degree
      // would.
      NSString *text =
          r.baseIsHue ? nil
                      : MirageReadoutNumber(values.firstObject.doubleValue, r);
      if (!text)
        continue;
      [block addObject:@{@"name" : lane.label ?: lane.key, @"value" : text}];
    }
    if (!block.count)
      continue;
    // Only headed when there is something for the heading to say. A single
    // unnamed puck has nothing to disambiguate, so it would be a blank line.
    NSString *heading = nameRings ? MirageRingLabel([self _ringAtIndex:i])
                                  : (puckName.length ? puckName : nil);
    if (heading)
      [rows addObject:@{@"name" : heading}];
    [rows addObjectsFromArray:block];
  }
  [self _setReadoutRows:rows.count > 1 ? rows : @[]];
}

@end
