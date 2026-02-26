//
//  KKMetalDeviceCache.m
//  KeyframelessKit
//
//  Created by Dom on 25/02/2026.
//

#import "KKMetalDeviceCache.h"
#import "KKRenderHelpers.h"
#import <FxPlug/FxPlugSDK.h>

const NSUInteger kMaxCommandQueues = 5;

static NSString *kKey_InUse = @"InUse";
static NSString *kKey_CommandQueue = @"CommandQueue";

@interface KKMetalDeviceCacheItem : NSObject

@property (nonatomic, strong) id<MTLDevice>                          gpuDevice;
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *>    *commandQueueCache;
@property (nonatomic, strong) NSLock                                 *commandQueueCacheLock;
@property (nonatomic, strong) NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *pipelineStates;

- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (nullable id<MTLCommandQueue>)getNextFreeCommandQueue;
- (void)returnCommandQueue:(id<MTLCommandQueue>)commandQueue;
- (BOOL)containsCommandQueue:(id<MTLCommandQueue>)commandQueue;
- (void)registerPipelineState:(id<MTLRenderPipelineState>)pipelineState forKey:(NSString *)key;
- (nullable id<MTLRenderPipelineState>)pipelineStateForKey:(NSString *)key;

@end


@implementation KKMetalDeviceCacheItem

- (instancetype)initWithDevice:(id<MTLDevice>)device
{
    self = [super init];
    if (self != nil)
    {
        _gpuDevice = device;
        _commandQueueCache = [[NSMutableArray alloc] initWithCapacity:kMaxCommandQueues];
        _commandQueueCacheLock = [[NSLock alloc] init];
        _pipelineStates = [[NSMutableDictionary alloc] init];
        
        for (NSUInteger i = 0; i < kMaxCommandQueues; i++)
        {
            NSMutableDictionary *dict = [NSMutableDictionary dictionary];
            [dict setObject:@NO forKey:kKey_InUse];
            [dict setObject:[_gpuDevice newCommandQueue] forKey:kKey_CommandQueue];
            [_commandQueueCache addObject:dict];
        }
        
        if (!_commandQueueCache || !_commandQueueCacheLock)
        {
            return nil;
        }
    }
    return self;
}

- (void)registerPipelineState:(id<MTLRenderPipelineState>)pipelineState forKey:(NSString *)key
{
    [_pipelineStates setObject:pipelineState forKey:key];
}

- (nullable id<MTLRenderPipelineState>)pipelineStateForKey:(NSString *)key
{
    return [_pipelineStates objectForKey:key];
}

- (id<MTLCommandQueue>)getNextFreeCommandQueue
{
    id<MTLCommandQueue> result = nil;
    [_commandQueueCacheLock lock];
    for (NSUInteger i = 0; result == nil && i < kMaxCommandQueues; i++)
    {
        NSMutableDictionary *dict = [_commandQueueCache objectAtIndex:i];
        if (![[dict objectForKey:kKey_InUse] boolValue])
        {
            [dict setObject:@YES forKey:kKey_InUse];
            result = [dict objectForKey:kKey_CommandQueue];
        }
    }
    [_commandQueueCacheLock unlock];
    return result;
}

- (void)returnCommandQueue:(id<MTLCommandQueue>)commandQueue
{
    [_commandQueueCacheLock lock];
    for (NSMutableDictionary *dict in _commandQueueCache)
    {
        if ([dict objectForKey:kKey_CommandQueue] == commandQueue)
        {
            [dict setObject:@NO forKey:kKey_InUse];
            break;
        }
    }
    [_commandQueueCacheLock unlock];
}

- (BOOL)containsCommandQueue:(id<MTLCommandQueue>)commandQueue
{
    for (NSMutableDictionary *dict in _commandQueueCache)
    {
        if ([dict objectForKey:kKey_CommandQueue] == commandQueue)
        {
            return YES;
        }
    }
    return NO;
}

@end

@implementation KKMetalDeviceCache {
    NSMutableArray<KKMetalDeviceCacheItem *> *_deviceCaches;
}

+ (instancetype)sharedCache
{
    static KKMetalDeviceCache *sSharedCache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sSharedCache = [[KKMetalDeviceCache alloc] init];
    });
    return sSharedCache;
}

- (instancetype)init
{
    self = [super init];
    if (self != nil)
    {
        NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
        _deviceCaches = [[NSMutableArray alloc] initWithCapacity:devices.count];
        for (id<MTLDevice> device in devices)
        {
            KKMetalDeviceCacheItem *item = [[KKMetalDeviceCacheItem alloc] initWithDevice:device];
            if (item)
            {
                [_deviceCaches addObject:item];
            }
        }
    }
    return self;
}

