// SPDX-License-Identifier: GPL-2.0-or-later
// Forms of Metal calls that a device must answer itself: where it does not, Metal's base classes answer with nil or
// with nothing at all, and no error. Every case passes on Apple's device (give "default" for the bundle), which is
// what each expectation here was measured on:
// 1. The pipeline-state forms that answer through a completion handler call it (render: 2 forms, compute: 3).
// 2. newCommandQueueWithDescriptor: gives a queue that runs command buffers.
// 3. blitCommandEncoderWithDescriptor: / computeCommandEncoderWithDescriptor: give encoders that encode.
// 4. Texture views: newTextureViewWithDescriptor: gives the view the older call gives, and a view knows the texture
//    it was made from (parentTexture, parentRelativeLevel, parentRelativeSlice).
// 5. A format's bytes per pixel: formats of one size report one allocatedSize, and a texture on an IOSurface whose
//    last row is not padded still reads and writes its surface (a 16-bit packed format, and 4:2:2 video).
//
//   clang++ -arch arm64 -O2 -fobjc-arc -isysroot "$(xcrun --show-sdk-path)" test/test_api_forms.mm \
//       -framework Foundation -framework Metal -framework IOSurface -o build/test_api_forms
//   build/test_api_forms dist/XnuCpuMetal.bundle

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <objc/message.h>
#include <mach/mach.h>
#include <pthread.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <unistd.h>

@interface NSObject (XnuCpuMetalPluginForms)
- (id)initWithAcceleratorPort:(unsigned)port;
@end

static id<MTLDevice> loadBundleDevice(const char *bundlePath) {
    if (strcmp(bundlePath, "default") == 0) {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) fprintf(stderr, "FAIL: MTLCreateSystemDefaultDevice returned nil\n");
        return dev;
    }
    NSBundle *b = [NSBundle bundleWithPath:[NSString stringWithUTF8String:bundlePath]];
    if (!b || ![b load]) { fprintf(stderr, "FAIL: cannot load bundle %s\n", bundlePath); return nil; }
    Class cls = [b principalClass];
    if (!cls) { fprintf(stderr, "FAIL: no principalClass\n"); return nil; }
    id<MTLDevice> dev = [[cls alloc] initWithAcceleratorPort:0];
    if (!dev) { fprintf(stderr, "FAIL: initWithAcceleratorPort:0 returned nil\n"); return nil; }
    return dev;
}

static id<MTLLibrary> gLibrary;

/* ---- 1. pipeline states through a completion handler ---- */

