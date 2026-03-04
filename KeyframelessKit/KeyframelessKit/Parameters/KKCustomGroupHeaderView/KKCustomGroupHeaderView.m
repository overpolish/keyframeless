//
//  KKCustomGroupHeaderView.m
//  KeyframelessKit
//
//  Created by Dom on 27/02/2026.
//

#import "KKCustomGroupHeaderView.h"
#import "KKHostInfo.h"
#include "KKLog.h"
#import "KKNumberField.h"
#import <AppKit/AppKit.h>
#import <CoreFoundation/CFCGTypes.h>
#include <Foundation/Foundation.h>
#import <FxPlug/FxPlugSDK.h>

#pragma mark - Layout Constants

// static const CGFloat kLeftMargin = 6.0;
// static const CGFloat kRightMargin = 80.0;
// static const CGFloat kChevronSize = 7.0;
// static const CGFloat kChevronPadding = 4.0;
// static const CGFloat kLabelChevronGap = 4.0;
// static const CGFloat kLabelDividerGap = 4.0;

// static const CGFloat kColumnMultiplier = 0.325;
// static const CGFloat kColumnConstant = -0.59;

// FCP clamps the label column to a min/max width. Motion has no such limits.
// static const CGFloat kFCPMinDivider = 141.0;
// static const CGFloat kFCPMaxDivider = 184.0;

@interface KKCustomGroupHeaderView ()
@property(nonatomic, strong) id<PROAPIAccessing> apiManager;
@property(nonatomic, strong) KKNumberField *numberField;
@property(nonatomic, assign) CGFloat currentChevronRotation;
@end

@implementation KKCustomGroupHeaderView {
  KKLog *log;
}

- (instancetype)initWithFrame:(NSRect)frame
                   apiManager:(id<PROAPIAccessing>)apiManager
                        label:(NSString *)label {
  self = [super initWithFrame:frame];
  if (self) {
    self.apiManager = apiManager;
    // self.currentChevronRotation = 90.0;
    log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];

    // [self addSubview:self.chevronButton];

    //  [self createLabelField:label];
    // self.labelField.translatesAutoresizingMaskIntoConstraints = NO;
    // [self addSubview:self.labelField];

    // self.customView = customView;
    // if (customView) {
    //   customView.translatesAutoresizingMaskIntoConstraints = NO;
    //   [self addSubview:customView];

    //   CGFloat nfWidth = [KKNumberField preferredWidth];
    //   CGFloat nfHeight = [KKNumberField preferredHeight];
    //   self.numberField = [[KKNumberField alloc]
    //       initWithFrame:NSMakeRect(0, 0, nfWidth, nfHeight)
    //          apiManager:apiManager];
    //   self.numberField.translatesAutoresizingMaskIntoConstraints = NO;
    //   [self addSubview:self.numberField];
    //   // Set the initial frame now; setFrameSize: keeps it updated from here
    //   on. [self positionNumberFieldForSize:frame.size];
    // }

    // [self setupConstraints];
  }
  return self;
}

- (void)drawContent:(NSRect)dirtyRect {
  // TODO draw triangle, label, etc
}

// - (void)drawRect:(NSRect)dirtyRect {
//   // TODO clean - debug
//   [super drawRect:dirtyRect];
//   [[NSColor redColor] setFill];
//   NSRectFill(self.bounds);
// }

// TODO clean
// - (void)setFrameSize:(NSSize)newSize {
//   [super setFrameSize:newSize];
//   [self positionNumberFieldForSize:newSize];
// }

// TODO clean?
// - (void)positionNumberFieldForSize:(NSSize)size {
//   if (!self.numberField)
//     return;
//   [NSAnimationContext beginGrouping];
//   [NSAnimationContext currentContext].duration = 0;
//   CGFloat nfWidth = [KKNumberField preferredWidth];
//   CGFloat nfHeight = [KKNumberField preferredHeight];
//   self.numberField.frame =
//       NSMakeRect(size.width - kRightMargin,
//                  round((size.height - nfHeight) / 2.0), nfWidth, nfHeight);
//   [NSAnimationContext endGrouping];
// }

