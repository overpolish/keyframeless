/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One step in a sequential guided tour. targetView is evaluated lazily at
/// display time — return nil to dim the host without a spotlight cutout.
@interface KKJoyrideStep : NSObject
+ (instancetype)stepWithMessage:(NSString *)message
                     targetView:(nullable NSView * (^)(void))targetView;
@property(nonatomic, copy) NSString *message;
@property(nonatomic, copy, nullable) NSView * (^targetView)(void);
/// Screen-space spotlight rect, evaluated each time the overlay redraws.
/// Takes precedence over targetView when non-nil. Return NSZeroRect to suppress
/// the cutout (e.g. position not known yet).
@property(nonatomic, copy, nullable) NSRect (^targetScreenRect)(void);
/// When YES the spotlight cutout is drawn as a circle (for circular OSC
/// handles).
@property(nonatomic) BOOL spotlightCircular;
/// When YES, clicks inside the spotlight pass through to the app below instead
/// of being forwarded to the XPC inspector window. Use for OSC / viewer steps.
@property(nonatomic) BOOL spotlightPassThrough;
/// When set, called on the main queue with the screen-space point of a
/// mouseDown inside the spotlight (instead of letting it fall through to FCP).
/// Use to drive plugin OSC methods directly without a Finder-activation trick.
@property(nonatomic, copy, nullable) void (^spotlightMouseDown)
    (NSPoint screenPoint);
/// Called on the main queue with each mouseDragged point while a
/// spotlightMouseDown-triggered drag is in progress.
@property(nonatomic, copy, nullable) void (^spotlightMouseDragged)
    (NSPoint screenPoint);
/// Called on the main queue with the mouseUp point after spotlightMouseDown.
@property(nonatomic, copy, nullable) void (^spotlightMouseUp)
    (NSPoint screenPoint);
/// Magnify (pinch) events are delivered to the frontmost window — the guide
/// panel — and `ignoresMouseEvents` does NOT pass gestures through (unlike
/// clicks/scroll), so they're dropped before reaching content below. When
/// set, the panel intercepts magnify events and hands them here so a step
/// can forward the pinch to its control (e.g. a mini-canvas zoom).
@property(nonatomic, copy, nullable) void (^spotlightMagnifyEvent)
    (NSEvent *event);
/// When set alongside targetScreenRect, the spotlight is drawn as a capsule
/// spanning from the primary targetScreenRect centre to this rect's centre.
/// Use for "drag from A to B" steps. Falls back to spotlightCircular behaviour
/// when this block returns NSZeroRect.
@property(nonatomic, copy, nullable) NSRect (^pillToScreenRect)(void);
/// When YES, the overlay shows a "Next" button to advance programmatically.
/// Use for informational steps; leave NO for steps that expect user action.
@property(nonatomic) BOOL showsNext;
/// Key character that auto-advances this step when pressed. Matched
/// case-insensitively against event.charactersIgnoringModifiers.
/// Nil means no key-triggered advance.
@property(nonatomic, copy, nullable) NSString *advanceOnCharacter;
/// Common modifier flags (shift/ctrl/opt/cmd) that must be held — and no
/// others — for advanceOnCharacter to fire. 0 means any modifiers are fine.
@property(nonatomic) NSEventModifierFlags advanceOnModifierFlags;
/// Step counter shown in the bubble. 0 = auto (1-based position in the steps
/// array). Set when one logical step should display as a different number
/// (e.g. a combined press→drag step that visually presents as two steps).
@property(nonatomic) NSInteger displayStepNumber;
/// Total step count shown in the bubble. 0 = auto (steps array count). Set to
/// keep a stable "N" while displayStepNumber changes within a single step.
@property(nonatomic) NSInteger displayTotalSteps;
/// Called once on the main queue when this step becomes active, just after its
/// (possibly empty) spotlight is shown. Fire-and-forget: use for an async
/// transition into the step — e.g. an OSC step that must zoom-to-fit the
/// viewer first. Have targetScreenRect return NSZeroRect until the work lands,
/// then call -refreshSpotlight (e.g. from a position observer) to reveal the
/// cutout. This is what lets one guide move between inspector and OSC steps.
@property(nonatomic, copy, nullable) void (^onEnter)(void);
@end

/// Drives a sequential guided tour over a host view. Each step shows a
/// spotlight overlay with a tooltip bubble and a next/done action button.
/// Plugins create one per guide, start it from a KKHelpGuide onStart block,
/// and retain it until onComplete fires.
@interface KKJoyrideController : NSObject

- (instancetype)initWithHostView:(NSView *)hostView NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Starts the sequential tour. onComplete fires after the final step's action
/// button is tapped or when -dismiss is called.
- (void)startWithSteps:(NSArray<KKJoyrideStep *> *)steps
            onComplete:(nullable void (^)(void))onComplete;

/// Advances to the next step. Call this when the user completes a step's
/// expected action. No-ops on the final step (use dismiss instead).
- (void)advance;

/// Ends the tour immediately and fires onComplete.
- (void)dismiss;

/// Redraws the current step's overlay. Call when a targetScreenRect block's
/// return value has changed (e.g. the OSC handle has moved on screen).
- (void)refreshSpotlight;

/// Updates the live overlay's tooltip text and step counter in place without
/// advancing (no panel/monitor rebuild). Use to make one continuous-gesture
/// step present as two visual steps — e.g. swap "Click…" → "Drag…" on
/// mousedown while the same press flows into the drag.
- (void)updateMessage:(NSString *)message stepNumber:(NSInteger)stepNumber;

@property(nonatomic, readonly) BOOL isActive;
/// 0-based index of the step currently being shown.
@property(nonatomic, readonly) NSInteger currentStepIndex;
/// Optional extra XPC window to forward cutout clicks to (e.g. a popover that
/// opens during the tour). Set before the step that spotlights content inside
/// it; clear when that window closes.
@property(nonatomic, weak, nullable) NSWindow *additionalPassthroughWindow;
/// Windows to set ignoresMouseEvents=YES for the duration of any
/// spotlightPassThrough step, so clicks fall through to the host app (FCP)
/// rather than being absorbed by ViewBridge XPC windows. Restored to NO on
/// each non-passthrough step and when the guide ends.
@property(nonatomic, copy, nullable)
    NSArray<NSWindow *> *hostPassthroughWindows;
/// Called each time a spotlightPassThrough step becomes the active step.
/// Use to activate the host app so click-throughs land as real events rather
/// than activation taps (e.g. [fcpApp activateWithOptions:...]).
@property(nonatomic, copy, nullable) void (^passthroughActivationHandler)(void);

/// When YES, the overlay panel does NOT set `ignoresMouseEvents` — so the
/// windowserver actually delivers gesture events (pinch/magnify) to the
/// panel, where `-sendEvent:` forwards them to the active step's
/// `spotlightMagnifyEvent`. Click-through still works (the global mouse
/// monitor + synthesize-into-target path doesn't depend on the panel
/// ignoring events, and the overlay's hitTest returns nil). Default NO —
/// only guides that need to forward gestures into scrollable content (e.g.
/// a mini-canvas) should set it. Set before `startWithSteps:`.
@property(nonatomic) BOOL forwardsGestures;

@end

NS_ASSUME_NONNULL_END