static int test1_PipelineCompletionHandlers(id<MTLDevice> dev) {
    MTLRenderPipelineDescriptor *rd = [[MTLRenderPipelineDescriptor alloc] init];
    rd.vertexFunction = [gLibrary newFunctionWithName:@"vertexMain"];
    rd.fragmentFunction = [gLibrary newFunctionWithName:@"fragmentMain"];
    rd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLFunction> kernel = [gLibrary newFunctionWithName:@"kernelMain"];
    MTLComputePipelineDescriptor *cd = [[MTLComputePipelineDescriptor alloc] init];
    cd.computeFunction = kernel;
    if (!rd.vertexFunction || !rd.fragmentFunction || !kernel) { fprintf(stderr, "FAIL [1/5]: the library lacks a function\n"); return 1; }

    static const char *const names[5] = {
        "newRenderPipelineStateWithDescriptor:completionHandler:",
        "newRenderPipelineStateWithDescriptor:options:completionHandler:",
        "newComputePipelineStateWithFunction:completionHandler:",
        "newComputePipelineStateWithFunction:options:completionHandler:",
        "newComputePipelineStateWithDescriptor:options:completionHandler:",
    };
    static std::atomic<int> called[5], good[5], insideCall[5];
    static std::atomic<int> calling{-1};
    pthread_t caller = pthread_self();
    dispatch_group_t all = dispatch_group_create();
    for (int i = 0; i < 5; i++) dispatch_group_enter(all);
    auto answered = ^(int i, id state, NSError *error) {
        if (calling.load() == i && pthread_equal(pthread_self(), caller)) insideCall[i] = 1;
        if (state && !error) good[i] = 1;
        else fprintf(stderr, "  %s: state %s, error %s\n", names[i], state ? "given" : "nil", error.localizedDescription.UTF8String ?: "nil");
        if (called[i].fetch_add(1) == 0) dispatch_group_leave(all);
    };
    calling = 0;
    [dev newRenderPipelineStateWithDescriptor:rd completionHandler:^(id<MTLRenderPipelineState> s, NSError *e) { answered(0, s, e); }];
    calling = 1;
    [dev newRenderPipelineStateWithDescriptor:rd options:MTLPipelineOptionNone
                            completionHandler:^(id<MTLRenderPipelineState> s, MTLRenderPipelineReflection *r, NSError *e) { (void)r; answered(1, s, e); }];
    calling = 2;
    [dev newComputePipelineStateWithFunction:kernel completionHandler:^(id<MTLComputePipelineState> s, NSError *e) { answered(2, s, e); }];
    calling = 3;
    [dev newComputePipelineStateWithFunction:kernel options:MTLPipelineOptionNone
                           completionHandler:^(id<MTLComputePipelineState> s, MTLComputePipelineReflection *r, NSError *e) { (void)r; answered(3, s, e); }];
    calling = 4;
    [dev newComputePipelineStateWithDescriptor:cd options:MTLPipelineOptionNone
                             completionHandler:^(id<MTLComputePipelineState> s, MTLComputePipelineReflection *r, NSError *e) { (void)r; answered(4, s, e); }];
    calling = -1;
    dispatch_group_wait(all, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    usleep(50000);   // a handler called twice would show now
    int bad = 0;
    for (int i = 0; i < 5; i++) {
        if (called[i] == 1 && good[i] && !insideCall[i]) continue;
        fprintf(stderr, "FAIL [1/5]: %s: the handler was called %d time(s) in 30 s%s%s\n", names[i], called[i].load(),
                called[i] ? (good[i] ? "" : ", without a pipeline state") : "",
                insideCall[i] ? ", inside the call on the caller's thread (a caller that holds a lock its handler takes stops there)" : "");
        bad = 1;
    }
    if (bad) return 1;
    printf("PASS [1/5]: the five pipeline-state forms with a completion handler each called it once, with a state, not inside the call\n");
    return 0;
}

/* ---- 2. a queue from a descriptor ---- */

static int test2_CommandQueueWithDescriptor(id<MTLDevice> dev) {
    id desc = [NSClassFromString(@"MTLCommandQueueDescriptor") new];   // macOS 15
    if (!desc) { printf("SKIP [2/5]: no MTLCommandQueueDescriptor on this system\n"); return 0; }
    typedef id (*NewFromDescriptor)(id, SEL, id) NS_RETURNS_RETAINED;
    id<MTLCommandQueue> q = ((NewFromDescriptor)objc_msgSend)(dev, sel_registerName("newCommandQueueWithDescriptor:"), desc);
    if (!q) { fprintf(stderr, "FAIL [2/5]: newCommandQueueWithDescriptor: returned nil\n"); return 1; }
    id<MTLBuffer> buf = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    memset(buf.contents, 0, 16);
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit fillBuffer:buf range:NSMakeRange(0, 4) value:0x5A];
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    uint32_t v = 0;
    memcpy(&v, buf.contents, 4);
    if (!cb || cb.status != MTLCommandBufferStatusCompleted || v != 0x5A5A5A5Au) {
        fprintf(stderr, "FAIL [2/5]: a command buffer of that queue: %s, status %lu, the buffer it fills 0x%08x\n",
                cb ? "made" : "nil", (unsigned long)cb.status, v);
        return 1;
    }
    printf("PASS [2/5]: newCommandQueueWithDescriptor: gives a queue whose command buffer runs\n");
    return 0;
}

/* ---- 3. encoders from a pass descriptor ---- */

static int test3_EncodersWithDescriptor(id<MTLDevice> dev) {
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLBuffer> buf = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    memset(buf.contents, 0, 16);
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoderWithDescriptor:[MTLBlitPassDescriptor blitPassDescriptor]];
    [blit fillBuffer:buf range:NSMakeRange(0, 4) value:0xC3];
    [blit endEncoding];
    id<MTLComputeCommandEncoder> compute = [cb computeCommandEncoderWithDescriptor:[MTLComputePassDescriptor computePassDescriptor]];
    [compute endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    uint32_t v = 0;
    memcpy(&v, buf.contents, 4);
    if (!blit || !compute || cb.status != MTLCommandBufferStatusCompleted || v != 0xC3C3C3C3u) {
        fprintf(stderr, "FAIL [3/5]: blitCommandEncoderWithDescriptor: -> %s, computeCommandEncoderWithDescriptor: -> %s, status %lu, the buffer the blit pass fills 0x%08x (expected 0xc3c3c3c3)\n",
                blit ? "an encoder" : "nil", compute ? "an encoder" : "nil", (unsigned long)cb.status, v);
        return 1;
    }
    printf("PASS [3/5]: blitCommandEncoderWithDescriptor: and computeCommandEncoderWithDescriptor: give encoders; the blit pass ran\n");
    return 0;
}