// - (void)setupConstraints {
//   NSLayoutGuide *divider = [[NSLayoutGuide alloc] init];
//   [self addLayoutGuide:divider];

//   // Proportional width at lower priority so FCP min/max can override it.
//   NSLayoutConstraint *proportional =
//       [NSLayoutConstraint constraintWithItem:divider
//                                    attribute:NSLayoutAttributeWidth
//                                    relatedBy:NSLayoutRelationEqual
//                                       toItem:self
//                                    attribute:NSLayoutAttributeWidth
//                                   multiplier:kColumnMultiplier
//                                     constant:kColumnConstant];
//   proportional.priority = NSLayoutPriorityDefaultHigh; // 750

//   NSMutableArray *constraints = [NSMutableArray arrayWithArray:@[
//     [divider.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
//     proportional,

//     [self.chevronButton.leadingAnchor
//         constraintEqualToAnchor:self.leadingAnchor
//                        constant:kLeftMargin + kChevronPadding],
//     [self.chevronButton.centerYAnchor
//         constraintEqualToAnchor:self.centerYAnchor],
//     [self.chevronButton.widthAnchor constraintEqualToConstant:kChevronSize],
//     [self.chevronButton.heightAnchor constraintEqualToConstant:kChevronSize],

//     [self.labelField.leadingAnchor
//         constraintEqualToAnchor:self.chevronButton.trailingAnchor
//                        constant:kLabelChevronGap],
//     [self.labelField.trailingAnchor
//         constraintLessThanOrEqualToAnchor:divider.trailingAnchor
//                                  constant:-kLabelDividerGap],
//     [self.labelField.centerYAnchor
//     constraintEqualToAnchor:self.centerYAnchor],
//   ]];

//   if (self.customView) {
//     [constraints addObjectsFromArray:@[
//       [self.customView.leadingAnchor
//           constraintEqualToAnchor:divider.trailingAnchor],
//       [self.customView.trailingAnchor
//           constraintEqualToAnchor:self.trailingAnchor
//                          constant:-kRightMargin],
//       [self.customView.topAnchor constraintEqualToAnchor:self.topAnchor],
//       [self.customView.bottomAnchor
//       constraintEqualToAnchor:self.bottomAnchor],
//     ]];
//   }

//   // FCP: required min/max constraints override the proportional one (which
//   is
//   // at 750) so the column clamps to the allowed range instead of
//   // growing/shrinking freely.
//   if ([KKHostInfo isRunningInFinalCut]) {
//     [constraints addObjectsFromArray:@[
//       [divider.widthAnchor
//           constraintGreaterThanOrEqualToConstant:kFCPMinDivider],
//       [divider.widthAnchor
//       constraintLessThanOrEqualToConstant:kFCPMaxDivider],
//     ]];
//   }

//   [NSLayoutConstraint activateConstraints:constraints];
// }

- (NSTextField *)createLabelField:(NSString *)text {
  static NSColor *labelColor = nil;
  static NSFont *labelFont = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    // TODO pull into const/colors
    labelColor = [NSColor colorWithWhite:0xb3 / 255.0 alpha:1.0];
    labelFont = [NSFont systemFontOfSize:11.0 weight:NSFontWeightLight];
  });

  NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
  field.stringValue = text ?: @"Label";
  field.backgroundColor = [NSColor clearColor];
  field.textColor = labelColor;
  field.font = labelFont;

  field.editable = NO;
  field.selectable = NO;
  field.bordered = NO;

  return field;
}

// - (NSButton *)createChevronButton {
//   NSButton *chevronButton = [[NSButton alloc] init];
//   chevronButton.bordered = NO;
//   chevronButton.imagePosition = NSImageOnly;
//   chevronButton.buttonType = NSButtonTypeMomentaryChange;
//   chevronButton.target = self;
//   chevronButton.action = @selector(chevronClicked:);
//   chevronButton.translatesAutoresizingMaskIntoConstraints = NO;
//   [self updateChevronImage];
//   return chevronButton;
// }

// + (NSImage *)baseChevronImage {
//   static NSImage *baseChevron = nil;
//   static dispatch_once_t onceToken;
//   dispatch_once(&onceToken, ^{
//     CGFloat size = 9.0;
//     baseChevron = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];

