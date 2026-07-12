/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <AppKit/AppKit.h>

@class KKTimelineLanesView;
@class ShaderCatalogEntry;

NS_ASSUME_NONNULL_BEGIN

/// Shows the saved-shader browser (`ShaderBrowserView`) as a chrome-less
/// companion panel beside the code-editor popover, riding the same
/// `KKPopoverKeepAlive` open/close notifications the Canvas layer list uses.
/// The Shader inspector owns one and drives the row callbacks.
@interface ShaderBrowserController : NSObject

- (instancetype)initWithLanesView:(KKTimelineLanesView *)lanesView;

/// Tear down (from the owner's dealloc): drop callbacks first, then hide.
- (void)invalidate;

/// Refresh the grid from the local catalog (e.g. after a Save).
- (void)reload;

/// Rebuild the grid without re-fetching the community list (local-only changes
/// like rename).
- (void)refreshLocal;

@property(nonatomic, copy, nullable) void (^onSelectEntry)
    (ShaderCatalogEntry *entry);
@property(nonatomic, copy, nullable) void (^onPublishEntry)
    (ShaderCatalogEntry *entry);
@property(nonatomic, copy, nullable) void (^onDeleteEntry)
    (ShaderCatalogEntry *entry);
@property(nonatomic, copy, nullable) void (^onRenameEntry)
    (ShaderCatalogEntry *entry, NSString *name);

@end

NS_ASSUME_NONNULL_END
