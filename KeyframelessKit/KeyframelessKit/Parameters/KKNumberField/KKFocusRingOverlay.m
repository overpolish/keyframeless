//
//  KKFocusRingOverlay.m
//  KeyframelessKit
//
//  Created by Dom on 01/03/2026.
//

#import "KKFocusRingOverlay.h"
#import "KKNumberFieldGeometry.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat KKNumberFieldFocusInset = 1.0;
static const CGFloat KKNumberFieldFocusCornerRadius = 2.0;
static const CGFloat KKNumberFieldFocusLineWidth = 3.5;
static const CGFloat KKNumberFieldGlowLineWidth = 3.0;
static const CGFloat KKNumberFieldGlowAlpha = 0.2;

@interface KKFocusRingOverlay () {
    NSColor *_color;
    CALayer *_containerLayer;
    CAShapeLayer *_ringLayer;
    CAShapeLayer *_glowLayer;
    CGFloat _padding;
}
@end

@implementation KKFocusRingOverlay

- (instancetype)initWithColor:(NSColor *)color {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _color = color;
        _padding = KKFocusRingPanelPadding;
        self.wantsLayer = YES;
        [self buildLayers];
    }
    return self;
}

- (void)buildLayers {
    self.layer.masksToBounds = NO;

    // Container holds the ring layers and is the animation target.
    // anchorPoint is updated in updatePaths to match the field rect center.
    _containerLayer = [CALayer layer];
    _containerLayer.masksToBounds = NO;
    _containerLayer.opacity = 0;
    [self.layer addSublayer:_containerLayer];

    _glowLayer = [CAShapeLayer layer];
    _glowLayer.fillColor = nil;
    _glowLayer.strokeColor = [_color colorWithAlphaComponent:KKNumberFieldGlowAlpha].CGColor;
    _glowLayer.lineWidth = KKNumberFieldGlowLineWidth;
    [_containerLayer addSublayer:_glowLayer];

    // Ring is a filled even-odd compound path (outer rounded rect + inner hole).
    // This ensures the stroke can never extend inward regardless of animation state.
    _ringLayer = [CAShapeLayer layer];
    _ringLayer.fillColor = _color.CGColor;
    _ringLayer.strokeColor = nil;
    _ringLayer.fillRule = kCAFillRuleEvenOdd;
    [_containerLayer addSublayer:_ringLayer];
}

/// Compound fill path for the ring: outer rounded rect minus inner rounded rect hole.
/// |expansion| expands the outer boundary outward beyond its steady-state position.
/// The inner boundary is always fixed so the ring never encroaches inward.
- (CGPathRef)ringPathWithExpansion:(CGFloat)expansion CF_RETURNS_RETAINED {
    CGFloat w = NSWidth(self.bounds);
    CGFloat h = NSHeight(self.bounds);
    CGFloat p = _padding;
    NSRect fr = NSMakeRect(p + KKNumberFieldPrefixWidth, p,
                           w - 2 * p - KKNumberFieldPrefixWidth - KKNumberFieldSuffixWidth, h - 2 * p);
    NSRect focusRect = NSInsetRect(fr, KKNumberFieldFocusInset, KKNumberFieldFocusInset);
    CGFloat halfLW = KKNumberFieldFocusLineWidth / 2.0;

    NSRect outerRect = NSInsetRect(focusRect, -(halfLW + expansion), -(halfLW + expansion));
    CGFloat outerRadius = KKNumberFieldFocusCornerRadius + halfLW + expansion;

    NSRect innerRect = NSInsetRect(focusRect, halfLW, halfLW);
    CGFloat innerRadius = MAX(0.1, KKNumberFieldFocusCornerRadius - halfLW);

    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRoundedRect(path, NULL, NSRectToCGRect(outerRect), outerRadius, outerRadius);
    CGPathAddRoundedRect(path, NULL, NSRectToCGRect(innerRect), innerRadius, innerRadius);
    return path;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self updatePaths];
}

- (void)updatePaths {
    CGFloat w = NSWidth(self.bounds);
    CGFloat h = NSHeight(self.bounds);

    // The panel frame is padded on all sides by _padding so the ring stroke is never clipped
    // at the window edge. Compute the field rect within those padded bounds.
    CGFloat p = _padding;
    NSRect fr = NSMakeRect(p + KKNumberFieldPrefixWidth, p,
                           w - 2 * p - KKNumberFieldPrefixWidth - KKNumberFieldSuffixWidth, h - 2 * p);
    NSRect focusRect = NSInsetRect(fr, KKNumberFieldFocusInset, KKNumberFieldFocusInset);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    _containerLayer.bounds = CGRectMake(0, 0, w, h);
    _containerLayer.anchorPoint = CGPointMake(0.5, 0.5);
    _containerLayer.position = CGPointMake(w / 2.0, h / 2.0);

    CGPathRef ringPath = [self ringPathWithExpansion:0];
    _ringLayer.path = ringPath;
    CGPathRelease(ringPath);

    // Position the glow so its outer edge aligns with the ring's inner boundary.
    // The glow then extends inward from there — the ring fill covers the outward half.
    CGFloat halfLW = KKNumberFieldFocusLineWidth / 2.0;
    CGFloat halfGlowLW = KKNumberFieldGlowLineWidth / 2.0;
    NSRect innerRect = NSInsetRect(focusRect, halfLW, halfLW);
    NSRect glowRect = NSInsetRect(innerRect, halfGlowLW, halfGlowLW);
    CGPathRef glowPath = CGPathCreateWithRect(NSRectToCGRect(glowRect), nil);
    _glowLayer.path = glowPath;
    CGPathRelease(glowPath);

    [CATransaction commit];
}

- (void)setPanelPadding:(CGFloat)padding {
    _padding = padding;
}

- (NSView *)hitTest:(NSPoint)point {
    return nil; // pass all events through to views beneath
}

- (void)animateIn {
    CGFloat duration = 0.23;
    CAMediaTimingFunction *easeIn = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];

    // Set final model state first so layers snap to end values when animations finish.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _containerLayer.opacity = 1.0;
    _containerLayer.transform = CATransform3DIdentity;
    [CATransaction commit];

    // Path: outer boundary starts expanded, contracts to its final position.
    CGPathRef startPath = [self ringPathWithExpansion:14.0];
    CABasicAnimation *pathAnim = [CABasicAnimation animationWithKeyPath:@"path"];
    pathAnim.fromValue = (__bridge id)startPath;
    pathAnim.duration = duration;
    pathAnim.timingFunction = easeIn;
    [_ringLayer addAnimation:pathAnim forKey:@"focusIn.path"];
    CGPathRelease(startPath);

    // Custom aggressive ease-in — stays near-transparent before snapping to full opacity.
    CAMediaTimingFunction *aggressiveEaseIn = [CAMediaTimingFunction functionWithControlPoints:0.9:0.0:1.0:1.0];
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.0;
    fade.duration = duration;
    fade.timingFunction = aggressiveEaseIn;
    [_containerLayer addAnimation:fade forKey:@"focusIn.opacity"];
}

- (void)hide {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _containerLayer.opacity = 0.0;
    [CATransaction commit];
}

@end
