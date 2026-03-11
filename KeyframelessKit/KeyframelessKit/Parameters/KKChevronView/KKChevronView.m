/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKChevronView.h"
#import "NSColor+KKColors.h"
#import <AppKit/AppKit.h>
#import <CoreFoundation/CFCGTypes.h>
#import <CoreGraphics/CGGeometry.h>
#include <objc/NSObjCRuntime.h>

const CGFloat kChevronWidth = 7.5;
const CGFloat kChevronHeight = 9.0;

@implementation KKChevronView {
  NSButton *_chevronButton;
  CGFloat _currentChevronRotation;
  NSLayoutConstraint *_centerXConstraint;
  NSLayoutConstraint *_centerYConstraint;
  NSUInteger _chevronAnimationToken;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    [self commonInit];
  }
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
  self = [super initWithCoder:coder];
  if (self) {
    [self commonInit];
  }
  return self;
}

- (void)commonInit {
  _isExpanded = NO;
  _currentChevronRotation = 0.0;
  _chevronAnimationToken = 0;

  _chevronButton = [self createChevronButton];
  [self addSubview:_chevronButton];

  CGFloat canvasSize = MAX(kChevronWidth, kChevronHeight);

  _centerXConstraint =
      [_chevronButton.centerXAnchor constraintEqualToAnchor:self.centerXAnchor];
  _centerYConstraint =
      [_chevronButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor
                                                   constant:-1.0];

  [NSLayoutConstraint activateConstraints:@[
    _centerXConstraint, _centerYConstraint,
    [_chevronButton.widthAnchor constraintEqualToConstant:canvasSize],
    [_chevronButton.heightAnchor constraintEqualToConstant:canvasSize]
  ]];

  [self updateChevronImage];
}

- (NSButton *)createChevronButton {
  NSButton *chevronButton = [[NSButton alloc] init];
  chevronButton.bordered = NO;
  chevronButton.imagePosition = NSImageOnly;
  chevronButton.buttonType = NSButtonTypeMomentaryChange;
  chevronButton.target = self;
  chevronButton.action = @selector(chevronClicked:);
  chevronButton.translatesAutoresizingMaskIntoConstraints = NO;
  return chevronButton;
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
  if (_isExpanded == expanded) {
    return;
  }

  _isExpanded = expanded;

  if (animated) {
    [self animateChevronToExpanded:expanded];
  } else {
    _currentChevronRotation = expanded ? 90.0 : 0.0;
    [self updateChevronImage];
  }
}

- (void)setIsExpanded:(BOOL)isExpanded {
  [self setExpanded:isExpanded animated:NO];
}

+ (NSImage *)chevronImageAtAngle:(CGFloat)angle color:(NSColor *)color {
  static NSCache *imageCache = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    imageCache = [[NSCache alloc] init];
  });

  CGFloat r, g, b, a;
  NSColor *calibratedColor =
      [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
  [calibratedColor getRed:&r green:&g blue:&b alpha:&a];
  NSString *cacheKey = [NSString
      stringWithFormat:@"%.0f_%.3f_%.3f_%.3f_%.3f", angle, r, g, b, a];
  NSImage *cached = [imageCache objectForKey:cacheKey];
  if (cached) {
    return cached;
  }

  CGFloat canvasSize = MAX(kChevronWidth, kChevronHeight);
  NSImage *image =
      [[NSImage alloc] initWithSize:NSMakeSize(canvasSize, canvasSize)];
  [image lockFocus];

  NSBezierPath *chevron = [NSBezierPath bezierPath];

  if (angle == 0.0) {
    // Pointing right
    [chevron moveToPoint:NSMakePoint(0, 0)];
    [chevron lineToPoint:NSMakePoint(kChevronWidth, kChevronHeight / 2.0)];
    [chevron lineToPoint:NSMakePoint(0, kChevronHeight)];
  } else if (angle == 40.0) {
    // Rotated 40 degrees clockwise
    CGFloat angle = -40.0 * M_PI / 180.0;
    CGFloat cosA = cos(angle);
    CGFloat sinA = sin(angle);
    const CGFloat offsetX = 2.0;
    const CGFloat offsetY = -0.5;

    CGFloat cx = kChevronWidth / 2.0;
    CGFloat cy = kChevronHeight / 2.0;

    CGFloat x1 = cx + (-cx) * cosA - (-cy) * sinA + offsetX;
    CGFloat y1 = cy + (-cx) * sinA + (-cy) * cosA + offsetY;
    CGFloat x2 = cx + (cx)*cosA - (0) * sinA + offsetX;
    CGFloat y2 = cy + (cx)*sinA + (0) * cosA + offsetY;
    CGFloat x3 = cx + (-cx) * cosA - (cy)*sinA + offsetX;
    CGFloat y3 = cy + (-cx) * sinA + (cy)*cosA + offsetY;

    [chevron moveToPoint:NSMakePoint(x1, y1)];
    [chevron lineToPoint:NSMakePoint(x2, y2)];
    [chevron lineToPoint:NSMakePoint(x3, y3)];
  } else if (angle == 90.0) {
    // Pointing down - width and height reversed as we are rotated 90 degrees
    [chevron moveToPoint:NSMakePoint(0, kChevronWidth)];
    [chevron lineToPoint:NSMakePoint(kChevronHeight, kChevronWidth)];
    [chevron lineToPoint:NSMakePoint(kChevronHeight / 2.0, 0)];
  }

  [chevron closePath];
  [color setFill];
  [chevron fill];

  [image unlockFocus];

  [imageCache setObject:image forKey:cacheKey];
  return image;
}

- (void)updateChevronImage {
  NSImage *chevronImage =
      [[self class] chevronImageAtAngle:_currentChevronRotation
                                  color:[NSColor expandChevron]];
  _chevronButton.image = chevronImage;

  NSImage *activeChevronImage =
      [[self class] chevronImageAtAngle:_currentChevronRotation
                                  color:[NSColor activeExpandChevron]];
  _chevronButton.alternateImage = activeChevronImage;

  // Shift left and up when pointing down
  if (_currentChevronRotation == 90.0) {
    _centerXConstraint.constant = -0.5;
    _centerYConstraint.constant = -1.0;
  } else {
    _centerXConstraint.constant = 0.5;
    _centerYConstraint.constant = -0.5;
  }
}

- (void)chevronClicked:(id)sender {
  [self setExpanded:!self.isExpanded animated:YES];

  if (self.onToggle) {
    self.onToggle(self.isExpanded);
  }
}

- (void)animateChevronToExpanded:(BOOL)expanded {
  _chevronAnimationToken++;
  NSUInteger currentToken = _chevronAnimationToken;

  __weak typeof(self) weakSelf = self;
  if (expanded) {
    _currentChevronRotation = 40.0;
    [self updateChevronImage];

    // Schedule second frame
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          __strong typeof(weakSelf) strongSelf = weakSelf;
          if (strongSelf->_chevronAnimationToken == currentToken) {
            strongSelf->_currentChevronRotation = 90.0;
            [strongSelf updateChevronImage];
          }
        });
  } else {
    _currentChevronRotation = 40.0;
    [self updateChevronImage];

    // Schedule second frame
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          __strong typeof(weakSelf) strongSelf = weakSelf;
          if (strongSelf->_chevronAnimationToken == currentToken) {
            strongSelf->_currentChevronRotation = 0.0;
            [strongSelf updateChevronImage];
          }
        });
  }
}

@end