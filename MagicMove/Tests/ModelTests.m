/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Constants.h"
#import "MockHost.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import <math.h>

@interface Fixture : NSObject
@property MockHost *host;
@property MagicMovePlugin *plugin;
@end
@implementation Fixture
- (instancetype)init {
  if ((self = [super init])) {
    _host = [MockHost new];
    _plugin = [[MagicMovePlugin alloc] initWithAPIManager:_host];
    _host.plugin = _plugin;
    assert([_plugin addParametersWithError:nil]);
  }
  return self;
}
@end
static void testParameterContract(void) {
  Fixture *f = [Fixture new];
  MockHost *h = f.host;
  UInt32 headerFlags=[h.flags[@(MMHeaderControls)] unsignedIntValue];
  assert(headerFlags & kFxParameterFlag_CUSTOM_UI);
  assert(headerFlags & kFxParameterFlag_NOT_ANIMATABLE);
  assert(headerFlags & kFxParameterFlag_DONT_SAVE);
  for(NSNumber *parameter in @[@(MMMotionBlurSamples),@(MMMotionBlurShutterAngle)]) {
    assert([h.definitions[parameter][@"kind"] isEqual:@"int"]);
    UInt32 flags=[h.flags[parameter] unsignedIntValue];
    assert((flags & kFxParameterFlag_HIDDEN) && (flags & kFxParameterFlag_NOT_ANIMATABLE));
    assert(!(flags & kFxParameterFlag_DONT_SAVE));
  }
  assert([h.editors[@(MMMotionBlurSamples)] intValue]==16);
  assert([h.editors[@(MMMotionBlurShutterAngle)] intValue]==180);
  NSUInteger visible = 0;
  for (NSNumber *key in h.definitions) {
    assert(key.unsignedIntValue >= 1 && key.unsignedIntValue <= 9999);
    if (!([h.flags[key] unsignedIntValue] & kFxParameterFlag_HIDDEN))
      visible++;
  }
  assert(visible == 8); // Header, six properties and one shared timing editor.
  UInt32 refreshFlags=[h.flags[@(MMHostRefreshToken)] unsignedIntValue];
  assert(refreshFlags & kFxParameterFlag_HIDDEN);
  assert(refreshFlags & kFxParameterFlag_NOT_ANIMATABLE);
  assert(!(refreshFlags & (kFxParameterFlag_DONT_SAVE | kFxParameterFlag_CUSTOM_UI)));
  assert([[f.plugin classesForCustomParameterID:MMHostRefreshToken] containsObject:NSString.class]);
  UInt32 timingFlags=[h.flags[@(MMTimingControls)] unsignedIntValue];
  assert(timingFlags & kFxParameterFlag_NOT_ANIMATABLE);
  assert(timingFlags & kFxParameterFlag_DONT_SAVE);
  assert([h.definitions[@(MMPositionControls)][@"name"] isEqualToString:@""]);
  UInt32 customFlags = [h.flags[@(MMPositionControls)] unsignedIntValue];
  assert(customFlags & kFxParameterFlag_CUSTOM_UI);
  assert(!(customFlags & kFxParameterFlag_NOT_ANIMATABLE));
  assert(!(customFlags & kFxParameterFlag_DONT_SAVE));
  UInt32 opacityFlags=[h.flags[@(MMOpacityControls)] unsignedIntValue];
  assert(opacityFlags & kFxParameterFlag_CUSTOM_UI);
  assert(opacityFlags & kFxParameterFlag_USE_FULL_VIEW_WIDTH);
  assert(!(opacityFlags & (kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE)));
  assert([h.definitions[@(MMOpacityControls)][@"name"] isEqualToString:@""]);
  UInt32 scaleFlags=[h.flags[@(MMScaleControls)] unsignedIntValue];
  assert(scaleFlags & kFxParameterFlag_CUSTOM_UI);
  assert(!(scaleFlags & (kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE)));
  assert([h.definitions[@(MMScaleControls)][@"name"] isEqualToString:@""]);
  assert([h.definitions[@(MMScaleProportional)][@"default"] boolValue]);
  // Editor state changes must not reveal hidden rows during scrubbing.
  for (NSNumber *key in h.definitions)
    if (key.unsignedIntValue != MMHeaderControls && key.unsignedIntValue != MMPositionControls && key.unsignedIntValue != MMScaleControls && key.unsignedIntValue != MMTimingControls && key.unsignedIntValue != MMOpacityControls && key.unsignedIntValue != MMRotationControls && key.unsignedIntValue != MMBlurControls && key.unsignedIntValue != MMAnchorControls)
      assert([h.flags[key] unsignedIntValue] & kFxParameterFlag_HIDDEN);
  NSDictionary *properties = nil;
  assert([f.plugin properties:&properties error:nil]);
  assert([properties[kFxPropertyKey_VariesWhenParamsAreStatic] boolValue]);
  assert(![properties[kFxPropertyKey_MayRemapTime] boolValue]);
}
static void testUnavailableAPIsAndFailedReads(void) {
  MockHost *unavailable = [MockHost new];
  unavailable.missingProtocols =
      [NSSet setWithObject:@"FxParameterCreationAPI_v5"];
  MagicMovePlugin *unconfigured =
      [[MagicMovePlugin alloc] initWithAPIManager:unavailable];
  NSError *creationError = nil;
  assert(![unconfigured addParametersWithError:&creationError] &&
         creationError);
  assert(unavailable.definitions.count == 0);
  // A failed pose read leaves the caller's render state untouched.
  Fixture *f = [Fixture new];
  f.host.failReadParameter = MMPositionControls;
  NSData *sentinel = [@"unchanged" dataUsingEncoding:NSUTF8StringEncoding],
         *state = sentinel;
  NSError *error = nil;
  assert(![f.plugin pluginState:&state
                         atTime:TestTime(0)
                        quality:0
                          error:&error] &&
         error);
  assert(state == sentinel);
  f.host.failReadParameter = 0;
  for (NSString *name in
       @[ @"FxKeyframeAPI_v3", @"FxParameterRetrievalAPI_v6" ]) {
    f.host.missingProtocols = [NSSet setWithObject:name];
    error = nil;
    state = sentinel;
    assert(![f.plugin pluginState:&state atTime:TestTime(0) quality:0 error:&error]);
    assert(state == sentinel);
  }
}
@interface TileBoundsDouble : NSObject
@property FxRect imagePixelBounds;
@property FxMatrix44 *pixelTransform;
@end
@implementation TileBoundsDouble
- (FxMatrix44 *)inversePixelTransform { return self.pixelTransform ?: [FxMatrix44 new]; }
@end
static BOOL MMRectEqual(FxRect a, FxRect b) {
  return a.left == b.left && a.right == b.right && a.top == b.top && a.bottom == b.bottom;
}
static void testRenderInputAndTileContracts(void) {
  Fixture *f = [Fixture new];
  TileBoundsDouble *tile = [TileBoundsDouble new];
  tile.imagePixelBounds =
      (FxRect){.left = -10, .right = 1920, .top = 1080, .bottom = -20};
  FxRect requested = {0};
  FxRect smallTile = {.left = 0, .right = 20, .top = 20, .bottom = 0};
  NSError *error = nil;
  assert([f.plugin sourceTileRect:&requested
                 sourceImageIndex:0
                     sourceImages:@[ (id)tile ]
              destinationTileRect:smallTile
                 destinationImage:(id)tile
                      pluginState:nil
                           atTime:TestTime(0)
                            error:&error]);
  assert(!error && requested.left == -10 && requested.right == 1920 &&
         requested.top == 1080 && requested.bottom == -20);
  // The inspector reads pixel dimensions from the image callbacks, so a
  // half-resolution tile must still publish the full frame size.
  assert(CGSizeEqualToSize(f.plugin.inspectorImageSize, CGSizeMake(1930, 1100)));
  TileBoundsDouble *half = [TileBoundsDouble new];
  half.imagePixelBounds = (FxRect){.left = 0, .right = 960, .top = 540, .bottom = 0};
  Matrix44Data doubling = {{2, 0, 0, 0}, {0, 2, 0, 0}, {0, 0, 1, 0}, {0, 0, 0, 1}};
  half.pixelTransform = [[FxMatrix44 alloc] initWithMatrix44Data:doubling];
  assert([f.plugin sourceTileRect:&requested
                 sourceImageIndex:0
                     sourceImages:@[ (id)half ]
              destinationTileRect:smallTile
                 destinationImage:(id)half
                      pluginState:nil
                           atTime:TestTime(0)
                            error:&error]);
  assert(CGSizeEqualToSize(f.plugin.inspectorImageSize, CGSizeMake(1920, 1080)));
  assert(![f.plugin sourceTileRect:&requested
                  sourceImageIndex:1
                      sourceImages:@[ (id)tile ]
               destinationTileRect:(FxRect){0}
                  destinationImage:(id)tile
                       pluginState:nil
                            atTime:TestTime(0)
                             error:&error] &&
         error);
  error = nil;
  assert(![f.plugin renderDestinationImage:(id)tile
                              sourceImages:@[]
                               pluginState:[NSData data]
                                    atTime:TestTime(0)
                                     error:&error] &&
         error);
  error = nil;
  // The rect is sized by the pose but must stay centred on the frame. A rect
  // whose centre shifted with the moved content moved the buffer the same way
  // and the host's placement cancelled the translation: Position changed
  // nothing on screen. Growth is symmetric, capped at one frame per side, and
  // absent entirely when the pose keeps content inside the frame.
  TileBoundsDouble *frame = [TileBoundsDouble new];
  frame.imagePixelBounds = (FxRect){.left = 0, .right = 1920, .top = 1080, .bottom = 0};
  MMTransform pose = {0};
  pose.scale = pose.scaleY = 1;
  FxRect grown = {0};
  FxRect (^rectFor)(MMTransform) = ^FxRect(MMTransform state) {
    FxRect out = {0};
    NSError *rectError = nil;
    assert([f.plugin destinationImageRect:&out
                             sourceImages:@[ (id)frame ]
                         destinationImage:(id)frame
                              pluginState:[NSData dataWithBytes:&state length:sizeof(state)]
                                   atTime:TestTime(0)
                                    error:&rectError]);
    assert(!rectError);
    return out;
  };
  // Nothing leaves the frame: no allocation beyond it.
  grown = rectFor(pose);
  assert(grown.left == 0 && grown.right == 1920 && grown.top == 1080 && grown.bottom == 0);
  pose.scale = pose.scaleY = 0.5f;
  grown = rectFor(pose);
  assert(grown.left == 0 && grown.right == 1920 && grown.top == 1080 && grown.bottom == 0);
  // Half a frame right grows both sides by half a frame, and only in X.
  pose.scale = pose.scaleY = 1;
  pose.offset = (vector_float2){0.5f, 0};
  grown = rectFor(pose);
  assert(grown.left == -960 && grown.right == 2880 && grown.top == 1080 && grown.bottom == 0);
  // Moving the other way costs the same: the centre never moves.
  pose.offset = (vector_float2){-0.5f, 0};
  assert(MMRectEqual(rectFor(pose), grown));
  // Y grows independently, and past the cap the margin stops at one frame.
  pose.offset = (vector_float2){0, 0.25f};
  grown = rectFor(pose);
  assert(grown.left == 0 && grown.right == 1920 && grown.top == 1350 && grown.bottom == -270);
  pose.offset = (vector_float2){4.0f, 0};
  grown = rectFor(pose);
  assert(grown.left == -1920 && grown.right == 3840 && grown.top == 1080 && grown.bottom == 0);
  error = nil;
  assert(![f.plugin destinationImageRect:&grown
                            sourceImages:@[]
                        destinationImage:(id)frame
                             pluginState:nil
                                  atTime:TestTime(0)
                                   error:&error] && error);
}
static void testPoseTimingMotionMetadata(void) {
  KFPoseTiming *base = [[KFPoseTiming alloc] initWithDuration:2
                                                      available:YES
                                                         amount:3
                                                          speed:4];
  assert(base.motionSeed == 0 && base.motionLinked &&
         base.motionComponentMask == UINT32_MAX);
  KFPoseTiming *configured =
      [base timingByReplacingMotionSeed:UINT32_MAX linked:NO componentMask:5];
  assert(configured.duration == 2 && configured.available &&
         configured.amount == 3 && configured.speed == 4 &&
         configured.motionSeed == UINT32_MAX && !configured.motionLinked &&
         configured.motionComponentMask == 5);
  KFPoseTiming *linked = [configured timingByReplacingLinkID:@"group"];
  assert([linked.linkID isEqualToString:@"group"] &&
         linked.motionSeed == UINT32_MAX && !linked.motionLinked &&
         linked.motionComponentMask == 5);
  NSError *error = nil;
  NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:configured
                                            requiringSecureCoding:YES
                                                            error:&error];
  assert(archive && !error);
  KFPoseTiming *decoded = [NSKeyedUnarchiver unarchivedObjectOfClass:KFPoseTiming.class
                                                              fromData:archive
                                                                 error:&error];
  assert(decoded && !error && [decoded isEqual:configured] &&
         decoded.hash == configured.hash);
  assert([[base timingByCopyingMotionOptionsFrom:configured] isEqual:
      [base timingByReplacingMotionSeed:UINT32_MAX linked:NO componentMask:5]]);
  // Pre-options archives retain the prior independent component pattern.
  NSKeyedArchiver *legacy=[[NSKeyedArchiver alloc] initRequiringSecureCoding:YES];
  [legacy encodeDouble:1.2 forKey:@"duration"]; [legacy encodeBool:NO forKey:@"available"];
  [legacy encodeDouble:1 forKey:@"amount"]; [legacy encodeDouble:1 forKey:@"speed"]; [legacy finishEncoding];
  NSKeyedUnarchiver *reader=[[NSKeyedUnarchiver alloc] initForReadingFromData:legacy.encodedData error:&error];
  KFPoseTiming *old=[[KFPoseTiming alloc] initWithCoder:reader]; [reader finishDecoding];
  assert(old && !old.motionLinked && old.motionSeed==0 && old.motionComponentMask==UINT32_MAX);

}
#define RUN(test)                                                              \
  do {                                                                         \
    @autoreleasepool {                                                         \
      printf("  %s ... ", #test);                                              \
      fflush(stdout);                                                          \
      test();                                                                  \
      puts("passed");                                                          \
    }                                                                          \
  } while (0)
int main(void) {
  RUN(testParameterContract);
  RUN(testUnavailableAPIsAndFailedReads);
  RUN(testRenderInputAndTileContracts);
  RUN(testPoseTimingMotionMetadata);
  puts("MagicMove model: 4 test groups passed");
}
