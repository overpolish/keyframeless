/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKMiniViewerRenderer.h>
#import <KeyframelessKit/KKMiniViewerView.h>

NS_ASSUME_NONNULL_BEGIN

/// Shared base for the mini-viewer radial-extent OSC sets (KKRingOSCSet /
/// KKBoxOSCSet). A ring and a box have an IDENTICAL value model - a field
/// normalized 0..1 over [min,max], centred on an object point (or a linked
/// #point), aspect-lockable - and differ only in geometry, drawing, and
/// interaction. This base owns the spec store and those shared value / centre /
/// aspect-lock reads (all through the host KKMiniViewerRenderer's public
/// hooks), so a new radial OSC only implements its own geometry + draw + drag.
/// Abstract: not instantiated directly.
@interface KKRadialOSCSet : NSObject

- (instancetype)initWithRenderer:(KKMiniViewerRenderer *)renderer
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// The lane labels, in order.
@property(nonatomic, copy, readonly) NSArray<NSString *> *labels;

@end

NS_ASSUME_NONNULL_END
