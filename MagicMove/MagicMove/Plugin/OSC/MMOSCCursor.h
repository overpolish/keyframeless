/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <Foundation/Foundation.h>
@class NSCursor;

// FCP's own resize cursor art (extracted from LunaKit, bundled in Resources)
// for a box handle: 0-3 corners bottom-left, bottom-right, top-right, top-left
// map to the two diagonals; 4-7 edges bottom, right, top, left map to
// vertical/horizontal. nil for any other index. Falls back to AppKit cursors
// when the art is missing.
NSCursor *_Nullable MMResizeCursorForBoxHandle(NSInteger handleIndex);
