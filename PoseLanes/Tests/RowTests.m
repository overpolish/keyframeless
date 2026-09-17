/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "TestLanes.h"
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
// Exercise the production rows and their attachment/refresh methods.
@interface KFVectorRow (RowTests)
- (void)refreshValues;
@end
@interface KFScalarRow (RowTests)
- (void)refreshValues;
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
static id<KFPropertyPose> lanePose(KFPropertyLane *lane, NSArray<NSNumber *> *values) {
  return [lane.defaultPose poseByReplacingValues:values authored:YES easing:MTEasingSmooth
                                     addedMotion:MTAddedMotionNone timing:[KFPoseTiming new]];
}
static void publish(RowHost *host, double x, double y) {
  host.blobs[@(KFTestPosition)]=lanePose(KFTestPositionLane(), @[@(x), @(y)]);
  [KFTestPositionLane() refreshCacheForManager:host time:kCMTimeZero];
}
static void displayed(ICInspectorRow *row,double x,double y) {
  assert(row.fields[0].enabled && row.fields[1].enabled);
  assert(row.fields[0].stringValue.length && row.fields[1].stringValue.length);
  assert(row.fields[0].doubleValue==x && row.fields[1].doubleValue==y);
}
int main(int argc, const char *argv[]) {
 @autoreleasepool {
  KFTestRegisterLanes();
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
  // Rows are created by the plugin, which owns the view caches.
  KFTestEffect *rowPlugin=[[KFTestEffect alloc] initWithAPIManager:host]; host.plugin=rowPlugin;
  // Position reads in pixels, which the image callbacks publish on the plugin.
  rowPlugin.inspectorImageSize=CGSizeMake(100,100);
  KFVectorRow *row=(KFVectorRow *)[rowPlugin createViewForParameterID:KFTestPosition];
  for (NSTextField *field in row.fields) assert(!field.enabled && !field.stringValue.length);
  [window.contentView addSubview:row];
  NSUInteger reads=host.nativeKeyReads;
  [row refreshValues];
  // With no payload saved the host serves the lane default, which the row
  // shows in pixels without enumerating keys.
  for (ICValueTextField *field in row.fields) assert(field.enabled && field.doubleValue==0);
  assert(host.nativeKeyReads==reads);

  publish(host,37,142);
  reads=host.nativeKeyReads;
  [row refreshValues]; displayed(row,37,142);
  assert(host.nativeKeyReads==reads);

  // A temporary failed snapshot retains the display but makes it uneditable.
  host.failReadParameter=KFTestPosition;
  [KFTestPositionLane() refreshCacheForManager:host time:kCMTimeZero];
  [row refreshValues];
  assert(!row.fields[0].enabled && !row.fields[1].enabled);
  assert(row.fields[0].doubleValue==37 && row.fields[1].doubleValue==142);
  host.failReadParameter=0;
  publish(host,0,100); [row refreshValues]; displayed(row,0,100);
  host.plugin.inspectorImageSize=CGSizeMake(1920,1080);
  publish(host,25,-50); [row refreshValues]; displayed(row,480,-540);
  NSUInteger groups=host.undoGroupsStarted;
  row.fields[0].doubleValue=960; row.onValueCommit(row.fields[0]);
  id<KFPropertyPose> edited=host.blobs[@(KFTestPosition)];
  assert(edited.values[0].doubleValue==50 && edited.values[1].doubleValue==-50);
  assert(host.undoGroupsStarted==groups+1 && host.undoGroupsStarted==host.undoGroupsEnded);
  ICValueTextField *scrub=(ICValueTextField *)row.fields[1];
  groups=host.undoGroupsStarted;
  scrub.onScrubBegin();
  scrub.doubleValue=108; row.onValueCommit(scrub);
  scrub.doubleValue=216; row.onValueCommit(scrub);
  scrub.onScrubEnd();
  edited=host.blobs[@(KFTestPosition)];
  assert(edited.values[0].doubleValue==50 && edited.values[1].doubleValue==20);
  assert(host.undoGroupsStarted==groups+1 && host.undoGroupsStarted==host.undoGroupsEnded);
  host.plugin.inspectorImageSize=CGSizeZero; [row refreshValues];
  assert(!row.fields[0].enabled && !row.fields[1].enabled);
  [row removeFromSuperview];

  // Rebuilding rows must not re-announce cache tokens: Motion rebuilds every
  // row several times per selection and each write is a host round trip.
  NSString *combinedToken=nil, *scaleToken=nil;
  assert([host getStringParameterValue:&combinedToken fromParameter:KFTestPositionCacheToken] && combinedToken.length);
  assert([host getStringParameterValue:&scaleToken fromParameter:KFTestScaleCacheToken] && scaleToken.length);
  NSUInteger starts=host.starts;
  for (NSNumber *identifier in @[@(KFTestPosition),@(KFTestScale),@(KFTestOpacity),@(KFTestRotation)]) {
    NSView *rebuilt=[rowPlugin createViewForParameterID:identifier.unsignedIntValue];
    assert(rebuilt);
  }
  assert(host.starts==starts);
  NSString *token=nil;
  assert([host getStringParameterValue:&token fromParameter:KFTestPositionCacheToken] && [token isEqual:combinedToken]);
  assert([host getStringParameterValue:&token fromParameter:KFTestScaleCacheToken] && [token isEqual:scaleToken]);
  // The rebuilt rows still read the live cache.
  KFVectorRow *rebuiltPosition=(KFVectorRow *)[rowPlugin createViewForParameterID:KFTestPosition];
  host.plugin.inspectorImageSize=CGSizeMake(1920,1080);
  publish(host,25,-50);
  [window.contentView addSubview:rebuiltPosition];
  [rebuiltPosition refreshValues]; displayed(rebuiltPosition,480,-540);
  [rebuiltPosition removeFromSuperview];

  // The shared clock refreshes every attached view from one host action; each
  // view opening its own is what made selection expensive.
  host.plugin.inspectorImageSize=CGSizeMake(1920,1080);
  publish(host,25,-50);
  KFVectorRow *clockPosition=(KFVectorRow *)[rowPlugin createViewForParameterID:KFTestPosition];
  KFScalarRow *clockOpacity=(KFScalarRow *)[rowPlugin createViewForParameterID:KFTestOpacity];
  [window.contentView addSubview:clockPosition];
  [window.contentView addSubview:clockOpacity];
  clockPosition.fields[0].doubleValue=0;
  starts=host.starts;
  [rowPlugin.inspectorClock refreshNow];
  assert(host.starts==starts+1);
  displayed(clockPosition,480,-540);
  // Views leaving their window stop being refreshed.
  [clockPosition removeFromSuperview];
  [clockOpacity removeFromSuperview];
  starts=host.starts;
  [rowPlugin.inspectorClock refreshNow];
  assert(host.starts==starts);

  // A newly recreated row must not inherit the old row's values or defaults.
  RowHost *other=[RowHost new];
  KFTestEffect *otherPlugin=[[KFTestEffect alloc] initWithAPIManager:other]; other.plugin=otherPlugin;
  otherPlugin.inspectorImageSize=CGSizeMake(100,100);
  KFVectorRow *replacement=(KFVectorRow *)[otherPlugin createViewForParameterID:KFTestPosition];
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
  replacement.onValueCommit(replacement.fields[0]);
  assert(fabs([(id<KFPropertyPose>)other.blobs[@(KFTestPosition)] values][0].doubleValue-162.037)<1e-9);
  reads=other.nativeKeyReads;
  assert(replacement.fields[0].tag==0 && replacement.fields[1].tag==1);
  replacement.frame=NSMakeRect(0,0,340,24);
  [replacement layoutSubtreeIfNeeded];
  assert(NSMaxX(replacement.fields[0].frame) < NSMinX(replacement.fields[1].frame));
  assert(NSMaxX(replacement.fields[1].frame) <= NSWidth(replacement.bounds));
  NSTextField *label=nil;
  for (NSView *v in replacement.subviews)
    if ([v isKindOfClass:NSTextField.class] && [[(NSTextField *)v stringValue] isEqualToString:@"Position"])
      label=(NSTextField *)v;
  assert(label && NSMinX(label.frame)==21 && label.font.pointSize==11);
  assert(NSMinY(replacement.fields[0].frame)==NSMinY(label.frame)-1);
  NSUInteger suffixes=0;
  for (NSTextField *text in replacement.unitLabels) {
    assert(text.superview==nil);
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
  // A percent-of-image lane needs dimensions before it can show pixels; the
  // effect publishes them from its image callbacks, which is the plugin's own
  // contract.
  RowHost *geometryHost=[RowHost new];
  KFTestEffect *plugin=[[KFTestEffect alloc] initWithAPIManager:geometryHost];
  KFVectorRow *geometryRow=(KFVectorRow *)[plugin createViewForParameterID:KFTestPosition];
  publish(geometryHost,25,-50);
  [window.contentView addSubview:geometryRow];
  assert(!geometryRow.fields[0].enabled);
  plugin.inspectorImageSize=CGSizeMake(1920,1080);
  [geometryRow refreshValues]; displayed(geometryRow,480,-540);
  geometryRow.fields[0].doubleValue=960; geometryRow.onValueCommit(geometryRow.fields[0]);
  assert([(id<KFPropertyPose>)geometryHost.blobs[@(KFTestPosition)] values][0].doubleValue==50);
  [geometryRow removeFromSuperview];
  // A recreated row can use dimensions from before it was attached.
  geometryRow=(KFVectorRow *)[plugin createViewForParameterID:KFTestPosition];
  publish(geometryHost,50,-50);
  [window.contentView addSubview:geometryRow]; displayed(geometryRow,960,-540);
  [geometryRow removeFromSuperview];
  // The host renders previews of the same frame at its own scales. Scaling an
  // 84 pixel preview's bounds back up misses the 1920x1080 frame by 1.3%, so
  // such a pass must not move a readout measured at full resolution: during
  // playback these arrive continuously and the displayed pixels drifted with
  // them while the stored value never changed.
  RowHost *playbackHost=[RowHost new];
  KFTestEffect *playbackPlugin=[[KFTestEffect alloc] initWithAPIManager:playbackHost];
  playbackHost.plugin=playbackPlugin;
  KFVectorRow *playbackRow=(KFVectorRow *)[playbackPlugin createViewForParameterID:KFTestPosition];
  publish(playbackHost,25,-50);
  // A preview pass is all there is to go on at first, so it is used.
  [playbackPlugin publishInspectorImageSize:CGSizeMake(1945.5,1111.714) measuredFrom:CGSizeMake(84,48)];
  [window.contentView addSubview:playbackRow];
  [playbackRow refreshValues]; displayed(playbackRow,486.375,-555.857);
  // The full-frame pass measures the same frame far more precisely.
  [playbackPlugin publishInspectorImageSize:CGSizeMake(1920,1080) measuredFrom:CGSizeMake(1920,1080)];
  [playbackRow refreshValues]; displayed(playbackRow,480,-540);
  for (NSUInteger i=0;i<3;i++) {
    [playbackPlugin publishInspectorImageSize:CGSizeMake(1945.5,1111.714) measuredFrom:CGSizeMake(84,48)];
    [playbackPlugin publishInspectorImageSize:CGSizeMake(1927.486,1080.833) measuredFrom:CGSizeMake(214,120)];
    [playbackRow refreshValues]; displayed(playbackRow,480,-540);
  }
  // A project actually resized lands further out than rounding can explain,
  // so even a coarse pass reports it.
  [playbackPlugin publishInspectorImageSize:CGSizeMake(1280,720) measuredFrom:CGSizeMake(84,48)];
  [playbackRow refreshValues]; displayed(playbackRow,320,-360);
  [playbackRow removeFromSuperview];
  RowHost *scaleHost=[RowHost new];
  KFTestEffect *scalePlugin=[[KFTestEffect alloc] initWithAPIManager:scaleHost];
  scalePlugin.inspectorImageSize=CGSizeMake(100,100);
  scaleHost.plugin=scalePlugin;
  assert([scalePlugin addParameters]);
  KFVectorRow *scaleRow=(KFVectorRow *)[scalePlugin createViewForParameterID:KFTestScale];
  [window.contentView addSubview:scaleRow];
  [scaleRow refreshValues]; displayed(scaleRow,100,100);
  assert(scaleRow.linkButton.state==NSControlStateValueOn);
  hostAccent(scaleRow.linkButton.contentTintColor);
  [scaleRow setNeedsLayout:YES]; [scaleRow layoutSubtreeIfNeeded];
  // The host's trailing controls must remain outside the custom row's hit area.
  for(CGFloat width=320;width<=550;width+=115) {
    scaleRow.frame=NSMakeRect(13,7,width,24);
    [scaleRow layoutSubtreeIfNeeded];
    for(CGFloat x=width-ICInspectorHostGutter;x<width;x+=10)
      assert([scaleRow hitTest:NSMakePoint(13+x,19)]==nil);
    NSTextField *field=scaleRow.fields[0];
    NSPoint center=[scaleRow convertPoint:NSMakePoint(NSMidX(field.frame),NSMidY(field.frame)) toView:scaleRow.superview];
    assert([scaleRow hitTest:center]==field);
  }

  CGFloat glyphCenter=NSMaxY(scaleRow.titleLabel.frame)-scaleRow.titleLabel.firstBaselineOffsetFromTop
      +scaleRow.titleLabel.font.capHeight/2;
  assert(fabs(NSMidY(scaleRow.linkButton.frame)-glyphCenter)<=0.25);
  assert(NSMinY(scaleRow.fields[0].frame)==NSMinY(scaleRow.titleLabel.frame)-1);
  assert([scaleRow.unitLabels[0].stringValue isEqualToString:@"%"]);
  // Percentage decorations are painted without remote text-field views.
  for (NSTextField *unit in scaleRow.unitLabels) assert(unit.superview==nil);
  assert([scaleRow.fields[0].stringValue isEqualToString:@"100.0"]);
  KFVectorRow *positionRow=(KFVectorRow *)[scalePlugin createViewForParameterID:KFTestPosition];
  // Opening Position must not replace Scale's cache token.
  NSUInteger scaleReads=scaleHost.nativeKeyReads;
  [scaleRow refreshValues]; displayed(scaleRow,100,100);
  assert(scaleHost.nativeKeyReads==scaleReads);
  id<KFPropertyPose> positionBefore=scaleHost.blobs[@(KFTestPosition)];
  NSUInteger scaleGroups=scaleHost.undoGroupsStarted;
  scaleRow.fields[0].doubleValue=150; scaleRow.onValueCommit(scaleRow.fields[0]);
  assert(scaleRow.fields[1].doubleValue==150); // linked partner updates immediately
  assert(scaleHost.undoGroupsStarted==scaleGroups+1 && scaleHost.undoDepth==0);
  assert([positionBefore isEqual:scaleHost.blobs[@(KFTestPosition)]]);
  scaleRow.onLinkToggle(scaleRow.linkButton);
  assert(scaleRow.linkButton.state==NSControlStateValueOff);
  assert([scaleRow.linkButton.contentTintColor isEqual:ICInspectorTokens.inactiveControlColor]);
  scaleRow.fields[1].doubleValue=75; scaleRow.onValueCommit(scaleRow.fields[1]);
  id<KFPropertyPose> scalePose=scaleHost.blobs[@(KFTestScale)];
  assert(scalePose.values[0].doubleValue==150 && scalePose.values[1].doubleValue==75);
  scaleRow.onLinkToggle(scaleRow.linkButton);
  ICValueTextField *scaleField=(ICValueTextField *)scaleRow.fields[0];
  scaleGroups=scaleHost.undoGroupsStarted;
  scaleField.onScrubBegin();
  scaleField.doubleValue=180; scaleRow.onValueCommit(scaleField);
  scaleField.doubleValue=200; scaleRow.onValueCommit(scaleField);
  scaleField.onScrubEnd();
  assert(scaleHost.undoGroupsStarted==scaleGroups+1 && scaleHost.undoDepth==0);
  scalePose=scaleHost.blobs[@(KFTestScale)];
  assert(scalePose.values[0].doubleValue==200 && scalePose.values[1].doubleValue==100);
  // Beyond the range the pair scales together rather than one axis clamping,
  // and a negative edit collapses both to the minimum.
  scaleHost.blobs[@(KFTestScale)]=lanePose(KFTestScaleLane(), @[@100, @200]);
  [KFTestScaleLane() refreshCacheForManager:scaleHost time:kCMTimeZero];
  scaleField.doubleValue=400; scaleRow.onValueCommit(scaleField);
  scalePose=scaleHost.blobs[@(KFTestScale)];
  assert(scalePose.values[0].doubleValue==200 && scalePose.values[1].doubleValue==400);
  scaleField.doubleValue=-50; scaleRow.onValueCommit(scaleField);
  scalePose=scaleHost.blobs[@(KFTestScale)];
  assert(scalePose.values[0].doubleValue==0 && scalePose.values[1].doubleValue==0);
  assert(scaleHost.starts==scaleHost.ends);
  [scaleRow removeFromSuperview];
  (void)positionRow;
  KFScalarRow *opacityRow=(KFScalarRow *)[scalePlugin createViewForParameterID:KFTestOpacity];
  [window.contentView addSubview:opacityRow]; [opacityRow refreshValues];
  [window.contentView addSubview:positionRow];
  [window.contentView addSubview:scaleRow];
  NSArray<ICInspectorRow *> *selectionRows=@[(ICInspectorRow *)positionRow,(ICInspectorRow *)scaleRow,opacityRow];
  NSArray *selectionIDs=@[@(KFTestPosition),@(KFTestScale),@(KFTestOpacity)];
  for(NSUInteger selected=0;selected<selectionRows.count;selected++) {
    scalePlugin.activeInspectorParameterID=[selectionIDs[selected] unsignedIntValue];
    scalePlugin.graphedInspectorParameters=[NSSet setWithObject:selectionIDs[selected]];
    [NSNotificationCenter.defaultCenter postNotificationName:KFInspectorPresentationChanged object:scalePlugin];
    for(NSUInteger i=0;i<selectionRows.count;i++) {
      ICInspectorRow *candidate=selectionRows[i];
      assert(candidate.selected==(i==selected));
      NSArray *colors=KFPropertyLaneForParameter([selectionIDs[i] unsignedIntValue]).componentColors;
      assert([candidate.componentColors isEqualToArray:colors]);
      for(NSUInteger axis=0;axis<candidate.axisLabels.count;axis++)
        assert([candidate.axisLabels[axis].textColor isEqual:!candidate.enabled ? ICInspectorTokens.disabledTextColor : (i==selected ? colors[axis] : ICInspectorTokens.decorationColor)]);
      assert([candidate.titleLabel.font isEqual:i==selected ? ICInspectorTokens.selectedLabelFont : ICInspectorTokens.labelFont]);
      assert([candidate.titleLabel.textColor isEqual:!candidate.enabled ? ICInspectorTokens.disabledTextColor : (i==selected ? ICInspectorTokens.accentMatchingHost : ICInspectorTokens.labelColor)]);
    }
  }
  scalePlugin.activeInspectorParameterID=KFTestScale;
  scalePlugin.graphedInspectorParameters=[NSSet setWithArray:@[@(KFTestPosition),@(KFTestScale)]];
  [NSNotificationCenter.defaultCenter postNotificationName:KFInspectorPresentationChanged object:scalePlugin];
  for (NSUInteger i=0;i<selectionRows.count;i++) {
    ICInspectorRow *candidate=selectionRows[i];
    assert(candidate.selected==(i==1));
    for (NSUInteger axis=0;axis<candidate.axisLabels.count;axis++)
      assert([candidate.axisLabels[axis].textColor isEqual:!candidate.enabled ? ICInspectorTokens.disabledTextColor : (i<2 ? KFPropertyLaneForParameter([selectionIDs[i] unsignedIntValue]).componentColors[axis] : ICInspectorTokens.decorationColor)]);
    for (NSTextField *suffix in candidate.unitLabels) assert([suffix.textColor isEqual:candidate.enabled ? ICInspectorTokens.decorationColor : ICInspectorTokens.disabledTextColor]);
  }
  scalePlugin.graphedInspectorParameters=[NSSet setWithObject:@(KFTestScale)];
  [NSNotificationCenter.defaultCenter postNotificationName:KFInspectorPresentationChanged object:scalePlugin];
  assert([positionRow.axisLabels[0].textColor isEqual:((ICInspectorRow *)positionRow).enabled ? ICInspectorTokens.decorationColor : ICInspectorTokens.disabledTextColor]);
  scalePlugin.activeInspectorParameterID=0;
  [NSNotificationCenter.defaultCenter postNotificationName:KFInspectorPresentationChanged object:scalePlugin];
  [positionRow removeFromSuperview]; [scaleRow removeFromSuperview];
  assert([opacityRow.titleLabel.stringValue isEqualToString:@"Opacity"]);
  assert(opacityRow.fields[0].enabled && opacityRow.sliderView.enabled);
  assert(opacityRow.fields[0].doubleValue==100 && opacityRow.sliderView.doubleValue==100);
  assert(opacityRow.unitLabels[0].superview==nil);
  for(CGFloat width=320;width<=550;width+=115) {
    opacityRow.frame=NSMakeRect(13,7,width,24); [opacityRow setNeedsLayout:YES]; [opacityRow layoutSubtreeIfNeeded];
    assert([opacityRow hitTest:NSMakePoint(13+width-60,19)]==nil);
    assert(NSMaxX(opacityRow.sliderView.frame)<NSMinX(opacityRow.fields[0].frame));
  }
  NSUInteger opacityGroups=scaleHost.undoGroupsStarted, opacityReads=scaleHost.nativeKeyReads;
  opacityRow.onScrubBegin();
  opacityRow.fields[0].doubleValue=75; opacityRow.onValueCommit(opacityRow.fields[0]);
  opacityRow.fields[0].doubleValue=50; opacityRow.onValueCommit(opacityRow.fields[0]);
  opacityRow.onScrubEnd(); [opacityRow refreshValues];
  assert(scaleHost.undoGroupsStarted==opacityGroups+1 && scaleHost.undoDepth==0);
  assert([(id<KFPropertyPose>)scaleHost.blobs[@(KFTestOpacity)] value]==50);
  assert(opacityRow.fields[0].doubleValue==50 && opacityRow.sliderView.doubleValue==50);
  // Refresh does not enumerate keys, and unavailable snapshots keep readouts
  // while preventing stale writes through either input.
  opacityReads=scaleHost.nativeKeyReads; [opacityRow refreshValues];
  assert(scaleHost.nativeKeyReads==opacityReads);
  scaleHost.failReadParameter=KFTestOpacity;
  [KFTestOpacityLane() refreshCacheForManager:scaleHost time:kCMTimeZero]; [opacityRow refreshValues];
  assert(!opacityRow.fields[0].enabled && !opacityRow.sliderView.enabled && opacityRow.fields[0].doubleValue==50);
  scaleHost.failReadParameter=0; [KFTestOpacityLane() refreshCacheForManager:scaleHost time:kCMTimeZero];
  [opacityRow refreshValues]; assert(opacityRow.fields[0].enabled && opacityRow.sliderView.enabled);
  assert(scaleHost.starts==scaleHost.ends);
  [opacityRow removeFromSuperview];
  KFVectorRow *rotationRow=(KFVectorRow *)[scalePlugin createViewForParameterID:KFTestRotation];
  [window.contentView addSubview:rotationRow]; [rotationRow refreshValues];
  assert(rotationRow.fields.count==3 && [rotationRow.titleLabel.stringValue isEqualToString:@"Rotation"]);
  for(ICValueTextField *field in rotationRow.fields) assert(field.enabled && field.doubleValue==0);
  for(NSTextField *unit in rotationRow.unitLabels) assert(unit.superview==nil && [unit.stringValue isEqualToString:@"°"]);
  for(CGFloat width=320;width<=550;width+=115) {
    rotationRow.frame=NSMakeRect(13,7,width,24); [rotationRow setNeedsLayout:YES]; [rotationRow layoutSubtreeIfNeeded];
    assert([rotationRow hitTest:NSMakePoint(13+width-60,19)]==nil);
    assert(NSWidth(rotationRow.titleLabel.frame)>0); // Label yields space to signed decimal readouts.
    for(NSUInteger axis=0;axis<3;axis++) {
      ICValueTextField *field=rotationRow.fields[axis];
      for(NSNumber *value in @[@123.4,@(-123.4),@888.8,@(-888.8)]) {
        NSString *text=[field.formatter stringForObjectValue:value];
        CGFloat required=ceil([text sizeWithAttributes:@{NSFontAttributeName:field.font}].width)+2*ICInspectorFieldTextInset;
        assert(NSWidth(field.frame)>=required);
      }
      assert(NSMaxX(rotationRow.fields[axis].frame)<=NSMinX(rotationRow.unitLabels[axis].frame));
      assert(NSMaxX(rotationRow.unitLabels[axis].frame)<=width-ICInspectorHostGutter);
    }
  }
  NSUInteger rotationGroups=scaleHost.undoGroupsStarted;
  rotationRow.onScrubBegin();
  rotationRow.fields[0].doubleValue=720; rotationRow.onValueCommit(rotationRow.fields[0]);
  rotationRow.fields[2].doubleValue=-360; rotationRow.onValueCommit(rotationRow.fields[2]);
  rotationRow.onScrubEnd(); [rotationRow refreshValues];
  assert(scaleHost.undoGroupsStarted==rotationGroups+1 && scaleHost.undoDepth==0);
  assert(rotationRow.fields[0].doubleValue==720 && rotationRow.fields[1].doubleValue==0 && rotationRow.fields[2].doubleValue==-360);
  scalePlugin.activeInspectorParameterID=KFTestRotation;
  scalePlugin.graphedInspectorParameters=[NSSet setWithObject:@(KFTestRotation)];
  [NSNotificationCenter.defaultCenter postNotificationName:KFInspectorPresentationChanged object:scalePlugin];
  assert(rotationRow.selected);
  for(NSUInteger axis=0;axis<3;axis++) assert([rotationRow.axisLabels[axis].textColor isEqual:KFPropertyLaneForParameter(KFTestRotation).componentColors[axis]]);
  KFPropertyPoseCache *rotationCache=[KFTestRotationLane() cacheForManager:scaleHost];
  CMTime firstTime=TestTime(0),lastTime=TestTime(4);
  NSArray *rotationEntries=@[
    @{@"time":@0,@"nativeTime":[NSValue valueWithBytes:&firstTime objCType:@encode(CMTime)],@"pose":KFTestRotationLane().defaultPose},
    @{@"time":@4,@"nativeTime":[NSValue valueWithBytes:&lastTime objCType:@encode(CMTime)],@"pose":scaleHost.blobs[@(KFTestRotation)]}];
  [rotationCache setValue:rotationEntries forKey:@"entries"];
  KFTimingEditor *rotationPanel=[[KFTimingEditor alloc] initWithEffect:scalePlugin];
  [window.contentView addSubview:rotationPanel];
  NSView *rotationGraph=[rotationPanel valueForKey:@"graph"];
  [rotationGraph performSelector:@selector(prepareCurves)];
  assert([[rotationGraph valueForKey:@"curvePaths"] count]==3);
  assert([[rotationGraph valueForKey:@"componentColors"] isEqualToArray:KFPropertyLaneForParameter(KFTestRotation).componentColors]);
  [rotationPanel removeFromSuperview]; [rotationRow removeFromSuperview];
  scalePlugin.activeInspectorParameterID=0;
  // The shared panel is independent of native keyframe controls and survives
  // opening before a cache snapshot is available.
  KFTimingEditor *panel=[[KFTimingEditor alloc] initWithEffect:scalePlugin];
  panel.frame=NSMakeRect(0,0,395,256);
  [window.contentView addSubview:panel];
  assert(![[panel valueForKey:@"available"] isEnabled]);
  [panel layoutSubtreeIfNeeded];
  for(NSView *child in panel.subviews) {
    assert(NSMinY(child.frame)>=0 && NSMaxY(child.frame)<=NSHeight(panel.bounds));
    assert(NSMinX(child.frame)>=0 && NSMaxX(child.frame)<=NSWidth(panel.bounds));
  }
  NSString *previewPath=NSProcessInfo.processInfo.environment[@"MM_TIMING_PREVIEW"];
  if(previewPath) {
    id<KFPropertyPose> a=lanePose(KFTestScaleLane(), @[@100, @80]);
    id<KFPropertyPose> b=lanePose(KFTestScaleLane(), @[@180, @140]);
    CMTime first=TestTime(0),last=TestTime(3);
    NSArray *entries=@[
      @{@"time":@0,@"nativeTime":[NSValue valueWithBytes:&first objCType:@encode(CMTime)],@"pose":a},
      @{@"time":@3,@"nativeTime":[NSValue valueWithBytes:&last objCType:@encode(CMTime)],@"pose":b}];
    [[KFTestScaleLane() cacheForManager:scaleHost] setValue:entries forKey:@"entries"];
    scalePlugin.activeInspectorParameterID=KFTestScale;
    [panel performSelector:@selector(refresh)];
    panel.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [panel layoutSubtreeIfNeeded];
    NSBitmapImageRep *bitmap=[panel bitmapImageRepForCachingDisplayInRect:panel.bounds];
    [panel cacheDisplayInRect:panel.bounds toBitmapImageRep:bitmap];
    [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:previewPath atomically:YES];
  }
  [panel removeFromSuperview];
  [window close];
  puts("Custom row: empty loading state, delayed values, immediate attachment refresh, zero values, unavailable snapshots and no refresh keyframe reads passed");
 }
}
