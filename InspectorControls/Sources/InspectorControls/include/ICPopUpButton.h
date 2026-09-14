/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN
// Native popup interaction with inspector readout styling. The trailing 16 pt
// decoration column matches a standard inspector suffix; the title is right aligned.
// Populate/select items and use target/action through the normal NSPopUpButton API.
@interface ICPopUpButton : NSPopUpButton
// True through native menu tracking and delivery of its selection action.
@property(nonatomic, readonly, getter=isInteracting) BOOL interacting;
@property(nonatomic, copy, nullable) NSMenu * _Nullable (^contextMenuProvider)(void);
@end
NS_ASSUME_NONNULL_END
