#include <objc/message.h>
// XnuCpuMetal.bundle — Pure-CPU Metal plugin for xnulinux (macOS 27).
// Principal class: XnuCpuMetalDevice (subclass of IOGPUMetalDevice).
// Backend: libxnu_m2v.dylib (steelbrain/metal2vulkan) -> libvulkan.1.dylib -> Mesa lavapipe (libvulkan_lvp.dylib).

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurfaceRef.h>
#import <IOKit/IOKitLib.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <deque>
#include <functional>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include "xnu_m2v.h"
#include "XnuCpuMetalShim.h"

@interface IOGPUMetalDevice : NSObject
@end

@protocol XcmOriginalStitching
- (NSString *)newDagStringWithGraphs:(NSArray<MTLFunctionStitchingGraph *> *)graphs;
@end

@interface MTLFunctionConstantValues (XcmPrivateAccess)
- (NSArray *)newIndexedConstantArray;
- (NSArray *)newNamedConstantArray;
@end

@protocol XcmPrivateConstantValue
- (NSUInteger)dataType;
- (void *)data;
- (NSUInteger)index;
- (NSString *)name;
@end

static bool xcmTraceOn() { static bool on = getenv("XNU_CPU_METAL_TRACE") != nullptr; return on; }

static NSError *xcmError(NSString *domain, NSInteger code, const char *fallback) {
    const char *msg = xm2v_last_error();
    NSString *desc = (msg && msg[0]) ? [NSString stringWithUTF8String:msg]
                                     : [NSString stringWithUTF8String:(fallback ?: "XnuCpuMetal error")];
    return [NSError errorWithDomain:domain code:code userInfo:@{NSLocalizedDescriptionKey: desc}];
}

static uint64_t xcmConstantBytes(uint64_t type) {
    switch (type) {
        case 3: case 29: case 33: return 4;
        case 4: case 30: case 34: return 8;
        case 5: case 31: case 35: return 12;
        case 6: case 32: case 36: return 16;
        case 16: case 37: case 41: case 121: return 2;
        case 17: case 38: case 42: case 122: return 4;
        case 18: case 39: case 43: case 123: return 6;
        case 19: case 40: case 44: case 124: return 8;
        case 45: case 49: case 53: return 1;
        case 46: case 50: case 54: return 2;
        case 47: case 51: case 55: return 3;
        case 48: case 52: case 56: return 4;
        case 81: case 85: return 8;
        case 82: case 86: return 16;
        case 83: case 87: return 24;
        case 84: case 88: return 32;
        default: return 0;
    }
}

/* ======================== MTLCompiler CodeGen (Stitched Libraries) ======================== */

typedef void (^XcmCodeGenReply)(int32_t status, const void *reply, size_t length, const char *message);

static void *xcmRunBlock(void *block) {
    @autoreleasepool { ((__bridge void (^)(void))block)(); }
    return nullptr;
}

static void xcmOnLargeStack(void (^body)(void)) {
    pthread_attr_t attr;
    pthread_t thread;
    if (pthread_attr_init(&attr)) { body(); return; }
    bool made = !pthread_attr_setstacksize(&attr, 16u << 20) &&
                !pthread_create(&thread, &attr, xcmRunBlock, (__bridge void *)body);
    pthread_attr_destroy(&attr);
    if (made) pthread_join(thread, nullptr);
    else body();
}

static NSData *xcmCodeGenRequest(uint32_t type, const std::vector<uint8_t> &request,
                                 NSString **warnings, NSString **failure) {
    static void *service = nullptr;
    static void (*build)(void *, void *, uint32_t, const void *, size_t, XcmCodeGenReply) = nullptr;
    static dispatch_once_t once;
    static std::mutex lock;
    dispatch_once(&once, ^{
        static const char kFramework[] = "/System/Library/PrivateFrameworks/MTLCompiler.framework";
        std::string path = std::string(kFramework) + "/MTLCompiler";
        void *lib = dlopen(path.c_str(), RTLD_NOW);
        if (!lib) {
            static const char kPrefix[] = "/System/Library/PrivateFrameworks/MTLCompiler.framework/Versions/";
            for (uint32_t i = 0, n = _dyld_image_count(); i < n && !lib; i++) {
                const char *name = _dyld_get_image_name(i);
                if (!name || !strstr(name, "/Metal.framework/") || strcmp(strrchr(name, '/'), "/Metal")) continue;
                unsigned long size = 0;
                const char *strings = (const char *)getsectiondata(
                    (const struct mach_header_64 *)_dyld_get_image_header(i), "__TEXT", "__cstring", &size);
                for (unsigned long at = 0; strings && at + sizeof(kPrefix) < size;) {
                    const char *text = strings + at;
                    size_t len = strnlen(text, size - at);
                    if (!strncmp(text, kPrefix, sizeof(kPrefix) - 1) && len > sizeof(kPrefix) &&
                        !strcmp(text + len - 12, "/MTLCompiler")) {
                        path.assign(text, len);
                        lib = dlopen(path.c_str(), RTLD_NOW);
                        break;
                    }
                    at += len + 1;
                }
            }
        }
        if (!lib) {
            path = std::string(kFramework) + "/Versions/Current/MTLCompiler";
            lib = dlopen(path.c_str(), RTLD_NOW);
        }
        if (!lib) {
            unsigned long highest = 0;
            for (NSString *entry in [[NSFileManager defaultManager]
                     contentsOfDirectoryAtPath:[@(kFramework) stringByAppendingString:@"/Versions"] error:nil]) {
                unsigned long ver = strtoul(entry.UTF8String, nullptr, 10);
                if (ver > highest && [entry isEqualToString:[NSString stringWithFormat:@"%lu", ver]]) highest = ver;
            }
            if (highest) {
                path = std::string(kFramework) + "/Versions/" + std::to_string(highest) + "/MTLCompiler";
                lib = dlopen(path.c_str(), RTLD_NOW);
            }
        }
        auto create = lib ? (void *(*)(const char *))dlsym(lib, "MTLCodeGenServiceCreate") : nullptr;
        build = lib ? (void (*)(void *, void *, uint32_t, const void *, size_t, XcmCodeGenReply))
                          dlsym(lib, "MTLCodeGenServiceBuildRequest")
                    : nullptr;
        service = (create && build) ? create("xnu-cpu-metal") : nullptr;
    });
    if (!service) {
        if (failure) *failure = @"MTLCompiler.framework not available";
        return nil;
    }
    __block NSData *metallib = nil;
    __block NSString *warned = nil, *message = nil;
    __block bool called = false;
    {
        std::lock_guard<std::mutex> guard(lock);
        xcmOnLargeStack(^{
            build(service, nullptr, type, request.data(), request.size(),
                  ^(int32_t status, const void *reply, size_t length, const char *why) {
                      called = true;
                      uint32_t hdr = 0, warn = 0;
                      if (reply && length >= 16) {
                          memcpy(&hdr, (const uint8_t *)reply + 8, 4);
                          memcpy(&warn, (const uint8_t *)reply + 12, 4);
                      }
                      if (status || !reply || length < 16 || (uint64_t)hdr + warn > length) {
                          message = (why && *why) ? @(why)
                                                  : [NSString stringWithFormat:@"MTLCompiler failed (status %d)", status];
                          return;
                      }
                      if (warn) {
                          warned = [[NSString alloc] initWithBytes:(const uint8_t *)reply + hdr
                                                            length:warn
                                                          encoding:NSUTF8StringEncoding];
                      }
                      metallib = [NSData dataWithBytes:(const uint8_t *)reply + hdr + warn
                                                length:length - hdr - warn];
                  });
        });
    }
    if (!called) message = @"MTLCompiler did not respond";
    if (warnings) *warnings = warned;
    if (failure) *failure = message;
    return metallib;
}

/* ======================== Base Object ======================== */

@interface XcmObject : NSObject
@property (nonatomic, copy) NSString *label;
@end
@implementation XcmObject
- (uint64_t)globalTraceObjectID { return 0; }
@end

/* ======================== Buffer ======================== */

@interface XcmBuffer : XcmObject {
@public
    Xm2vBuffer *_handle;
    id _device;
    MTLResourceOptions _options;
    uint64_t _length;
    MTLPurgeableState _purgeable;
}
- (instancetype)initWithHandle:(Xm2vBuffer *)h device:(id)dev options:(MTLResourceOptions)opts;
@end

