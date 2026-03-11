/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKCustomGroupHeaderView.h"
#import "KKLabelView.h"
#import "KKLog.h"
#import "KKNumberField.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKParameterRowView.h>

#pragma mark - Layout Constants

// static const CGFloat kLeftMargin = 6.0;
// static const CGFloat kRightMargin = 80.0;
// static const CGFloat kChevronSize = 7.0;
// static const CGFloat kChevronPadding = 4.0;
// static const CGFloat kLabelChevronGap = 4.0;

// FCP clamps the label column to a min/max width. Motion has no such limits.
// static const CGFloat kFCPMinDivider = 141.0;
// static const CGFloat kFCPMaxDivider = 184.0;

@interface KKCustomGroupHeaderView ()
@property(nonatomic, strong) KKNumberField *numberField;
@property(nonatomic, assign) CGFloat currentChevronRotation;
@end

@implementation KKCustomGroupHeaderView {
  KKLog *log;
}

- (instancetype)initWithFrame:(NSRect)frameRect
                   apiManager:(id<PROAPIAccessing>)apiManager
                  parameterId:(UInt32)parameterId {
  self = [super initWithFrame:frameRect
                   apiManager:apiManager
                  parameterId:parameterId];
  if (self) {
    NSView *label = [[KKLabelView alloc] initWithText:@"Radius"];
    self.leftView = label;

    NSView *right = [[NSView alloc] initWithFrame:NSZeroRect];
    right.wantsLayer = YES;
    right.layer.backgroundColor = [[NSColor greenColor] CGColor];
    self.rightView = right;
  }
  return self;
}

// - (instancetype)initWithFrame:(NSRect)frame
//                    apiManager:(id<PROAPIAccessing>)apiManager
//                   parameterId:(UInt32)parameterId
//                         {
//   self = [super initWithFrame:frame];
//   if (self) {
//     self.apiManager = apiManager;
//     // self.currentChevronRotation = 90.0;
//     log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];

//     // [self addSubview:self.chevronButton];

//     // self.customView = customView;
//     // if (customView) {
//     //   customView.translatesAutoresizingMaskIntoConstraints = NO;
//     //   [self addSubview:customView];

//     //   CGFloat nfWidth = [KKNumberField preferredWidth];
//     //   CGFloat nfHeight = [KKNumberField preferredHeight];
//     //   self.numberField = [[KKNumberField alloc]
//     //       initWithFrame:NSMakeRect(0, 0, nfWidth, nfHeight)
//     //          apiManager:apiManager];
//     //   self.numberField.translatesAutoresizingMaskIntoConstraints = NO;
//     //   [self addSubview:self.numberField];
//     //   // Set the initial frame now; setFrameSize: keeps it updated from
//     here
//     //   on. [self positionNumberFieldForSize:frame.size];
//     // }

//     // [self setupConstraints];
//   }
//   return self;
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
