/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@class FxImageTile;
@protocol PROAPIAccessing;

NS_ASSUME_NONNULL_BEGIN

@interface KKToolbarItem : NSObject
@property(nonatomic, copy) NSString *iconName;
@property(nonatomic, copy, nullable) NSString *shortcutLabel;
/// Optional already-localized hover tooltip. Shown as a bubble above the button
/// while the host reports this item as `hoveredTag`. Lets compact icon-only
/// buttons carry a localized name without a width-constrained inline label.
@property(nonatomic, copy, nullable) NSString *tooltip;
@property(nonatomic, assign) NSInteger tag;
/// A thin vertical divider rather than a button: no icon/label/highlight, not
/// hit-testable (clicks fall through to the toolbar body). Use to group items.
@property(nonatomic, assign) BOOL isSeparator;
/// A non-interactive vertical divider between item groups.
+ (instancetype)separator;
/// Override item width (0 = use default). Use for compact or wide items.
@property(nonatomic, assign) CGFloat customWidth;
/// Override item height (0 = use default). Use for compact items.
@property(nonatomic, assign) CGFloat customHeight;
/// Vertical offset for the icon in ioSurface coords (negative = up).
@property(nonatomic, assign) CGFloat iconYOffset;
/// Override the icon tint (nil = the default light grey).
@property(nonatomic, strong, nullable) NSColor *iconColor;
/// Override the icon point size (0 = the default).
@property(nonatomic, assign) CGFloat iconPointSize;
+ (instancetype)itemWithIcon:(NSString *)sfSymbolName
                         tag:(NSInteger)tag
               shortcutLabel:(nullable NSString *)shortcutLabel;
@end

@interface KKToolbar : NSObject

/// Scales every drawn dimension (buttons, icons, labels, padding, tooltip) and
/// the hit-test rects by this factor. Default 1.0 (the viewer). The mini-viewer
/// sets it < 1 so the same bar fits its small surface, the way the shared OSC
/// glyphs scale with the popover size.
@property(nonatomic, assign) CGFloat uiScale;

/// Mirror the drawn bar vertically about its own centre. Default NO (the FxPlug
/// viewer surface). The mini-viewer's MTKView pass is Y-flipped relative to that
/// surface, so it sets YES to keep glyph content + the per-button layout upright
/// without moving the bar.
@property(nonatomic, assign) BOOL flipVertical;

/// Override the divider (separator) tint. Default nil = the built-in mid-grey.
/// Set it to match a custom handle/icon tint so the dividers read as part of the
/// same chrome.
@property(nonatomic, strong, nullable) NSColor *separatorColor;

/// Tag of the currently active item (0 = no highlight).
@property(nonatomic, assign) NSInteger activeTag;

/// Optional second active tag for independent toggle highlights (0 = none).
@property(nonatomic, assign) NSInteger secondaryActiveTag;

/// Optional third active tag for independent toggle highlights (0 = none).
@property(nonatomic, assign) NSInteger tertiaryActiveTag;

/// Optional set of highlighted item tags (NSNumbers), for bars with more than
/// three independent highlights (e.g. a radio tool + several grid toggles). An
/// item highlights if its tag is here OR matches active/secondary/tertiary.
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *activeTags;

/// Extra margin from the bottom edge in points (default 8).
@property(nonatomic, assign) CGFloat bottomMargin;

/// When >= 0, align the toolbar to the right edge with this margin (default -1
/// = centered).
@property(nonatomic, assign) CGFloat rightMargin;

/// When YES, the toolbar is positioned freely at `anchorCenter` (its centre, in
/// ioSurface coords, clamped to stay fully on-screen) instead of the anchored
/// bottom/right margins - for a user-draggable, persisted toolbar. Default NO.
@property(nonatomic, assign) BOOL usesAnchorCenter;

/// The free centre (ioSurface coords, Y-down) used when `usesAnchorCenter`.
@property(nonatomic, assign) CGPoint anchorCenter;

/// Tag of the item the pointer is hovering (0 = none). The host sets this from
/// its mouse-moved hit-test; the draw shows that item's `tooltip` bubble.
@property(nonatomic, assign) NSInteger hoveredTag;

/// The toolbar items (read-only).
@property(nonatomic, readonly) NSArray<KKToolbarItem *> *items;

/// Frame of the toolbar after the last draw (ioSurface coords, Y-down).
@property(nonatomic, readonly) NSRect toolbarFrame;

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                             items:(NSArray<KKToolbarItem *> *)items;

/// Draw the toolbar onto an FxPlug destination tile (the viewer OSC surface).
/// Call every frame.
- (void)drawWithDestinationImage:(FxImageTile *)destinationImage;

/// Draw the toolbar into an encoder that's already in a render pass (e.g. the
/// mini-viewer's MTKView pass), reusing the exact same layout + textures. The
/// caller supplies a KKVertexShader/KKLabelFragment pipeline built for the
/// target's pixel format, and the viewport size in target pixels. Lets the mini
/// render the same bar as the viewer (the shared-OSC pattern).
- (void)drawInEncoder:(id<MTLRenderCommandEncoder>)encoder
               device:(id<MTLDevice>)device
             pipeline:(id<MTLRenderPipelineState>)pipeline
        viewportWidth:(float)width
               height:(float)height;

/// The button rect for the item at the given index (ioSurface coords).
- (NSRect)buttonRectAtIndex:(NSUInteger)index;

/// Hit test. Returns the item tag or 0 if not hit.
- (NSInteger)hitTestAtX:(double)x y:(double)y;

@end

NS_ASSUME_NONNULL_END