@implementation XcmBuffer
- (instancetype)initWithHandle:(Xm2vBuffer *)h device:(id)dev options:(MTLResourceOptions)opts {
    if ((self = [super init])) {
        _handle = h;
        _device = dev;
        _options = opts;
        _length = xm2v_buffer_length(h);
        _purgeable = MTLPurgeableStateNonVolatile;
    }
    return self;
}
- (void)dealloc {
    if (_handle) { xm2v_buffer_release(_handle); _handle = nullptr; }
}
- (id<MTLDevice>)device { return _device; }
- (void *)contents { return _handle ? xm2v_buffer_contents(_handle) : nullptr; }
- (NSUInteger)length { return (NSUInteger)_length; }
- (uint64_t)gpuAddress { return _handle ? xm2v_buffer_gpu_address(_handle) : 0; }
- (void)didModifyRange:(NSRange)range {
    if (_handle) xm2v_buffer_did_modify_range(_handle, range.location, range.length);
}
- (MTLResourceOptions)resourceOptions { return _options; }
- (MTLStorageMode)storageMode { return (MTLStorageMode)((_options & MTLResourceStorageModeMask) >> MTLResourceStorageModeShift); }
- (MTLCPUCacheMode)cpuCacheMode { return (MTLCPUCacheMode)((_options & MTLResourceCPUCacheModeMask) >> MTLResourceCPUCacheModeShift); }
- (MTLHazardTrackingMode)hazardTrackingMode { return (MTLHazardTrackingMode)((_options & MTLResourceHazardTrackingModeMask) >> MTLResourceHazardTrackingModeShift); }
- (NSUInteger)allocatedSize { return (NSUInteger)_length; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state {
    MTLPurgeableState prev = _purgeable;
    if (state != MTLPurgeableStateKeepCurrent) _purgeable = state;
    return prev;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow {
    (void)offset; (void)bytesPerRow;
    return [_device newTextureWithDescriptor:desc];
}
@end

/* ======================== Texture (with IOSurface bidirectional sync) ======================== */

@interface XcmTexture : XcmObject {
@public
    Xm2vTexture *_handle;
    id _device;
    MTLTextureType _textureType;
    MTLPixelFormat _pixelFormat;
    NSUInteger _width, _height, _depth, _mipLevels, _sampleCount, _arrayLength;
    MTLTextureUsage _usage;
    MTLResourceOptions _options;
    MTLPurgeableState _purgeable;
    IOSurfaceRef _iosurface;
    NSUInteger _iosurfacePlane;
    uint32_t _iosurfaceSeed;
    BOOL _iosurfaceSyncedIn;
}
- (instancetype)initWithHandle:(Xm2vTexture *)h device:(id)dev descriptor:(MTLTextureDescriptor *)desc;
- (void)syncFromIOSurfaceIfNeeded;
- (void)syncToIOSurface;
@end

@implementation XcmTexture
- (instancetype)initWithHandle:(Xm2vTexture *)h device:(id)dev descriptor:(MTLTextureDescriptor *)desc {
    if ((self = [super init])) {
        _handle = h;
        _device = dev;
        _textureType = desc.textureType;
        _pixelFormat = desc.pixelFormat;
        _width = desc.width;
        _height = desc.height;
        _depth = desc.depth;
        _mipLevels = desc.mipmapLevelCount;
        _sampleCount = desc.sampleCount;
        _arrayLength = desc.arrayLength;
        _usage = desc.usage;
        _options = desc.resourceOptions;
        _purgeable = MTLPurgeableStateNonVolatile;
    }
    return self;
}
- (void)dealloc {
    if (_handle) { xm2v_texture_release(_handle); _handle = nullptr; }
    if (_iosurface) { CFRelease(_iosurface); _iosurface = nullptr; }
}
static std::mutex gIOSurfaceWriterLock;
static std::unordered_map<uint32_t, __weak id> gIOSurfaceLastWriter;

static void xcmRecordIOSurfaceWriter(IOSurfaceRef surf, id cmdBuf) {
    if (!surf || !cmdBuf) return;
    uint32_t sid = IOSurfaceGetID(surf);
    if (!sid) return;
    std::lock_guard<std::mutex> lk(gIOSurfaceWriterLock);
    gIOSurfaceLastWriter[sid] = cmdBuf;
}

static void xcmFlushIOSurfaceWriter(IOSurfaceRef surf) {
    if (!surf) return;
    uint32_t sid = IOSurfaceGetID(surf);
    if (!sid) return;
    id writer = nil;
    {
        std::lock_guard<std::mutex> lk(gIOSurfaceWriterLock);
        auto it = gIOSurfaceLastWriter.find(sid);
        if (it != gIOSurfaceLastWriter.end()) writer = it->second;
    }
    if (writer && [writer respondsToSelector:@selector(waitUntilCompleted)] &&
        [(id<MTLCommandBuffer>)writer status] >= MTLCommandBufferStatusCommitted) {
        [(id<MTLCommandBuffer>)writer waitUntilCompleted];
    }
}

- (void)syncFromIOSurfaceIfNeeded {
    if (!_iosurface || !_handle) return;
    xcmFlushIOSurfaceWriter(_iosurface);
    uint32_t seed = IOSurfaceGetSeed(_iosurface);
    if (_iosurfaceSyncedIn && seed == _iosurfaceSeed) return;
    if (IOSurfaceLock(_iosurface, kIOSurfaceLockReadOnly, nullptr) == kIOReturnSuccess) {
        size_t planeCount = IOSurfaceGetPlaneCount(_iosurface);
        void *base = (planeCount > 0) ? IOSurfaceGetBaseAddressOfPlane(_iosurface, _iosurfacePlane)
                                      : IOSurfaceGetBaseAddress(_iosurface);
        size_t bpr = (planeCount > 0) ? IOSurfaceGetBytesPerRowOfPlane(_iosurface, _iosurfacePlane)
                                      : IOSurfaceGetBytesPerRow(_iosurface);
        if (base && bpr > 0) {
            xm2v_texture_replace_region(_handle, 0, 0, 0, _width, _height, 1, 0, 0, base, bpr, 0);
        }
        IOSurfaceUnlock(_iosurface, kIOSurfaceLockReadOnly, nullptr);
        _iosurfaceSeed = seed;
        _iosurfaceSyncedIn = YES;
    }
}
- (void)syncToIOSurface {
    if (!_iosurface || !_handle) return;
    if (IOSurfaceLock(_iosurface, 0, nullptr) == kIOReturnSuccess) {
        size_t planeCount = IOSurfaceGetPlaneCount(_iosurface);
        void *base = (planeCount > 0) ? IOSurfaceGetBaseAddressOfPlane(_iosurface, _iosurfacePlane)
                                      : IOSurfaceGetBaseAddress(_iosurface);
        size_t bpr = (planeCount > 0) ? IOSurfaceGetBytesPerRowOfPlane(_iosurface, _iosurfacePlane)
                                      : IOSurfaceGetBytesPerRow(_iosurface);
        if (base && bpr > 0) {
            bool ok = xm2v_texture_get_bytes(_handle, base, bpr, 0, 0, 0, 0, _width, _height, 1, 0, 0);
            if (xcmTraceOn() || !ok) {
                const uint8_t *p = (const uint8_t *)base;
                size_t nz = 0;
                for (size_t i = 0; i < bpr * _height; i++) if (p[i]) nz++;
                fprintf(stderr, "XCM syncToIOSurface(%p surf=%p fmt=%lu %lux%lu bpr=%zu) ok=%d nz=%zu/%zu err=%s\n",
                        (__bridge void *)self, _iosurface, (unsigned long)_pixelFormat,
                        (unsigned long)_width, (unsigned long)_height, bpr, ok, nz, bpr * _height,
                        ok ? "ok" : xm2v_last_error());
            }
        }
        IOSurfaceUnlock(_iosurface, 0, nullptr);
        _iosurfaceSeed = IOSurfaceGetSeed(_iosurface);
        _iosurfaceSyncedIn = YES;
    }
}
- (id<MTLDevice>)device { return _device; }
- (MTLTextureType)textureType { return _textureType; }
- (MTLPixelFormat)pixelFormat { return _pixelFormat; }
- (NSUInteger)width { return _width; }
- (NSUInteger)height { return _height; }
- (NSUInteger)depth { return _depth; }
- (NSUInteger)mipmapLevelCount { return _mipLevels; }
- (NSUInteger)sampleCount { return _sampleCount; }
- (NSUInteger)arrayLength { return _arrayLength; }
- (MTLTextureUsage)usage { return _usage; }
- (MTLResourceOptions)resourceOptions { return _options; }
- (MTLStorageMode)storageMode { return (MTLStorageMode)((_options & MTLResourceStorageModeMask) >> MTLResourceStorageModeShift); }
- (MTLCPUCacheMode)cpuCacheMode { return (MTLCPUCacheMode)((_options & MTLResourceCPUCacheModeMask) >> MTLResourceCPUCacheModeShift); }
- (MTLHazardTrackingMode)hazardTrackingMode { return (MTLHazardTrackingMode)((_options & MTLResourceHazardTrackingModeMask) >> MTLResourceHazardTrackingModeShift); }
- (BOOL)isFramebufferOnly { return NO; }
- (BOOL)allowGPUOptimizedContents { return YES; }
- (BOOL)isDrawable { return NO; }
- (NSUInteger)protectionOptions { return 0; }
- (NSUInteger)allocatedSize {
    NSUInteger bpp = 4;
    switch (_pixelFormat) {
        case MTLPixelFormatA8Unorm: case MTLPixelFormatR8Unorm: case MTLPixelFormatR8Snorm:
        case MTLPixelFormatR8Uint: case MTLPixelFormatR8Sint: case MTLPixelFormatStencil8:
            bpp = 1; break;
        case MTLPixelFormatR16Unorm: case MTLPixelFormatR16Snorm: case MTLPixelFormatR16Uint:
        case MTLPixelFormatR16Sint: case MTLPixelFormatR16Float: case MTLPixelFormatRG8Unorm:
        case MTLPixelFormatRG8Snorm: case MTLPixelFormatRG8Uint: case MTLPixelFormatRG8Sint:
        case MTLPixelFormatDepth16Unorm:
            bpp = 2; break;
        case MTLPixelFormatRGBA16Unorm: case MTLPixelFormatRGBA16Snorm: case MTLPixelFormatRGBA16Uint:
        case MTLPixelFormatRGBA16Sint: case MTLPixelFormatRGBA16Float:
        case MTLPixelFormatRG32Uint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRG32Float:
        case MTLPixelFormatDepth32Float_Stencil8:
            bpp = 8; break;
        case MTLPixelFormatRGBA32Uint: case MTLPixelFormatRGBA32Sint: case MTLPixelFormatRGBA32Float:
            bpp = 16; break;
        default: bpp = 4; break;
    }
    NSUInteger sz = MAX(1ul, _width) * MAX(1ul, _height) * MAX(1ul, _depth) * MAX(1ul, _arrayLength) * MAX(1ul, _sampleCount) * bpp;
    return (sz + 255ul) & ~255ul;
}
- (id<MTLTexture>)parentTexture { return nil; }
- (id<MTLBuffer>)buffer { return nil; }
- (IOSurfaceRef)iosurface { return _iosurface; }
- (NSUInteger)iosurfacePlane { return _iosurfacePlane; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state {
    MTLPurgeableState prev = _purgeable;
    if (state != MTLPurgeableStateKeepCurrent) _purgeable = state;
    return prev;
}
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice
            withBytes:(const void *)pixelBytes bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage {
    if (_handle) {
        xm2v_texture_replace_region(_handle,
            region.origin.x, region.origin.y, region.origin.z,
            region.size.width, region.size.height, region.size.depth,
            level, slice, pixelBytes, bytesPerRow, bytesPerImage);
    }
}
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level
            withBytes:(const void *)pixelBytes bytesPerRow:(NSUInteger)bytesPerRow {
    [self replaceRegion:region mipmapLevel:level slice:0 withBytes:pixelBytes bytesPerRow:bytesPerRow bytesPerImage:0];
}
- (void)getBytes:(void *)pixelBytes bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage
      fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice {
    if (_handle) {
        xm2v_texture_get_bytes(_handle, pixelBytes, bytesPerRow, bytesPerImage,
            region.origin.x, region.origin.y, region.origin.z,
            region.size.width, region.size.height, region.size.depth,
            level, slice);
    }
}
- (void)getBytes:(void *)pixelBytes bytesPerRow:(NSUInteger)bytesPerRow
      fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level {
    [self getBytes:pixelBytes bytesPerRow:bytesPerRow bytesPerImage:0 fromRegion:region mipmapLevel:level slice:0];
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)pixelFormat
                                    textureType:(MTLTextureType)textureType
                                         levels:(NSRange)levelRange
                                         slices:(NSRange)sliceRange {
    if (!_handle) return nil;
    Xm2vTexture *vh = xm2v_texture_new_view(_handle, (uint64_t)pixelFormat, (uint64_t)textureType,
                                            levelRange.location, levelRange.length,
                                            sliceRange.location, sliceRange.length);
    if (!vh) return nil;
    MTLTextureDescriptor *desc = [[MTLTextureDescriptor alloc] init];
    desc.textureType = textureType;
    desc.pixelFormat = pixelFormat;
    desc.width = MAX(1ul, _width >> levelRange.location);
    desc.height = MAX(1ul, _height >> levelRange.location);
    desc.depth = MAX(1ul, _depth >> levelRange.location);
    desc.mipmapLevelCount = levelRange.length;
    desc.sampleCount = _sampleCount;
    desc.arrayLength = sliceRange.length;
    desc.usage = _usage;
    desc.resourceOptions = _options;
    return (id<MTLTexture>)[[XcmTexture alloc] initWithHandle:vh device:_device descriptor:desc];
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)pixelFormat {
    return [self newTextureViewWithPixelFormat:pixelFormat textureType:_textureType
                                        levels:NSMakeRange(0, _mipLevels)
                                        slices:NSMakeRange(0, _arrayLength)];
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)pixelFormat
                                    textureType:(MTLTextureType)textureType
                                         levels:(NSRange)levelRange
                                         slices:(NSRange)sliceRange
                                        swizzle:(MTLTextureSwizzleChannels)swizzle {
    (void)swizzle;
    return [self newTextureViewWithPixelFormat:pixelFormat textureType:textureType levels:levelRange slices:sliceRange];
}
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (BOOL)isAliasable { return NO; }
- (MTLTextureSwizzleChannels)swizzle {
    return MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
}
- (MTLResourceID)gpuResourceID {
    MTLResourceID rid = { _handle ? xm2v_texture_gpu_resource_id(_handle) : 0 };
    return rid;
}
@end

/* ======================== Function & Library ======================== */

@class XcmLibrary;

@interface XcmArgumentEncoder : XcmObject {
@public
    Xm2vArgumentEncoder *_handle;
    id _device;
    id _argumentBuffer;
}
- (instancetype)initWithHandle:(Xm2vArgumentEncoder *)h device:(id)dev;
@end

@interface XcmFunction : XcmObject {
@public
    Xm2vFunction *_handle;
    id _device;
    XcmLibrary *_library;
    NSString *_name;
    NSString *_sourceName;
    MTLFunctionType _functionType;
    MTLFunctionConstantValues *_constantValues;
}
- (instancetype)initWithHandle:(Xm2vFunction *)h device:(id)dev library:(XcmLibrary *)lib name:(NSString *)name type:(MTLFunctionType)type;
@end

@implementation XcmFunction
- (instancetype)initWithHandle:(Xm2vFunction *)h device:(id)dev library:(XcmLibrary *)lib name:(NSString *)name type:(MTLFunctionType)type {
    if ((self = [super init])) {
        _handle = h;
        _device = dev;
        _library = lib;
        _name = [name copy];
        _sourceName = [name copy];
        _functionType = h ? (MTLFunctionType)xm2v_function_type(h) : type;
    }
    return self;
}
- (void)dealloc {
    if (_handle) { xm2v_function_release(_handle); _handle = nullptr; }
}
- (id<MTLDevice>)device { return _device; }
- (NSString *)name { return _name; }
- (MTLFunctionType)functionType { return _functionType; }
- (NSArray *)vertexAttributes { return @[]; }
- (NSArray *)stageInputAttributes { return @[]; }
- (NSDictionary *)functionConstantsDictionary { return @{}; }
- (id<MTLArgumentEncoder>)newArgumentEncoderWithBufferIndex:(NSUInteger)bufferIndex {
    if (!_handle) return nil;
    Xm2vArgumentEncoder *enc = xm2v_function_new_argument_encoder(_handle, (uint32_t)bufferIndex);
    if (!enc) {
        if (xcmTraceOn()) fprintf(stderr, "XCM newArgumentEncoderWithBufferIndex:%lu (%s) FAILED: %s\n",
                                  (unsigned long)bufferIndex, _name.UTF8String ?: "?", xm2v_last_error());
        return nil;
    }
    return (id<MTLArgumentEncoder>)[[XcmArgumentEncoder alloc] initWithHandle:enc device:_device];
}
- (id<MTLArgumentEncoder>)newArgumentEncoderWithBufferIndex:(NSUInteger)bufferIndex
                                                 reflection:(MTLAutoreleasedArgument *)reflection {
    if (reflection) *reflection = nil;
    return [self newArgumentEncoderWithBufferIndex:bufferIndex];
}
@end

@interface XcmLibrary : XcmObject {
@public
    Xm2vLibrary *_handle;
    id _device;
    NSData *_metallibData;
}
- (instancetype)initWithHandle:(Xm2vLibrary *)h device:(id)dev data:(NSData *)data;
@end

static bool xcmForEachMetallibEntry(NSData *data, const std::function<bool(const std::string &, int)> &visit) {
    if (!data || data.length < 88) return false;
    const uint8_t *file = (const uint8_t *)data.bytes;
    size_t length = data.length;
    if (memcmp(file, "MTLB", 4) != 0) return false;
    uint64_t listAt = 0;
    memcpy(&listAt, file + 24, 8);
    if (listAt > length - 4) return false;
    uint32_t count = 0;
    memcpy(&count, file + listAt, 4);
    size_t at = listAt + 4;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t size = 0;
        if (at > length - 4) return false;
        memcpy(&size, file + at, 4);
        if (size < 8 || size > length - at) return false;
        size_t end = at + size;
        std::string entry;
        int type = -1;
        for (size_t t = at + 4; t + 4 <= end && memcmp(file + t, "ENDT", 4) != 0;) {
            if (t + 6 > end) return false;
            uint16_t n = 0;
            memcpy(&n, file + t + 4, 2);
            const uint8_t *v = file + t + 6;
            if (n > end - (t + 6)) return false;
            if (!memcmp(file + t, "NAME", 4)) entry.assign((const char *)v, strnlen((const char *)v, n));
            else if (!memcmp(file + t, "TYPE", 4) && n >= 1) type = v[0];
            t += 6 + n;
        }
        if (!visit(entry, type)) return true;
        at = end;
    }
    return true;
}

static NSData *xcmExtractFunctionBitcode(XcmFunction *fn) {
    if (!fn || !fn->_library || !fn->_library->_metallibData) return nil;
    NSData *data = fn->_library->_metallibData;
    const uint8_t *file = (const uint8_t *)data.bytes;
    size_t length = data.length;
    const char *wanted = (fn->_sourceName ?: fn->_name).UTF8String;
    if (!file || !wanted || length < 88 || memcmp(file, "MTLB", 4) != 0) return nil;
    uint64_t listAt = 0, bitcodeAt = 0, bitcodeSize = 0;
    memcpy(&listAt, file + 24, 8);
    memcpy(&bitcodeAt, file + 72, 8);
    memcpy(&bitcodeSize, file + 80, 8);
    if (listAt > length - 4 || bitcodeAt > length || bitcodeSize > length - bitcodeAt) return nil;
    uint32_t count = 0;
    memcpy(&count, file + listAt, 4);
    size_t at = listAt + 4;
    for (uint32_t i = 0; i < count; i++) {
        uint32_t size = 0;
        if (at > length - 4) return nil;
        memcpy(&size, file + at, 4);
        if (size < 8 || size > length - at) return nil;
        size_t end = at + size;
        std::string name;
        uint64_t bytes = 0, offset = 0;
        bool sized = false, placed = false;
        for (size_t t = at + 4; t + 4 <= end && memcmp(file + t, "ENDT", 4) != 0;) {
            if (t + 6 > end) return nil;
            uint16_t n = 0;
            memcpy(&n, file + t + 4, 2);
            const uint8_t *v = file + t + 6;
            if (n > end - (t + 6)) return nil;
            if (!memcmp(file + t, "NAME", 4)) name.assign((const char *)v, strnlen((const char *)v, n));
            else if (!memcmp(file + t, "MDSZ", 4) && n >= 8) { memcpy(&bytes, v, 8); sized = true; }
            else if (!memcmp(file + t, "OFFT", 4) && n >= 24) { memcpy(&offset, v + 16, 8); placed = true; }
            t += 6 + n;
        }
        if (name == wanted) {
            if (!sized || !placed || offset > bitcodeSize || bytes > bitcodeSize - offset) return nil;
            return [NSData dataWithBytes:file + bitcodeAt + offset length:(NSUInteger)bytes];
        }
        at = end;
    }
    return nil;
}

static XcmFunction *xcmLookupCIKernelFunction(XcmLibrary *lib, NSString *name) {
    if (!lib || !lib->_metallibData || !name || lib->_metallibData.length < 88) return nil;
    const uint8_t *file = (const uint8_t *)lib->_metallibData.bytes;
    if (file[10] != 1) return nil; // file_type 1 = CoreImage / dynamic kernel library
    const char *wanted = name.UTF8String;
    if (!wanted) return nil;
    XcmFunction *found = nil;
    xcmForEachMetallibEntry(lib->_metallibData, [&](const std::string &entry, int type) {
        if (entry != wanted) return true;
        if (type == 5) {
            found = [[XcmFunction alloc] initWithHandle:nullptr device:lib->_device library:lib name:name type:(MTLFunctionType)4];
        }
        return false;
    });
    return found;
}

@implementation XcmLibrary
- (instancetype)initWithHandle:(Xm2vLibrary *)h device:(id)dev data:(NSData *)data {
    if ((self = [super init])) {
        _handle = h;
        _device = dev;
        _metallibData = data;
    }
    return self;
}
- (void)dealloc {
    if (_handle) { xm2v_library_release(_handle); _handle = nullptr; }
}
- (id<MTLDevice>)device { return _device; }
- (MTLLibraryType)type { return MTLLibraryTypeExecutable; }
- (NSString *)installName { return nil; }
- (NSArray<NSString *> *)functionNames {
    NSMutableArray<NSString *> *arr = [NSMutableArray array];
    if (!_handle) return arr;
    size_t count = xm2v_library_function_count(_handle);
    char buf[512];
    for (size_t i = 0; i < count; i++) {
        size_t len = xm2v_library_function_name_at(_handle, i, buf, sizeof(buf));
        if (len > 0) [arr addObject:[NSString stringWithUTF8String:buf]];
    }
    return arr;
}
- (NSArray<NSString *> *)externFunctionNames {
    NSMutableArray<NSString *> *arr = [NSMutableArray array];
    if (_handle) {
        size_t count = xm2v_library_extern_function_count(_handle);
        char buf[512];
        for (size_t i = 0; i < count; i++) {
            size_t len = xm2v_library_extern_function_name_at(_handle, i, buf, sizeof(buf));
            if (len > 0) [arr addObject:[NSString stringWithUTF8String:buf]];
        }
    }
    if (arr.count == 0 && _metallibData) {
        xcmForEachMetallibEntry(_metallibData, [&](const std::string &entry, int type) {
            if (type == 5 && !entry.empty()) [arr addObject:@(entry.c_str())];
            return true;
        });
    }
    return arr;
}
- (id<MTLFunction>)newFunctionWithName:(NSString *)functionName {
    if (!functionName) return nil;
    if (XcmFunction *ciFn = xcmLookupCIKernelFunction(self, functionName))
        return (id<MTLFunction>)ciFn;
    if (!_handle) return nil;
    Xm2vFunction *fn = xm2v_library_new_function(_handle, functionName.UTF8String);
    if (!fn) fn = xm2v_library_new_extern_function(_handle, functionName.UTF8String);
    if (!fn) return nil;
    return (id<MTLFunction>)[[XcmFunction alloc] initWithHandle:fn device:_device library:self name:functionName type:MTLFunctionTypeKernel];
}
static void xcmExtractConstants(MTLFunctionConstantValues *constantValues,
                                std::vector<Xm2vConstant> &constants,
                                std::deque<std::string> &nameStorage,
                                std::deque<std::vector<uint8_t>> &byteStorage) {
    if (!constantValues) return;
    MTLFunctionConstantValues *snap = [constantValues copy];
    NSArray *indexed = [snap respondsToSelector:@selector(newIndexedConstantArray)] ? [snap newIndexedConstantArray] : nil;
    NSArray *named = [snap respondsToSelector:@selector(newNamedConstantArray)] ? [snap newNamedConstantArray] : nil;
    for (int grp = 0; grp < 2; grp++) {
        for (id<XcmPrivateConstantValue> v in (grp ? named : indexed)) {
            uint64_t dt = v.dataType;
            uint64_t sz = xcmConstantBytes(dt);
            void *ptr = v.data;
            if (!sz || !ptr) continue;
            byteStorage.emplace_back((const uint8_t *)ptr, (const uint8_t *)ptr + (size_t)sz);
            Xm2vConstant c = {};
            c.data_type = dt;
            if (grp == 0) {
                c.index = (uint32_t)v.index;
                c.name = nullptr;
            } else {
                nameStorage.emplace_back(v.name.UTF8String ?: "");
                c.name = nameStorage.back().c_str();
            }
            c.bytes = byteStorage.back().data();
            c.length = (size_t)sz;
            constants.push_back(c);
        }
    }
}

- (id<MTLFunction>)newFunctionWithName:(NSString *)name
                        constantValues:(MTLFunctionConstantValues *)constantValues
                                 error:(NSError **)error {
    if (!name) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorFunctionNotFound, "Nil function name");
        return nil;
    }
    if (XcmFunction *ciFn = xcmLookupCIKernelFunction(self, name)) {
        if (error) *error = nil;
        return (id<MTLFunction>)ciFn;
    }
    if (!_handle) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorInternal, "Null library");
        return nil;
    }
    std::vector<Xm2vConstant> constants;
    std::deque<std::string> nameStorage;
    std::deque<std::vector<uint8_t>> byteStorage;
    xcmExtractConstants(constantValues, constants, nameStorage, byteStorage);
    Xm2vFunction *fn = constants.empty()
        ? xm2v_library_new_function(_handle, name.UTF8String)
        : xm2v_library_new_function_specialized(_handle, name.UTF8String, constants.data(), (uint32_t)constants.size());
    if (!fn) fn = xm2v_library_new_extern_function(_handle, name.UTF8String);
    if (!fn) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorFunctionNotFound, "Function not found");
        return nil;
    }
    if (error) *error = nil;
    XcmFunction *out = [[XcmFunction alloc] initWithHandle:fn device:_device library:self name:name type:MTLFunctionTypeKernel];
    if (constantValues) out->_constantValues = [constantValues copy];
    return (id<MTLFunction>)out;
}
- (void)newFunctionWithName:(NSString *)name
             constantValues:(MTLFunctionConstantValues *)constantValues
          completionHandler:(void (^)(id<MTLFunction>, NSError *))completionHandler {
    NSError *err = nil;
    id<MTLFunction> fn = [self newFunctionWithName:name constantValues:constantValues error:&err];
    if (completionHandler) completionHandler(fn, err);
}
- (id<MTLFunction>)newFunctionWithDescriptor:(MTLFunctionDescriptor *)d error:(NSError **)error {
    if (!d || !d.name) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorFunctionNotFound, "Missing function name");
        return nil;
    }
    if (XcmFunction *ciFn = xcmLookupCIKernelFunction(self, d.name)) {
        if (d.specializedName) ciFn->_name = [d.specializedName copy];
        if (error) *error = nil;
        return (id<MTLFunction>)ciFn;
    }
    if (!_handle) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorInternal, "Null library");
        return nil;
    }
    std::vector<Xm2vConstant> constants;
    std::deque<std::string> nameStorage;
    std::deque<std::vector<uint8_t>> byteStorage;
    xcmExtractConstants(d.constantValues, constants, nameStorage, byteStorage);
    Xm2vFunction *fn = xm2v_library_new_function_with_descriptor(
        _handle,
        d.name.UTF8String,
        d.specializedName ? d.specializedName.UTF8String : nullptr,
        constants.empty() ? nullptr : constants.data(),
        (uint32_t)constants.size(),
        (uint64_t)d.options);
    if (!fn) fn = xm2v_library_new_extern_function(_handle, d.name.UTF8String);
    if (!fn) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorFunctionNotFound, "Function not found");
        return nil;
    }
    if (error) *error = nil;
    XcmFunction *out = [[XcmFunction alloc] initWithHandle:fn device:_device library:self name:d.name type:MTLFunctionTypeKernel];
    if (d.specializedName) out->_name = [d.specializedName copy];
    if (d.constantValues) out->_constantValues = [d.constantValues copy];
    return (id<MTLFunction>)out;
}
- (void)newFunctionWithDescriptor:(MTLFunctionDescriptor *)d
                completionHandler:(void (^)(id<MTLFunction>, NSError *))completionHandler {
    NSError *err = nil;
    id<MTLFunction> fn = [self newFunctionWithDescriptor:d error:&err];
    if (completionHandler) completionHandler(fn, err);
}
@end

