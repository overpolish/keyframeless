/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import "MMCombinedPose.h"
#import "MMScalePose.h"
@import InspectorControls;

@interface ICValueTextField (StyleTest)
- (void)styleFieldEditor;
@end
@interface EditorStyleField : ICValueTextField
@property(nonatomic, strong) NSTextView *testEditor;
@end
@implementation EditorStyleField
- (NSText *)currentEditor { return self.testEditor; }
@end
static void hostAccent(NSColor *color) {
  NSColor *rgb=[color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  assert(fabs(rgb.redComponent-0x5B/255.0)<1e-6);
  assert(fabs(rgb.greenComponent-0x5C/255.0)<1e-6);
  assert(fabs(rgb.blueComponent-0xE9/255.0)<1e-6);
}
// Exercise the production row and its attachment/refresh methods.
@interface MMCustomRow : NSView
@property(nonatomic, readonly) NSArray<NSTextField *> *fields;
@property(nonatomic, readonly) NSArray<NSTextField *> *axisLabels;
@property(nonatomic, readonly) NSArray<NSTextField *> *unitLabels;
@property(nonatomic, copy) CGSize (^imageSizeProvider)(void);
- (instancetype)initWithManager:(id<PROAPIAccessing>)manager;
- (void)refreshValues;
- (void)commitValue:(NSTextField *)field;
@property(nonatomic, readonly) NSButton *linkButton;
@property(nonatomic, readonly) NSTextField *titleLabel;
- (void)toggleProportional:(NSButton *)button;
@end
@interface RowHost : MockHost <FxCustomParameterActionAPI_v4>
@property NSSize imageSize;
@property NSUInteger starts;
@property NSUInteger ends;
@end
@implementation RowHost
- (instancetype)init { self=[super init]; if(self) _imageSize=NSMakeSize(100,100); return self; }
- (void)startAction:(id)sender { self.starts++; }
- (void)endAction:(id)sender { self.ends++; }
- (CMTime)currentTime { return kCMTimeZero; }
@end
@interface GeometryTile : FxImageTile
@property FxRect testBounds;
@property FxMatrix44 *testTransform;
@end
@implementation GeometryTile
- (FxRect)imagePixelBounds { return self.testBounds; }
- (FxMatrix44 *)inversePixelTransform { return self.testTransform; }
@end
@interface MagicMovePlugin (GeometryTest)
- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED;
- (BOOL)sourceTileRect:(FxRect *)rect sourceImageIndex:(NSUInteger)index
    sourceImages:(NSArray<FxImageTile *> *)sources destinationTileRect:(FxRect)tileRect
    destinationImage:(FxImageTile *)destination pluginState:(NSData *)state
    atTime:(CMTime)time error:(NSError **)error;
@end
static void publish(RowHost *host, double x, double y) {
  host.blobs[@(MMCustomControls)]=[[MMCombinedPose alloc] initWithPositionX:x positionY:y scale:100 authored:YES];
  MMRefreshCombinedPoseCache(host,kCMTimeZero);
}
static void displayed(MMCustomRow *row,double x,double y) {
  assert(row.fields[0].enabled && row.fields[1].enabled);
  assert(row.fields[0].stringValue.length && row.fields[1].stringValue.length);
  assert(row.fields[0].doubleValue==x && row.fields[1].doubleValue==y);
}
int main(int argc, const char *argv[]) {
 @autoreleasepool {
  [NSApplication sharedApplication];
  EditorStyleField *editorField=[EditorStyleField valueField];
  editorField.testEditor=[NSTextView new];
  [editorField styleFieldEditor];
  hostAccent(editorField.testEditor.insertionPointColor);
  NSColor *selection=editorField.testEditor.selectedTextAttributes[NSBackgroundColorAttributeName];
  hostAccent(selection); assert(fabs(selection.alphaComponent-0.3)<1e-6);
  NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,240,100)
      styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:YES];
  window.releasedWhenClosed=NO; // Never order the test window on screen.
  RowHost *host=[RowHost new];
  MMCustomRow *row=[[MMCustomRow alloc] initWithManager:host];
  row.imageSizeProvider = ^CGSize { return NSSizeToCGSize(host.imageSize); };
  for (NSTextField *field in row.fields) assert(!field.enabled && !field.stringValue.length);
  [window.contentView addSubview:row];
  NSUInteger reads=host.nativeKeyReads;
  [row refreshValues];
  for (NSTextField *field in row.fields) assert(!field.enabled && !field.stringValue.length);
  assert(host.nativeKeyReads==reads);

  publish(host,37,142);
  reads=host.nativeKeyReads;
  [row refreshValues]; displayed(row,37,142);
  assert(host.nativeKeyReads==reads);

  // A temporary failed snapshot retains the display but makes it uneditable.
  host.failReadParameter=MMCustomControls;
  MMRefreshCombinedPoseCache(host,kCMTimeZero);
  [row refreshValues];
  assert(!row.fields[0].enabled && !row.fields[1].enabled);
  assert(row.fields[0].doubleValue==37 && row.fields[1].doubleValue==142);
  host.failReadParameter=0;
  publish(host,0,100); [row refreshValues]; displayed(row,0,100);
  host.imageSize=NSMakeSize(1920,1080);
  publish(host,25,-50); [row refreshValues]; displayed(row,480,-540);
  NSUInteger groups=host.undoGroupsStarted;
  row.fields[0].doubleValue=960; [row commitValue:row.fields[0]];
  MMCombinedPose *edited=host.blobs[@(MMCustomControls)];
  assert(edited.positionX==50 && edited.positionY==-50);
  assert(host.undoGroupsStarted==groups+1 && host.undoGroupsStarted==host.undoGroupsEnded);
  ICValueTextField *scrub=(ICValueTextField *)row.fields[1];
  groups=host.undoGroupsStarted;
  scrub.onScrubBegin();
  scrub.doubleValue=108; [row commitValue:scrub];
  scrub.doubleValue=216; [row commitValue:scrub];
  scrub.onScrubEnd();
  edited=host.blobs[@(MMCustomControls)];
  assert(edited.positionX==50 && edited.positionY==20);
  assert(host.undoGroupsStarted==groups+1 && host.undoGroupsStarted==host.undoGroupsEnded);
  host.imageSize=NSZeroSize; [row refreshValues];
  assert(!row.fields[0].enabled && !row.fields[1].enabled);
  [row removeFromSuperview];

  // A newly recreated row must not inherit the old row's values or defaults.
  RowHost *other=[RowHost new];
  MMCustomRow *replacement=[[MMCustomRow alloc] initWithManager:other];
  replacement.imageSizeProvider = ^CGSize { return NSSizeToCGSize(other.imageSize); };
  for (NSTextField *field in replacement.fields) assert(!field.enabled && !field.stringValue.length);
  publish(other,0,175); // Cache ready before attachment; no timer turn required.
  reads=other.nativeKeyReads;
  [window.contentView addSubview:replacement];
  displayed(replacement,0,175);
  assert([replacement.fields[0].stringValue isEqualToString:@"0"]);
  assert([replacement.fields[1].stringValue isEqualToString:@"175"]);
  publish(other,162.037,-18.264); [replacement refreshValues];
  assert([replacement.fields[0].stringValue isEqualToString:@"162"]);
  assert([replacement.fields[1].stringValue isEqualToString:@"-18"]);
  assert(fabs([replacement.fields[0].objectValue doubleValue]-162.037)<1e-9);
  [replacement commitValue:replacement.fields[0]];
  assert(fabs(((MMCombinedPose *)other.blobs[@(MMCustomControls)]).positionX-162.037)<1e-9);
  reads=other.nativeKeyReads;
  assert(replacement.fields[0].tag==MMPositionX && replacement.fields[1].tag==MMPositionY);
  replacement.frame=NSMakeRect(0,0,340,24);
  [replacement layoutSubtreeIfNeeded];
  assert(NSMaxX(replacement.fields[0].frame) < NSMinX(replacement.fields[1].frame));
  assert(NSMaxX(replacement.fields[1].frame) <= NSWidth(replacement.bounds));
  NSTextField *label=nil;
  for (NSView *v in replacement.subviews)
    if ([v isKindOfClass:NSTextField.class] && [[(NSTextField *)v stringValue] isEqualToString:@"Position"])
      label=(NSTextField *)v;
  assert(label && NSMinX(label.frame)==21 && label.font.pointSize==11);
  assert(NSMinY(replacement.fields[0].frame)==NSMinY(label.frame)-2);
  NSUInteger suffixes=0;
  for (NSView *v in replacement.subviews) {
    if (![v isKindOfClass:NSTextField.class]) continue;
    NSTextField *text=(NSTextField *)v;
    if ([text.stringValue isEqualToString:@"px"]) {
      suffixes++; assert(text.font.pointSize==11);
      NSColor *color=[text.textColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
      assert(fabs(color.redComponent-179.0/255.0)<0.001);
    }
  }
  assert(suffixes==2 && replacement.fields[0].font.pointSize==11);
  CGFloat previousFieldWidth=0;
  for (NSNumber *width in @[@320, @403, @500]) {
    replacement.frame=NSMakeRect(0,0,width.doubleValue,24);
    [replacement setNeedsLayout:YES]; [replacement layoutSubtreeIfNeeded];
    assert(NSMaxX(replacement.fields[1].frame) <= width.doubleValue-75);
    assert(NSMaxX(label.frame) < NSMinX(replacement.fields[0].frame));
    assert(NSWidth(replacement.fields[0].frame)>previousFieldWidth);
    previousFieldWidth=NSWidth(replacement.fields[0].frame);
    assert(NSMinX(replacement.axisLabels[1].frame)-NSMaxX(replacement.unitLabels[0].frame)==14);
  }
  reads=other.nativeKeyReads;
  if (argc>1) {
    replacement.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSBitmapImageRep *rep=[replacement bitmapImageRepForCachingDisplayInRect:replacement.bounds];
    [replacement cacheDisplayInRect:replacement.bounds toBitmapImageRep:rep];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(argv[1]) atomically:YES];
  }
  assert(other.nativeKeyReads==reads);
  assert(host.starts==host.ends && other.starts==other.ends);
  [replacement removeFromSuperview];
  // Exercise the production image callback -> plugin -> inspector path with
  // no OSC geometry API, a half-resolution image and a smaller requested tile.
  RowHost *geometryHost=[RowHost new];
  geometryHost.missingProtocols=[NSSet setWithObject:@"FxOnScreenControlAPI_v2"];
  MagicMovePlugin *plugin=[[MagicMovePlugin alloc] initWithAPIManager:geometryHost];
  MMCustomRow *geometryRow=(MMCustomRow *)[plugin createViewForParameterID:MMCustomControls];
  publish(geometryHost,25,-50);
  [window.contentView addSubview:geometryRow];
  assert(!geometryRow.fields[0].enabled);
  GeometryTile *tile=[GeometryTile new];
  tile.testBounds=(FxRect){.left=0,.right=960,.bottom=0,.top=540};
  Matrix44Data matrix={{2,0,0,0},{0,2,0,0},{0,0,1,0},{0,0,0,1}};
  tile.testTransform=[[FxMatrix44 alloc] initWithMatrix44Data:matrix];
  FxRect sourceRect;
  assert([plugin sourceTileRect:&sourceRect sourceImageIndex:0 sourceImages:@[tile]
      destinationTileRect:((FxRect){.left=0,.right=100,.bottom=0,.top=100})
      destinationImage:tile pluginState:nil atTime:kCMTimeZero error:nil]);
  [geometryRow refreshValues]; displayed(geometryRow,480,-540);
  geometryRow.fields[0].doubleValue=960; [geometryRow commitValue:geometryRow.fields[0]];
  assert(((MMCombinedPose *)geometryHost.blobs[@(MMCustomControls)]).positionX==50);
  [geometryRow removeFromSuperview];
  // A recreated row can use dimensions from before it was attached.
  geometryRow=(MMCustomRow *)[plugin createViewForParameterID:MMCustomControls];
  publish(geometryHost,50,-50);
  [window.contentView addSubview:geometryRow]; displayed(geometryRow,960,-540);
  [geometryRow removeFromSuperview];
  RowHost *scaleHost=[RowHost new];
  MagicMovePlugin *scalePlugin=[[MagicMovePlugin alloc] initWithAPIManager:scaleHost];
  scaleHost.plugin=scalePlugin;
  assert([scalePlugin addParametersWithError:nil]);
  MMCustomRow *scaleRow=(MMCustomRow *)[scalePlugin createViewForParameterID:MMScaleControls];
  [window.contentView addSubview:scaleRow];
  [scaleRow refreshValues]; displayed(scaleRow,100,100);
  assert(scaleRow.linkButton.state==NSControlStateValueOn);
  hostAccent(scaleRow.linkButton.contentTintColor);
  [scaleRow setNeedsLayout:YES]; [scaleRow layoutSubtreeIfNeeded];
  CGFloat glyphCenter=NSMaxY(scaleRow.titleLabel.frame)-scaleRow.titleLabel.firstBaselineOffsetFromTop
      +scaleRow.titleLabel.font.capHeight/2;
  assert(fabs(NSMidY(scaleRow.linkButton.frame)-glyphCenter)<=0.25);
  assert(NSMinY(scaleRow.fields[0].frame)==NSMinY(scaleRow.titleLabel.frame)-2);
  assert([scaleRow.unitLabels[0].stringValue isEqualToString:@"%"]);
  assert([scaleRow.fields[0].stringValue isEqualToString:@"100.0"]);
  MMCustomRow *positionRow=(MMCustomRow *)[scalePlugin createViewForParameterID:MMCustomControls];
  // Opening Position must not replace Scale's cache token.
  NSUInteger scaleReads=scaleHost.nativeKeyReads;
  [scaleRow refreshValues]; displayed(scaleRow,100,100);
  assert(scaleHost.nativeKeyReads==scaleReads);
  MMCombinedPose *positionBefore=scaleHost.blobs[@(MMCustomControls)];
  NSUInteger scaleGroups=scaleHost.undoGroupsStarted;
  scaleRow.fields[0].doubleValue=150; [scaleRow commitValue:scaleRow.fields[0]];
  assert(scaleRow.fields[1].doubleValue==150); // linked partner updates immediately
  assert(scaleHost.undoGroupsStarted==scaleGroups+1 && scaleHost.undoDepth==0);
  assert([positionBefore isEqual:scaleHost.blobs[@(MMCustomControls)]]);
  [scaleRow toggleProportional:scaleRow.linkButton];
  assert(scaleRow.linkButton.state==NSControlStateValueOff);
  assert([scaleRow.linkButton.contentTintColor isEqual:ICInspectorTokens.inactiveControlColor]);
  scaleRow.fields[1].doubleValue=75; [scaleRow commitValue:scaleRow.fields[1]];
  MMScalePose *scalePose=scaleHost.blobs[@(MMScaleControls)];
  assert(scalePose.x==150 && scalePose.y==75);
  [scaleRow toggleProportional:scaleRow.linkButton];
  ICValueTextField *scaleField=(ICValueTextField *)scaleRow.fields[0];
  scaleGroups=scaleHost.undoGroupsStarted;
  scaleField.onScrubBegin();
  scaleField.doubleValue=180; [scaleRow commitValue:scaleField];
  scaleField.doubleValue=200; [scaleRow commitValue:scaleField];
  scaleField.onScrubEnd();
  assert(scaleHost.undoGroupsStarted==scaleGroups+1 && scaleHost.undoDepth==0);
  scalePose=scaleHost.blobs[@(MMScaleControls)];
  assert(scalePose.x==200 && scalePose.y==100);
  assert(scaleHost.starts==scaleHost.ends);
  [scaleRow removeFromSuperview];
  (void)positionRow;
  [window close];
  puts("Custom row: empty loading state, delayed values, immediate attachment refresh, zero values, unavailable snapshots and no refresh keyframe reads passed");
 }
}
