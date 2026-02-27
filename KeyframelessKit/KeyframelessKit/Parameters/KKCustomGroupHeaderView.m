//
//  KKCustomGroupHeaderView.m
//  KeyframelessKit
//
//  Created by Dom on 27/02/2026.
//

#import "KKCustomGroupHeaderView.h"

@implementation KKCustomGroupHeaderView

- (instancetype)initWithFrame:(NSRect)frame
                   apiManager:(id<PROAPIAccessing>)apiManager
                        label:(NSString *)label
                   customView:(NSView *)customView
{
    self = [super initWithFrame:frame];
    if (self) {
        self.apiManager = apiManager;
        self.isExpanded = NO;
        self.currentRotation = 90.0;
        
        self.chevronButton = [[NSButton alloc] initWithFrame:NSZeroRect];
        self.chevronButton.bordered = NO;
        self.chevronButton.imagePosition = NSImageOnly;
        self.chevronButton.buttonType = NSButtonTypeMomentaryChange;
        self.chevronButton.target = self;
        self.chevronButton.action = @selector(chevronClicked:);
        
        [self updateChevronImage];
        
        [self addSubview:self.chevronButton];
        
        self.labelField = [self createLabelField:label];
        [self addSubview:self.labelField];
        
        self.customView = customView;
        if (self.customView)
        {
            [self addSubview:self.customView];
        }
    }
    return self;
}

+ (NSImage *)baseChevronImage
{
    static NSImage *baseChevron = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CGFloat size = 9.0;
        baseChevron = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
        
        [baseChevron lockFocus];
        
       [[NSGraphicsContext currentContext] setShouldAntialias:YES];
       [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
        
        // Chevron pointing DOWN - will be rotated as needed
        CGFloat chevronWidth = 9.0;
        CGFloat chevronHeight = 7.5;
        CGFloat offsetX = (size - chevronWidth) / 2.0;
        CGFloat offsetY = (size - chevronHeight) / 2.0;
        
        NSBezierPath *chevron = [NSBezierPath bezierPath];
        [chevron moveToPoint:NSMakePoint(offsetX, offsetY + chevronHeight)];
        [chevron lineToPoint:NSMakePoint(offsetX + chevronWidth, offsetY + chevronHeight)];
        [chevron lineToPoint:NSMakePoint(offsetX + chevronWidth / 2.0, offsetY)];
        [chevron closePath];
        
        // Use a template color that will be tinted
        [[NSColor blackColor] setFill];
        [chevron fill];
        
        [baseChevron unlockFocus];
    });
    
    return baseChevron;
}

- (NSTextField *)createLabelField:(NSString *)text
{
    static NSColor *labelColor = nil;
    static NSFont *labelFont = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        labelColor = [NSColor colorWithWhite:0xb3/255.0 alpha:1.0];
        labelFont = [NSFont systemFontOfSize:11.0 weight:NSFontWeightLight];
    });
    
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSZeroRect];
    field.stringValue = text ?: @"Label";
    field.editable = NO;
    field.selectable = NO;
    field.bordered = NO;
    field.backgroundColor = [NSColor clearColor];
    field.textColor = labelColor;
    field.font = labelFont;
    
    return field;
}

- (NSImage *)createChevronImageWithColor:(NSColor *)color rotation:(CGFloat)degrees
{
    CGFloat size = 9.0;
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
    
    [image lockFocus];
    
    [[NSGraphicsContext currentContext] setShouldAntialias:YES];
    [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
    
    [NSGraphicsContext saveGraphicsState];
    
    NSAffineTransform *transform = [NSAffineTransform transform];
    [transform translateXBy:size / 2.0 yBy:size / 2.0];
    [transform rotateByDegrees:degrees];
    [transform translateXBy:-size / 2.0 yBy:-size / 2.0];
    [transform concat];
    
    // Draw the base chevron with the specified color
    NSImage *baseChevron = [[self class] baseChevronImage];
    [color setFill];
    
    NSRect imageRect = NSMakeRect(0, 0, size, size);
    [baseChevron drawInRect:imageRect 
                   fromRect:NSZeroRect 
                  operation:NSCompositingOperationSourceOver 
                   fraction:1.0];
    
    // Apply color tinting
    NSRectFillUsingOperation(imageRect, NSCompositingOperationSourceIn);
    
    [NSGraphicsContext restoreGraphicsState];
    
    [image unlockFocus];
    
    return image;
}

- (void)updateChevronImage
{
    NSImage *chevronImage = [self createChevronImageWithColor:[NSColor colorWithWhite:0x91/255.0 alpha:1.0]
                                                     rotation:self.currentRotation];
    self.chevronButton.image = chevronImage;
    
    NSImage *darkChevronImage = [self createChevronImageWithColor:[NSColor colorWithWhite:0x6e/255.0 alpha:1.0]
                                                         rotation:self.currentRotation];
    self.chevronButton.alternateImage = darkChevronImage;
}

- (void)drawRect:(NSRect)dirtyRect
{
    [super drawRect:dirtyRect];
    
    CGFloat leftMargin = 6.0;
    CGFloat rightMargin = 80.0;
    
    NSRect contentRect = self.bounds;
    contentRect.origin.x += leftMargin;
    contentRect.size.width -= (leftMargin + rightMargin);
    
    if (contentRect.size.width <= 0.0)
    {
        return;
    }
    
    // 1/3 left, 2/3 right
    CGFloat leftWidth = floor(contentRect.size.width * (1.0 / 3.0));
    
    NSRect leftRect = NSMakeRect(contentRect.origin.x,
                                 contentRect.origin.y,
                                 leftWidth,
                                 contentRect.size.height);
    
    NSRect rightRect = NSMakeRect(NSMaxX(leftRect),
                                  contentRect.origin.y,
                                  contentRect.size.width - leftWidth,
                                  contentRect.size.height);
    
    [[NSColor clearColor] setFill];
    NSRectFill(leftRect);
    
    if (self.customView) {
        self.customView.frame = rightRect;
    } else {
        [[NSColor clearColor] setFill];
        NSRectFill(rightRect);
    }
    
    CGFloat chevronSize = 7.0;
    CGFloat chevronPadding = 4.0;
    CGFloat chevronX = leftRect.origin.x + chevronPadding;
    CGFloat chevronY = NSMidY(leftRect) - chevronSize / 2.0;
    
    self.chevronButton.frame = NSMakeRect(chevronX, chevronY, chevronSize, chevronSize);
    
    // Label after chevron
    CGFloat labelX = NSMaxX(self.chevronButton.frame) + 4.0;
    CGFloat labelWidth = NSMaxX(leftRect) - labelX - 4.0;
    [self.labelField sizeToFit];
    CGFloat labelHeight = self.labelField.frame.size.height;
    CGFloat labelY = NSMidY(leftRect) - labelHeight / 2.0;
    
    self.labelField.frame = NSMakeRect(labelX, labelY, labelWidth, labelHeight);
}

- (void)chevronClicked:(id)sender
{
    self.isExpanded = !self.isExpanded;
    
    CGFloat startRotation = self.currentRotation;
    CGFloat targetRotation = self.isExpanded ? 0.0 : 90.0;
    CGFloat delta = targetRotation - startRotation;
    
    // 3 step animation
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.016 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   ^{
        self.currentRotation = startRotation + (delta * 0.33);
        [self updateChevronImage];
    });
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.032 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   ^{
        self.currentRotation = startRotation + (delta * 0.67);
        [self updateChevronImage];
    });
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.048 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(),
                   ^{
        self.currentRotation = targetRotation;
        [self updateChevronImage];
    });
}

@end