/* ======================== Pipelines & States ======================== */

@interface XcmComputePipeline : XcmObject {
@public
    Xm2vComputePipeline *_handle;
    id _device;
}
- (instancetype)initWithHandle:(Xm2vComputePipeline *)h device:(id)dev;
@end

@implementation XcmComputePipeline
- (instancetype)initWithHandle:(Xm2vComputePipeline *)h device:(id)dev {
    if ((self = [super init])) { _handle = h; _device = dev; }
    return self;
}
- (void)dealloc { if (_handle) { xm2v_compute_pipeline_release(_handle); _handle = nullptr; } }
- (id<MTLDevice>)device { return _device; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return _handle ? (NSUInteger)xm2v_compute_pipeline_max_threads(_handle) : 64; }
- (NSUInteger)threadExecutionWidth { return _handle ? (NSUInteger)xm2v_compute_pipeline_thread_width(_handle) : 4; }
- (NSUInteger)staticThreadgroupMemoryLength { return _handle ? (NSUInteger)xm2v_compute_pipeline_static_tg_mem(_handle) : 0; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
@end

@interface XcmRenderPipeline : XcmObject {
@public
    Xm2vRenderPipeline *_handle;
    id _device;
}
- (instancetype)initWithHandle:(Xm2vRenderPipeline *)h device:(id)dev;
@end

@implementation XcmRenderPipeline
- (instancetype)initWithHandle:(Xm2vRenderPipeline *)h device:(id)dev {
    if ((self = [super init])) { _handle = h; _device = dev; }
    return self;
}
- (void)dealloc { if (_handle) { xm2v_render_pipeline_release(_handle); _handle = nullptr; } }
- (id<MTLDevice>)device { return _device; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
@end

@interface XcmSampler : XcmObject {
@public
    Xm2vSampler *_handle;
    id _device;
}
- (instancetype)initWithHandle:(Xm2vSampler *)h device:(id)dev;
@end
@implementation XcmSampler
- (instancetype)initWithHandle:(Xm2vSampler *)h device:(id)dev {
    if ((self = [super init])) { _handle = h; _device = dev; }
    return self;
}
- (void)dealloc { if (_handle) { xm2v_sampler_release(_handle); _handle = nullptr; } }
- (id<MTLDevice>)device { return _device; }
- (MTLResourceID)gpuResourceID {
    MTLResourceID rid = { _handle ? xm2v_sampler_gpu_resource_id(_handle) : 0 };
    return rid;
}
@end

@implementation XcmArgumentEncoder
- (instancetype)initWithHandle:(Xm2vArgumentEncoder *)h device:(id)dev {
    if ((self = [super init])) { _handle = h; _device = dev; }
    return self;
}
- (void)dealloc {
    if (_handle) { xm2v_argument_encoder_release(_handle); _handle = nullptr; }
}
- (id<MTLDevice>)device { return _device; }
- (NSUInteger)encodedLength { return _handle ? (NSUInteger)xm2v_argument_encoder_encoded_length(_handle) : 0; }
- (NSUInteger)alignment { return _handle ? (NSUInteger)xm2v_argument_encoder_alignment(_handle) : 1; }
- (void)setArgumentBuffer:(id<MTLBuffer>)argumentBuffer offset:(NSUInteger)offset {
    if (!_handle) return;
    _argumentBuffer = argumentBuffer;
    Xm2vBuffer *bh = (argumentBuffer && [argumentBuffer isKindOfClass:[XcmBuffer class]])
        ? ((XcmBuffer *)argumentBuffer)->_handle : nullptr;
    if (!xm2v_argument_encoder_set_argument_buffer(_handle, bh, offset) && xcmTraceOn())
        fprintf(stderr, "XCM argEnc setArgumentBuffer:offset:%lu FAILED: %s\n", (unsigned long)offset, xm2v_last_error());
}
- (void)setArgumentBuffer:(id<MTLBuffer>)argumentBuffer startOffset:(NSUInteger)startOffset arrayElement:(NSUInteger)arrayElement {
    if (!_handle) return;
    _argumentBuffer = argumentBuffer;
    Xm2vBuffer *bh = (argumentBuffer && [argumentBuffer isKindOfClass:[XcmBuffer class]])
        ? ((XcmBuffer *)argumentBuffer)->_handle : nullptr;
    if (!xm2v_argument_encoder_set_argument_buffer_array_element(_handle, bh, startOffset, arrayElement) && xcmTraceOn())
        fprintf(stderr, "XCM argEnc setArgumentBuffer:startOffset:%lu:arrayElement:%lu FAILED: %s\n",
                (unsigned long)startOffset, (unsigned long)arrayElement, xm2v_last_error());
}
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    if (!_handle) return;
    Xm2vBuffer *bh = (buffer && [buffer isKindOfClass:[XcmBuffer class]]) ? ((XcmBuffer *)buffer)->_handle : nullptr;
    xm2v_argument_encoder_set_buffer(_handle, bh, offset, (uint32_t)index);
}
- (void)setBuffers:(const id<MTLBuffer> *)buffers offsets:(const NSUInteger *)offsets withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++)
        [self setBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
}
- (void)setTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    if (!_handle) return;
    Xm2vTexture *th = nullptr;
    if (texture && [texture isKindOfClass:[XcmTexture class]]) {
        XcmTexture *xt = (XcmTexture *)texture;
        [xt syncFromIOSurfaceIfNeeded];
        th = xt->_handle;
    }
    xm2v_argument_encoder_set_texture(_handle, th, (uint32_t)index);
}
- (void)setTextures:(const id<MTLTexture> *)textures withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++)
        [self setTexture:textures[i] atIndex:range.location + i];
}
- (void)setSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    if (!_handle) return;
    Xm2vSampler *sh = (sampler && [sampler isKindOfClass:[XcmSampler class]]) ? ((XcmSampler *)sampler)->_handle : nullptr;
    xm2v_argument_encoder_set_sampler(_handle, sh, (uint32_t)index);
}
- (void)setSamplerStates:(const id<MTLSamplerState> *)samplers withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++)
        [self setSamplerState:samplers[i] atIndex:range.location + i];
}
- (void)setComputePipelineState:(id<MTLComputePipelineState>)pipeline atIndex:(NSUInteger)index {
    if (!_handle) return;
    Xm2vComputePipeline *ph = (pipeline && [pipeline isKindOfClass:[XcmComputePipeline class]]) ? ((XcmComputePipeline *)pipeline)->_handle : nullptr;
    xm2v_argument_encoder_set_compute_pipeline(_handle, ph, (uint32_t)index);
}
- (void)setComputePipelineStates:(const id<MTLComputePipelineState> *)pipelines withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++)
        [self setComputePipelineState:pipelines[i] atIndex:range.location + i];
}
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)pipeline atIndex:(NSUInteger)index {
    if (!_handle) return;
    Xm2vRenderPipeline *ph = (pipeline && [pipeline isKindOfClass:[XcmRenderPipeline class]]) ? ((XcmRenderPipeline *)pipeline)->_handle : nullptr;
    xm2v_argument_encoder_set_render_pipeline(_handle, ph, (uint32_t)index);
}
- (void)setRenderPipelineStates:(const id<MTLRenderPipelineState> *)pipelines withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++)
        [self setRenderPipelineState:pipelines[i] atIndex:range.location + i];
}
- (void *)constantDataAtIndex:(NSUInteger)index {
    return _handle ? xm2v_argument_encoder_constant_data(_handle, (uint32_t)index) : nullptr;
}
- (id<MTLArgumentEncoder>)newArgumentEncoderForBufferAtIndex:(NSUInteger)index {
    if (!_handle) return nil;
    Xm2vArgumentEncoder *nested = xm2v_argument_encoder_new_nested(_handle, (uint32_t)index);
    return nested ? (id<MTLArgumentEncoder>)[[XcmArgumentEncoder alloc] initWithHandle:nested device:_device] : nil;
}
@end

@interface XcmDepthStencil : XcmObject {
@public
    Xm2vDepthStencil *_handle;
    id _device;
}
- (instancetype)initWithHandle:(Xm2vDepthStencil *)h device:(id)dev;
@end
@implementation XcmDepthStencil
- (instancetype)initWithHandle:(Xm2vDepthStencil *)h device:(id)dev {
    if ((self = [super init])) { _handle = h; _device = dev; }
    return self;
}
- (void)dealloc { if (_handle) { xm2v_depth_stencil_release(_handle); _handle = nullptr; } }
- (id<MTLDevice>)device { return _device; }
@end

@interface XcmEvent : XcmObject {
@public
    Xm2vEvent *_handle;
    id _device;
}
- (instancetype)initWithHandle:(Xm2vEvent *)h device:(id)dev;
@end
@implementation XcmEvent
- (instancetype)initWithHandle:(Xm2vEvent *)h device:(id)dev {
    if ((self = [super init])) { _handle = h; _device = dev; }
    return self;
}
- (void)dealloc { if (_handle) { xm2v_event_release(_handle); _handle = nullptr; } }
- (id<MTLDevice>)device { return _device; }
@end

@interface XcmFence : XcmObject {
@public
    Xm2vFence *_handle;
    id _device;
}
- (instancetype)initWithHandle:(Xm2vFence *)h device:(id)dev;
@end
@implementation XcmFence
- (instancetype)initWithHandle:(Xm2vFence *)h device:(id)dev {
    if ((self = [super init])) { _handle = h; _device = dev; }
    return self;
}
- (void)dealloc { if (_handle) { xm2v_fence_release(_handle); _handle = nullptr; } }
- (id<MTLDevice>)device { return _device; }
@end

@interface XcmHeap : XcmObject {
@public
    id _device;
    NSUInteger _size;
    MTLStorageMode _storageMode;
    MTLCPUCacheMode _cpuCacheMode;
    MTLHazardTrackingMode _hazardTrackingMode;
    MTLHeapType _type;
    MTLPurgeableState _purgeable;
}
- (instancetype)initWithDevice:(id)dev descriptor:(MTLHeapDescriptor *)desc;
@end

@implementation XcmHeap
- (instancetype)initWithDevice:(id)dev descriptor:(MTLHeapDescriptor *)desc {
    if ((self = [super init])) {
        _device = dev;
        _size = desc.size;
        _storageMode = desc.storageMode;
        _cpuCacheMode = desc.cpuCacheMode;
        _hazardTrackingMode = desc.hazardTrackingMode;
        _type = desc.type;
        _purgeable = MTLPurgeableStateNonVolatile;
    }
    return self;
}
- (id<MTLDevice>)device { return _device; }
- (NSUInteger)size { return _size; }
- (NSUInteger)usedSize { return 0; }
- (NSUInteger)currentAllocatedSize { return _size; }
- (MTLStorageMode)storageMode { return _storageMode; }
- (MTLCPUCacheMode)cpuCacheMode { return _cpuCacheMode; }
- (MTLHazardTrackingMode)hazardTrackingMode { return _hazardTrackingMode; }
- (MTLResourceOptions)resourceOptions {
    return ((MTLResourceOptions)_storageMode << MTLResourceStorageModeShift) |
           ((MTLResourceOptions)_cpuCacheMode << MTLResourceCPUCacheModeShift) |
           ((MTLResourceOptions)_hazardTrackingMode << MTLResourceHazardTrackingModeShift);
}
- (MTLHeapType)type { return _type; }
- (NSUInteger)protectionOptions { return 0; }
- (NSUInteger)maxAvailableSizeWithAlignment:(NSUInteger)alignment { (void)alignment; return _size; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state {
    MTLPurgeableState prev = _purgeable;
    if (state != MTLPurgeableStateKeepCurrent) _purgeable = state;
    return prev;
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    return [_device newBufferWithLength:length options:options];
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options offset:(NSUInteger)offset {
    (void)offset;
    return [_device newBufferWithLength:length options:options];
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc {
    return [_device newTextureWithDescriptor:desc];
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)desc offset:(NSUInteger)offset {
    (void)offset;
    return [_device newTextureWithDescriptor:desc];
}
@end

/* ======================== Forward declaration for CommandBuffer ======================== */

@interface XcmCommandBuffer : XcmObject {
@public
    Xm2vCommandBuffer *_handle;
    id _device;
    id _queue;
    NSMutableArray<MTLCommandBufferHandler> *_scheduledHandlers;
    NSMutableArray<MTLCommandBufferHandler> *_completedHandlers;
    NSMutableArray<XcmTexture *> *_dirtyIOSurfaceTextures;
    BOOL _handlersFired;
    BOOL _iosurfaceFlushed;
    NSUInteger _protectionOptions;
}
- (instancetype)initWithHandle:(Xm2vCommandBuffer *)h device:(id)dev queue:(id)q;
- (void)markDirtyIOSurfaceTexture:(XcmTexture *)tex;
@end

/* ======================== Encoders ======================== */

@interface XcmComputeEncoder : XcmObject {
@public
    Xm2vComputeEncoder *_handle;
    id _device;
    XcmCommandBuffer *_cmdBuf;
    NSMutableArray *_retained;
    id _boundBuffers[31];
}
- (instancetype)initWithHandle:(Xm2vComputeEncoder *)h device:(id)dev commandBuffer:(XcmCommandBuffer *)cb;
@end

@implementation XcmComputeEncoder
- (instancetype)initWithHandle:(Xm2vComputeEncoder *)h device:(id)dev commandBuffer:(XcmCommandBuffer *)cb {
    if ((self = [super init])) {
        _handle = h;
        _device = dev;
        _cmdBuf = cb;
        _retained = [NSMutableArray array];
    }
    return self;
}
- (void)dealloc {
    if (_handle) { xm2v_compute_encoder_end(_handle); _handle = nullptr; }
}
- (id<MTLDevice>)device { return _device; }
- (void)setComputePipelineState:(id<MTLComputePipelineState>)state {
    if (!_handle || !state) return;
    [_retained addObject:state];
    xm2v_compute_encoder_set_pipeline(_handle, ((XcmComputePipeline *)state)->_handle);
}
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    if (!_handle) return;
    if (index < 31) _boundBuffers[index] = buffer;
    if (buffer) [_retained addObject:buffer];
    Xm2vBuffer *bh = buffer ? ((XcmBuffer *)buffer)->_handle : nullptr;
    xm2v_compute_encoder_set_buffer(_handle, bh, offset, (uint32_t)index);
}
- (void)setBuffers:(const id<MTLBuffer> *)buffers offsets:(const NSUInteger *)offsets withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++)
        [self setBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
}
- (void)setBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index {
    if (index < 31 && _boundBuffers[index])
        [self setBuffer:_boundBuffers[index] offset:offset atIndex:index];
}
- (void)setBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index {
    if (_handle) xm2v_compute_encoder_set_bytes(_handle, bytes, length, (uint32_t)index);
}
- (void)setTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    if (!_handle) return;
    if (texture && [texture isKindOfClass:[XcmTexture class]]) {
        XcmTexture *xt = (XcmTexture *)texture;
        [_retained addObject:xt];
        [xt syncFromIOSurfaceIfNeeded];
        if (xt->_iosurface && (xt->_usage & MTLTextureUsageShaderWrite))
            [_cmdBuf markDirtyIOSurfaceTexture:xt];
    }
    Xm2vTexture *th = texture ? ((XcmTexture *)texture)->_handle : nullptr;
    xm2v_compute_encoder_set_texture(_handle, th, (uint32_t)index);
}
- (void)setTextures:(const id<MTLTexture> *)textures withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++)
        [self setTexture:textures[i] atIndex:range.location + i];
}
- (void)setSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    if (!_handle) return;
    if (sampler) [_retained addObject:sampler];
    Xm2vSampler *sh = sampler ? ((XcmSampler *)sampler)->_handle : nullptr;
    xm2v_compute_encoder_set_sampler(_handle, sh, (uint32_t)index);
}
- (void)setSamplerStates:(const id<MTLSamplerState> *)samplers withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++)
        [self setSamplerState:samplers[i] atIndex:range.location + i];
}
- (void)setThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index {
    if (_handle) xm2v_compute_encoder_set_threadgroup_memory_length(_handle, (uint32_t)length, (uint32_t)index);
}
- (void)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage {
    if (!_handle || !resource) return;
    [_retained addObject:resource];
    if ([resource isKindOfClass:[XcmBuffer class]]) {
        xm2v_compute_encoder_use_buffer(_handle, ((XcmBuffer *)resource)->_handle, (uint64_t)usage);
    } else if ([resource isKindOfClass:[XcmTexture class]]) {
        XcmTexture *xt = (XcmTexture *)resource;
        if (usage & (MTLResourceUsageRead | MTLResourceUsageSample)) [xt syncFromIOSurfaceIfNeeded];
        if ((usage & MTLResourceUsageWrite) && xt->_iosurface) [_cmdBuf markDirtyIOSurfaceTexture:xt];
        xm2v_compute_encoder_use_texture(_handle, xt->_handle, (uint64_t)usage);
    }
}
- (void)useResources:(const id<MTLResource> *)resources count:(NSUInteger)count usage:(MTLResourceUsage)usage {
    for (NSUInteger i = 0; i < count; i++)
        [self useResource:resources[i] usage:usage];
}
- (void)useHeap:(id<MTLHeap>)heap { (void)heap; }
- (void)useHeaps:(const id<MTLHeap> *)heaps count:(NSUInteger)count { (void)heaps; (void)count; }
- (void)dispatchThreadgroups:(MTLSize)threadgroupsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup {
    if (_handle) {
        xm2v_compute_encoder_dispatch_threadgroups(_handle,
            threadgroupsPerGrid.width, threadgroupsPerGrid.height, threadgroupsPerGrid.depth,
            threadsPerThreadgroup.width, threadsPerThreadgroup.height, threadsPerThreadgroup.depth);
    }
}
- (void)dispatchThreads:(MTLSize)threadsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup {
    if (_handle) {
        xm2v_compute_encoder_dispatch_threads(_handle,
            threadsPerGrid.width, threadsPerGrid.height, threadsPerGrid.depth,
            threadsPerThreadgroup.width, threadsPerThreadgroup.height, threadsPerThreadgroup.depth);
    }
}
- (void)endEncoding {
    if (_handle) { xm2v_compute_encoder_end(_handle); _handle = nullptr; }
    [_retained removeAllObjects];
}
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
- (void)insertDebugSignpost:(NSString *)string { (void)string; }
@end

