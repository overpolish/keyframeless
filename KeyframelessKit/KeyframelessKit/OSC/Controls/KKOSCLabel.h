/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <KeyframelessKit/KKOnScreenControl.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKOSCLabel : NSObject

/// The text to display. Changing this invalidates the cached texture.
@property(nonatomic, copy) NSString *text;

/// When YES, uses a monospaced font. Default NO.
@property(nonatomic) BOOL monospaced;

/// Logical size of the rendered label in canvas units.
@property(nonatomic, readonly) CGSize size;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager;

/// Draw the label centered at the given canvas position.
- (void)drawAtCanvasPosition:(CGPoint)canvasPosition
            destinationImage:(FxImageTile *)destinationImage;

@end

NS_ASSUME_NONNULL_END