//     [baseChevron lockFocus];

//     [[NSGraphicsContext currentContext] setShouldAntialias:YES];
//     [[NSGraphicsContext currentContext]
//         setImageInterpolation:NSImageInterpolationHigh];

//     // Chevron pointing DOWN - will be rotated as needed
//     CGFloat chevronWidth = 9.0;
//     CGFloat chevronHeight = 7.5;
//     CGFloat offsetX = (size - chevronWidth) / 2.0;
//     CGFloat offsetY = (size - chevronHeight) / 2.0;

//     NSBezierPath *chevron = [NSBezierPath bezierPath];
//     [chevron moveToPoint:NSMakePoint(offsetX, offsetY + chevronHeight)];
//     [chevron lineToPoint:NSMakePoint(offsetX + chevronWidth,
//                                      offsetY + chevronHeight)];
//     [chevron lineToPoint:NSMakePoint(offsetX + chevronWidth / 2.0, offsetY)];
//     [chevron closePath];

//     [[NSColor blackColor] setFill];
//     [chevron fill];

//     [baseChevron unlockFocus];
//   });

//   return baseChevron;
// }

// - (NSImage *)createChevronImageWithColor:(NSColor *)color
//                                 rotation:(CGFloat)degrees {
//   CGFloat size = 9.0;
//   NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];

//   [image lockFocus];

//   [[NSGraphicsContext currentContext] setShouldAntialias:YES];
//   [[NSGraphicsContext currentContext]
//       setImageInterpolation:NSImageInterpolationHigh];

//   [NSGraphicsContext saveGraphicsState];

//   NSAffineTransform *transform = [NSAffineTransform transform];
//   [transform translateXBy:size / 2.0 yBy:size / 2.0];
//   [transform rotateByDegrees:degrees];
//   [transform translateXBy:-size / 2.0 yBy:-size / 2.0];
//   [transform concat];

//   NSImage *baseChevron = [[self class] baseChevronImage];
//   [color setFill];

//   NSRect imageRect = NSMakeRect(0, 0, size, size);
//   [baseChevron drawInRect:imageRect
//                  fromRect:NSZeroRect
//                 operation:NSCompositingOperationSourceOver
//                  fraction:1.0];

//   NSRectFillUsingOperation(imageRect, NSCompositingOperationSourceIn);

//   [NSGraphicsContext restoreGraphicsState];

//   [image unlockFocus];

//   return image;
// }

// - (void)updateChevronImage {
//   NSImage *chevronImage =
//       [self createChevronImageWithColor:[NSColor colorWithWhite:0x91 / 255.0
//                                                           alpha:1.0]
//                                rotation:self.currentChevronRotation];
//   self.chevronButton.image = chevronImage;

//   NSImage *darkChevronImage =
//       [self createChevronImageWithColor:[NSColor colorWithWhite:0x6e / 255.0
//                                                           alpha:1.0]
//                                rotation:self.currentChevronRotation];
//   self.chevronButton.alternateImage = darkChevronImage;
// }

// - (void)chevronClicked:(id)sender {
//   self.isExpanded = !self.isExpanded;

//   CGFloat startRotation = self.currentChevronRotation;
//   CGFloat targetRotation = self.isExpanded ? 0.0 : 90.0;
//   CGFloat delta = targetRotation - startRotation;

//   // 3 step animation
//   dispatch_after(
//       dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.016 * NSEC_PER_SEC)),
//       dispatch_get_main_queue(), ^{
//         self.currentChevronRotation = startRotation + (delta * 0.33);
//         [self updateChevronImage];
//       });

//   dispatch_after(
//       dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.032 * NSEC_PER_SEC)),
//       dispatch_get_main_queue(), ^{
//         self.currentChevronRotation = startRotation + (delta * 0.67);
//         [self updateChevronImage];
//       });

//   dispatch_after(
//       dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.048 * NSEC_PER_SEC)),
//       dispatch_get_main_queue(), ^{
//         self.currentChevronRotation = targetRotation;
//         [self updateChevronImage];
//       });
// }

@end
