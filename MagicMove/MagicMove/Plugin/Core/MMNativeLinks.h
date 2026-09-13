/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
// These operations use custom native pose lanes, independently of legacy links.
// Call inside a host action; menu/timing callers own their undo group.
BOOL MMSetNativePropertyLink(id<PROAPIAccessing> manager, UInt32 sourceID,
                             UInt32 partnerID, CMTime playhead, BOOL linked);
BOOL MMNativePropertyLinked(id<PROAPIAccessing> manager, UInt32 parameter,
                            CMTime playhead);
BOOL MMWriteNativeLinkedPose(id<PROAPIAccessing> manager, UInt32 parameter,
                             CMTime time, id pose);
// Callback snapshots prepare moves without writing; release applies the latest
// move once, so host drags retain capture and never recursively move partners.
void MMObserveNativeLinks(id<PROAPIAccessing> manager, UInt32 parameter,
                          BOOL mouseDown);
BOOL MMCommitNativeLinkMoves(id<PROAPIAccessing> manager, BOOL mouseDown,
                             NSError **error);
BOOL MMHasPendingNativeLinkMoves(id<PROAPIAccessing> manager);
NSMenu *MMNativePropertyMenu(id<PROAPIAccessing> manager, NSView *sender,
                             UInt32 parameter);

// Stable per-group gutter tint; nil when this property has no linked group.
NSColor *MMNativePropertyLinkColor(id<PROAPIAccessing> manager, UInt32 parameter, CMTime playhead);