@interface XcmRenderEncoder : XcmObject {
@public
    Xm2vRenderEncoder *_handle;
    id _device;
    XcmCommandBuffer *_cmdBuf;
    NSMutableArray *_retained;
    NSMutableDictionary *_vbufs, *_fbufs;   // slot -> bound buffer (for set*BufferOffset:atIndex:)
    BOOL _hasPipeline;
}
- (instancetype)initWithHandle:(Xm2vRenderEncoder *)h device:(id)dev commandBuffer:(XcmCommandBuffer *)cb;
@end

@implementation XcmRenderEncoder
- (instancetype)initWithHandle:(Xm2vRenderEncoder *)h device:(id)dev commandBuffer:(XcmCommandBuffer *)cb {
    if ((self = [super init])) { _handle = h; _device = dev; _cmdBuf = cb; _retained = [NSMutableArray array]; }
    return self;
}
- (void)dealloc { if (_handle) { xm2v_render_encoder_end(_handle); _handle = nullptr; } }
- (id<MTLDevice>)device { return _device; }
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)pipelineState {
    if (!_handle) return;
    if (!pipelineState || ![pipelineState isKindOfClass:[XcmRenderPipeline class]] || !((XcmRenderPipeline *)pipelineState)->_handle) {
        _hasPipeline = NO;
        return;
    }
    _hasPipeline = YES;
    [_retained addObject:pipelineState];
    bool ok = xm2v_render_encoder_set_pipeline(_handle, ((XcmRenderPipeline *)pipelineState)->_handle);
    if (!ok) fprintf(stderr, "XCM setRenderPipelineState FAILED: %s\n", xm2v_last_error());
}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)depthStencilState {
    if (!_handle) return;
    if (depthStencilState) [_retained addObject:depthStencilState];
    Xm2vDepthStencil *h = depthStencilState ? ((XcmDepthStencil *)depthStencilState)->_handle : nullptr;
    xm2v_render_encoder_set_depth_stencil(_handle, h);
}
- (void)setViewport:(MTLViewport)vp {
    if (_handle) xm2v_render_encoder_set_viewport(_handle, vp.originX, vp.originY, vp.width, vp.height, vp.znear, vp.zfar);
}
- (void)setScissorRect:(MTLScissorRect)r {
    if (_handle) xm2v_render_encoder_set_scissor(_handle, r.x, r.y, r.width, r.height);
}
- (void)setCullMode:(MTLCullMode)cullMode {
    if (_handle) xm2v_render_encoder_set_cull_mode(_handle, (uint64_t)cullMode);
}
- (void)setFrontFacingWinding:(MTLWinding)winding {
    if (_handle) xm2v_render_encoder_set_front_facing_winding(_handle, (uint64_t)winding);
}
- (void)setVertexBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    if (!_handle) return;
    if (!_vbufs) _vbufs = [NSMutableDictionary dictionary];
    if (buffer) _vbufs[@(index)] = buffer; else [_vbufs removeObjectForKey:@(index)];
    if (buffer) [_retained addObject:buffer];
    xm2v_render_encoder_set_vertex_buffer(_handle, buffer ? ((XcmBuffer *)buffer)->_handle : nullptr, offset, (uint32_t)index);
}
- (void)setVertexBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index {
    if (_handle) xm2v_render_encoder_set_vertex_bytes(_handle, bytes, length, (uint32_t)index);
}
- (void)setVertexTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    if (!_handle) return;
    if (texture && [texture isKindOfClass:[XcmTexture class]]) {
        [_retained addObject:texture];
        [(XcmTexture *)texture syncFromIOSurfaceIfNeeded];
    }
    xm2v_render_encoder_set_vertex_texture(_handle, texture ? ((XcmTexture *)texture)->_handle : nullptr, (uint32_t)index);
}
- (void)setVertexSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    if (!_handle) return;
    if (sampler) [_retained addObject:sampler];
    xm2v_render_encoder_set_vertex_sampler(_handle, sampler ? ((XcmSampler *)sampler)->_handle : nullptr, (uint32_t)index);
}
- (void)setFragmentBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    if (!_handle) return;
    if (!_fbufs) _fbufs = [NSMutableDictionary dictionary];
    if (buffer) _fbufs[@(index)] = buffer; else [_fbufs removeObjectForKey:@(index)];
    if (buffer) [_retained addObject:buffer];
    xm2v_render_encoder_set_fragment_buffer(_handle, buffer ? ((XcmBuffer *)buffer)->_handle : nullptr, offset, (uint32_t)index);
}
- (void)setFragmentBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index {
    if (_handle) xm2v_render_encoder_set_fragment_bytes(_handle, bytes, length, (uint32_t)index);
}
- (void)setFragmentTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    if (!_handle) return;
    if (texture && [texture isKindOfClass:[XcmTexture class]]) {
        [_retained addObject:texture];
        [(XcmTexture *)texture syncFromIOSurfaceIfNeeded];
    }
    xm2v_render_encoder_set_fragment_texture(_handle, texture ? ((XcmTexture *)texture)->_handle : nullptr, (uint32_t)index);
}
- (void)setFragmentTextures:(const id<MTLTexture> *)textures withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++)
        [self setFragmentTexture:textures[i] atIndex:range.location + i];
}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    if (!_handle) return;
    if (sampler) [_retained addObject:sampler];
    xm2v_render_encoder_set_fragment_sampler(_handle, sampler ? ((XcmSampler *)sampler)->_handle : nullptr, (uint32_t)index);
}
- (void)setFragmentSamplerStates:(const id<MTLSamplerState> *)samplers withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++)
        [self setFragmentSamplerState:samplers[i] atIndex:range.location + i];
}
- (void)setVertexBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index {
    id b = _vbufs[@(index)]; if (b) [self setVertexBuffer:b offset:offset atIndex:index];
}
- (void)setFragmentBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index {
    id b = _fbufs[@(index)]; if (b) [self setFragmentBuffer:b offset:offset atIndex:index];
}
- (void)setVertexBuffers:(const id<MTLBuffer> *)buffers offsets:(const NSUInteger *)offsets withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++) [self setVertexBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
}
- (void)setFragmentBuffers:(const id<MTLBuffer> *)buffers offsets:(const NSUInteger *)offsets withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++) [self setFragmentBuffer:buffers[i] offset:offsets[i] atIndex:range.location + i];
}
- (void)setVertexTextures:(const id<MTLTexture> *)textures withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++) [self setVertexTexture:textures[i] atIndex:range.location + i];
}
- (void)setVertexSamplerStates:(const id<MTLSamplerState> *)samplers withRange:(NSRange)range {
    for (NSUInteger i = 0; i < range.length; i++) [self setVertexSamplerState:samplers[i] atIndex:range.location + i];
}
- (void)setViewports:(const MTLViewport *)viewports count:(NSUInteger)count { if (count) [self setViewport:viewports[0]]; }
- (void)setScissorRects:(const MTLScissorRect *)rects count:(NSUInteger)count { if (count) [self setScissorRect:rects[0]]; }
// State the CPU backend keeps at its defaults (fill, clip, bias, blend constant, stencil reference) and residency hints.
- (void)setTriangleFillMode:(MTLTriangleFillMode)mode { (void)mode; }
- (void)setDepthClipMode:(MTLDepthClipMode)mode { (void)mode; }
- (void)setDepthBias:(float)b slopeScale:(float)s clamp:(float)c { (void)b; (void)s; (void)c; }
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a {
    if (_handle) xm2v_render_encoder_set_blend_color(_handle, r, g, b, a);
}
- (void)setStencilReferenceValue:(uint32_t)v {
    if (_handle) xm2v_render_encoder_set_stencil_reference_values(_handle, v, v);
}
- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b {
    if (_handle) xm2v_render_encoder_set_stencil_reference_values(_handle, f, b);
}
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)mode offset:(NSUInteger)offset { (void)mode; (void)offset; }
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u stages:(MTLRenderStages)st {
    if (!_handle || !r) return;
    [_retained addObject:r];
    if ([r isKindOfClass:[XcmBuffer class]]) {
        xm2v_render_encoder_use_buffer(_handle, ((XcmBuffer *)r)->_handle, (uint64_t)u, (uint64_t)st);
    } else if ([r isKindOfClass:[XcmTexture class]]) {
        XcmTexture *xt = (XcmTexture *)r;
        if (u & (MTLResourceUsageRead | MTLResourceUsageSample)) [xt syncFromIOSurfaceIfNeeded];
        if ((u & MTLResourceUsageWrite) && xt->_iosurface) [_cmdBuf markDirtyIOSurfaceTexture:xt];
        xm2v_render_encoder_use_texture(_handle, xt->_handle, (uint64_t)u, (uint64_t)st);
    }
}
- (void)useResource:(id<MTLResource>)r usage:(MTLResourceUsage)u {
    [self useResource:r usage:u stages:(MTLRenderStageVertex | MTLRenderStageFragment)];
}
- (void)useResources:(const id<MTLResource> *)r count:(NSUInteger)n usage:(MTLResourceUsage)u stages:(MTLRenderStages)st {
    for (NSUInteger i = 0; i < n; i++) [self useResource:r[i] usage:u stages:st];
}
- (void)useResources:(const id<MTLResource> *)r count:(NSUInteger)n usage:(MTLResourceUsage)u {
    [self useResources:r count:n usage:u stages:(MTLRenderStageVertex | MTLRenderStageFragment)];
}
- (void)useHeap:(id<MTLHeap>)h { (void)h; }
- (void)useHeap:(id<MTLHeap>)h stages:(MTLRenderStages)st { (void)h; (void)st; }
- (void)useHeaps:(const id<MTLHeap> *)h count:(NSUInteger)n { (void)h; (void)n; }
- (void)useHeaps:(const id<MTLHeap> *)h count:(NSUInteger)n stages:(MTLRenderStages)st { (void)h; (void)n; (void)st; }
- (void)textureBarrier {}
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope afterStages:(MTLRenderStages)after beforeStages:(MTLRenderStages)before {
    (void)scope; (void)after; (void)before;
}
- (void)memoryBarrierWithResources:(const id<MTLResource> *)resources count:(NSUInteger)count afterStages:(MTLRenderStages)after beforeStages:(MTLRenderStages)before {
    (void)resources; (void)count; (void)after; (void)before;
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart
           vertexCount:(NSUInteger)vertexCount instanceCount:(NSUInteger)instanceCount
          baseInstance:(NSUInteger)baseInstance {
    if (_handle && _hasPipeline) {
        bool ok = xm2v_render_encoder_draw_primitives(_handle, (uint64_t)primitiveType, vertexStart, vertexCount, instanceCount, baseInstance);
        if (!ok) fprintf(stderr, "XCM drawPrimitives FAILED: %s\n", xm2v_last_error());
    }
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount {
    [self drawPrimitives:primitiveType vertexStart:vertexStart vertexCount:vertexCount instanceCount:1 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount
                    indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer
            indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instanceCount
                   baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)baseInstance {
    if (!_handle || !_hasPipeline || !indexBuffer) return;
    [_retained addObject:indexBuffer];
    bool ok = xm2v_render_encoder_draw_indexed_primitives(_handle, (uint64_t)primitiveType, indexCount, (uint64_t)indexType,
        ((XcmBuffer *)indexBuffer)->_handle, indexBufferOffset, instanceCount, baseVertex, baseInstance);
    if (!ok) fprintf(stderr, "XCM drawIndexedPrimitives FAILED: %s\n", xm2v_last_error());
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount
                    indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer
            indexBufferOffset:(NSUInteger)indexBufferOffset {
    [self drawIndexedPrimitives:primitiveType indexCount:indexCount indexType:indexType
                    indexBuffer:indexBuffer indexBufferOffset:indexBufferOffset
                  instanceCount:1 baseVertex:0 baseInstance:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount
                    indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer
            indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instanceCount {
    [self drawIndexedPrimitives:primitiveType indexCount:indexCount indexType:indexType
                    indexBuffer:indexBuffer indexBufferOffset:indexBufferOffset
                  instanceCount:instanceCount baseVertex:0 baseInstance:0];
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart
           vertexCount:(NSUInteger)vertexCount instanceCount:(NSUInteger)instanceCount {
    [self drawPrimitives:primitiveType vertexStart:vertexStart vertexCount:vertexCount instanceCount:instanceCount baseInstance:0];
}
- (void)endEncoding {
    if (_handle) { xm2v_render_encoder_end(_handle); _handle = nullptr; }
    [_retained removeAllObjects];
}
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
- (void)insertDebugSignpost:(NSString *)string { (void)string; }
@end

@interface XcmBlitEncoder : XcmObject {
@public
    Xm2vBlitEncoder *_handle;
    id _device;
    XcmCommandBuffer *_cmdBuf;
    NSMutableArray *_retained;
}
- (instancetype)initWithHandle:(Xm2vBlitEncoder *)h device:(id)dev commandBuffer:(XcmCommandBuffer *)cb;
@end

@implementation XcmBlitEncoder
- (instancetype)initWithHandle:(Xm2vBlitEncoder *)h device:(id)dev commandBuffer:(XcmCommandBuffer *)cb {
    if ((self = [super init])) { _handle = h; _device = dev; _cmdBuf = cb; _retained = [NSMutableArray array]; }
    return self;
}
- (void)dealloc { if (_handle) { xm2v_blit_encoder_end(_handle); _handle = nullptr; } }
- (id<MTLDevice>)device { return _device; }
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)srcOff
              toBuffer:(id<MTLBuffer>)dst destinationOffset:(NSUInteger)dstOff size:(NSUInteger)size {
    if (!_handle || !src || !dst) return;
    [_retained addObject:src]; [_retained addObject:dst];
    xm2v_blit_encoder_copy_buffer_to_buffer(_handle, ((XcmBuffer *)src)->_handle, srcOff, ((XcmBuffer *)dst)->_handle, dstOff, size);
}
- (void)copyFromBuffer:(id<MTLBuffer>)src sourceOffset:(NSUInteger)srcOff
     sourceBytesPerRow:(NSUInteger)bpr sourceBytesPerImage:(NSUInteger)bpi
            sourceSize:(MTLSize)sz toTexture:(id<MTLTexture>)dst
      destinationSlice:(NSUInteger)slice destinationLevel:(NSUInteger)level destinationOrigin:(MTLOrigin)origin {
    if (!_handle || !src || !dst) return;
    [_retained addObject:src]; [_retained addObject:dst];
    if ([dst isKindOfClass:[XcmTexture class]] && ((XcmTexture *)dst)->_iosurface)
        [_cmdBuf markDirtyIOSurfaceTexture:(XcmTexture *)dst];
    xm2v_blit_encoder_copy_buffer_to_texture(_handle, ((XcmBuffer *)src)->_handle, srcOff, bpr, bpi,
        sz.width, sz.height, sz.depth, ((XcmTexture *)dst)->_handle, slice, level, origin.x, origin.y, origin.z);
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)slice sourceLevel:(NSUInteger)level
           sourceOrigin:(MTLOrigin)origin sourceSize:(MTLSize)sz toBuffer:(id<MTLBuffer>)dst
      destinationOffset:(NSUInteger)dstOff destinationBytesPerRow:(NSUInteger)bpr destinationBytesPerImage:(NSUInteger)bpi {
    if (!_handle || !src || !dst) return;
    [_retained addObject:src]; [_retained addObject:dst];
    if ([src isKindOfClass:[XcmTexture class]]) [(XcmTexture *)src syncFromIOSurfaceIfNeeded];
    xm2v_blit_encoder_copy_texture_to_buffer(_handle, ((XcmTexture *)src)->_handle, slice, level,
        origin.x, origin.y, origin.z, sz.width, sz.height, sz.depth, ((XcmBuffer *)dst)->_handle, dstOff, bpr, bpi);
}
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
           sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)sz toTexture:(id<MTLTexture>)dst
       destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)do_ {
    if (!_handle || !src || !dst) return;
    [_retained addObject:src]; [_retained addObject:dst];
    if ([src isKindOfClass:[XcmTexture class]]) [(XcmTexture *)src syncFromIOSurfaceIfNeeded];
    if ([dst isKindOfClass:[XcmTexture class]] && ((XcmTexture *)dst)->_iosurface)
        [_cmdBuf markDirtyIOSurfaceTexture:(XcmTexture *)dst];
    xm2v_blit_encoder_copy_texture_to_texture(_handle, ((XcmTexture *)src)->_handle, ss, sl,
        so.x, so.y, so.z, sz.width, sz.height, sz.depth, ((XcmTexture *)dst)->_handle, ds, dl, do_.x, do_.y, do_.z);
}
- (void)fillBuffer:(id<MTLBuffer>)buffer range:(NSRange)range value:(uint8_t)value {
    if (!_handle || !buffer) return;
    [_retained addObject:buffer];
    xm2v_blit_encoder_fill_buffer(_handle, ((XcmBuffer *)buffer)->_handle, range.location, range.length, value);
}
- (void)generateMipmapsForTexture:(id<MTLTexture>)texture {
    if (!_handle || !texture) return;
    [_retained addObject:texture];
    xm2v_blit_encoder_generate_mipmaps(_handle, ((XcmTexture *)texture)->_handle);
}
- (void)synchronizeResource:(id<MTLResource>)resource {
    if (!_handle || !resource) return;
    [_retained addObject:resource];
    if ([resource isKindOfClass:[XcmBuffer class]])
        xm2v_blit_encoder_synchronize_buffer(_handle, ((XcmBuffer *)resource)->_handle);
    else if ([resource isKindOfClass:[XcmTexture class]])
        xm2v_blit_encoder_synchronize_texture(_handle, ((XcmTexture *)resource)->_handle);
}
- (void)endEncoding {
    if (_handle) { xm2v_blit_encoder_end(_handle); _handle = nullptr; }
    [_retained removeAllObjects];
}
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
- (void)insertDebugSignpost:(NSString *)string { (void)string; }
@end

/* ======================== CommandBuffer & Queue ======================== */

@implementation XcmCommandBuffer
- (instancetype)initWithHandle:(Xm2vCommandBuffer *)h device:(id)dev queue:(id)q {
    if ((self = [super init])) {
        _handle = h;
        _device = dev;
        _queue = q;
        _scheduledHandlers = [NSMutableArray array];
        _completedHandlers = [NSMutableArray array];
        _dirtyIOSurfaceTextures = [NSMutableArray array];
    }
    return self;
}
- (void)dealloc { if (_handle) { xm2v_command_buffer_release(_handle); _handle = nullptr; } }
- (void)markDirtyIOSurfaceTexture:(XcmTexture *)tex {
    if (tex && tex->_iosurface && ![_dirtyIOSurfaceTextures containsObject:tex]) {
        [_dirtyIOSurfaceTextures addObject:tex];
        xcmRecordIOSurfaceWriter(tex->_iosurface, self);
    }
}
- (id<MTLDevice>)device { return _device; }
- (id<MTLCommandQueue>)commandQueue { return _queue; }
- (BOOL)retainedReferences { return YES; }
- (NSUInteger)protectionOptions { return _protectionOptions; }
- (void)setProtectionOptions:(NSUInteger)opts { _protectionOptions = opts; }
- (CFTimeInterval)GPUStartTime { return 0.0; }
- (CFTimeInterval)GPUEndTime { return 0.0; }
- (CFTimeInterval)kernelStartTime { return 0.0; }
- (CFTimeInterval)kernelEndTime { return 0.0; }
- (MTLCommandBufferStatus)status {
    return _handle ? (MTLCommandBufferStatus)xm2v_command_buffer_status(_handle) : MTLCommandBufferStatusError;
}
- (NSError *)error {
    if (self.status == MTLCommandBufferStatusError)
        return xcmError(MTLCommandBufferErrorDomain, MTLCommandBufferErrorInternal, "Command buffer failed");
    return nil;
}
- (void)enqueue {}
- (void)addScheduledHandler:(MTLCommandBufferHandler)block {
    if (block) [_scheduledHandlers addObject:[block copy]];
}
- (void)addCompletedHandler:(MTLCommandBufferHandler)block {
    if (block) [_completedHandlers addObject:[block copy]];
}
- (void)_flushIOSurfacesOnce {
    @synchronized(self) {
        if (_iosurfaceFlushed) return;
        _iosurfaceFlushed = YES;
        for (XcmTexture *tex in _dirtyIOSurfaceTextures) [tex syncToIOSurface];
        [_dirtyIOSurfaceTextures removeAllObjects];
    }
}
- (void)_fireHandlersOnce {
    @synchronized(self) {
        if (_handlersFired) return;
        _handlersFired = YES;
        NSArray<MTLCommandBufferHandler> *sched = [_scheduledHandlers copy];
        NSArray<MTLCommandBufferHandler> *comp = [_completedHandlers copy];
        [_scheduledHandlers removeAllObjects];
        [_completedHandlers removeAllObjects];
        for (MTLCommandBufferHandler h in sched) h((id<MTLCommandBuffer>)self);
        for (MTLCommandBufferHandler h in comp) h((id<MTLCommandBuffer>)self);
    }
}
- (void)commit {
    if (xcmTraceOn()) fprintf(stderr, "XCM commit cb=%p sched=%lu comp=%lu dirty=%lu\n",
                              (__bridge void *)self, (unsigned long)_scheduledHandlers.count,
                              (unsigned long)_completedHandlers.count, (unsigned long)_dirtyIOSurfaceTextures.count);
    if (_handle) {
        bool ok = xm2v_command_buffer_commit(_handle);
        if (!ok) fprintf(stderr, "XCM commit FAILED cb=%p err=%s\n", (__bridge void *)self, xm2v_last_error());
    }
    if (_scheduledHandlers.count || _completedHandlers.count || _dirtyIOSurfaceTextures.count) {
        static dispatch_queue_t waitQ;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ waitQ = dispatch_queue_create("xcm.cb.wait", DISPATCH_QUEUE_CONCURRENT); });
        dispatch_async(waitQ, ^{
            if (_handle) {
                bool wok = xm2v_command_buffer_wait_until_completed(_handle, 60000);
                if (!wok) fprintf(stderr, "XCM wait FAILED cb=%p status=%u err=%s\n",
                                  (__bridge void *)self, xm2v_command_buffer_status(_handle), xm2v_last_error());
            }
            [self _flushIOSurfacesOnce];
            [self _fireHandlersOnce];
        });
    }
}
- (void)commitAndWaitUntilSubmitted {
    [self commit];
}
- (void)waitUntilScheduled {
    [self waitUntilCompleted];
}
- (void)waitUntilCompleted {
    if (_handle) xm2v_command_buffer_wait_until_completed(_handle, 60000);
    [self _flushIOSurfacesOnce];
    [self _fireHandlersOnce];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoder {
    if (!_handle) return nil;
    Xm2vComputeEncoder *eh = xm2v_compute_encoder_new(_handle);
    if (xcmTraceOn()) fprintf(stderr, "XCM computeCommandEncoder -> %p\n", (void *)eh);
    return eh ? (id<MTLComputeCommandEncoder>)[[XcmComputeEncoder alloc] initWithHandle:eh device:_device commandBuffer:self] : nil;
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)dispatchType {
    (void)dispatchType;
    return [self computeCommandEncoder];
}
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)desc {
    if (!_handle || !desc) return nil;
    Xm2vRenderPassDesc rd = {};
    rd.color_attachment_count = 8;
    for (int i = 0; i < 8; i++) {
        MTLRenderPassColorAttachmentDescriptor *ca = desc.colorAttachments[i];
        if (ca && ca.texture && [ca.texture isKindOfClass:[XcmTexture class]]) {
            XcmTexture *xt = (XcmTexture *)ca.texture;
            if (ca.loadAction == MTLLoadActionLoad) [xt syncFromIOSurfaceIfNeeded];
            if (xt->_iosurface && ca.storeAction != MTLStoreActionDontCare)
                [self markDirtyIOSurfaceTexture:xt];
            rd.color_attachments[i].texture = xt->_handle;
            rd.color_attachments[i].level = ca.level;
            rd.color_attachments[i].slice = ca.slice;
            rd.color_attachments[i].load_action = (uint64_t)ca.loadAction;
            rd.color_attachments[i].store_action = (uint64_t)ca.storeAction;
            rd.color_attachments[i].clear_r = ca.clearColor.red;
            rd.color_attachments[i].clear_g = ca.clearColor.green;
            rd.color_attachments[i].clear_b = ca.clearColor.blue;
            rd.color_attachments[i].clear_a = ca.clearColor.alpha;
        }
    }
    if (desc.depthAttachment.texture && [desc.depthAttachment.texture isKindOfClass:[XcmTexture class]]) {
        rd.depth_texture = ((XcmTexture *)desc.depthAttachment.texture)->_handle;
        rd.depth_load_action = (uint64_t)desc.depthAttachment.loadAction;
        rd.depth_store_action = (uint64_t)desc.depthAttachment.storeAction;
        rd.clear_depth = desc.depthAttachment.clearDepth;
    }
    if (desc.stencilAttachment.texture && [desc.stencilAttachment.texture isKindOfClass:[XcmTexture class]]) {
        rd.stencil_texture = ((XcmTexture *)desc.stencilAttachment.texture)->_handle;
        rd.stencil_load_action = (uint64_t)desc.stencilAttachment.loadAction;
        rd.stencil_store_action = (uint64_t)desc.stencilAttachment.storeAction;
        rd.clear_stencil = desc.stencilAttachment.clearStencil;
    }
    Xm2vRenderEncoder *eh = xm2v_render_encoder_new(_handle, &rd);
    if (xcmTraceOn()) fprintf(stderr, "XCM renderEncoder -> %p\n", (void *)eh);
    return eh ? (id<MTLRenderCommandEncoder>)[[XcmRenderEncoder alloc] initWithHandle:eh device:_device commandBuffer:self] : nil;
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoder {
    if (!_handle) return nil;
    Xm2vBlitEncoder *eh = xm2v_blit_encoder_new(_handle);
    return eh ? (id<MTLBlitCommandEncoder>)[[XcmBlitEncoder alloc] initWithHandle:eh device:_device commandBuffer:self] : nil;
}
- (void)encodeSignalEvent:(id<MTLEvent>)event value:(uint64_t)value {
    if (_handle && [event isKindOfClass:[XcmEvent class]])
        xm2v_command_buffer_encode_signal_event(_handle, ((XcmEvent *)event)->_handle, value);
}
- (void)encodeWaitForEvent:(id<MTLEvent>)event value:(uint64_t)value {
    if (_handle && [event isKindOfClass:[XcmEvent class]])
        xm2v_command_buffer_encode_wait_event(_handle, ((XcmEvent *)event)->_handle, value);
}
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
@end

@interface XcmQueue : XcmObject {
@public
    Xm2vQueue *_handle;
    id _device;
    NSUInteger _gpuPriority;
    NSUInteger _bgGpuPriority;
    dispatch_queue_t _submissionQueue;
    dispatch_queue_t _completionQueue;
}
- (instancetype)initWithHandle:(Xm2vQueue *)h device:(id)dev;
@end

@implementation XcmQueue
- (instancetype)initWithHandle:(Xm2vQueue *)h device:(id)dev {
    if ((self = [super init])) { _handle = h; _device = dev; _gpuPriority = 1; _bgGpuPriority = 2; }
    return self;
}
- (void)dealloc { if (_handle) { xm2v_queue_release(_handle); _handle = nullptr; } }
- (id<MTLDevice>)device { return _device; }
- (void)setSubmissionQueue:(dispatch_queue_t)q { _submissionQueue = q; }
- (void)setCompletionQueue:(dispatch_queue_t)q { _completionQueue = q; }
- (NSUInteger)getGPUPriority { return _gpuPriority; }
- (NSUInteger)getBackgroundGPUPriority { return _bgGpuPriority; }
- (BOOL)setGPUPriority:(NSUInteger)p { _gpuPriority = p; return YES; }
- (BOOL)setGPUPriority:(NSUInteger)p offset:(unsigned short)o { (void)o; _gpuPriority = p; return YES; }
- (BOOL)setBackgroundGPUPriority:(NSUInteger)p { _bgGpuPriority = p; return YES; }
- (BOOL)setBackgroundGPUPriority:(NSUInteger)p offset:(unsigned short)o { (void)o; _bgGpuPriority = p; return YES; }
- (BOOL)_setGPUPriority:(NSUInteger)p backgroundPriority:(NSUInteger)b { _gpuPriority = p; _bgGpuPriority = b; return YES; }
- (id<MTLCommandBuffer>)commandBuffer {
    if (!_handle) return nil;
    Xm2vCommandBuffer *cb = xm2v_command_buffer_new(_handle);
    return cb ? (id<MTLCommandBuffer>)[[XcmCommandBuffer alloc] initWithHandle:cb device:_device queue:self] : nil;
}
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences { return [self commandBuffer]; }
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)desc {
    (void)desc;
    return [self commandBuffer];
}
@end

/* ======================== Dynamic _MTLDevice Subclass ======================== */

static Xm2vDevice *gXm2vDevice = nullptr;
static uint64_t gRegistryID = 0x584e554350550001ULL;
static id gSingletonDevice = nil;

static NSString *xcmDev_name(id, SEL) {
    char buf[256] = {};
    if (gXm2vDevice && xm2v_device_name(gXm2vDevice, buf, sizeof(buf)) > 0)
        return [NSString stringWithFormat:@"XnuCpuMetal (%s)", buf];
    return @"XnuCpuMetal (lavapipe)";
}
static uint64_t xcmDev_registryID(id, SEL) { return gRegistryID; }
static BOOL xcmDev_isLowPower(id, SEL) { return YES; }
static BOOL xcmDev_isHeadless(id, SEL) { return YES; }
static BOOL xcmDev_isRemovable(id, SEL) { return NO; }
static BOOL xcmDev_hasUnifiedMemory(id, SEL) { return YES; }
static NSUInteger xcmDev_maxBufferLength(id, SEL) {
    return gXm2vDevice ? (NSUInteger)xm2v_device_max_buffer_length(gXm2vDevice) : (256 * 1024 * 1024);
}
static MTLSize xcmDev_maxThreadsPerThreadgroup(id, SEL) {
    uint64_t v[3] = {256, 256, 256};
    if (gXm2vDevice) xm2v_device_max_threads_per_threadgroup(gXm2vDevice, v);
    return MTLSizeMake((NSUInteger)v[0], (NSUInteger)v[1], (NSUInteger)v[2]);
}
static NSUInteger xcmDev_maxTex2D(id, SEL) { return 16384; }
static NSUInteger xcmDev_maxTex3D(id, SEL) { return 2048; }
static NSUInteger xcmDev_maxTexLayers(id, SEL) { return 2048; }
static NSUInteger xcmDev_maxColorAtt(id, SEL) { return 8; }
static NSUInteger xcmDev_maxTGMem(id, SEL) { return 32768; }
static NSUInteger xcmDev_minLinearAlign(id, SEL, MTLPixelFormat) { return 64; }
static NSUInteger xcmDev_minTileAlign(id, SEL, MTLPixelFormat) { return 64; }
static NSUInteger xcmDev_align64(id, SEL) { return 64; }
static NSUInteger xcmDev_rwTexTier(id, SEL) { return MTLReadWriteTextureTier2; }
static BOOL xcmDev_yes(id, SEL) { return YES; }
static BOOL xcmDev_supportsSampleCount(id, SEL, NSUInteger c) { return c == 1; }
static BOOL xcmDev_supportsFeatureSet(id, SEL, NSUInteger) { return YES; }
static BOOL xcmDev_supportsFamily(id, SEL, MTLGPUFamily family) {
    return gXm2vDevice ? xm2v_device_supports_family(gXm2vDevice, (int64_t)family) : NO;
}

static id xcmDev_newCommandQueue(id self, SEL) NS_RETURNS_RETAINED;
static id xcmDev_newCommandQueueMax(id self, SEL, NSUInteger) NS_RETURNS_RETAINED;
static id xcmDev_newBufferLen(id self, SEL, NSUInteger, MTLResourceOptions) NS_RETURNS_RETAINED;
static id xcmDev_newBufferBytes(id self, SEL, const void *, NSUInteger, MTLResourceOptions) NS_RETURNS_RETAINED;
static id xcmDev_newBufferNoCopy(id self, SEL, void *, NSUInteger, MTLResourceOptions, void (^)(void *, NSUInteger)) NS_RETURNS_RETAINED;
static id xcmDev_newTexture(id self, SEL, MTLTextureDescriptor *) NS_RETURNS_RETAINED;
static id xcmDev_newTextureIOSurface(id self, SEL, MTLTextureDescriptor *, IOSurfaceRef, NSUInteger) NS_RETURNS_RETAINED;
static id xcmDev_newTextureIOSurfaceSlice(id self, SEL, MTLTextureDescriptor *, IOSurfaceRef, NSUInteger, NSUInteger) NS_RETURNS_RETAINED;
static id xcmDev_newDefaultLibrary(id self, SEL) NS_RETURNS_RETAINED;
static id xcmDev_newDefaultLibraryWithBundle(id self, SEL, NSBundle *, NSError **) NS_RETURNS_RETAINED;
static id xcmDev_newLibraryWithSource(id self, SEL, NSString *, MTLCompileOptions *, NSError **) NS_RETURNS_RETAINED;
static id xcmDev_newLibraryWithData(id self, SEL, dispatch_data_t, NSError **) NS_RETURNS_RETAINED;
static id xcmDev_newLibraryWithURL(id self, SEL, NSURL *, NSError **) NS_RETURNS_RETAINED;
static id xcmDev_newLibraryWithFile(id self, SEL, NSString *, NSError **) NS_RETURNS_RETAINED;
static id xcmDev_newLibraryWithStitched(id self, SEL, MTLStitchedLibraryDescriptor *, NSError **) NS_RETURNS_RETAINED;
static id xcmDev_newLibraryWithStitchedArchive(id self, SEL, MTLStitchedLibraryDescriptor *, id, NSError **) NS_RETURNS_RETAINED;
static id xcmDev_newComputePSO(id self, SEL, id<MTLFunction>, NSError **) NS_RETURNS_RETAINED;
static id xcmDev_newComputePSOOpts(id self, SEL, id<MTLFunction>, MTLPipelineOption, MTLComputePipelineReflection **, NSError **) NS_RETURNS_RETAINED;
static id xcmDev_newComputePSODesc(id self, SEL, MTLComputePipelineDescriptor *, MTLPipelineOption, MTLComputePipelineReflection **, NSError **) NS_RETURNS_RETAINED;
static id xcmDev_newRenderPSO(id self, SEL, MTLRenderPipelineDescriptor *, NSError **) NS_RETURNS_RETAINED;
static id xcmDev_newRenderPSOOpts(id self, SEL, MTLRenderPipelineDescriptor *, MTLPipelineOption, MTLRenderPipelineReflection **, NSError **) NS_RETURNS_RETAINED;
static id xcmDev_newSampler(id self, SEL, MTLSamplerDescriptor *) NS_RETURNS_RETAINED;
static id xcmDev_newDepthStencil(id self, SEL, MTLDepthStencilDescriptor *) NS_RETURNS_RETAINED;
static id xcmDev_newEvent(id self, SEL) NS_RETURNS_RETAINED;
static id xcmDev_newFence(id self, SEL) NS_RETURNS_RETAINED;
static id xcmDev_newHeap(id self, SEL, MTLHeapDescriptor *) NS_RETURNS_RETAINED;

static id xcmDev_newCommandQueue(id self, SEL) {
    if (!gXm2vDevice) return nil;
    Xm2vQueue *q = xm2v_queue_new(gXm2vDevice);
    return q ? [[XcmQueue alloc] initWithHandle:q device:self] : nil;
}
static id xcmDev_newCommandQueueMax(id self, SEL, NSUInteger) {
    return xcmDev_newCommandQueue(self, nullptr);
}
static id xcmDev_newBufferLen(id self, SEL, NSUInteger length, MTLResourceOptions opts) {
    if (!gXm2vDevice) return nil;
    Xm2vBuffer *b = xm2v_buffer_new(gXm2vDevice, length, opts, nullptr);
    if (xcmTraceOn()) fprintf(stderr, "XCM newBufferLen(%lu, 0x%lx) -> %p\n", (unsigned long)length, (unsigned long)opts, (void *)b);
    return b ? [[XcmBuffer alloc] initWithHandle:b device:self options:opts] : nil;
}
static id xcmDev_newBufferBytes(id self, SEL, const void *pointer, NSUInteger length, MTLResourceOptions opts) {
    if (!gXm2vDevice) return nil;
    Xm2vBuffer *b = xm2v_buffer_new(gXm2vDevice, length, opts, pointer);
    return b ? [[XcmBuffer alloc] initWithHandle:b device:self options:opts] : nil;
}
static id xcmDev_newBufferNoCopy(id self, SEL, void *pointer, NSUInteger length, MTLResourceOptions opts, void (^deallocator)(void *, NSUInteger)) {
    (void)deallocator;
    if (!gXm2vDevice) return nil;
    Xm2vBuffer *b = xm2v_buffer_new_no_copy(gXm2vDevice, pointer, length, opts);
    if (!b) b = xm2v_buffer_new(gXm2vDevice, length, opts, pointer);
    return b ? [[XcmBuffer alloc] initWithHandle:b device:self options:opts] : nil;
}
static id xcmDev_newTexture(id self, SEL, MTLTextureDescriptor *desc) {
    if (!gXm2vDevice || !desc) return nil;
    Xm2vTextureDesc td = {};
    td.texture_type = (uint64_t)desc.textureType;
    td.pixel_format = (uint64_t)desc.pixelFormat;
    td.width = desc.width;
    td.height = desc.height;
    td.depth = desc.depth;
    td.mipmap_level_count = desc.mipmapLevelCount;
    td.sample_count = desc.sampleCount;
    td.array_length = desc.arrayLength;
    td.resource_options = (uint64_t)desc.resourceOptions;
    td.usage = (uint64_t)desc.usage;
    Xm2vTexture *t = xm2v_texture_new(gXm2vDevice, &td);
    if (!t || xcmTraceOn()) {
        fprintf(stderr, "XCM newTexture -> %p fmt=%lu type=%lu %lux%lux%lu mip=%lu usage=0x%lx opts=0x%lx err=%s\n",
                (void *)t, (unsigned long)desc.pixelFormat, (unsigned long)desc.textureType,
                (unsigned long)desc.width, (unsigned long)desc.height, (unsigned long)desc.depth,
                (unsigned long)desc.mipmapLevelCount, (unsigned long)desc.usage, (unsigned long)desc.resourceOptions,
                t ? "ok" : xm2v_last_error());
    }
    return t ? [[XcmTexture alloc] initWithHandle:t device:self descriptor:desc] : nil;
}
static id xcmDev_newTextureIOSurface(id self, SEL, MTLTextureDescriptor *desc, IOSurfaceRef surface, NSUInteger plane) {
    if (xcmTraceOn()) fprintf(stderr, "XCM enter newTextureIOSurface desc=%p surf=%p plane=%lu\n", (__bridge void *)desc, surface, (unsigned long)plane);
    if (!gXm2vDevice || !desc) return nil;
    // Force Shared storage internally so replaceRegion/getBytes sync with IOSurface directly.
    MTLTextureDescriptor *copy = [desc copy];
    copy.storageMode = MTLStorageModeShared;
    XcmTexture *tex = xcmDev_newTexture(self, nullptr, copy);
    if (xcmTraceOn()) fprintf(stderr, "XCM newTextureIOSurface -> %p surf=%p plane=%lu\n", (__bridge void *)tex, surface, (unsigned long)plane);
    if (tex && surface) {
        CFRetain(surface);
        tex->_iosurface = surface;
        tex->_iosurfacePlane = plane;
        [tex syncFromIOSurfaceIfNeeded];
    }
    return tex;
}
static id xcmDev_newTextureIOSurfaceSlice(id self, SEL, MTLTextureDescriptor *desc, IOSurfaceRef surface, NSUInteger plane, NSUInteger slice) {
    (void)slice;
    return xcmDev_newTextureIOSurface(self, nullptr, desc, surface, plane);
}
static id xcmDev_newLibraryWithData(id self, SEL, dispatch_data_t data, NSError **error) {
    if (!gXm2vDevice || !data) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorInternal, "Null library data");
        return nil;
    }
    const void *buf = nullptr;
    size_t len = 0;
    dispatch_data_t contig = dispatch_data_create_map(data, &buf, &len);
    NSData *nsCopy = (buf && len) ? [NSData dataWithBytes:buf length:len] : nil;
    Xm2vLibrary *lib = xm2v_library_new_with_data(gXm2vDevice, buf, len);
    (void)contig;
    if (!lib) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorCompileFailure, "Library load failed");
        return nil;
    }
    return [[XcmLibrary alloc] initWithHandle:lib device:self data:nsCopy];
}
static id xcmDev_newLibraryWithURL(id self, SEL, NSURL *url, NSError **error) {
    NSData *nsdata = [NSData dataWithContentsOfURL:url options:0 error:error];
    if (!nsdata) return nil;
    dispatch_data_t d = dispatch_data_create(nsdata.bytes, nsdata.length, nullptr, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    return xcmDev_newLibraryWithData(self, nullptr, d, error);
}
static id xcmDev_newLibraryWithFile(id self, SEL, NSString *filepath, NSError **error) {
    return xcmDev_newLibraryWithURL(self, nullptr, [NSURL fileURLWithPath:filepath], error);
}
static NSString *xcmQuoteArg(NSString *text) {
    if ([text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\"\\'"]].location == NSNotFound)
        return text;
    NSString *escaped = [[text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
        stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}

static NSString *xcmCompileArguments(MTLCompileOptions *options) {
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithObjects:@"--driver-mode=metal", @"-x", @"metal", nil];
    NSUInteger version = (options && options.languageVersion) ? (NSUInteger)options.languageVersion : (NSUInteger)MTLLanguageVersion3_1;
    unsigned major = (unsigned)(version >> 16), minor = (unsigned)(version & 0xffff);
    [args addObject:[NSString stringWithFormat:(major >= 3 ? @"-std=metal%u.%u" : @"-std=macos-metal%u.%u"), major, minor]];
    SEL modeSel = sel_registerName("mathMode"), fnSel = sel_registerName("mathFloatingPointFunctions");
    NSString *modeName = nil, *fnName = nil;
    if (options && [options respondsToSelector:modeSel] && [options respondsToSelector:fnSel]) {
        switch (((NSInteger (*)(id, SEL))objc_msgSend)(options, modeSel)) {
            case MTLMathModeSafe: modeName = @"safe"; break;
            case MTLMathModeRelaxed: modeName = @"relaxed"; break;
            case MTLMathModeFast: modeName = @"fast"; break;
        }
        switch (((NSInteger (*)(id, SEL))objc_msgSend)(options, fnSel)) {
            case MTLMathFloatingPointFunctionsFast: fnName = @"fast"; break;
            case MTLMathFloatingPointFunctionsPrecise: fnName = @"precise"; break;
        }
    }
    if (modeName && fnName) {
        [args addObject:[@"-fmetal-math-mode=" stringByAppendingString:modeName]];
        [args addObject:[@"-fmetal-math-fp32-functions=" stringByAppendingString:fnName]];
    } else {
        BOOL fast = options ? ((BOOL (*)(id, SEL))objc_msgSend)(options, sel_registerName("fastMathEnabled")) : YES;
        [args addObject:fast ? @"-ffast-math" : @"-fno-fast-math"];
    }
    if (options.preserveInvariance) [args addObject:@"-fpreserve-invariance"];
    if (options.optimizationLevel == MTLLibraryOptimizationLevelSize) [args addObject:@"-Os"];
    [options.preprocessorMacros enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSObject *value, BOOL *) {
        [args addObject:xcmQuoteArg([NSString stringWithFormat:@"-D%@=%@", name, value])];
    }];
    [args addObject:xcmQuoteArg([@"-fmodules-cache-path=" stringByAppendingString:[NSTemporaryDirectory() stringByAppendingPathComponent:@"xcm-msl"]])];
    return [args componentsJoinedByString:@" "];
}

