//
//  KKNumberFieldTextView.m
//  KeyframelessKit
//
//  Created by Dom on 01/03/2026.
//

#import "KKNumberFieldTextView.h"
#import "KKNumberField+Private.h"

static const unichar KKKeyEscape = 27;

@implementation KKNumberFieldTextView

- (void)mouseDown:(NSEvent *)event {
    if (!self.isEditable) {
        [self.parentField beginEditing];
        [self.window makeFirstResponder:self];
        [super mouseDown:event];
    } else {
        [super mouseDown:event];
    }
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // Capture arrow keys when editing — without this, arrows control the timeline scrubber.
    if (self.isEditable && event.type == NSEventTypeKeyDown) {
        NSString *chars = event.charactersIgnoringModifiers;
        if (chars.length == 1) {
            unichar c = [chars characterAtIndex:0];
            if (c == NSLeftArrowFunctionKey || c == NSRightArrowFunctionKey || c == NSUpArrowFunctionKey ||
                c == NSDownArrowFunctionKey) {
                [self interpretKeyEvents:@[ event ]];
                return YES;
            } else if (c == KKKeyEscape) {
                self.string = [self.parentField displayStringForEditing];
                [self.window makeFirstResponder:nil];
                return YES;
            }
        }
    }
    return [super performKeyEquivalent:event];
}

@end
