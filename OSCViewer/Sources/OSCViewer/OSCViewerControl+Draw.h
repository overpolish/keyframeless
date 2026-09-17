/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import "OSCViewerControl.h"

// The draw tick: the playhead-motion verdict that decides whether the elements
// appear at all, the element append in draw order, and the Metal pass. Split
// out because the tick owns that whole decision, while the control itself keeps
// host geometry, hit precedence, cursor arbitration and the drags.
@interface OSCViewerControl (Draw)
// Drops the playhead inference so the next tick reports a stopped playhead,
// and returns whether the elements were hidden. Pointer and key callbacks call
// this: the control has to be there when it is being reached for, and a caller
// carrying forceUpdate uses the result to demand the redraw that brings it
// back, since a control cannot invalidate itself.
- (BOOL)restoreAfterPointerActivity;
@end
