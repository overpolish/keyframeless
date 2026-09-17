/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "Constants.h"
#import "MockHost.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import "MMLanes.h"
#import <IOSurface/IOSurface.h>
#import <CoreVideo/CoreVideo.h>
#import <math.h>

// Keyed custom values, as the host serves them for the combined pose.
@interface BlurHost : MockHost @end
@implementation BlurHost
- (BOOL)getCustomParameterValue:(NSObject<NSSecureCoding,NSCopying> **)value
                  fromParameter:(UInt32)p atTime:(CMTime)t {
  if (p != MMPositionControls || ![self lane:p].count)
    return [super getCustomParameterValue:value fromParameter:p atTime:t];
  NSArray *keys = [self lane:p];
  *value = keys.firstObject[@"value"];
  for (NSDictionary *key in keys) {
    if ([key[@"time"] doubleValue] > CMTimeGetSeconds(t)) break;
    *value = key[@"value"];
  }
  return YES;
}
@end

// The transition lasts one shutter sample, so the trail spans the frame.
static id<KFPropertyPose> LanePose(KFPropertyLane *lane, NSArray<NSNumber *> *values, MTEasing easing) {
  return [lane.defaultPose poseByReplacingValues:values authored:YES easing:easing
      addedMotion:MTAddedMotionNone
      timing:[[KFPoseTiming alloc] initWithDuration:1.0/60 available:NO amount:1 speed:1]];
}
static id<KFPropertyPose> Pose(double x, MTEasing easing) {
  return LanePose(MMPositionLane(), @[@(x), @0], easing);
}

static void Key(MockHost *host, double time, id<KFPropertyPose> pose) {
  FxKeyframe key;
  FxInitKeyframe(key, kFxKeyframe_CurrentVersion);
  key.time = TestTime(time);
  [[host lane:MMPositionControls] addObject:[@{@"time":@(time), @"value":pose,
      @"key":[NSValue valueWithBytes:&key objCType:@encode(FxKeyframe)]} mutableCopy]];
}

