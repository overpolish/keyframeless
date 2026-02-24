//
//  MetalDeviceCache.m
//  Rounded
//
//  Created by Dom on 23/02/2026.
//

#import "MetalDeviceCache.h"

const NSUInteger    kMaxCommandQueues   = 5;
static NSString*    kKey_InUse          = @"InUse";
static NSString*    kKey_CommandQueue   = @"CommandQueue";

static MetalDeviceCache*   gDeviceCache    = nil;

@interface MetalDeviceCacheItem : NSObject

@property (readonly)    id<MTLDevice>                           gpuDevice;
@property (readonly)    id<MTLRenderPipelineState>              pipelineState;
@property (readonly)    id<MTLRenderPipelineState>              oscPipelineState;
@property (retain)      NSMutableArray<NSMutableDictionary*>*   commandQueueCache;
@property (readonly)    NSLock*                                 commandQueueCacheLock;
@property (readonly)    MTLPixelFormat                          pixelFormat;

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   pixelFormat:(MTLPixelFormat)pixFormat;
- (id<MTLCommandQueue>)getNextFreeCommandQueue;
- (void)returnCommandQueue:(id<MTLCommandQueue>)commandQueue;
- (BOOL)containsCommandQueue:(id<MTLCommandQueue>)commandQueue;

@end

@implementation MetalDeviceCacheItem

- (instancetype)initWithDevice:(id<MTLDevice>)device
                   pixelFormat:(MTLPixelFormat)pixFormat;
{
    self = [super init];
    
    if (self != nil)
    {
        _gpuDevice = [device retain];
        
        _commandQueueCache = [[NSMutableArray alloc] initWithCapacity:kMaxCommandQueues];
        for (NSUInteger i = 0; (_commandQueueCache != nil) && (i < kMaxCommandQueues); i++)
        {
            NSMutableDictionary*   commandDict = [NSMutableDictionary dictionary];
            [commandDict setObject:[NSNumber numberWithBool:NO]
                            forKey:kKey_InUse];
            
            id<MTLCommandQueue> commandQueue    = [_gpuDevice newCommandQueue];
            [commandDict setObject:commandQueue
                            forKey:kKey_CommandQueue];
            
            [_commandQueueCache addObject:commandDict];
        }
        
        // Load all the shader files with a .metal file extension in the project
        id<MTLLibrary> defaultLibrary = [[_gpuDevice newDefaultLibrary] autorelease];
        
        // Load the vertex function from the library
        id<MTLFunction> vertexFunction = [[defaultLibrary newFunctionWithName:@"vertexShader"] autorelease];
        
        // Load the fragment function from the library
        id<MTLFunction> fragmentFunction = [[defaultLibrary newFunctionWithName:@"fragmentShader"] autorelease];
        
        id<MTLFunction> oscVertexFunction = [[defaultLibrary newFunctionWithName:@"OSCVertexShader"] autorelease];
        id<MTLFunction> oscFragmentFunction = [[defaultLibrary newFunctionWithName:@"OSCFragmentShader"] autorelease];
        
        // Configure a pipeline descriptor that is used to create a pipeline state
        MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
        pipelineStateDescriptor.label = @"Simple Pipeline";
        pipelineStateDescriptor.vertexFunction = vertexFunction;
        pipelineStateDescriptor.fragmentFunction = fragmentFunction;
        pipelineStateDescriptor.colorAttachments[0].pixelFormat = pixFormat;
        _pixelFormat = pixFormat;
        
        NSError*    error = nil;
        _pipelineState = [_gpuDevice newRenderPipelineStateWithDescriptor:pipelineStateDescriptor
                                                                              error:&error];
        if (error != nil)
        {
            NSLog (@"Error generating radius pipeline state: %@", error);
        }
        
        MTLRenderPipelineDescriptor *oscStateDescriptor = [[[MTLRenderPipelineDescriptor alloc] init] autorelease];
        oscStateDescriptor.label = @"Rounded OSC Pipeline State";
        oscStateDescriptor.vertexFunction = oscVertexFunction;
        oscStateDescriptor.fragmentFunction = oscFragmentFunction;
        oscStateDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        
        _oscPipelineState = [_gpuDevice newRenderPipelineStateWithDescriptor:oscStateDescriptor
                                                                       error:&error];
        
        if (_commandQueueCache != nil)
        {
            _commandQueueCacheLock = [[NSLock alloc] init];
        }
        
        if (_commandQueueCache != nil)
        {
            _commandQueueCacheLock = [[NSLock alloc] init];
        }
        
        if ((_gpuDevice == nil) || (_commandQueueCache == nil) || (_commandQueueCacheLock == nil) ||
            (_pipelineState == nil) || (_oscPipelineState == nil))
        {
            [self release];
            self = nil;
        }
    }
    
    return self;
}

