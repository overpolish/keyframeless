/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The ONE rule set for OSC element visibility (master tick, per-element
/// pills, Opt-hold reveal/peek, ghost dimming, dot-hierarchy compounds).
/// Both frontends - the viewer's KKOnScreenControl visibility category and
/// KKMiniViewerRenderer - assemble a KKOSCVisibilityState from their own
/// storage and route every visibility decision through these functions, so
/// the two surfaces cannot drift. Add new rules HERE, never inline in a
/// frontend.
typedef struct {
  /// Handles locked out entirely (the mini-viewer's boundary lock). Nothing
  /// shows or reveals. The viewer has no lock concept - pass NO.
  BOOL locked;
  /// The master visibility tick is OFF (viewer: !oscMasterVisible; mini:
  /// handlesHidden).
  BOOL masterOff;
  /// Opt-hold reveal is engaged (Opt held, the host wired the toggle, and not
  /// locked).
  BOOL revealActive;
} KKOSCVisibilityState;

/// Dim alpha for a revealed-but-hidden ghost element.
FOUNDATION_EXPORT const float kKKOSCGhostAlpha;

/// "Peek and use": master off + Opt held. Every enabled control reveals fully
/// interactive at FULL alpha (usable, not a dimmed re-show target).
FOUNDATION_EXPORT BOOL KKOSCVisibilityPeek(KKOSCVisibilityState s);

/// The element is ENABLED by configuration (master on and not individually
/// hidden) - the plain visibility check, independent of any transient reveal.
FOUNDATION_EXPORT BOOL KKOSCVisibilityEnabled(KKOSCVisibilityState s,
                                              BOOL individuallyHidden);

/// The element is drawn + hit-tested THIS FRAME.
///   master on  : visible unless individually hidden; Opt-hold also reveals a
///                hidden one as a dim ghost (so an Opt-click can re-show it).
///   master off : Opt-hold "peek" shows ONLY the elements left enabled - the
///                ones you turned off stay off (peek mirrors a flip back to
///                master-on, respecting the per-element config).
FOUNDATION_EXPORT BOOL KKOSCVisibilityShown(KKOSCVisibilityState s,
                                            BOOL individuallyHidden);

/// The element is a reveal target under Opt-hold: with the master on that is
/// the elements you HID (ghosts to re-show); with the master off it is the
/// elements left ENABLED (the peek set).
FOUNDATION_EXPORT BOOL KKOSCVisibilityRevealEligible(KKOSCVisibilityState s,
                                                     BOOL individuallyHidden);

/// Draw alpha for an element given whether it is user-hidden (master off or
/// its own pill off): full in peek mode, dimmed ghost when user-hidden,
/// otherwise full.
FOUNDATION_EXPORT float KKOSCVisibilityGhostAlpha(KKOSCVisibilityState s,
                                                  BOOL userHidden);

/// Whether `label` is hidden by the per-element set, INCLUDING the dot
/// hierarchy: an ancestor being hidden hides its children ("Rotation" hides
/// "Rotation.X"), mirroring the inspector compound pills.
FOUNDATION_EXPORT BOOL KKOSCLabelHiddenInSet(NSSet<NSString *> *_Nullable set,
                                             NSString *_Nullable label);

NS_ASSUME_NONNULL_END