static id xcmDev_newDefaultLibraryWithBundle(id self, SEL, NSBundle *bundle, NSError **error) {
    NSURL *url = [bundle URLForResource:@"default" withExtension:@"metallib"];
    if (!url) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorFileNotFound, "Bundle has no default.metallib");
        return nil;
    }
    return xcmDev_newLibraryWithURL(self, nullptr, url, error);
}
static id xcmDev_newDefaultLibrary(id self, SEL) {
    return xcmDev_newDefaultLibraryWithBundle(self, nullptr, [NSBundle mainBundle], nil);
}
static id xcmDev_newLibraryWithSource(id self, SEL, NSString *source, MTLCompileOptions *options, NSError **error) {
    if (!source) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorCompileFailure, "Nil source");
        return nil;
    }
    NSData *text = [source dataUsingEncoding:NSUTF8StringEncoding];
    NSString *argStr = xcmCompileArguments(options);
    const char *argC = argStr.UTF8String ?: "";
    uint64_t sourceBytes = (text.length + 1 + 3) & ~uint64_t(3);
    uint64_t optionBytes = strlen(argC) + 1;
    std::vector<uint8_t> req(16 + sourceBytes + optionBytes, 0);
    memcpy(req.data(), &sourceBytes, 8);
    memcpy(req.data() + 8, &optionBytes, 8);
    memcpy(req.data() + 16, text.bytes, text.length);
    memcpy(req.data() + 16 + sourceBytes, argC, optionBytes);
    NSString *warnings = nil, *failure = nil;
    NSData *metallib = xcmCodeGenRequest(13, req, &warnings, &failure);
    if (!metallib) {
        if (xcmTraceOn()) fprintf(stderr, "XCM newLibraryWithSource failed: %s\n", failure.UTF8String ?: "?");
        if (error) *error = [NSError errorWithDomain:MTLLibraryErrorDomain code:MTLLibraryErrorCompileFailure
                                            userInfo:@{NSLocalizedDescriptionKey: failure ?: @"Metal source compilation failed"}];
        return nil;
    }
    dispatch_data_t data = dispatch_data_create(metallib.bytes, metallib.length, nullptr, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    id<MTLLibrary> lib = xcmDev_newLibraryWithData(self, nullptr, data, error);
    if (lib && warnings.length && error)
        *error = [NSError errorWithDomain:MTLLibraryErrorDomain code:MTLLibraryErrorCompileWarning
                                 userInfo:@{NSLocalizedDescriptionKey: warnings}];
    return lib;
}
static void xcmDev_newLibraryWithSourceAsync(id self, SEL, NSString *source, MTLCompileOptions *options, MTLNewLibraryCompletionHandler handler) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        id<MTLLibrary> lib = xcmDev_newLibraryWithSource(self, nullptr, source, options, &err);
        if (handler) handler(lib, err);
    });
}
static id xcmDev_newLibraryWithStitched(id self, SEL, MTLStitchedLibraryDescriptor *d, NSError **error) {
    NSArray<MTLFunctionStitchingGraph *> *graphs = d.functionGraphs;
    NSArray<id<MTLFunction>> *functions = d.functions;
    if (!graphs.count || !functions.count) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorCompileFailure, "Stitched library needs graphs and functions");
        return nil;
    }
    NSString *dag = [(id<XcmOriginalStitching>)self newDagStringWithGraphs:graphs];
    if (!dag.length) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorCompileFailure, "Empty stitching DAG text");
        return nil;
    }
    std::vector<uint8_t> req;
    auto pushWord = [&](uint32_t v) {
        const uint8_t *b = (const uint8_t *)&v;
        req.insert(req.end(), b, b + 4);
    };
    const char *text = dag.UTF8String;
    pushWord(0x64616720); // 'dag '
    req.insert(req.end(), text, text + strlen(text) + 1);
    pushWord(0x6e756d66); // 'numf'
    pushWord((uint32_t)functions.count);
    for (id fn in functions) {
        NSData *bc = [fn isKindOfClass:[XcmFunction class]] ? xcmExtractFunctionBitcode((XcmFunction *)fn) : nil;
        if (!bc) {
            if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorCompileFailure, "Missing bitcode for stitched function");
            return nil;
        }
        pushWord(0x62697463); // 'bitc'
        pushWord((uint32_t)bc.length);
        const uint8_t *b = (const uint8_t *)bc.bytes;
        req.insert(req.end(), b, b + bc.length);
    }
    // macOS 27 MTLCompilerObject::stitchFunctionDag trailing slots
    pushWord(0x6e756d73); pushWord(0); // 'nums'
    pushWord(0x7074666d); pushWord(0); // 'ptfm'
    pushWord(0x61726964); pushWord(0); // 'arid'

    NSString *warnings = nil, *failure = nil;
    NSData *metallib = xcmCodeGenRequest(14, req, &warnings, &failure);
    if (!metallib) {
        if (error) *error = [NSError errorWithDomain:MTLLibraryErrorDomain
                                                code:MTLLibraryErrorCompileFailure
                                            userInfo:@{NSLocalizedDescriptionKey: failure ?: @"Stitched library compilation failed"}];
        return nil;
    }
    dispatch_data_t data = dispatch_data_create(metallib.bytes, metallib.length, nullptr, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    return xcmDev_newLibraryWithData(self, nullptr, data, error);
}
static id xcmDev_newLibraryWithStitchedArchive(id self, SEL, MTLStitchedLibraryDescriptor *d, id, NSError **error) {
    return xcmDev_newLibraryWithStitched(self, nullptr, d, error);
}
static void xcmDev_newLibraryWithStitchedAsync(id self, SEL, MTLStitchedLibraryDescriptor *d, MTLNewLibraryCompletionHandler handler) {
    NSError *err = nil;
    id<MTLLibrary> lib = xcmDev_newLibraryWithStitched(self, nullptr, d, &err);
    if (handler) handler(lib, err);
}
static id xcmDev_newComputePSO(id self, SEL, id<MTLFunction> fn, NSError **error) {
    if (!gXm2vDevice || ![fn isKindOfClass:[XcmFunction class]] || !((XcmFunction *)fn)->_handle) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorInternal, "Invalid function");
        return nil;
    }
    Xm2vComputePipeline *pso = xm2v_compute_pipeline_new(gXm2vDevice, ((XcmFunction *)fn)->_handle);
    if (xcmTraceOn() || !pso) {
        fprintf(stderr, "XCM newComputePSO(%s) -> %p err=%s\n",
                fn.name.UTF8String ?: "?", (void *)pso, pso ? "ok" : xm2v_last_error());
    }
    if (!pso) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorCompileFailure, "Compute PSO failed");
        return nil;
    }
    return [[XcmComputePipeline alloc] initWithHandle:pso device:self];
}
static id xcmDev_newComputePSOOpts(id self, SEL, id<MTLFunction> fn, MTLPipelineOption, MTLComputePipelineReflection **refl, NSError **error) {
    if (refl) *refl = nil;
    return xcmDev_newComputePSO(self, nullptr, fn, error);
}
static void xcmCollectLinkedFunctions(MTLLinkedFunctions *linked,
                                      std::vector<Xm2vFunction *> &pubOut,
                                      std::vector<Xm2vFunction *> &privOut) {
    if (!linked) return;
    auto push = [](NSArray<id<MTLFunction>> *arr, std::vector<Xm2vFunction *> &dst) {
        for (id fn in arr) {
            if ([fn isKindOfClass:[XcmFunction class]] && ((XcmFunction *)fn)->_handle)
                dst.push_back(((XcmFunction *)fn)->_handle);
        }
    };
    push(linked.functions, pubOut);
    push(linked.binaryFunctions, pubOut);
    push(linked.privateFunctions, privOut);
}