- (void)dealloc
{
    [_gpuDevice release];
    [_commandQueueCache release];
    [_commandQueueCacheLock release];
    [_pipelineState release];
    [_oscPipelineState release];
    
    [super dealloc];
}

- (id<MTLCommandQueue>)getNextFreeCommandQueue
{
    id<MTLCommandQueue> result  = nil;
    
    [_commandQueueCacheLock lock];
    NSUInteger  index   = 0;
    while ((result == nil) && (index < kMaxCommandQueues))
    {
        NSMutableDictionary*    nextCommandQueue    = [_commandQueueCache objectAtIndex:index];
        NSNumber*               inUse               = [nextCommandQueue objectForKey:kKey_InUse];
        if (![inUse boolValue])
        {
            [nextCommandQueue setObject:[NSNumber numberWithBool:YES]
                                 forKey:kKey_InUse];
            result = [nextCommandQueue objectForKey:kKey_CommandQueue];
        }
        index++;
    }
    [_commandQueueCacheLock unlock];
    
    return result;
}

- (void)returnCommandQueue:(id<MTLCommandQueue>)commandQueue
{
    [_commandQueueCacheLock lock];
    
    BOOL        found   = false;
    NSUInteger  index   = 0;
    while ((!found) && (index < kMaxCommandQueues))
    {
        NSMutableDictionary*    nextCommandQueuDict = [_commandQueueCache objectAtIndex:index];
        id<MTLCommandQueue>     nextCommandQueue    = [nextCommandQueuDict objectForKey:kKey_CommandQueue];
        if (nextCommandQueue == commandQueue)
        {
            found = YES;
            [nextCommandQueuDict setObject:[NSNumber numberWithBool:NO]
                                    forKey:kKey_InUse];
        }
        index++;
    }
    
    [_commandQueueCacheLock unlock];
}

- (BOOL)containsCommandQueue:(id<MTLCommandQueue>)commandQueue
{
    BOOL        found   = NO;
    NSUInteger  index   = 0;
    while ((!found) && (index < kMaxCommandQueues))
    {
        NSMutableDictionary*    nextCommandQueuDict = [_commandQueueCache objectAtIndex:index];
        id<MTLCommandQueue>     nextCommandQueue    = [nextCommandQueuDict objectForKey:kKey_CommandQueue];
        if (nextCommandQueue == commandQueue)
        {
            found = YES;
        }
        index++;
    }
    
    return found;
}

@end

@implementation MetalDeviceCache

+ (MTLPixelFormat)MTLPixelFormatForImageTile:(FxImageTile*)imageTile
{
    MTLPixelFormat  result  = MTLPixelFormatRGBA16Float;
    
    switch (imageTile.ioSurface.pixelFormat)
    {
        case kCVPixelFormatType_128RGBAFloat:
            result = MTLPixelFormatRGBA32Float;
            break;
            
        case kCVPixelFormatType_32BGRA:
            result = MTLPixelFormatBGRA8Unorm;
            break;
            
        default:
            break;
    }
    
    return result;
}

+ (MetalDeviceCache*)deviceCache;
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gDeviceCache = [[MetalDeviceCache alloc] init];
    });
    
    return gDeviceCache;
}