/* ---- 4. texture views ---- */

static NSString *shape(id<MTLTexture> t) {
    if (!t) return @"nil";
    return [NSString stringWithFormat:@"type=%lu fmt=%lu %lux%lux%lu mips=%lu array=%lu", (unsigned long)t.textureType,
            (unsigned long)t.pixelFormat, (unsigned long)t.width, (unsigned long)t.height, (unsigned long)t.depth,
            (unsigned long)t.mipmapLevelCount, (unsigned long)t.arrayLength];
}

static int parentIs(const char *what, id<MTLTexture> t, id<MTLTexture> parent, NSUInteger level, NSUInteger slice) {
    if (!t) { fprintf(stderr, "FAIL [4/5]: %s: nil\n", what); return 1; }
    if (t.parentTexture == parent && t.parentRelativeLevel == level && t.parentRelativeSlice == slice) return 0;
    fprintf(stderr, "FAIL [4/5]: %s: parentTexture %s, parentRelativeLevel %lu, parentRelativeSlice %lu (expected %s, %lu, %lu)\n", what,
            !t.parentTexture ? "nil" : t.parentTexture == parent ? "the texture it was made from" : "another texture",
            (unsigned long)t.parentRelativeLevel, (unsigned long)t.parentRelativeSlice,
            parent ? "the texture it was made from" : "nil", (unsigned long)level, (unsigned long)slice);
    return 1;
}

