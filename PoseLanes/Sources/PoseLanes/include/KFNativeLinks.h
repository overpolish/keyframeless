/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
// These operations use custom native pose lanes, independently of legacy links.
// Call inside a host action; menu/timing callers own their undo group.
BOOL KFSetNativePropertyLink(id<PROAPIAccessing> manager, UInt32 sourceID,
                             UInt32 partnerID, CMTime playhead, BOOL linked);
BOOL KFNativePropertyLinked(id<PROAPIAccessing> manager, UInt32 parameter,
                            CMTime playhead);
BOOL KFWriteNativeLinkedPose(id<PROAPIAccessing> manager, UInt32 parameter,
                             CMTime time, id pose);
// Callback snapshots prepare moves without writing; release applies the latest
// move once, so host drags retain capture and never recursively move partners.
void KFObserveNativeLinks(id<PROAPIAccessing> manager, UInt32 parameter,
                          BOOL mouseDown);
BOOL KFCommitNativeLinkMoves(id<PROAPIAccessing> manager, BOOL mouseDown,
                             NSError **error);
BOOL KFHasPendingNativeLinkMoves(id<PROAPIAccessing> manager);
NSMenu *KFNativePropertyMenu(id<PROAPIAccessing> manager, NSView *sender,
                             UInt32 parameter);

// Stable per-group gutter tint; nil when this property has no linked group.
NSColor *KFNativePropertyLinkColor(id<PROAPIAccessing> manager, UInt32 parameter, CMTime playhead);

// Seed creation tracking before a native callback replaces the cached snapshot.
void KFPrimeDefaultKeyTracker(id<PROAPIAccessing> manager, UInt32 parameter);
