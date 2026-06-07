/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKKeyPose, KKLane;

NS_ASSUME_NONNULL_BEGIN

/// One lane's static pose captured for the copy/paste clipboard: the numeric
/// values plus the spatial-curve state (spatialSmooth / inHandle / outHandle).
/// The outgoing interval (easing curve, modulation, link) is deliberately not
/// carried - that's a gap concept, not part of a keypose's pose.
@interface KKKeyposeClipboardEntry : NSObject

@property(nonatomic, readonly, copy) NSString *label;
@property(nonatomic, readonly) NSInteger valueType; // KKLaneValueType
@property(nonatomic, readonly, copy) NSArray<NSNumber *> *values;
@property(nonatomic, readonly) BOOL spatialSmooth;
@property(nonatomic, readonly, copy, nullable) NSArray<NSNumber *> *inHandle;
@property(nonatomic, readonly, copy, nullable) NSArray<NSNumber *> *outHandle;

/// YES when this entry may paste onto `lane`: same label, same valueType, and
/// the component count matches. The label gate is what makes pasting a Rotation
/// value onto a Scale keypose (or a foreign plugin's lanes) a no-op.
- (BOOL)matchesLane:(KKLane *)lane;

/// A copy of `keypose` with this entry's values + spatial state written in,
/// preserving the keypose's time and outgoing interval.
- (KKKeyPose *)applyToKeypose:(KKKeyPose *)keypose;

@end

/// Reads/writes keypose poses on the general pasteboard so copy/paste works
/// across clips and plugin instances (each FxPlug instance is its own XPC
/// process, so an in-memory buffer could never share - the pasteboard is the
/// only channel).
@interface KKKeyposeClipboard : NSObject

/// Build an entry capturing `keypose`'s pose, tagged with `lane`'s identity.
+ (KKKeyposeClipboardEntry *)entryForKeypose:(KKKeyPose *)keypose
                                        lane:(KKLane *)lane;

/// Replace the general pasteboard's contents with these entries.
+ (void)writeEntries:(NSArray<KKKeyposeClipboardEntry *> *)entries;

/// Entries on the pasteboard, or nil if it holds no (valid) keypose payload.
+ (nullable NSArray<KKKeyposeClipboardEntry *> *)readEntries;

@end

NS_ASSUME_NONNULL_END