static int test4_TextureViews(id<MTLDevice> dev) {
    MTLTextureDescriptor *td = [[MTLTextureDescriptor alloc] init];
    td.textureType = MTLTextureType2DArray;
    td.pixelFormat = MTLPixelFormatRGBA8Unorm;
    td.width = 16; td.height = 8; td.mipmapLevelCount = 4; td.arrayLength = 6;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    if (!tex) { fprintf(stderr, "FAIL [4/5]: no texture\n"); return 1; }
    int rc = 0;

    // what a view knows of the texture it was made from
    id<MTLTexture> same = [tex newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
    id<MTLTexture> part = [tex newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB textureType:MTLTextureType2DArray
                                                      levels:NSMakeRange(1, 2) slices:NSMakeRange(2, 3)];
    id<MTLTexture> inner = [part newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm textureType:MTLTextureType2D
                                                        levels:NSMakeRange(1, 1) slices:NSMakeRange(1, 1)];
    rc |= parentIs("a texture that is no view", tex, nil, 0, 0);
    rc |= parentIs("a view in another format", same, tex, 0, 0);
    rc |= parentIs("a view of levels 1-2, slices 2-4", part, tex, 1, 2);
    rc |= parentIs("a view of level 1, slice 1 of that view", inner, part, 1, 1);
    __weak id<MTLTexture> weakParent = nil;
    id<MTLTexture> orphan = nil;
    @autoreleasepool {
        id<MTLTexture> owner = [dev newTextureWithDescriptor:td];
        weakParent = owner;
        orphan = [owner newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
    }
    if (orphan && (!orphan.parentTexture || orphan.parentTexture != weakParent)) {
        fprintf(stderr, "FAIL [4/5]: once the program let go of a texture, its view's parentTexture is %s\n", orphan.parentTexture ? "another texture" : "nil");
        rc = 1;
    }

    // the descriptor form (macOS 26) gives the view the older call gives
    const char *descResult = "skipped (no MTLTextureViewDescriptor on this system)";
    id vd = [NSClassFromString(@"MTLTextureViewDescriptor") new];
    if (vd) {
        [vd setValue:@(MTLPixelFormatRGBA8Unorm_sRGB) forKey:@"pixelFormat"];
        [vd setValue:@(MTLTextureType2DArray) forKey:@"textureType"];
        [vd setValue:[NSValue valueWithRange:NSMakeRange(1, 2)] forKey:@"levelRange"];
        [vd setValue:[NSValue valueWithRange:NSMakeRange(2, 3)] forKey:@"sliceRange"];
        typedef id (*NewFromDescriptor)(id, SEL, id) NS_RETURNS_RETAINED;
        id<MTLTexture> byDesc = ((NewFromDescriptor)objc_msgSend)(tex, sel_registerName("newTextureViewWithDescriptor:"), vd);
        if (!byDesc || ![shape(byDesc) isEqualToString:shape(part)] || ![shape(part) isEqualToString:@"type=3 fmt=71 8x4x1 mips=2 array=3"]) {
            fprintf(stderr, "FAIL [4/5]: newTextureViewWithDescriptor: gave %s; newTextureViewWithPixelFormat:textureType:levels:slices: for the same values gave %s (expected type=3 fmt=71 8x4x1 mips=2 array=3)\n",
                    shape(byDesc).UTF8String, shape(part).UTF8String);
            rc = 1;
        } else {
            rc |= parentIs("a view from a descriptor, levels 1-2, slices 2-4", byDesc, tex, 1, 2);
            descResult = "the same view as the older call";
        }
    }
    if (rc) return 1;
    printf("PASS [4/5]: views know their parent texture, level and slice; newTextureViewWithDescriptor: %s\n", descResult);
    return 0;
}

/* ---- 5. bytes per pixel ---- */

static int test5_BytesPerPixel(id<MTLDevice> dev) {
    // Two formats of the same size a pixel: textures of the same shape take the same room.
    static const struct { const char *name, *twinName; MTLPixelFormat format, twin; } pairs[] = {
        {"R8Unorm_sRGB", "R8Unorm", MTLPixelFormatR8Unorm_sRGB, MTLPixelFormatR8Unorm},
        {"RG8Unorm_sRGB", "RG8Unorm", MTLPixelFormatRG8Unorm_sRGB, MTLPixelFormatRG8Unorm},
        {"B5G6R5Unorm", "R16Unorm", MTLPixelFormatB5G6R5Unorm, MTLPixelFormatR16Unorm},
        {"A1BGR5Unorm", "R16Unorm", MTLPixelFormatA1BGR5Unorm, MTLPixelFormatR16Unorm},
        {"ABGR4Unorm", "R16Unorm", MTLPixelFormatABGR4Unorm, MTLPixelFormatR16Unorm},
        {"BGR5A1Unorm", "R16Unorm", MTLPixelFormatBGR5A1Unorm, MTLPixelFormatR16Unorm},
    };
    int rc = 0, compared = 0;
    for (const auto &p : pairs) {
        MTLTextureDescriptor *a = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:p.format width:512 height:512 mipmapped:NO];
        MTLTextureDescriptor *b = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:p.twin width:512 height:512 mipmapped:NO];
        a.usage = b.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> ta = [dev newTextureWithDescriptor:a], tb = [dev newTextureWithDescriptor:b];
        if (!ta || !tb) { printf("  (%s or %s: no such texture on this device, not compared)\n", p.name, p.twinName); continue; }
        compared++;
        if (ta.allocatedSize != tb.allocatedSize) {
            fprintf(stderr, "FAIL [5/5]: 512x512 %s reports allocatedSize %lu, %s (the same bytes a pixel) %lu\n",
                    p.name, (unsigned long)ta.allocatedSize, p.twinName, (unsigned long)tb.allocatedSize);
            rc = 1;
        }
    }

    // An IOSurface of 2-byte pixels, 2 rows, whose rows are padded and whose allocation ends with the last row's pixels
    // (one page exactly): IOSurfaceCreate makes it, and a texture on it reads and writes it. A packed format, and 4:2:2
    // video ('2vuy', what a decoder hands out).
    static const struct { const char *name; MTLPixelFormat format; uint32_t fourcc; } surfaces[] = {
        {"B5G6R5Unorm", MTLPixelFormatB5G6R5Unorm, 'L565'}, {"BGRG422", MTLPixelFormatBGRG422, '2vuy'},
    };
    NSMutableString *surfaceResult = [NSMutableString string];
    for (const auto &sf : surfaces) {
        size_t page = (size_t)vm_page_size, pad = 64, W = (page - pad) / 4, H = 2, bpr = W * 2 + pad;
        NSDictionary *props = @{
            (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @2,
            (id)kIOSurfaceBytesPerRow: @(bpr), (id)kIOSurfaceAllocSize: @(bpr * (H - 1) + W * 2),
            (id)kIOSurfacePixelFormat: @(sf.fourcc),
        };
        IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:sf.format width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> tex = nil;
        if (surf && IOSurfaceGetBytesPerRow(surf) == bpr && IOSurfaceGetAllocSize(surf) < bpr * H)
            tex = [dev newTextureWithDescriptor:td iosurface:surf plane:0];
        if (tex) {
            std::vector<uint16_t> drawn(W * H), read(W * H, 0), written(W, 0);
            IOSurfaceLock(surf, 0, nullptr);
            uint8_t *base = (uint8_t *)IOSurfaceGetBaseAddress(surf);
            for (size_t y = 0; y < H; y++)
                for (size_t x = 0; x < W; x++) {
                    drawn[y * W + x] = (uint16_t)(x * 7 + y * 131 + 1);
                    memcpy(base + y * bpr + x * 2, &drawn[y * W + x], 2);
                }
            IOSurfaceUnlock(surf, 0, nullptr);
            [tex getBytes:read.data() bytesPerRow:W * 2 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
            for (size_t x = 0; x < W; x++) written[x] = (uint16_t)(0xF000 + x);
            [tex replaceRegion:MTLRegionMake2D(0, H - 1, W, 1) mipmapLevel:0 withBytes:written.data() bytesPerRow:W * 2];
            IOSurfaceLock(surf, kIOSurfaceLockReadOnly, nullptr);
            bool wroteBack = memcmp((uint8_t *)IOSurfaceGetBaseAddress(surf) + (H - 1) * bpr, written.data(), W * 2) == 0;
            bool firstRowKept = memcmp(IOSurfaceGetBaseAddress(surf), drawn.data(), W * 2) == 0;
            IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, nullptr);
            bool readIn = memcmp(read.data(), drawn.data(), W * H * 2) == 0;
            if (!readIn || !wroteBack || !firstRowKept) {
                fprintf(stderr, "FAIL [5/5]: a %zux%zu %s texture on an IOSurface with %zu-byte rows and %zu bytes in all: getBytes %s what was drawn into the surface, replaceRegion of the last row %s the surface, the first row %s\n",
                        W, H, sf.name, bpr, IOSurfaceGetAllocSize(surf), readIn ? "gave" : "did not give", wroteBack ? "reached" : "did not reach",
                        firstRowKept ? "stayed" : "was lost");
                rc = 1;
            }
        }
        [surfaceResult appendFormat:@"%s%s %s", surfaceResult.length ? ", " : "", sf.name, tex ? "read and written" : "skipped (no such texture here)"];
        if (surf) CFRelease(surf);
    }
    if (rc) return 1;
    printf("PASS [5/5]: %d formats report the allocatedSize of their twin of the same size; a texture on an IOSurface that ends with its last row's pixels: %s\n",
           compared, surfaceResult.UTF8String);
    return 0;
}

int main(int argc, char **argv) {
    setvbuf(stdout, nullptr, _IONBF, 0);
    @autoreleasepool {
        const char *bundlePath = (argc > 1) ? argv[1] : getenv("XNU_CPU_METAL_BUNDLE");
        if (!bundlePath) { fprintf(stderr, "Usage: %s <XnuCpuMetal.bundle | default>\n", argv[0]); return 2; }
        id<MTLDevice> dev = loadBundleDevice(bundlePath);
        if (!dev) return 1;
        printf("Device: %s\n", dev.name.UTF8String);
        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                         "struct VOut { float4 pos [[position]]; };\n"
                         "vertex VOut vertexMain(uint vid [[vertex_id]]) { VOut o; o.pos = float4(float(vid) - 1.0, 0.0, 0.0, 1.0); return o; }\n"
                         "fragment float4 fragmentMain() { return float4(1.0); }\n"
                         "kernel void kernelMain(device uint *out [[buffer(0)]], uint g [[thread_position_in_grid]]) { out[g] = g; }\n";
        NSError *err = nil;
        gLibrary = [dev newLibraryWithSource:src options:nil error:&err];
        if (!gLibrary) { fprintf(stderr, "FAIL: newLibraryWithSource: %s\n", err.localizedDescription.UTF8String); return 1; }
        int rc = 0;
        rc |= test1_PipelineCompletionHandlers(dev);
        rc |= test2_CommandQueueWithDescriptor(dev);
        rc |= test3_EncodersWithDescriptor(dev);
        rc |= test4_TextureViews(dev);
        rc |= test5_BytesPerPixel(dev);
        if (rc == 0) printf("ALL API FORM TESTS PASSED!\n");
        return rc;
    }
}
