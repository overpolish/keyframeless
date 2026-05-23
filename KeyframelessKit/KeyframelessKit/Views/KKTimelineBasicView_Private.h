/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKTimelineBasicView.h>

#import "KKCheckboxView.h"
#import "KKTimelineZoomPan.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKTimingStage.h>

NS_ASSUME_NONNULL_BEGIN

static const CGFloat kGraphPadX = 20.0;     // left/right inset of the track
static const CGFloat kGraphPadTop = 8.0;    // headroom above the curve
static const CGFloat kRulerH = 13.0;        // top clip-duration ruler strip
static const CGFloat kRulerGap = 3.0;       // between ruler and graph top
static const CGFloat kLabelStripH = 22.0;   // bottom strip: labels + checkbox
static const CGFloat kGraphBottomGap = 6.0; // between track and label strip
static const CGFloat kDiamondR = 5.0;       // legacy diamond hit radius
static const CGFloat kPillW = 6.0;          // boundary pill width
static const CGFloat kPillInsetY = 4.0;     // pill inset from graph top/bottom
static const CGFloat kPillHitSlop = 3.0;    // extra hit slop around pill width
static const CGFloat kCurveWidth = 2.0;
static const NSInteger kCurveSamples = 160;
static const CGFloat kTickMinSpacing = 50.0; // px between ruler ticks

// Display fractions used for a phase that is currently off, so the section
// is still legible and toggling it on activates that region rather than
// growing from zero width.
static const double kDefaultInEnd = 0.22;
static const double kDefaultOutStart = 0.78;
static const double kEps = 1.0e-4;
static const double kMinPhaseFrac = 0.002;  // fallback when duration unknown
static const double kMinPhaseSeconds = 0.1; // absolute min In/Out duration
static const double kMinHoldFrac = 0.05;    // min Hold span between boundaries

typedef NS_ENUM(NSInteger, KKBasicBoundary) {
  KKBasicBoundaryInStart = 0,
  KKBasicBoundaryHold = 1,
  KKBasicBoundaryOutEnd = 2,
};

typedef NS_ENUM(NSInteger, KKBasicSection) {
  KKBasicSectionNone = 0,
  KKBasicSectionIn = 1,
  KKBasicSectionHold = 2,
  KKBasicSectionOut = 3,
};

// The Basic projection of the shared timeline: derived from the animatable
// lanes' keyposes (all opted-in lanes share boundary times — the invariant).
typedef struct {
  BOOL anyAnimatable;
  BOOL inEnabled;
  BOOL outEnabled;
  double inEndFrac;
  double outStartFrac;
  KKEasingCurve inCurve;
  KKEasingCurve outCurve;
  double inIntensity;
  double outIntensity;
  double inFrequency;
  double outFrequency;
  BOOL holdDrift;       // the two interior Hold keyposes carry different values
  BOOL inIsTransition;  // the In phase endpoints actually differ (value-based)
  BOOL outIsTransition; // the Out phase endpoints actually differ (value-based)
  KKEasingCurve holdCurve;
  double holdIntensity;
  double holdFrequency;
  KKIntervalModulation holdMod;
  double holdModIntensity;
  double holdModFrequency;
  uint32_t holdModSeed;
  double clipDur;   // seconds; for the log-weight time scale
  double zoom;      // 1 = fit; visible span = 1/zoom of the warped axis
  double panOffset; // visible start in warped-u space [0, 1-1/zoom]
} KKBasicProj;

typedef struct {
  BOOL inEnabled;
  BOOL outEnabled;
  NSInteger holdStart;
  NSInteger holdEnd;
} KKHoldShape;

// Pure timeline/projection helpers — definitions live in the core .m and are
// reused across the categories below.
FOUNDATION_EXPORT KKHoldShape KKShapeOfLane(KKLane *lane);
FOUNDATION_EXPORT BOOL KKValuesEqual(NSArray<NSNumber *> *a,
                                     NSArray<NSNumber *> *b);
FOUNDATION_EXPORT KKHoldEffect KKBasicHoldEffect(KKIntervalModulation m);
FOUNDATION_EXPORT double KKBasicHoldValue(double t, KKBasicProj p,
                                          double holdEnd);
