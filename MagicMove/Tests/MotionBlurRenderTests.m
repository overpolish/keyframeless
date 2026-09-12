/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "MockHost.h"
#import "ShaderTypes.h"
#import <IOSurface/IOSurface.h>
#import <CoreVideo/CoreVideo.h>
#import <math.h>

// Only the host image wrapper is replaced; production render and the shared
// texture pool, command buffer, sample passes and accumulation all run on Metal.
@interface BlurTile : FxImageTile
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic, strong) IOSurface *surface;
@end
@implementation BlurTile
- (IOSurface *)ioSurface { return self.surface; }
- (uint64_t)deviceRegistryID { return self.texture.device.registryID; }
- (id<MTLTexture>)metalTextureForDevice:(id<MTLDevice>)device { return self.texture; }
- (FxRect)imagePixelBounds { return (FxRect){0,0,(int)self.texture.width,(int)self.texture.height}; }
- (FxRect)tilePixelBounds { return self.imagePixelBounds; }
- (CMTime)mediaTime { return TestTime(1); }
@end
@interface BlurPlugin : MagicMovePlugin
@property(nonatomic, strong) id<MTLRenderPipelineState> testPipeline;
@property(nonatomic) NSUInteger sampleDraws;
@property(nonatomic, strong) id<MTLCommandBuffer> firstBuffer;
@end
@implementation BlurPlugin
- (id<MTLRenderPipelineState>)pipelineStateForPluginID:(NSString *)pluginID destinationImage:(FxImageTile *)image vertexShader:(NSString *)vertex fragmentShader:(NSString *)fragment blendMode:(KKBlendMode)blend { return self.testPipeline; }
- (BOOL)encodeFullScreenQuadIntoTexture:(id<MTLTexture>)dest destinationImage:(FxImageTile *)image commandBuffer:(id<MTLCommandBuffer>)buffer sourceTextures:(NSArray<id<MTLTexture>> *)sources commands:(void (^)(id<MTLRenderCommandEncoder>, NSArray<id<MTLTexture>> *))commands {
  if (!self.firstBuffer) self.firstBuffer = buffer;
  assert(buffer == self.firstBuffer); // All samples share one command buffer.
  self.sampleDraws++;
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
    MockHost *host = [MockHost new];
    BlurPlugin *plugin = [[BlurPlugin alloc] initWithAPIManager:host]; host.plugin = plugin;
    plugin.testPipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    assert(plugin.testPipeline && [plugin addParametersWithError:&error]);
    BlurTile *source = Tile(device), *dest = Tile(device);
    float input[64*32*4] = {0}, output[64*32*4] = {0};
    for (int y=0;y<32;++y) for (int x=24;x<40;++x) {
      input[(y*64+x)*4] = .25; input[(y*64+x)*4+3] = .5;
    }
    [source.texture replaceRegion:MTLRegionMake2D(0,0,64,32) mipmapLevel:0 withBytes:input bytesPerRow:64*16];
    // A trail from x=0 to x=16 pixels over the default shutter.
    host.frameDuration = TestTime(1.0/30);
    TestAdd(host,MMPositionX,0,0); TestAdd(host,MMPositionX,1,25);
    host.editors[@(MMTransitionDuration)] = @(1.0/60); TestChange(host,MMTransitionDuration,1);
    host.editors[@(MMPositionEasing)] = @(MTEasingLinear); TestChange(host,MMPositionEasing,1);
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
    puts("Motion blur GPU: 16 shared-buffer samples, premultiplied trail, alpha conservation and disabled sharp render passed");
  }
}