static id xcmDev_newComputePSODesc(id self, SEL, MTLComputePipelineDescriptor *desc, MTLPipelineOption opts, MTLComputePipelineReflection **refl, NSError **error) {
    (void)opts;
    if (refl) *refl = nil;
    if (!gXm2vDevice || !desc || ![desc.computeFunction isKindOfClass:[XcmFunction class]] || !((XcmFunction *)desc.computeFunction)->_handle) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorInternal, "Invalid compute pipeline descriptor");
        return nil;
    }
    std::vector<Xm2vFunction *> pubLinked, privLinked;
    xcmCollectLinkedFunctions(desc.linkedFunctions, pubLinked, privLinked);
    Xm2vComputePipeline *pso = (pubLinked.empty() && privLinked.empty())
        ? xm2v_compute_pipeline_new(gXm2vDevice, ((XcmFunction *)desc.computeFunction)->_handle)
        : xm2v_compute_pipeline_new_with_linked(
              gXm2vDevice, ((XcmFunction *)desc.computeFunction)->_handle,
              pubLinked.empty() ? nullptr : pubLinked.data(), (uint32_t)pubLinked.size(),
              privLinked.empty() ? nullptr : privLinked.data(), (uint32_t)privLinked.size());
    if (xcmTraceOn() || !pso) {
        fprintf(stderr, "XCM newComputePSODesc(%s, linked=%zu+%zu) -> %p err=%s\n",
                desc.computeFunction.name.UTF8String ?: "?", pubLinked.size(), privLinked.size(),
                (void *)pso, pso ? "ok" : xm2v_last_error());
    }
    if (!pso) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorCompileFailure, "Compute PSO failed");
        return nil;
    }
    return [[XcmComputePipeline alloc] initWithHandle:pso device:self];
}
static void xcmDev_newComputePSOAsync(id self, SEL, id<MTLFunction> fn, void (^handler)(id<MTLComputePipelineState>, NSError *)) {
    NSError *err = nil;
    id pso = xcmDev_newComputePSO(self, nullptr, fn, &err);
    if (handler) handler(pso, err);
}
static id xcmDev_newRenderPSO(id self, SEL, MTLRenderPipelineDescriptor *desc, NSError **error) {
    if (!gXm2vDevice || !desc || ![desc.vertexFunction isKindOfClass:[XcmFunction class]] || !((XcmFunction *)desc.vertexFunction)->_handle) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorInternal, "Invalid render pipeline descriptor");
        return nil;
    }
    Xm2vRenderPipelineDesc rd = {};
    rd.vertex_function = ((XcmFunction *)desc.vertexFunction)->_handle;
    if (desc.fragmentFunction && [desc.fragmentFunction isKindOfClass:[XcmFunction class]])
        rd.fragment_function = ((XcmFunction *)desc.fragmentFunction)->_handle;
    std::vector<Xm2vFunction *> vPub, vPriv, fPub, fPriv;
    xcmCollectLinkedFunctions(desc.vertexLinkedFunctions, vPub, vPriv);
    xcmCollectLinkedFunctions(desc.fragmentLinkedFunctions, fPub, fPriv);
    rd.vertex_linked_functions = vPub.empty() ? nullptr : vPub.data();
    rd.vertex_linked_function_count = (uint32_t)vPub.size();
    rd.vertex_private_linked_functions = vPriv.empty() ? nullptr : vPriv.data();
    rd.vertex_private_linked_function_count = (uint32_t)vPriv.size();
    rd.fragment_linked_functions = fPub.empty() ? nullptr : fPub.data();
    rd.fragment_linked_function_count = (uint32_t)fPub.size();
    rd.fragment_private_linked_functions = fPriv.empty() ? nullptr : fPriv.data();
    rd.fragment_private_linked_function_count = (uint32_t)fPriv.size();
    rd.color_attachment_count = 8;
    for (int i = 0; i < 8; i++) {
        MTLRenderPipelineColorAttachmentDescriptor *ca = desc.colorAttachments[i];
        if (ca && ca.pixelFormat != MTLPixelFormatInvalid) {
            rd.color_attachments[i].pixel_format = (uint64_t)ca.pixelFormat;
            rd.color_attachments[i].blending_enabled = ca.isBlendingEnabled;
            rd.color_attachments[i].rgb_blend_op = (uint64_t)ca.rgbBlendOperation;
            rd.color_attachments[i].alpha_blend_op = (uint64_t)ca.alphaBlendOperation;
            rd.color_attachments[i].src_rgb_blend = (uint64_t)ca.sourceRGBBlendFactor;
            rd.color_attachments[i].dst_rgb_blend = (uint64_t)ca.destinationRGBBlendFactor;
            rd.color_attachments[i].src_alpha_blend = (uint64_t)ca.sourceAlphaBlendFactor;
            rd.color_attachments[i].dst_alpha_blend = (uint64_t)ca.destinationAlphaBlendFactor;
            rd.color_attachments[i].write_mask = (uint64_t)ca.writeMask;
        }
    }
    rd.depth_attachment_pixel_format = (uint64_t)desc.depthAttachmentPixelFormat;
    rd.stencil_attachment_pixel_format = (uint64_t)desc.stencilAttachmentPixelFormat;
    rd.sample_count = desc.rasterSampleCount;
    std::vector<Xm2vVertexAttribute> vattrs;
    std::vector<Xm2vVertexLayout> vlayouts;
    if (MTLVertexDescriptor *vd = desc.vertexDescriptor) {
        for (NSUInteger i = 0; i < 31; i++) {
            MTLVertexAttributeDescriptor *a = vd.attributes[i];
            if (a && a.format != MTLVertexFormatInvalid) {
                Xm2vVertexAttribute xa = {};
                xa.index = (uint32_t)i;
                xa.format = (uint64_t)a.format;
                xa.offset = (uint32_t)a.offset;
                xa.buffer_index = (uint32_t)a.bufferIndex;
                vattrs.push_back(xa);
            }
            MTLVertexBufferLayoutDescriptor *l = vd.layouts[i];
            if (l && (l.stride != 0 || l.stride == MTLBufferLayoutStrideDynamic)) {
                Xm2vVertexLayout xl = {};
                xl.index = (uint32_t)i;
                xl.dynamic_stride = (l.stride == MTLBufferLayoutStrideDynamic);
                xl.stride = xl.dynamic_stride ? 0 : (uint64_t)l.stride;
                xl.step_function = (uint64_t)l.stepFunction;
                xl.step_rate = (uint32_t)l.stepRate;
                vlayouts.push_back(xl);
            }
        }
    }
    rd.vertex_attributes = vattrs.empty() ? nullptr : vattrs.data();
    rd.vertex_attribute_count = (uint32_t)vattrs.size();
    rd.vertex_layouts = vlayouts.empty() ? nullptr : vlayouts.data();
    rd.vertex_layout_count = (uint32_t)vlayouts.size();
    Xm2vRenderPipeline *pso = xm2v_render_pipeline_new(gXm2vDevice, &rd);
    if (!pso) {
        // Retry once with unspecified declared function constants defaulted to zero
        // (QuartzCore/RenderBox omit default-false constants that gate stage_in attributes / color inputs).
        auto rebuildZeroRest = [](id fnObj) -> Xm2vFunction * {
            if (!fnObj || ![fnObj isKindOfClass:[XcmFunction class]]) return nullptr;
            XcmFunction *xf = (XcmFunction *)fnObj;
            if (!xf->_library || !xf->_library->_handle) return nullptr;
            NSString *srcName = xf->_sourceName ?: xf->_name;
            if (!srcName) return nullptr;
            std::vector<Xm2vConstant> constants;
            std::deque<std::string> nameStorage;
            std::deque<std::vector<uint8_t>> byteStorage;
            xcmExtractConstants(xf->_constantValues, constants, nameStorage, byteStorage);
            return xm2v_library_new_function_specialized_zero_rest(
                xf->_library->_handle, srcName.UTF8String,
                constants.empty() ? nullptr : constants.data(), (uint32_t)constants.size());
        };
        Xm2vFunction *zv = rebuildZeroRest(desc.vertexFunction);
        Xm2vFunction *zf = desc.fragmentFunction ? rebuildZeroRest(desc.fragmentFunction) : nullptr;
        if (zv || zf) {
            Xm2vRenderPipelineDesc rd2 = rd;
            if (zv) rd2.vertex_function = zv;
            if (zf) rd2.fragment_function = zf;
            pso = xm2v_render_pipeline_new(gXm2vDevice, &rd2);
            if (xcmTraceOn()) {
                fprintf(stderr, "XCM newRenderPSO zeroRest retry(v=%s,f=%s) -> %p err=%s\n",
                        desc.vertexFunction.name.UTF8String ?: "?",
                        desc.fragmentFunction.name.UTF8String ?: "-",
                        (void *)pso, pso ? "ok" : xm2v_last_error());
            }
            if (zv) xm2v_function_release(zv);
            if (zf) xm2v_function_release(zf);
        }
    }
    // If Metal's vertex/fragment shader declares a stage_in attribute or color input attachment
    // that the descriptor omitted (e.g. QuartzCore Vfx unused attribute 4, or sparse RenderBox
    // color attachments), fill the missing slot with a safe default and retry.
    for (int attempt = 0; !pso && attempt < 8; attempt++) {
        const char *err = xm2v_last_error();
        if (!err) break;
        unsigned missingIdx = 0;
        if (const char *va = strstr(err, "InvalidDescriptor(VertexAttribute { attribute: ")) {
            if (sscanf(va, "InvalidDescriptor(VertexAttribute { attribute: %u", &missingIdx) == 1 && missingIdx < 31) {
                bool exists = false;
                for (const auto &a : vattrs) if (a.index == missingIdx) { exists = true; break; }
                if (exists) break;
                uint32_t bufIdx = vlayouts.empty() ? 0 : vlayouts[0].index;
                if (vlayouts.empty()) {
                    Xm2vVertexLayout xl = {};
                    xl.index = 0; xl.stride = 16; xl.step_function = (uint64_t)MTLVertexStepFunctionConstant; xl.step_rate = 0;
                    vlayouts.push_back(xl);
                }
                Xm2vVertexAttribute xa = {};
                xa.index = missingIdx;
                xa.format = (uint64_t)MTLVertexFormatFloat4;
                xa.offset = 0;
                xa.buffer_index = bufIdx;
                vattrs.push_back(xa);
                rd.vertex_attributes = vattrs.data();
                rd.vertex_attribute_count = (uint32_t)vattrs.size();
                rd.vertex_layouts = vlayouts.data();
                rd.vertex_layout_count = (uint32_t)vlayouts.size();
                pso = xm2v_render_pipeline_new(gXm2vDevice, &rd);
                if (xcmTraceOn()) fprintf(stderr, "XCM newRenderPSO missing-vattr(%u) retry -> %p err=%s\n", missingIdx, (void *)pso, pso ? "ok" : xm2v_last_error());
                continue;
            }
        }
        if (const char *ca = strstr(err, "InvalidDescriptor(ColorAttachment { index: ")) {
            if (sscanf(ca, "InvalidDescriptor(ColorAttachment { index: %u", &missingIdx) == 1 && missingIdx < 8) {
                if (rd.color_attachments[missingIdx].pixel_format != 0) break;
                uint64_t fallbackFmt = rd.color_attachments[0].pixel_format ? rd.color_attachments[0].pixel_format : (uint64_t)MTLPixelFormatRGBA16Float;
                rd.color_attachments[missingIdx].pixel_format = fallbackFmt;
                rd.color_attachments[missingIdx].write_mask = (uint64_t)MTLColorWriteMaskAll;
                pso = xm2v_render_pipeline_new(gXm2vDevice, &rd);
                if (xcmTraceOn()) fprintf(stderr, "XCM newRenderPSO missing-color(%u) retry -> %p err=%s\n", missingIdx, (void *)pso, pso ? "ok" : xm2v_last_error());
                continue;
            }
        }
        break;
    }
    if (xcmTraceOn() || !pso) {
        fprintf(stderr, "XCM newRenderPSO(v=%s,f=%s, vl=%zu+%zu, fl=%zu+%zu, fLinkedObj=%p) -> %p err=%s\n",
                desc.vertexFunction.name.UTF8String ?: "?",
                desc.fragmentFunction.name.UTF8String ?: "-",
                vPub.size(), vPriv.size(), fPub.size(), fPriv.size(),
                (__bridge void *)desc.fragmentLinkedFunctions,
                (void *)pso, pso ? "ok" : xm2v_last_error());
        if (!pso && !vattrs.empty()) {
            fprintf(stderr, "  vattrs(%zu):", vattrs.size());
            for (const auto &a : vattrs) fprintf(stderr, " [idx=%u fmt=%llu off=%u buf=%u]", a.index, a.format, a.offset, a.buffer_index);
            fprintf(stderr, "\n  vlayouts(%zu):", vlayouts.size());
            for (const auto &l : vlayouts) fprintf(stderr, " [idx=%u stride=%llu dyn=%d step=%llu rate=%u]", l.index, l.stride, l.dynamic_stride, l.step_function, l.step_rate);
            fprintf(stderr, "\n");
        }
        if (!pso && desc.fragmentLinkedFunctions) {
            MTLLinkedFunctions *fl = desc.fragmentLinkedFunctions;
            fprintf(stderr, "  fl.functions=%lu binary=%lu private=%lu groups=%lu\n",
                    (unsigned long)fl.functions.count, (unsigned long)fl.binaryFunctions.count,
                    (unsigned long)fl.privateFunctions.count, (unsigned long)fl.groups.count);
            for (id fn in fl.functions)
                fprintf(stderr, "    fn: %s (%s)\n", object_getClassName(fn), [fn respondsToSelector:@selector(name)] ? [[fn name] UTF8String] : "?");
            for (id fn in fl.privateFunctions)
                fprintf(stderr, "    priv: %s (%s)\n", object_getClassName(fn), [fn respondsToSelector:@selector(name)] ? [[fn name] UTF8String] : "?");
            for (id fn in fl.binaryFunctions)
                fprintf(stderr, "    bin: %s (%s)\n", object_getClassName(fn), [fn respondsToSelector:@selector(name)] ? [[fn name] UTF8String] : "?");
        }
    }
    if (!pso) {
        if (error) *error = xcmError(MTLLibraryErrorDomain, MTLLibraryErrorCompileFailure, "Render PSO failed");
        return nil;
    }
    return [[XcmRenderPipeline alloc] initWithHandle:pso device:self];
}
static id xcmDev_newRenderPSOOpts(id self, SEL, MTLRenderPipelineDescriptor *desc, MTLPipelineOption, MTLRenderPipelineReflection **refl, NSError **error) {
    if (refl) *refl = nil;
    return xcmDev_newRenderPSO(self, nullptr, desc, error);
}
static id xcmDev_newSampler(id self, SEL, MTLSamplerDescriptor *desc) {
    if (!gXm2vDevice || !desc) return nil;
    Xm2vSamplerDesc sd = {};
    sd.min_filter = (uint64_t)desc.minFilter;
    sd.mag_filter = (uint64_t)desc.magFilter;
    sd.mip_filter = (uint64_t)desc.mipFilter;
    sd.s_address_mode = (uint64_t)desc.sAddressMode;
    sd.t_address_mode = (uint64_t)desc.tAddressMode;
    sd.r_address_mode = (uint64_t)desc.rAddressMode;
    sd.max_anisotropy = desc.maxAnisotropy;
    sd.compare_function = (uint64_t)desc.compareFunction;
    sd.lod_min_clamp = desc.lodMinClamp;
    sd.lod_max_clamp = desc.lodMaxClamp;
    sd.normalized_coordinates = desc.normalizedCoordinates;
    Xm2vSampler *s = xm2v_sampler_new(gXm2vDevice, &sd);
    return s ? [[XcmSampler alloc] initWithHandle:s device:self] : nil;
}
static id xcmDev_newDepthStencil(id self, SEL, MTLDepthStencilDescriptor *desc) {
    if (!gXm2vDevice || !desc) return nil;
    Xm2vDepthStencilDesc dsd = {};
    dsd.depth_compare_function = (uint64_t)desc.depthCompareFunction;
    dsd.depth_write_enabled = desc.isDepthWriteEnabled;
    auto fillStencil = [](MTLStencilDescriptor *s, Xm2vStencilDesc &dst) {
        if (!s) return;
        dst.enabled = true;
        dst.stencil_compare_function = (uint64_t)s.stencilCompareFunction;
        dst.stencil_failure_operation = (uint64_t)s.stencilFailureOperation;
        dst.depth_failure_operation = (uint64_t)s.depthFailureOperation;
        dst.depth_stencil_pass_operation = (uint64_t)s.depthStencilPassOperation;
        dst.read_mask = s.readMask;
        dst.write_mask = s.writeMask;
    };
    fillStencil(desc.frontFaceStencil, dsd.front_face_stencil);
    fillStencil(desc.backFaceStencil, dsd.back_face_stencil);
    Xm2vDepthStencil *ds = xm2v_depth_stencil_new(gXm2vDevice, &dsd);
    return ds ? [[XcmDepthStencil alloc] initWithHandle:ds device:self] : nil;
}
static id xcmDev_newEvent(id self, SEL) {
    if (!gXm2vDevice) return nil;
    Xm2vEvent *ev = xm2v_event_new(gXm2vDevice);
    return ev ? [[XcmEvent alloc] initWithHandle:ev device:self] : nil;
}
static id xcmDev_newFence(id self, SEL) {
    if (!gXm2vDevice) return nil;
    Xm2vFence *f = xm2v_fence_new(gXm2vDevice);
    return f ? [[XcmFence alloc] initWithHandle:f device:self] : nil;
}
static id xcmDev_newHeap(id self, SEL, MTLHeapDescriptor *desc) {
    if (xcmTraceOn()) fprintf(stderr, "XCM newHeap(size=%lu storage=%lu)\n", (unsigned long)(desc ? desc.size : 0), (unsigned long)(desc ? desc.storageMode : 0));
    if (!desc) return nil;
    return [[XcmHeap alloc] initWithDevice:self descriptor:desc];
}
static MTLSizeAndAlign xcmDev_heapTexSizeAndAlign(id, SEL, MTLTextureDescriptor *desc) {
    NSUInteger w = desc ? MAX(1ul, desc.width) : 1;
    NSUInteger h = desc ? MAX(1ul, desc.height) : 1;
    NSUInteger d = desc ? MAX(1ul, desc.depth) : 1;
    NSUInteger sz = ((w * h * d * 16 + 255) & ~255ul);
    return MTLSizeAndAlign{sz, 256};
}
static MTLSizeAndAlign xcmDev_heapBufSizeAndAlign(id, SEL, NSUInteger len, MTLResourceOptions) { return MTLSizeAndAlign{len, 256}; }

