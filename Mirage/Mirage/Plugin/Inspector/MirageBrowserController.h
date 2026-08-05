/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <AppKit/AppKit.h>

@class KKTimelineLanesView;
@class MirageCatalogEntry;

NS_ASSUME_NONNULL_BEGIN

/// Shows the saved-shader browser (`MirageBrowserView`) as a chrome-less
/// companion panel beside the code-editor popover, riding the same
/// `KKPopoverKeepAlive` open/close notifications the Canvas layer list uses.
/// The Mirage inspector owns one and drives the row callbacks.
@interface MirageBrowserController : NSObject

- (instancetype)initWithLanesView:(KKTimelineLanesView *)lanesView;

/// Tear down (from the owner's dealloc): drop callbacks first, then hide.
- (void)invalidate;

/// Refresh the grid from the local catalog (e.g. after a Save).
- (void)reload;

/// Rebuild the grid without re-fetching the community list (local-only changes
/// like rename).
- (void)refreshLocal;

/// A card was clicked: load that template into the rack entry the strip has
/// SELECTED. One browser, one verb - adding a link to the chain is the "+"'s
/// job and never opens this.
@property(nonatomic, copy, nullable) void (^onSelectEntry)
    (MirageCatalogEntry *entry);
@property(nonatomic, copy, nullable) void (^onPublishEntry)
    (MirageCatalogEntry *entry);
@property(nonatomic, copy, nullable) void (^onDeleteEntry)
    (MirageCatalogEntry *entry);
@property(nonatomic, copy, nullable) void (^onRenameEntry)
    (MirageCatalogEntry *entry, NSString *name);

@end

NS_ASSUME_NONNULL_END