- (nullable KKMetalDeviceCacheItem *)cacheItemForRegistryID:(uint64_t)registryID
{
    for (KKMetalDeviceCacheItem *item in _deviceCaches)
    {
        if (item.gpuDevice.registryID == registryID)
        {
            return item;
        }
    }
    
    // Device not found - may have been added after init (e.g. eGPU hotplug
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    KKMetalDeviceCacheItem *result = nil;
    for (id<MTLDevice> device in devices)
    {
        if (device.registryID == registryID)
        {
            KKMetalDeviceCacheItem *item = [[KKMetalDeviceCacheItem alloc] initWithDevice:device] ;
            if (item)
            {
                [_deviceCaches addObject:item];
                result = item;
            }
            break;
        }
    }
    return result;
}

- (nullable id<MTLDevice>)deviceWithRegistryID:(uint64_t)registryID
{
    return [self cacheItemForRegistryID:registryID].gpuDevice;
}

- (nullable id<MTLRenderPipelineState>)buildAndRegisterPipelineStateForPluginID:(NSString *)pluginID
                                                                     registryID:(uint64_t)registryID
                                                                    pixelFormat:(MTLPixelFormat)pixelFormat
                                                                       bundleID:(NSString *)bundleID
                                                                   vertexShader:(NSString *)vertexShader
                                                                 fragmentShader:(NSString *)fragmentShader
                                                                      blendMode:(KKBlendMode)blendMode
{
    // Return if existing
    id<MTLRenderPipelineState> existing = [self pipelineStateForPluginID:pluginID
                                                              registryID:registryID
                                                             pixelFormat:pixelFormat];
    
    if (existing) return existing;
    
    id<MTLDevice> device = [self deviceWithRegistryID:registryID];
    if (!device) return nil;
    
    NSError *error = nil;
    id<MTLLibrary> library = nil;
    
    if (bundleID)
    {
        NSBundle *bundle = [NSBundle bundleWithIdentifier:bundleID];
        if (!bundle)
        {
            NSLog(@"KKMetalDeviceCache: bundle not found for ID: %@", bundleID);
            return nil;
        }
        library = [device newDefaultLibraryWithBundle:bundle error:&error];
    } else
    {
        library = [device newDefaultLibrary];
    }
    
    if (!library || error) {
        NSLog(@"KKMetalDeviceCache: failed to load Metal library (bundleID: %@): %@", bundleID, error);
        return nil;
    }
    
    id<MTLFunction> vertFn = [library newFunctionWithName:vertexShader];
    id<MTLFunction> fragFn = [library newFunctionWithName:fragmentShader];
    
    if (!vertFn || !fragFn)
    {
        NSLog(@"KKMetalDeviceCache: shader functions not found (%@, %@)", vertexShader, fragmentShader);
        return nil;
    }
    
    MTLRenderPipelineDescriptor *desc = [KKRenderHelpers createPipelineDescriptorWithVertexFunction:vertFn
                                                                                                fragmentFunction:fragFn
                                                                                                     pixelFormat:pixelFormat
                                                                                                       blendMode:blendMode];
    
    id<MTLRenderPipelineState> ps = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!ps || error)
    {
        NSLog(@"KKMetalDeviceCache: failed to create pipeline state for %@: %@", pluginID, error);
        return nil;
    }
    
    [self registerPipelineState:ps forPluginID:pluginID registryID:registryID pixelFormat:pixelFormat];
    return ps;
}

- (void)registerPipelineState:(id<MTLRenderPipelineState>)pipelineState
                  forPluginID:(NSString *)pluginID
                   registryID:(uint64_t)registryID
                  pixelFormat:(MTLPixelFormat)pixelFormat
{
    NSString *key = [NSString stringWithFormat:@"%@_%lu", pluginID, (unsigned long) pixelFormat];
    [[self cacheItemForRegistryID:registryID] registerPipelineState:pipelineState forKey:key];
}

- (nullable id<MTLRenderPipelineState>)pipelineStateForPluginID:(NSString *)pluginID
                                                     registryID:(uint64_t)registryID
                                                    pixelFormat:(MTLPixelFormat)pixelFormat
{
    NSString *key = [NSString stringWithFormat:@"%@_%lu", pluginID, (unsigned long)pixelFormat];
    return [[self cacheItemForRegistryID:registryID] pipelineStateForKey:key];
}

- (nullable id<MTLCommandQueue>)commandQueueWithRegistryID:(uint64_t)registryID
                                               pixelFormat:(MTLPixelFormat)pixelFormat
{
    return [[self cacheItemForRegistryID:registryID] getNextFreeCommandQueue];
}

- (void)returnCommandQueueToCache:(id<MTLCommandQueue>)commandQueue
{
    for (KKMetalDeviceCacheItem *item in _deviceCaches)
    {
        if ([item containsCommandQueue:commandQueue])
        {
            [item returnCommandQueue:commandQueue];
            break;
        }
    }
}

+ (MTLPixelFormat)pixelFormatForImageTile:(FxImageTile *)imageTile
{
    switch (imageTile.ioSurface.pixelFormat) {
        case kCVPixelFormatType_128RGBAFloat:
            return MTLPixelFormatRGBA32Float;
        case kCVPixelFormatType_32BGRA:
            return MTLPixelFormatBGRA8Unorm;
        default:
            return MTLPixelFormatRGBA16Float;
    }
}

@end
