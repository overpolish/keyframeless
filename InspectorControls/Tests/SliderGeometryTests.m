/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import <AppKit/AppKit.h>
#import "ICSliderView.h"
#include <assert.h>
#include <math.h>

@interface NSSliderCell (ICSliderGeometryTesting)
- (NSRect)trackRectForBarRect:(NSRect)barRect;
@end
@interface SliderActionTarget : NSObject
@property(nonatomic) NSUInteger count;
- (void)sliderChanged:(id)sender;
@end
@implementation SliderActionTarget
- (void)sliderChanged:(id)sender { self.count++; }
@end

static void near(CGFloat a, CGFloat b) { assert(fabs(a - b) < 0.01); }

int main(void) {
  @autoreleasepool {
    ICSliderView *view=[[ICSliderView alloc] initWithFrame:NSMakeRect(0,0,100,20)];
    view.minValue=0; view.maxValue=100; view.doubleValue=0;
    NSSliderCell *cell=view.slider.cell;
    SliderActionTarget *target=[SliderActionTarget new];
    view.target=target; view.action=@selector(sliderChanged:);
    NSRect bar=[cell barRectFlipped:NO];
    NSRect track=[cell trackRectForBarRect:bar];
    near(NSMinX(track), NSMinX(bar)-0.25);
    near(NSMaxX(track), NSMaxX(bar)-4.75);
    NSRect minKnob=[cell knobRectFlipped:NO];
    near(NSMidX(minKnob), NSMinX(bar)+3.75);
    view.doubleValue=100;
    NSRect maxKnob=[cell knobRectFlipped:NO];
    near(NSMaxX(maxKnob), NSMaxX(bar)-4.0);

    // A click maps through the same endpoint travel used by the knob.
    [cell startTrackingAt:NSMakePoint(NSMidX(maxKnob),NSMidY(bar)) inView:view];
    near(view.doubleValue,100);
    assert(target.count == 0); // Merely grabbing a thumb must not author a value.
    view.doubleValue=0;
    [cell startTrackingAt:NSMakePoint(NSMinX(bar)+3.75,NSMidY(bar)) inView:view];
    near(view.doubleValue,0);
    [cell continueTracking:NSMakePoint(3.75,10) at:NSMakePoint(NSMidX(bar),10) inView:view];
    near(view.doubleValue, (NSMidX(bar)-NSMinX(bar)-3.75)/(NSMaxX(bar)-NSMinX(bar)-12.5)*100);
    assert(target.count == 1);

    // Grabbing away from the centre must not jump the value or lose that
    // offset as the pointer follows the corrected travel range.
    view.doubleValue=50;
    NSRect middle=[cell knobRectFlipped:NO];
    NSPoint grab=NSMakePoint(NSMidX(middle)+2,NSMidY(middle));
    [cell startTrackingAt:grab inView:view.slider]; near(view.doubleValue,50);
    CGFloat nextCenter=NSMidX(minKnob)+(NSMidX(maxKnob)-NSMidX(minKnob))*.75;
    [cell continueTracking:grab at:NSMakePoint(nextCenter+2,grab.y) inView:view.slider];
    near(view.doubleValue,75);
    // Inverse mapping works for a signed range and clamps outside both ends.
    view.minValue=-20; view.maxValue=60; view.doubleValue=0;
    [cell startTrackingAt:NSMakePoint(NSMinX(track)-20,NSMidY(bar)) inView:view.slider];
    near(view.doubleValue,-20);
    [cell continueTracking:NSZeroPoint at:NSMakePoint(NSMaxX(track)+20,NSMidY(bar)) inView:view.slider];
    near(view.doubleValue,60);

    // Narrow controls clamp travel instead of reversing the mapping.
    ICSliderView *narrow=[[ICSliderView alloc] initWithFrame:NSMakeRect(0,0,8,20)];
    narrow.minValue=-2; narrow.maxValue=2; narrow.doubleValue=-2;
    NSRect narrowBar=[narrow.slider.cell barRectFlipped:NO];
    narrow.doubleValue=2;
    NSRect narrowMax=[narrow.slider.cell knobRectFlipped:NO];
    assert(NSMidX(narrowMax)>=NSMinX(narrowBar)+3.75);
    [narrow.slider.cell startTrackingAt:NSMakePoint(NSMidX(narrowMax),10) inView:narrow];
    near(narrow.doubleValue,2);
    puts("InspectorControls slider geometry: endpoints, mapping, grab offset and narrow travel passed");
  }
}