FOUNDATION_EXPORT double KKBasicMotionY(double t, KKBasicProj p);
FOUNDATION_EXPORT double KKBasicMotionYSmoothed(double t, KKBasicProj p);
FOUNDATION_EXPORT void KKBasicDisplayWidths(KKBasicProj p, double *outIn,
                                            double *outHold, double *outOut);
FOUNDATION_EXPORT double KKBasicFracToU(double frac, KKBasicProj p);
FOUNDATION_EXPORT double KKBasicUToFrac(double u, KKBasicProj p);
FOUNDATION_EXPORT double KKBasicBoundaryU(KKBasicProj p, NSInteger d, double v);
FOUNDATION_EXPORT double KKBasicSolveBoundary(KKBasicProj p, NSInteger d,
                                              double targetU, double lo,
                                              double hi);
FOUNDATION_EXPORT CGFloat KKBasicXForFrac(double frac, NSRect g, KKBasicProj p);
FOUNDATION_EXPORT double KKBasicFracForX(CGFloat x, NSRect g, KKBasicProj p);
FOUNDATION_EXPORT NSPoint KKBasicPoint(NSRect g, double frac, double val,
                                       double lo, double hi, KKBasicProj p);
FOUNDATION_EXPORT void KKBasicValueExtent(KKBasicProj p, double *outLo,
                                          double *outHi);

// Class extension: ivars only. Cross-category method decls live in the
// named (Internal) category below — declaring them in the class extension
// would trigger "category is implementing a method which will also be
// implemented by its primary class" when a category provides the body.
@interface KKTimelineBasicView () {
@package
  NSArray<KKLane *> *_availableLanes;
  KKTimeline *_timeline;
  KKCheckboxView *_inCheck;
  KKCheckboxView *_outCheck;
  NSTextField *_inLabel;
  NSTextField *_holdLabel;
  NSTextField *_outLabel;
  NSTrackingArea *_trackingArea;
  KKBasicSection _hoverSection;
  NSInteger _pressedDiamond;
  BOOL _dragActive;
  BOOL _scrubbing;
  // Sticky scrub-snap: which diamond frac the scrubber is currently snapped
  // to (or NAN if not snapped). Sticky to avoid pinging near the threshold
  // in log-warped regions where the visual jump on unsnap is large.
  double _snappedScrubFrac;
  NSPoint _pressPoint;
  NSView *_popoverAnchor;
  KKTimelineZoomPan *_zp;
  BOOL _zoomedNotified;
  // Backing storage for the public properties — declared here (instead of
  // synthesized in the core .m) so all categories can read/write them.
  double _clipDurationSeconds;
  double _frameDurationSeconds;
  double _playheadFraction;
  // Boundary-popover state — read by the onValue/onAnimate closures created
  // in _openBoundaryPopoverForDiamond:. Stored as ivars (not closure
  // locals) so an onion-skin filmstrip cell click can swap which boundary
  // the open popover targets without rebuilding the popover. Match the
  // closure captures in _openBoundaryPopoverForDiamond: 1:1.
  KKBasicBoundary _curBoundary;
  BOOL _curBoundaryInOn;
  BOOL _curBoundaryOutOn;
  double _curBoundaryHoldFrac;
  KKBasicSection _curAnimateSec;
  NSInteger _curDiamond;
  // Guide-only: optional callback fired AFTER the existing In/Out checkbox
  // handler runs. Lets a Joyride step advance on user toggle without
  // bypassing the normal _setInEnabled:/_setOutEnabled: path. phase: 0=In,
  // 1=Out. Stored here so the +Guide category can read/write it.
  void (^_onPhaseToggled)(NSInteger phase, BOOL on);
  // Guide-only: fired at the start of _openBoundaryPopoverForDiamond:
  // (i.e. when a diamond click resolves to a popover request). idx: 1-4
  // matching the diamond model (1 in-start, 2 hold-start, 3 hold-end,
  // 4 out-end).
  void (^_onDiamondTapped)(NSInteger idx);
  // Guide-only: fired at the start of _openGapPopoverForSection:. section is
  // a KKBasicSection (1=In, 2=Hold, 3=Out). Only fires for sections that
  // actually open a transition popover (In/Out for now); Hold has its own
  // _openHoldPopover path.
  void (^_onGapTapped)(NSInteger section);
}
@end