// Metal's loader picks a slice of a binary archive / fat metallib by [device targetDeviceArchitecture] (cpuType, cpuSubtype);
// nil asserts in +[MTLLoader sliceIDForDevice:...]. This device runs AIR (through metal2vulkan), so it names the AIR type.
static id xcmDev_targetDeviceArchitecture(id, SEL) {
    static id arch;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        int type = 0x01000017, subtype = 0;
        if (const char *e = getenv("XNU_CPU_METAL_ARCH_TYPE")) type = (int)strtol(e, nullptr, 0);
        if (const char *e = getenv("XNU_CPU_METAL_ARCH_SUBTYPE")) subtype = (int)strtol(e, nullptr, 0);
        // Metal's internal MTLTargetDeviceArchitecture (cpuType, subType, driverVersion), not the public MTLArchitecture.
        Class c = objc_getClass("MTLTargetDeviceArchitecture");
        if (c) {
            arch = [[c alloc] init];
            ((void (*)(id, SEL, unsigned))objc_msgSend)(arch, sel_registerName("setCpuType:"), (unsigned)type);
            ((void (*)(id, SEL, unsigned))objc_msgSend)(arch, sel_registerName("setSubType:"), (unsigned)subtype);
            unsigned long long dv = 0;
            if (const char *e = getenv("XNU_CPU_METAL_DRIVER_VERSION")) dv = strtoull(e, nullptr, 0);
            ((void (*)(id, SEL, unsigned long long))objc_msgSend)(arch, sel_registerName("setDriverVersion:"), dv);
        }
        if (xcmTraceOn()) fprintf(stderr, "XCM targetDeviceArchitecture -> %p (0x%x/%d)\n", (__bridge void *)arch, type, subtype);
    });
    return arch;
}