- (instancetype)init
{
    self = [super init];
    
    if (self != nil)
    {
        NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
        
        deviceCaches = [[NSMutableArray alloc] initWithCapacity:devices.count];
        
        for (id<MTLDevice> nextDevice in devices)
        {
            MetalDeviceCacheItem*  newCacheItem    = [[[MetalDeviceCacheItem alloc] initWithDevice:nextDevice
                                                                                       pixelFormat:MTLPixelFormatRGBA16Float]
                                                      autorelease];
            [deviceCaches addObject:newCacheItem];
        }
        
        [devices release];
    }
    
    return self;
}

- (void)dealloc
{
    [deviceCaches release];
    
    [super dealloc];
}

- (id<MTLDevice>)deviceWithRegistryID:(uint64_t)registryID
{
    for (MetalDeviceCacheItem* nextCacheItem in deviceCaches)
    {
        if (nextCacheItem.gpuDevice.registryID == registryID)
        {
            return nextCacheItem.gpuDevice;
        }
    }
    
    return nil;
}

- (id<MTLRenderPipelineState>)pipelineStateWithRegistryID:(uint64_t)registryID
                                              pixelFormat:(MTLPixelFormat)pixFormat
{
    for (MetalDeviceCacheItem* nextCacheItem in deviceCaches)
    {
        if ((nextCacheItem.gpuDevice.registryID == registryID)  &&
            (nextCacheItem.pixelFormat == pixFormat))
        {
            return nextCacheItem.pipelineState;
        }
    }
    // Didn't find one, so create one with the right settings
    NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
    id<MTLDevice>   device  = nil;
    for (id<MTLDevice> nextDevice in devices)
    {
        if (nextDevice.registryID == registryID)
        {
            device = nextDevice;
        }
    }
    
    id<MTLRenderPipelineState>  result  = nil;
    if (device != nil)
    {
        MetalDeviceCacheItem*   newCacheItem    = [[[MetalDeviceCacheItem alloc] initWithDevice:device
                                                                                    pixelFormat:pixFormat]
                                                    autorelease];
        if (newCacheItem != nil)
        {
            [deviceCaches addObject:newCacheItem];
            result = newCacheItem.pipelineState;
        }
    }
    [devices release];
    return result;
}

- (id<MTLRenderPipelineState>)oscPipelineStateWithRegistryID:(uint64_t)registryID
{
    for (MetalDeviceCacheItem* nextCacheItem in deviceCaches)
    {
        if (nextCacheItem.gpuDevice.registryID == registryID)
        {
            return nextCacheItem.oscPipelineState;
        }
    }
    
    return nil;
}

- (id<MTLCommandQueue>)commandQueueWithRegistryID:(uint64_t)registryID
                                      pixelFormat:(MTLPixelFormat)pixFormat;
{
    for (MetalDeviceCacheItem* nextCacheItem in deviceCaches)
    {
        if ((nextCacheItem.gpuDevice.registryID == registryID) &&
            (nextCacheItem.pixelFormat == pixFormat))
        {
            return [nextCacheItem getNextFreeCommandQueue];
        }
    }
    
    // Didn't find one, so create one with the right settings
    NSArray<id<MTLDevice>>* devices = MTLCopyAllDevices();
    id<MTLDevice>   device  = nil;
    for (id<MTLDevice> nextDevice in devices)
    {
        if (nextDevice.registryID == registryID)
        {
            device = nextDevice;
        }
    }
    
    id<MTLCommandQueue>  result  = nil;
    if (device != nil)
    {
        MetalDeviceCacheItem*   newCacheItem    = [[[MetalDeviceCacheItem alloc] initWithDevice:device
                                                                                    pixelFormat:pixFormat]
                                                   autorelease];
        if (newCacheItem != nil)
        {
            [deviceCaches addObject:newCacheItem];
            result = [newCacheItem getNextFreeCommandQueue];
        }
    }
    [devices release];
    return result;
}

- (void)returnCommandQueueToCache:(id<MTLCommandQueue>)commandQueue;
{
    for (MetalDeviceCacheItem* nextCacheItem in deviceCaches)
    {
        if ([nextCacheItem containsCommandQueue:commandQueue])
        {
            [nextCacheItem returnCommandQueue:commandQueue];
            break;
        }
    }
}

@end
