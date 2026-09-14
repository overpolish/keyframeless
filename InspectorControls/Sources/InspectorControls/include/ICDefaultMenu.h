/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import <AppKit/AppKit.h>
/// Appends preference actions. The consumer owns storage and menu lifecycle.
void ICAppendDefaultMenuItems(NSMenu *menu, id target, SEL action, id context, BOOL canSet);