static MTLArgumentBuffersTier xcmDev_argBufTier(id, SEL) { return MTLArgumentBuffersTier2; }

static Class createBackendDeviceClass(void) {
    static Class cls = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class base = objc_getClass("_MTLDevice");
        if (!base) base = [NSObject class];
        cls = objc_allocateClassPair(base, "XcmBackendDevice", 0);
        if (!cls) { cls = objc_getClass("XcmBackendDevice"); return; }

        struct Entry { const char *sel; IMP imp; const char *types; };
        static const Entry entries[] = {
            {"name", (IMP)xcmDev_name, "@16@0:8"},
            {"targetDeviceArchitecture", (IMP)xcmDev_targetDeviceArchitecture, "@16@0:8"},
            {"registryID", (IMP)xcmDev_registryID, "Q16@0:8"},
            {"isLowPower", (IMP)xcmDev_isLowPower, "B16@0:8"},
            {"isHeadless", (IMP)xcmDev_isHeadless, "B16@0:8"},
            {"isRemovable", (IMP)xcmDev_isRemovable, "B16@0:8"},
            {"hasUnifiedMemory", (IMP)xcmDev_hasUnifiedMemory, "B16@0:8"},
            {"maxBufferLength", (IMP)xcmDev_maxBufferLength, "Q16@0:8"},
            {"maxThreadsPerThreadgroup", (IMP)xcmDev_maxThreadsPerThreadgroup, "{?=QQQ}16@0:8"},
            {"maxTextureWidth2D", (IMP)xcmDev_maxTex2D, "Q16@0:8"},
            {"maxTextureHeight2D", (IMP)xcmDev_maxTex2D, "Q16@0:8"},
            {"maxTextureWidth1D", (IMP)xcmDev_maxTex2D, "Q16@0:8"},
            {"maxTextureWidth3D", (IMP)xcmDev_maxTex3D, "Q16@0:8"},
            {"maxTextureHeight3D", (IMP)xcmDev_maxTex3D, "Q16@0:8"},
            {"maxTextureDepth3D", (IMP)xcmDev_maxTex3D, "Q16@0:8"},
            {"maxTextureLayers", (IMP)xcmDev_maxTexLayers, "Q16@0:8"},
            {"maxColorAttachments", (IMP)xcmDev_maxColorAtt, "Q16@0:8"},
            {"maxThreadgroupMemoryLength", (IMP)xcmDev_maxTGMem, "Q16@0:8"},
            {"minimumLinearTextureAlignmentForPixelFormat:", (IMP)xcmDev_minLinearAlign, "Q24@0:8Q16"},
            {"minimumTextureBufferAlignmentForPixelFormat:", (IMP)xcmDev_minTileAlign, "Q24@0:8Q16"},
            {"linearTextureAlignmentBytes", (IMP)xcmDev_align64, "Q16@0:8"},
            {"iosurfaceTextureAlignmentBytes", (IMP)xcmDev_align64, "Q16@0:8"},
            {"iosurfaceReadOnlyTextureAlignmentBytes", (IMP)xcmDev_align64, "Q16@0:8"},
            {"deviceLinearTextureAlignmentBytes", (IMP)xcmDev_align64, "Q16@0:8"},
            {"deviceLinearReadOnlyTextureAlignmentBytes", (IMP)xcmDev_align64, "Q16@0:8"},
            {"readWriteTextureSupport", (IMP)xcmDev_rwTexTier, "Q16@0:8"},
            {"argumentBuffersSupport", (IMP)xcmDev_argBufTier, "Q16@0:8"},
            {"supportsSharedStorageTextures", (IMP)xcmDev_yes, "B16@0:8"},
            {"supportsRenderToLinearTextures", (IMP)xcmDev_yes, "B16@0:8"},
            {"supportsLinearTextureFromSharedBuffer", (IMP)xcmDev_yes, "B16@0:8"},
            {"supportsTextureSwizzle", (IMP)xcmDev_yes, "B16@0:8"},
            {"supportsNonPrivateDepthStencilTextures", (IMP)xcmDev_yes, "B16@0:8"},
            {"supportsTextureSampleCount:", (IMP)xcmDev_supportsSampleCount, "B24@0:8Q16"},
            {"supportsFeatureSet:", (IMP)xcmDev_supportsFeatureSet, "B24@0:8Q16"},
            {"supportsFamily:", (IMP)xcmDev_supportsFamily, "B24@0:8q16"},
            {"newCommandQueue", (IMP)xcmDev_newCommandQueue, "@16@0:8"},
            {"newCommandQueueWithMaxCommandBufferCount:", (IMP)xcmDev_newCommandQueueMax, "@24@0:8Q16"},
            {"newBufferWithLength:options:", (IMP)xcmDev_newBufferLen, "@32@0:8Q16Q24"},
            {"newBufferWithBytes:length:options:", (IMP)xcmDev_newBufferBytes, "@40@0:8^v16Q24Q32"},
            {"newBufferWithBytesNoCopy:length:options:deallocator:", (IMP)xcmDev_newBufferNoCopy, "@48@0:8^v16Q24Q32@?40"},
            {"newTextureWithDescriptor:", (IMP)xcmDev_newTexture, "@24@0:8@16"},
            {"newTextureWithDescriptor:iosurface:plane:", (IMP)xcmDev_newTextureIOSurface, "@40@0:8@16^{__IOSurface=}24Q32"},
            {"newTextureWithDescriptor:iosurface:plane:slice:", (IMP)xcmDev_newTextureIOSurfaceSlice, "@48@0:8@16^{__IOSurface=}24Q32Q40"},
            {"newDefaultLibrary", (IMP)xcmDev_newDefaultLibrary, "@16@0:8"},
            {"newDefaultLibraryWithBundle:error:", (IMP)xcmDev_newDefaultLibraryWithBundle, "@32@0:8@16^@24"},
            {"newLibraryWithSource:options:error:", (IMP)xcmDev_newLibraryWithSource, "@40@0:8@16@24^@32"},
            {"newLibraryWithSource:options:completionHandler:", (IMP)xcmDev_newLibraryWithSourceAsync, "v40@0:8@16@24@?32"},
            {"newLibraryWithData:error:", (IMP)xcmDev_newLibraryWithData, "@32@0:8@16^@24"},
            {"newLibraryWithURL:error:", (IMP)xcmDev_newLibraryWithURL, "@32@0:8@16^@24"},
            {"newLibraryWithFile:error:", (IMP)xcmDev_newLibraryWithFile, "@32@0:8@16^@24"},
            {"newLibraryWithStitchedDescriptor:error:", (IMP)xcmDev_newLibraryWithStitched, "@32@0:8@16^@24"},
            {"newLibraryWithStitchedDescriptor:destinationBinaryArchive:error:", (IMP)xcmDev_newLibraryWithStitchedArchive, "@40@0:8@16@24^@32"},
            {"newLibraryWithStitchedDescriptor:completionHandler:", (IMP)xcmDev_newLibraryWithStitchedAsync, "v32@0:8@16@?24"},
            {"newComputePipelineStateWithFunction:error:", (IMP)xcmDev_newComputePSO, "@32@0:8@16^@24"},
            {"newComputePipelineStateWithFunction:options:reflection:error:", (IMP)xcmDev_newComputePSOOpts, "@48@0:8@16Q24^@32^@40"},
            {"newComputePipelineStateWithDescriptor:options:reflection:error:", (IMP)xcmDev_newComputePSODesc, "@48@0:8@16Q24^@32^@40"},
            {"newComputePipelineStateWithFunction:completionHandler:", (IMP)xcmDev_newComputePSOAsync, "v32@0:8@16@?24"},
            {"newRenderPipelineStateWithDescriptor:error:", (IMP)xcmDev_newRenderPSO, "@32@0:8@16^@24"},
            {"newRenderPipelineStateWithDescriptor:options:reflection:error:", (IMP)xcmDev_newRenderPSOOpts, "@48@0:8@16Q24^@32^@40"},
            {"newSamplerStateWithDescriptor:", (IMP)xcmDev_newSampler, "@24@0:8@16"},
            {"newDepthStencilStateWithDescriptor:", (IMP)xcmDev_newDepthStencil, "@24@0:8@16"},
            {"newEvent", (IMP)xcmDev_newEvent, "@16@0:8"},
            {"newFence", (IMP)xcmDev_newFence, "@16@0:8"},
            {"newHeapWithDescriptor:", (IMP)xcmDev_newHeap, "@24@0:8@16"},
            {"heapTextureSizeAndAlignWithDescriptor:", (IMP)xcmDev_heapTexSizeAndAlign, "{?=QQ}24@0:8@16"},
            {"heapBufferSizeAndAlignWithLength:options:", (IMP)xcmDev_heapBufSizeAndAlign, "{?=QQ}32@0:8Q16Q24"},
        };
        for (const auto &e : entries)
            class_addMethod(cls, sel_registerName(e.sel), e.imp, e.types);
        Protocol *mtlDevProto = objc_getProtocol("MTLDevice");
        if (mtlDevProto) class_addProtocol(cls, mtlDevProto);
        // MTLAddDevice asserts [newDevice conformsToProtocol:@protocol(MTLDeviceSPI)] (Metal's own device list).
        Protocol *mtlDevSPI = objc_getProtocol("MTLDeviceSPI");
        if (!mtlDevSPI) fprintf(stderr, "XnuCpuMetal: no MTLDeviceSPI protocol in the runtime\n");
        if (mtlDevSPI) class_addProtocol(cls, mtlDevSPI);
        objc_registerClassPair(cls);
    });
    return cls;
}

static void fillBaseLimits(id device) {
    Class base = objc_getClass("_MTLDevice");
    SEL limitsSel = sel_registerName("limits");
    if (!base || !device || ![device isKindOfClass:base] || !class_getInstanceMethod(base, limitsSel)) return;
    uint8_t *limits = ((uint8_t *(*)(id, SEL))objc_msgSend)(device, limitsSel);
    ptrdiff_t at = limits - (uint8_t *)(__bridge void *)device;
    ptrdiff_t instance = (ptrdiff_t)class_getInstanceSize(base);
    if (!limits || at <= 0 || at >= instance) return;
    ptrdiff_t end = instance;
    bool found = false;
    unsigned count = 0;
    Ivar *ivars = class_copyIvarList(base, &count);
    for (unsigned i = 0; i < count; i++) {
        ptrdiff_t off = ivar_getOffset(ivars[i]);
        if (off == at) found = true;
        else if (off > at && off < end) end = off;
    }
    free(ivars);
    if (!found || end - at < 8) return;
    size_t size = (size_t)(end - at);
    struct LimitVal { const char *sel; uint64_t val; };
    const LimitVal kLimits[] = {
        {"maxTextureWidth1D", 16384},
        {"maxTextureWidth2D", 16384},
        {"maxTextureHeight2D", 16384},
        {"maxTextureWidth3D", 2048},
        {"maxTextureHeight3D", 2048},
        {"maxTextureDepth3D", 2048},
        {"maxTextureLayers", 2048},
        {"maxColorAttachments", 8},
        {"maxThreadgroupMemoryLength", 32768},
        {"maxBufferLength", xcmDev_maxBufferLength(device, nullptr)},
        {"maxFramebufferStorageBits", 512},
        {"maxTotalComputeThreadsPerThreadgroup", 1024},
        {"maxComputeSamplers", 16},
        {"maxFragmentSamplers", 16},
        {"maxVertexSamplers", 16},
        {"maxComputeTextures", 128},
        {"maxFragmentTextures", 128},
        {"maxVertexTextures", 128},
        {"maxComputeBuffers", 31},
        {"maxFragmentBuffers", 31},
        {"maxVertexBuffers", 31},
        {"maxVertexAttributes", 31},
        {"maxInterpolants", 32},
        {"maxViewports", 16},
        {"maxCustomSamplePositions", 0},
        {"linearTextureAlignmentBytes", 256},
    };
    for (const auto &lv : kLimits) {
        SEL s = sel_registerName(lv.sel);
        Method orig = class_getInstanceMethod(base, s);
        if (!orig || method_getNumberOfArguments(orig) != 2) continue;
        char ret = method_getTypeEncoding(orig)[0];
        if (ret != 'Q' && ret != 'I') continue;
        auto getter = (NSUInteger (*)(id, SEL))method_getImplementation(orig);
        for (size_t off = 0; off + 4 <= size; off += 4) {
            uint32_t saved;
            memcpy(&saved, limits + off, 4);
            uint32_t marker = 0x5a17c000u | (uint32_t)(off & 0xfff);
            memcpy(limits + off, &marker, 4);
            NSUInteger seen = getter(device, s);
            memcpy(limits + off, &saved, 4);
            if ((uint32_t)seen != marker || (seen >> 32) != 0) continue;
            bool wide = false;
            if (off + 8 <= size) {
                uint32_t next, one = 1;
                memcpy(&next, limits + off + 4, 4);
                memcpy(limits + off, &marker, 4);
                memcpy(limits + off + 4, &one, 4);
                wide = (getter(device, s) >> 32) == 1;
                memcpy(limits + off, &saved, 4);
                memcpy(limits + off + 4, &next, 4);
            }
            if (wide) {
                memcpy(limits + off, &lv.val, 8);
            } else {
                uint32_t narrow = lv.val > UINT32_MAX ? UINT32_MAX : (uint32_t)lv.val;
                memcpy(limits + off, &narrow, 4);
            }
            break;
        }
    }
}

extern "C" id xnu_cpu_metal_open_device(const char *loader, const char *icd_json, const char *cache_dir, unsigned port) {
    if (gSingletonDevice) return gSingletonDevice;
    gXm2vDevice = xm2v_device_open(loader, icd_json, cache_dir);
    if (!gXm2vDevice) {
        fprintf(stderr, "XnuCpuMetal: xm2v_device_open failed: %s\n", xm2v_last_error());
        return nil;
    }
    if (port) {
        uint64_t rid = 0;
        if (IORegistryEntryGetRegistryEntryID(port, &rid) == KERN_SUCCESS && rid != 0)
            gRegistryID = rid;
    }
    Class cls = createBackendDeviceClass();
    id dev = [[cls alloc] init];
    fillBaseLimits(dev);
    xcm_iogpu::install(dev, port);
    gSingletonDevice = dev;
    return dev;
}

/* ======================== Bundle Principal Class ======================== */

@interface XnuCpuMetalDevice : IOGPUMetalDevice
- (id)initWithAcceleratorPort:(unsigned)port;
- (id)initWithAcceleratorPort:(unsigned)port options:(unsigned long long)options;
@end

@implementation XnuCpuMetalDevice

- (id)initWithAcceleratorPort:(unsigned)port options:(unsigned long long)options {
    (void)options;
    return [self initWithAcceleratorPort:port];
}

- (id)initWithAcceleratorPort:(unsigned)port {
    static NSMutableArray *kept;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ kept = [NSMutableArray array]; });
    @synchronized(kept) { [kept addObject:self]; }

    Dl_info info = {};
    std::string contentsDir;
    if (dladdr((const void *)&xnu_cpu_metal_open_device, &info) && info.dli_fname) {
        std::string execPath(info.dli_fname);
        size_t pos = execPath.rfind("/MacOS/");
        if (pos != std::string::npos) contentsDir = execPath.substr(0, pos);
    }

    std::string loader = contentsDir.empty() ? "libvulkan.1.dylib" : (contentsDir + "/Frameworks/libvulkan.1.dylib");
    std::string icdJson = contentsDir.empty() ? "" : (contentsDir + "/Resources/lvp_icd.aarch64.json");

    const char *envLoader = getenv("XNU_CPU_METAL_LOADER");
    if (envLoader && envLoader[0]) loader = envLoader;
    const char *envIcd = getenv("XNU_CPU_METAL_ICD");
    if (envIcd && envIcd[0]) icdJson = envIcd;

    char cacheDir[512] = {};
    auto tryCacheDir = [&](const char *path) -> bool {
        if (!path || !path[0]) return false;
        mkdir(path, 0700);
        if (access(path, W_OK | X_OK) == 0) {
            strlcpy(cacheDir, path, sizeof(cacheDir));
            return true;
        }
        return false;
    };
    const char *envCache = getenv("XNU_CPU_METAL_CACHE_DIR");
    if (!tryCacheDir(envCache)) {
        char darwinCache[512] = {};
        bool ok = false;
        if (confstr(_CS_DARWIN_USER_CACHE_DIR, darwinCache, sizeof(darwinCache) - 32) > 0) {
            strlcat(darwinCache, "xnu-cpu-metal-m2v", sizeof(darwinCache));
            ok = tryCacheDir(darwinCache);
        }
        if (!ok) {
            char fallback[128];
            snprintf(fallback, sizeof(fallback), "/var/tmp/xnu-cpu-metal-%u", (unsigned)getuid());
            ok = tryCacheDir(fallback);
        }
        if (!ok) {
            char fallback[128];
            snprintf(fallback, sizeof(fallback), "/tmp/xnu-cpu-metal-%u", (unsigned)getuid());
            tryCacheDir(fallback);
        }
    }

    // Configure Mesa lavapipe LLVM JIT disk cache (bounded, overridable by caller).
    if (cacheDir[0]) {
        char mesaCache[544];
        snprintf(mesaCache, sizeof(mesaCache), "%s/mesa", cacheDir);
        mkdir(mesaCache, 0700);
        setenv("MESA_SHADER_CACHE_DIR", mesaCache, 0);
    }
    setenv("MESA_SHADER_CACHE_MAX_SIZE", "256M", 0);

    // Multi-VM safe lavapipe thread default: 0 (inline, no worker threads) on 1-CPU hosts,
    // capped at 2 on multi-core hosts; always overridable via LP_NUM_THREADS.
    if (!getenv("LP_NUM_THREADS")) {
        int ncpu = 1;
        size_t sz = sizeof(ncpu);
        if (sysctlbyname("hw.ncpu", &ncpu, &sz, nullptr, 0) != 0 || ncpu < 1) ncpu = 1;
        int lpThreads = (ncpu <= 1) ? 0 : (ncpu > 2 ? 2 : ncpu);
        char buf[16];
        snprintf(buf, sizeof(buf), "%d", lpThreads);
        setenv("LP_NUM_THREADS", buf, 0);
    }

    return xnu_cpu_metal_open_device(loader.c_str(), icdJson.c_str(), cacheDir, port);
}

@end
