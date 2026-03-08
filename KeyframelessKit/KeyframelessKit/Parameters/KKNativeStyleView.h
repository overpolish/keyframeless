/* KeyframelessKit - Shared framework for the Keyframeless FxPlug library
 * Copyright (C) 2026 overpolish
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#import <Cocoa/Cocoa.h>
#include <MacTypes.h>

@protocol PROAPIAccessing;

@interface KKNativeStyleView : NSView

@property(nonatomic, strong) id<PROAPIAccessing> apiManager;
@property(nonatomic, assign) UInt32 parameterId;

- (instancetype)initWithFrame:(NSRect)frame
                   apiManager:(id<PROAPIAccessing>)apiManager
                  parameterId:(UInt32)parameterId;

@end
