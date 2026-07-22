/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Private declarations shared between the Mirage browser's parts: the item
// model, the card view, its field subclasses, and the owner protocol. Not a
// public header - only MirageBrowserView.m / MirageCard.m /
// MirageBrowserFields.m include it.

#import <Cocoa/Cocoa.h>

@class MirageCatalogEntry;
@class KKCommunityEntry;

NS_ASSUME_NONNULL_BEGIN

/// The card's name-row height. Both the card layout and the grid's per-card
/// height need it, so it's declared here and defined in each.
extern const CGFloat kMirageCardNameH;

typedef NS_ENUM(NSInteger, _MirageItemKind) {
  _MirageItemBuiltin,   // shipped starter (favourite only)
  _MirageItemLocal,     // user-saved custom (delete + publish + rename)
  _MirageItemInstalled, // downloaded community, offline (uninstall + update)
  _MirageItemRemote     // community not installed (download)
};

@interface _MirageBrowserItem : NSObject
@property(nonatomic) _MirageItemKind kind;
@property(nonatomic, copy) NSString *entryID;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSString *author;
/// A MirageCategory.h id, already normalised. Drives the card's type badge and
/// the header's category filter.
@property(nonatomic, copy) NSString *category;
@property(nonatomic, strong, nullable) NSImage *thumbnail;
@property(nonatomic)
    BOOL updateAvailable; // installed + remote has newer version
@property(nonatomic, strong, nullable) MirageCatalogEntry *localEntry;
@property(nonatomic, strong, nullable) KKCommunityEntry *communityEntry;
@end

// The scroll's document view. Flipped so cards anchor at the top, and it
// reports its laid-out card height as its intrinsic size so KKPaddedScrollView
// (which pins width + top, not height) grows it and drives its edge fades.
@interface _MirageFlippedView : NSView
@property(nonatomic) CGFloat contentHeight;
@end

// The card name field, editable inline. In a ViewBridge panel key events arrive
// as key equivalents, not keyDown, so forward them to the field editor (the
// Canvas layer-list rename fix), else typing does nothing.
@interface _MirageRenameField : NSTextField
@end

// Search field with the same focus behaviour as the shader name field: don't
// grab focus from the key-view loop on open (only from a real click on the
// field), act on the first click even when the panel isn't key, and forward key
// equivalents to the field editor so typing works in the ViewBridge popover.
@interface _MirageSearchField : NSSearchField
@end

@class _MirageCard;
@protocol _MirageCardOwner
- (void)cardClicked:(_MirageCard *)card;
- (void)cardPublish:(_MirageCard *)card;
- (void)cardDelete:(_MirageCard *)card;
- (void)cardDownload:(_MirageCard *)card;
- (void)cardToggleFavorite:(_MirageCard *)card;
- (void)cardRename:(_MirageCard *)card toName:(NSString *)name;
- (void)card:(_MirageCard *)card didBeginRename:(BOOL)renaming;
@end

// One card: thumbnail + name, with hover buttons (delete top-left, favourite
// top-right, action bottom-right).
@interface _MirageCard : NSView <NSTextFieldDelegate, NSViewToolTipOwner>
@property(nonatomic, strong) _MirageBrowserItem *item;
@property(nonatomic, weak) id<_MirageCardOwner> owner;
@property(nonatomic) BOOL favorite;
- (instancetype)initWithItem:(_MirageBrowserItem *)item width:(CGFloat)width;
- (void)setHovered:(BOOL)hovered;
/// The pointer's position in this card's coordinates, on every move while it is
/// the hovered card. Drives the author badge's expand, which needs per-move
/// resolution rather than just card enter/exit. (Tracking areas would be the
/// obvious tool, but the browser already tracks hover with a global monitor -
/// this panel is a nonactivating ViewBridge child window.)
- (void)setHoverPoint:(NSPoint)point;
- (void)setThumbnail:(NSImage *)image;
@end

NS_ASSUME_NONNULL_END