// Cross-category private methods. Each one is *defined* in exactly one of
// the +Model / +Drawing / +Interaction / +Popovers (or core) .m files; all
// the others can call it via this declaration.
@interface KKTimelineBasicView (Internal)

- (void)_buildUI;
- (NSTextField *)_makeSectionLabel:(NSString *)text;
- (void)_restoreCheckboxes;

- (NSArray<NSNumber *> *)_holdValuesForLane:(KKLane *)lane;
- (nullable KKInterval *)_holdIntervalForLane:(KKLane *)lane;
- (BOOL)_holdLinked;
- (BOOL)_holdDrift;
/// Value-based phase classification (matches Advanced's per-keypose rule): a
/// phase is a real transition only when its endpoints actually carry different
/// values on some animatable lane. Drives pill / curve colour so a flat
/// (in-start == hold) In reads accent, not warning.
- (BOOL)_inIsTransition;
- (BOOL)_outIsTransition;
- (void)_toggleHoldLink;
- (KKLane *)_rebuiltLane:(KKLane *)lane
                    inOn:(BOOL)inOn
                   outOn:(BOOL)outOn
                     tIn:(double)tIn
                    tOut:(double)tOut;
- (void)_rebuildInOn:(BOOL)inOn
               outOn:(BOOL)outOn
                 tIn:(double)tIn
                tOut:(double)tOut;
- (void)_applyInEnabled:(BOOL)inOn outEnabled:(BOOL)outOn;
- (void)_setInEnabled:(BOOL)on;
- (void)_setOutEnabled:(BOOL)on;

- (double)_clipDuration;
- (KKBasicProj)_projection;
- (NSRect)_graphRect;

- (void)_strokeCurveFrom:(double)t0
                      to:(double)t1
                    proj:(KKBasicProj)p
                   xproj:(KKBasicProj)xp
                    rect:(NSRect)g
                      lo:(double)lo
                      hi:(double)hi
                  dashed:(BOOL)dashed
                   color:(NSColor *)color;
- (void)_drawDiamondAt:(NSPoint)c filled:(BOOL)filled color:(NSColor *)color;
- (void)_drawPillAtX:(CGFloat)x
              inRect:(NSRect)g
              filled:(BOOL)filled
               color:(NSColor *)color;
- (void)_drawDurationForSection:(KKBasicSection)section
                         inRect:(NSRect)g
                           proj:(KKBasicProj)p
                          xproj:(KKBasicProj)xp
                            dur:(double)dur
                         rulerY:(CGFloat)rulerY;
- (void)_drawRulerInRect:(NSRect)g proj:(KKBasicProj)p xproj:(KKBasicProj)xp;
- (void)_placeSection:(NSTextField *)label
             checkbox:(nullable KKCheckboxView *)check
              centerX:(CGFloat)cx
                 midY:(CGFloat)midY
              enabled:(BOOL)enabled;

- (KKBasicSection)_sectionAtPoint:(NSPoint)pt;
- (void)_notifyZoomChanged;
- (NSInteger)_diamondAtPoint:(NSPoint)pt proj:(KKBasicProj)p rect:(NSRect)g;
- (BOOL)_isInScrubBand:(NSPoint)pt rect:(NSRect)g;

- (void)_openGapPopoverForSection:(KKBasicSection)sec;
- (void)_setLaneParticipation:(BOOL)on
                     forLabel:(NSString *)label
                      section:(KKBasicSection)sec;
- (void)_openHoldPopover;
- (void)_mutateHoldModWith:(void (^)(KKInterval *iv))mut;
- (void)_setHoldModApplied:(BOOL)on forLabel:(NSString *)label;
- (void)_setHoldModComponent:(NSUInteger)componentIdx
                          on:(BOOL)on
                    forLabel:(NSString *)label;
- (void)_setHoldDriftApplied:(BOOL)on forLabel:(NSString *)label;
- (void)_mutateInterval:(KKBasicSection)section
                   with:(void (^)(KKInterval *iv))mut;
- (void)_openBoundaryPopoverForDiamond:(NSInteger)d;
- (void)_writeBoundary:(KKBasicBoundary)boundary
                values:(NSArray<NSNumber *> *)values
              forLabel:(NSString *)label
                  inOn:(BOOL)inOn
                 outOn:(BOOL)outOn
        holdTargetFrac:(double)holdTargetFrac;

@end

NS_ASSUME_NONNULL_END