// Only the host image wrapper is replaced; production render and the shared
// texture pool, command buffer, sample passes and accumulation all run on Metal.
@interface BlurTile : FxImageTile
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic, strong) IOSurface *surface;
@property(nonatomic, strong) FxMatrix44 *referenceTransform;
@end
@implementation BlurTile
- (IOSurface *)ioSurface { return self.surface; }
- (FxMatrix44 *)inversePixelTransform { return self.referenceTransform; }
- (uint64_t)deviceRegistryID { return self.texture.device.registryID; }
- (id<MTLTexture>)metalTextureForDevice:(id<MTLDevice>)device { return self.texture; }
- (FxRect)imagePixelBounds { return (FxRect){0,0,(int)self.texture.width,(int)self.texture.height}; }
- (FxRect)tilePixelBounds { return self.imagePixelBounds; }
- (CMTime)mediaTime { return TestTime(1); }
@end
@interface BlurPlugin : MagicMovePlugin
@property(nonatomic, strong) id<MTLRenderPipelineState> testPipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> accumulationPipeline;
@property(nonatomic) NSUInteger sampleDraws;
@property(nonatomic, strong) id<MTLCommandBuffer> firstBuffer;
@end
@implementation BlurPlugin
- (id<MTLRenderPipelineState>)renderPipelineForImage:(FxImageTile *)image vertex:(NSString *)vertex fragment:(NSString *)fragment { return [vertex isEqualToString:@"vertexShader"] ? self.testPipeline : self.accumulationPipeline; }
- (BOOL)encodeFullScreenQuadIntoTexture:(id<MTLTexture>)dest destinationImage:(FxImageTile *)image commandBuffer:(id<MTLCommandBuffer>)buffer sourceTextures:(NSArray<id<MTLTexture>> *)sources commands:(void (^)(id<MTLRenderCommandEncoder>, NSArray<id<MTLTexture>> *))commands {
  // The adapter shares its quad encoder with the sharp path. Count only
  // offscreen sample destinations, not the final output image.
  if (dest != [image metalTextureForDevice:buffer.device]) {
    if (!self.firstBuffer) self.firstBuffer = buffer;
    assert(buffer == self.firstBuffer); // All samples share one command buffer.
    self.sampleDraws++;
  }
  return [super encodeFullScreenQuadIntoTexture:dest destinationImage:image commandBuffer:buffer sourceTextures:sources commands:commands];
}
@end
static BlurTile *Tile(id<MTLDevice> device) {
  BlurTile *tile = [BlurTile new];
  MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:64 height:32 mipmapped:NO];
  d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  tile.texture = [device newTextureWithDescriptor:d];
  tile.surface = CFBridgingRelease(IOSurfaceCreate((__bridge CFDictionaryRef)@{
    (id)kIOSurfaceWidth:@64, (id)kIOSurfaceHeight:@32, (id)kIOSurfaceBytesPerElement:@16,
    (id)kIOSurfacePixelFormat:@(kCVPixelFormatType_128RGBAFloat)}));
  assert(tile.texture && tile.surface);
  return tile;
}
int main(int argc, const char **argv) {
  @autoreleasepool {
    assert(argc == 2);
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) { puts("Motion blur GPU: skipped (no Metal device)"); return 0; }
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&error];
    assert(library && !error);
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"vertexShader"];
    desc.fragmentFunction = [library newFunctionWithName:@"fragmentShader"];
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    BlurHost *host = [BlurHost new];
    // An unavailable host setting must read as a failure, not as zero.
    host.strictReadParameters =
        [NSSet setWithObjects:@(MMMotionBlurSamples), @(MMMotionBlurShutterAngle), nil];
    BlurPlugin *plugin = [[BlurPlugin alloc] initWithAPIManager:host]; host.plugin = plugin;
    plugin.testPipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    desc.vertexFunction=[library newFunctionWithName:@"RSRenderBlurVertex"];
    desc.fragmentFunction=[library newFunctionWithName:@"RSRenderBlurAccumulate"];
    plugin.accumulationPipeline=[device newRenderPipelineStateWithDescriptor:desc error:&error];
    assert(plugin.accumulationPipeline);
    assert(plugin.testPipeline && [plugin addParametersWithError:&error]);
    BlurTile *source = Tile(device), *dest = Tile(device);
    float input[64*32*4] = {0}, output[64*32*4] = {0};
    for (int y=0;y<32;++y) for (int x=24;x<40;++x) {
      input[(y*64+x)*4] = .25; input[(y*64+x)*4+3] = .5;
    }
    [source.texture replaceRegion:MTLRegionMake2D(0,0,64,32) mipmapLevel:0 withBytes:input bytesPerRow:64*16];
    // A trail from x=0 to x=16 pixels over the default shutter.
    host.frameDuration = TestTime(1.0/30);
    Key(host, 0, Pose(0, MTEasingSmooth));
    Key(host, 1, Pose(25, MTEasingLinear));
    host.editors[@(MMMotionBlur)] = @YES;
    NSData *state;
    assert([plugin pluginState:&state atTime:TestTime(1) quality:0 error:&error]);
    assert([plugin renderDestinationImage:dest sourceImages:@[source] pluginState:state atTime:TestTime(1) error:&error]);
    assert(plugin.sampleDraws == 16 && plugin.firstBuffer.status == MTLCommandBufferStatusCompleted);
    [dest.texture getBytes:output bytesPerRow:64*16 fromRegion:MTLRegionMake2D(0,0,64,32) mipmapLevel:0];
    float sum=0;
    for (int x=0;x<64;++x) {
      float *pixel=&output[(16*64+x)*4];
      assert(isfinite(pixel[3]) && pixel[3]>=0 && pixel[3]<=.501);
      assert(fabsf(pixel[0]-.5f*pixel[3])<1e-5); // Premultiplication survives averaging.
      sum += pixel[3];
    }
    assert(fabsf(sum-8)<.1); // No alpha/energy loss for an unclipped trail.
    assert(output[(16*64+30)*4+3] > .02 && output[(16*64+30)*4+3] < .49);
    assert(output[(16*64+52)*4+3] > .02 && output[(16*64+52)*4+3] < .49);
    // Disabled path remains a single sharp render, without blur sample draws.
    host.editors[@(MMMotionBlur)] = @NO;
    assert([plugin pluginState:&state atTime:TestTime(1) quality:0 error:&error]);
    assert([plugin renderDestinationImage:dest sourceImages:@[source] pluginState:state atTime:TestTime(1) error:&error]);
    [dest.texture getBytes:output bytesPerRow:64*16 fromRegion:MTLRegionMake2D(0,0,64,32) mipmapLevel:0];
    assert(output[(16*64+30)*4+3] == 0 && fabsf(output[(16*64+45)*4+3]-.5f)<1e-6);
    assert(plugin.sampleDraws == 16);

    // The production render path also applies the property Blur lane. With a
    // zero radius it must remain sharp; a positive pixel radius spreads the
    // source alpha into neighbouring pixels.
    host.blobs[@(MMBlurControls)] = LanePose(MMBlurLane(), @[@0], MTEasingSmooth);
    host.blobs[@(MMAnchorControls)] = LanePose(MMAnchorLane(), @[@0, @0], MTEasingSmooth);
    host.editors[@(MMMotionBlur)] = @NO;
    assert([plugin pluginState:&state atTime:TestTime(1) quality:0 error:&error]);
    assert([plugin renderDestinationImage:dest sourceImages:@[source] pluginState:state atTime:TestTime(1) error:&error]);
    [dest.texture getBytes:output bytesPerRow:64*16 fromRegion:MTLRegionMake2D(0,0,64,32) mipmapLevel:0];
    assert(output[(16*64+39)*4+3] == 0 && fabsf(output[(16*64+45)*4+3]-.5f)<1e-6);
    host.blobs[@(MMBlurControls)] = LanePose(MMBlurLane(), @[@3], MTEasingSmooth);
    assert([plugin pluginState:&state atTime:TestTime(1) quality:0 error:&error]);
    assert([plugin renderDestinationImage:dest sourceImages:@[source] pluginState:state atTime:TestTime(1) error:&error]);
    [dest.texture getBytes:output bytesPerRow:64*16 fromRegion:MTLRegionMake2D(0,0,64,32) mipmapLevel:0];
    assert(output[(16*64+39)*4+3] > 0 && output[(16*64+45)*4+3] < .5f);

    // Anchor is evaluated by the same production shader. Moving it and
    // scaling the source changes the rendered centroid around that pivot.
    host.blobs[@(MMBlurControls)] = LanePose(MMBlurLane(), @[@0], MTEasingSmooth);
    host.blobs[@(MMAnchorControls)] = LanePose(MMAnchorLane(), @[@12, @0], MTEasingSmooth);
    host.blobs[@(MMScaleControls)] = LanePose(MMScaleLane(), @[@50, @50], MTEasingSmooth);
    assert([plugin pluginState:&state atTime:TestTime(1) quality:0 error:&error]);
    assert([plugin renderDestinationImage:dest sourceImages:@[source] pluginState:state atTime:TestTime(1) error:&error]);
    [dest.texture getBytes:output bytesPerRow:64*16 fromRegion:MTLRegionMake2D(0,0,64,32) mipmapLevel:0];
    assert(output[(16*64+39)*4+3] == 0);
    assert(output[(16*64+51)*4+3] > 0);

    // Full-resolution pixel values and inverse preview scaling cancel out:
    // doubling the authored dimensions/values on a half-size source must keep
    // the exact same rendered pixels (including the anchor and Gaussian).
    host.blobs[@(MMBlurControls)] = LanePose(MMBlurLane(), @[@3], MTEasingSmooth);
    assert([plugin pluginState:&state atTime:TestTime(1) quality:0 error:&error]);
    assert([plugin renderDestinationImage:dest sourceImages:@[source] pluginState:state atTime:TestTime(1) error:&error]);
    float reference[64*32*4];
    [dest.texture getBytes:reference bytesPerRow:64*16 fromRegion:MTLRegionMake2D(0,0,64,32) mipmapLevel:0];
    Matrix44Data doubled={{2,0,0,0},{0,2,0,0},{0,0,1,0},{0,0,0,1}};
    source.referenceTransform=[[FxMatrix44 alloc] initWithMatrix44Data:doubled];
    host.blobs[@(MMAnchorControls)] = LanePose(MMAnchorLane(), @[@24, @0], MTEasingSmooth);
    host.blobs[@(MMBlurControls)] = LanePose(MMBlurLane(), @[@6], MTEasingSmooth);
    assert([plugin pluginState:&state atTime:TestTime(1) quality:0 error:&error]);
    assert([plugin renderDestinationImage:dest sourceImages:@[source] pluginState:state atTime:TestTime(1) error:&error]);
    [dest.texture getBytes:output bytesPerRow:64*16 fromRegion:MTLRegionMake2D(0,0,64,32) mipmapLevel:0];
    for(NSUInteger i=0;i<64*32*4;i++) assert(fabsf(output[i]-reference[i])<1e-6);
    source.referenceTransform=nil;

    // Spatial blur remains compatible with temporal motion blur and keeps the
    // shared 16-sample command-buffer path.
    host.blobs[@(MMBlurControls)] = LanePose(MMBlurLane(), @[@3], MTEasingSmooth);
    host.editors[@(MMMotionBlur)] = @YES;
    plugin.sampleDraws = 0; plugin.firstBuffer = nil;
    assert([plugin pluginState:&state atTime:TestTime(1) quality:0 error:&error]);
    assert([plugin renderDestinationImage:dest sourceImages:@[source] pluginState:state atTime:TestTime(1) error:&error]);
    assert(plugin.sampleDraws == 16 && plugin.firstBuffer.status == MTLCommandBufferStatusCompleted);
    host.editors[@(MMMotionBlurSamples)]=@8;
    host.editors[@(MMMotionBlurShutterAngle)]=@90;
    plugin.sampleDraws=0; plugin.firstBuffer=nil;
    assert([plugin pluginState:&state atTime:TestTime(1) quality:0 error:&error]);
    assert([plugin renderDestinationImage:dest sourceImages:@[source] pluginState:state atTime:TestTime(1) error:&error]);
    assert(plugin.sampleDraws==8 && plugin.firstBuffer.status==MTLCommandBufferStatusCompleted);
    host.editors[@(MMMotionBlurShutterAngle)]=@0;
    plugin.sampleDraws=0; plugin.firstBuffer=nil;
    assert([plugin pluginState:&state atTime:TestTime(1) quality:0 error:&error]);
    assert([plugin renderDestinationImage:dest sourceImages:@[source] pluginState:state atTime:TestTime(1) error:&error]);
    assert(plugin.sampleDraws==0);
    puts("Motion blur GPU: temporal samples, production spatial blur, anchor pivot and sharp identity passed");
  }
}
