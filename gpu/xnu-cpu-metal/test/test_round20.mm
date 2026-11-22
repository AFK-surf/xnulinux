// Round 20 regression test:
// Preserves all Round 19 assertions (1-3) + verifies true mach_vm_remap physical-page aliasing (4-7):
// 1. 16-byte linear/IOSurface texture alignment queries.
// 2. 2-plane 10-bit YCbCr IOSurface ('x420') -> MTLPixelFormatYCBCR10_420_2P (505) sampling.
// 3. CoreImage CIGaussianBlur across 18 non-64-aligned width/radius combinations.
// 4. mach_vm_remap aliasing + PROT_READ/unaligned bounded fallback counters + deallocator==nil/!=nil lifetime.
// 5. Ring buffer: concurrent CPU write to slice N+1 while GPU executes on slice N.
// 6. Calling [buf contents] before commit and inside addCompletedHandler: never blocks or deadlocks.
// 7. 33 MB wallpaper-sized NoCopy buffer submitted 10 times with 0 per-commit copies (proven by xcmNoCopyStats).

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <IOSurface/IOSurface.h>
#import <objc/message.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>

@interface NSObject (XnuCpuMetalPluginR20)
- (id)initWithAcceleratorPort:(unsigned)port;
- (NSDictionary *)xcmNoCopyStats;
@end

static id<MTLDevice> loadBundleDevice(const char *bundlePath) {
    if (bundlePath && strcmp(bundlePath, "default") == 0) {
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

static NSDictionary *getStats(id<MTLDevice> dev) {
    SEL s = @selector(xcmNoCopyStats);
    return [dev respondsToSelector:s] ? ((NSDictionary *(*)(id, SEL))objc_msgSend)(dev, s) : @{};
}

static int test1_Alignment(id<MTLDevice> dev) {
    NSUInteger a1 = [dev minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatBGRA8Unorm];
    NSUInteger a2 = [dev minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatRGBA16Float];
    NSUInteger a3 = [dev minimumTextureBufferAlignmentForPixelFormat:MTLPixelFormatBGRA8Unorm];
    SEL selIso = NSSelectorFromString(@"iosurfaceTextureAlignmentBytes");
    SEL selLin = NSSelectorFromString(@"linearTextureAlignmentBytes");
    NSUInteger isoA = [dev respondsToSelector:selIso] ? ((NSUInteger(*)(id, SEL))objc_msgSend)(dev, selIso) : 0;
    NSUInteger linA = [dev respondsToSelector:selLin] ? ((NSUInteger(*)(id, SEL))objc_msgSend)(dev, selLin) : 0;
    if (a1 != 16 || a2 != 16 || a3 != 16 || isoA != 16 || linA != 16) {
        fprintf(stderr, "FAIL [1/7]: expected 16, got %lu/%lu/%lu/%lu/%lu\n",
                (unsigned long)a1, (unsigned long)a2, (unsigned long)a3, (unsigned long)isoA, (unsigned long)linA);
        return 1;
    }
    printf("PASS [1/7]: all linear/IOSurface texture alignments == 16\n");
    return 0;
}

static int test2_YCbCrIOSurface(id<MTLDevice> dev) {
    const int W = 64, H = 64;
    NSDictionary *plane0 = @{
        (id)kIOSurfacePlaneWidth: @(W), (id)kIOSurfacePlaneHeight: @(H),
        (id)kIOSurfacePlaneBytesPerElement: @(2), (id)kIOSurfacePlaneBytesPerRow: @(W * 2),
        (id)kIOSurfacePlaneSize: @(W * 2 * H), (id)kIOSurfacePlaneOffset: @(0),
    };
    NSDictionary *plane1 = @{
        (id)kIOSurfacePlaneWidth: @(W / 2), (id)kIOSurfacePlaneHeight: @(H / 2),
        (id)kIOSurfacePlaneBytesPerElement: @(4), (id)kIOSurfacePlaneBytesPerRow: @((W / 2) * 4),
        (id)kIOSurfacePlaneSize: @((W / 2) * 4 * (H / 2)), (id)kIOSurfacePlaneOffset: @(W * 2 * H),
    };
    NSDictionary *props = @{
        (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H),
        (id)kIOSurfacePixelFormat: @((uint32_t)'x420'),
        (id)kIOSurfaceAllocSize: @(W * 2 * H + (W / 2) * 4 * (H / 2)),
        (id)kIOSurfacePlaneInfo: @[plane0, plane1],
    };
    IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
    if (!surf) return 1;
    IOSurfaceSetValue(surf, CFSTR("IOSurfaceYCbCrMatrix"), CFSTR("ITU_R_709_2"));
    IOSurfaceLock(surf, 0, NULL);
    uint16_t *yP = (uint16_t *)IOSurfaceGetBaseAddressOfPlane(surf, 0);
    size_t yBpr = IOSurfaceGetBytesPerRowOfPlane(surf, 0) / 2;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) yP[y * yBpr + x] = (uint16_t)(940 << 6);
    uint16_t *uvP = (uint16_t *)IOSurfaceGetBaseAddressOfPlane(surf, 1);
    size_t uvBpr = IOSurfaceGetBytesPerRowOfPlane(surf, 1) / 2;
    for (int y = 0; y < H / 2; y++) for (int x = 0; x < W / 2; x++) {
        uvP[y * uvBpr + x * 2 + 0] = (uint16_t)(512 << 6);
        uvP[y * uvBpr + x * 2 + 1] = (uint16_t)(512 << 6);
    }
    IOSurfaceUnlock(surf, 0, NULL);

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:(MTLPixelFormat)505
                                                                                  width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td iosurface:surf plane:0];
    if (!tex) { CFRelease(surf); return 1; }

    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                     "kernel void s(texture2d<float, access::sample> t [[texture(0)]], device float4 *o [[buffer(0)]], uint g [[thread_position_in_grid]]) {\n"
                     "  constexpr sampler sm(filter::linear); if (g == 0) o[0] = t.sample(sm, float2(0.5, 0.5)); }\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"s"] error:&err];
    id<MTLBuffer> outBuf = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:pso];
    [enc setTexture:tex atIndex:0];
    [enc setBuffer:outBuf offset:0 atIndex:0];
    [enc dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    float *rgba = (float *)outBuf.contents;
    CFRelease(surf);
    if (fabsf(rgba[0] - 1.0f) > 0.03f || fabsf(rgba[1] - 1.0f) > 0.03f ||
        fabsf(rgba[2] - 1.0f) > 0.03f || fabsf(rgba[3] - 1.0f) > 0.03f) {
        fprintf(stderr, "FAIL [2/7]: rgba=(%.3f,%.3f,%.3f,%.3f)\n", rgba[0], rgba[1], rgba[2], rgba[3]);
        return 1;
    }
    printf("PASS [2/7]: 2-plane YCBCR10_420_2P IOSurface sampled accurately\n");
    return 0;
}

static int test3_CIGaussianBlur(id<MTLDevice> dev) {
    CIContext *ctx = [CIContext contextWithMTLDevice:dev];
    const int widths[] = {124, 126, 128, 130, 136, 140};
    const float radii[] = {6.0f, 10.0f, 15.0f};
    int cases = 0;
    for (int w : widths) {
        for (float r : radii) {
            CIImage *base = [[CIImage imageWithColor:[CIColor colorWithRed:0.8 green:0.4 blue:0.15 alpha:1.0]]
                imageByCroppingToRect:CGRectMake(20, 20, w - 40, w - 40)];
            CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
            [blur setValue:base forKey:kCIInputImageKey];
            [blur setValue:@(r) forKey:kCIInputRadiusKey];
            CIImage *out = [blur.outputImage imageByCroppingToRect:CGRectMake(0, 0, w, w)];
            uint8_t *buf = (uint8_t *)calloc((size_t)w * (size_t)w * 4, 1);
            [ctx render:out toBitmap:buf rowBytes:(size_t)w * 4
                 bounds:CGRectMake(0, 0, w, w) format:kCIFormatRGBA8 colorSpace:CGColorSpaceCreateDeviceRGB()];
            uint8_t *p = buf + ((size_t)(w / 2) * (size_t)w + (size_t)(w / 2)) * 4;
            bool ok = (p[0] > 50 && p[3] > 50);
            free(buf);
            if (!ok) { fprintf(stderr, "FAIL [3/7]: CIGaussianBlur w=%d r=%.0f\n", w, r); return 1; }
            cases++;
        }
    }
    printf("PASS [3/7]: CoreImage CIGaussianBlur passed all %d non-64-aligned cases\n", cases);
    return 0;
}

static int test4_AliasAndFallbackAndLifetime(id<MTLDevice> dev) {
    size_t pageSz = (size_t)vm_page_size;
    NSDictionary *s0 = getStats(dev);
    uint64_t aliased0 = [s0[@"aliased"] unsignedLongLongValue];
    uint64_t ro0 = [s0[@"fallbackReadOnly"] unsignedLongLongValue];
    uint64_t unal0 = [s0[@"fallbackUnaligned"] unsignedLongLongValue];
    uint64_t copies0 = [s0[@"commitSyncCopies"] unsignedLongLongValue];

    // 4a. Read-only PROT_READ mmap -> must NOT remap, must increment fallbackReadOnly, must NOT crash
    void *roMem = mmap(nullptr, pageSz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    for (size_t i = 0; i < 64; i++) ((uint32_t *)roMem)[i] = (uint32_t)(100 + i);
    mprotect(roMem, pageSz, PROT_READ);

    // 4b. Page-aligned RW mmap with deallocator==nil -> must alias, preserve final GPU bytes after MTLBuffer release!
    void *rwMem = mmap(nullptr, pageSz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    memset(rwMem, 0, pageSz);
    ((uint32_t *)rwMem)[100] = 0xDEADBEEFu; // pre-existing data must survive initial copy + remap

    // 4c. Unaligned pointer -> must increment fallbackUnaligned
    void *rawUnal = mmap(nullptr, pageSz * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    void *unalPtr = (uint8_t *)rawUnal + 64;
    ((uint32_t *)unalPtr)[0] = 0x13572468u;

    // 4d. Page-aligned RW mmap with deallocator!=nil -> must alias and invoke deallocator cleanly
    void *ownedMem = mmap(nullptr, pageSz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    __block int deallocFired = 0;
    @autoreleasepool {
        id<MTLBuffer> roBuf = [dev newBufferWithBytesNoCopy:roMem length:pageSz options:MTLResourceStorageModeShared deallocator:nil];
        id<MTLBuffer> rwBuf = [dev newBufferWithBytesNoCopy:rwMem length:pageSz options:MTLResourceStorageModeShared deallocator:nil];
        id<MTLBuffer> unalBuf = [dev newBufferWithBytesNoCopy:unalPtr length:4096 options:MTLResourceStorageModeShared deallocator:nil];
        id<MTLBuffer> ownedBuf = [dev newBufferWithBytesNoCopy:ownedMem length:pageSz options:MTLResourceStorageModeShared
                                                   deallocator:^(void *p, NSUInteger l) {
            munmap(p, l);
            deallocFired++;
        }];
        if (!roBuf || !rwBuf || !unalBuf || !ownedBuf) { fprintf(stderr, "FAIL [4/7]: alloc nil\n"); return 1; }
        if (rwBuf.contents != rwMem || ownedBuf.contents != ownedMem) {
            fprintf(stderr, "FAIL [4/7]: aliased contents != caller ptr\n");
            return 1;
        }
        if (((uint32_t *)rwMem)[100] != 0xDEADBEEFu) {
            fprintf(stderr, "FAIL [4/7]: initial data lost after remap\n");
            return 1;
        }

        NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                         "kernel void add1(device const uint *a [[buffer(0)]], device uint *b [[buffer(1)]], uint g [[thread_position_in_grid]]) {\n"
                         "  if (g < 64) b[g] = a[g] + 1; }\n";
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
        id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"add1"] error:&err];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setBuffer:roBuf offset:0 atIndex:0];
        [enc setBuffer:rwBuf offset:0 atIndex:1];
        [enc dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];

        if (((uint32_t *)rwMem)[0] != 101 || ((uint32_t *)rwMem)[63] != 164 || ((uint32_t *)rwMem)[100] != 0xDEADBEEFu) {
            fprintf(stderr, "FAIL [4/7]: GPU output not visible in aliased rwMem\n");
            return 1;
        }
        (void)unalBuf;
    } // buffers released here!

    // After rwBuf dealloc (deallocator==nil), rwMem MUST still contain GPU output and remain writable!
    if (((uint32_t *)rwMem)[0] != 101 || ((uint32_t *)rwMem)[63] != 164) {
        fprintf(stderr, "FAIL [4/7]: rwMem data lost after MTLBuffer release (deallocator==nil)\n");
        return 1;
    }
    ((uint32_t *)rwMem)[0] = 0x55AA55AAu;
    if (deallocFired != 1) {
        fprintf(stderr, "FAIL [4/7]: deallocator not invoked (count=%d)\n", deallocFired);
        return 1;
    }

    NSDictionary *s1 = getStats(dev);
    uint64_t dAliased = [s1[@"aliased"] unsignedLongLongValue] - aliased0;
    uint64_t dRo = [s1[@"fallbackReadOnly"] unsignedLongLongValue] - ro0;
    uint64_t dUnal = [s1[@"fallbackUnaligned"] unsignedLongLongValue] - unal0;
    uint64_t dCopies = [s1[@"commitSyncCopies"] unsignedLongLongValue] - copies0;

    munmap(roMem, pageSz);
    munmap(rwMem, pageSz);
    munmap(rawUnal, pageSz * 2);

    if (dAliased != 2 || dRo != 1 || dUnal != 1 || dCopies != 0) {
        fprintf(stderr, "FAIL [4/7]: stats dAliased=%llu(exp 2) dRo=%llu(exp 1) dUnal=%llu(exp 1) dCopies=%llu(exp 0)\n",
                (unsigned long long)dAliased, (unsigned long long)dRo, (unsigned long long)dUnal, (unsigned long long)dCopies);
        return 1;
    }
    printf("PASS [4/7]: mach_vm_remap aliasing (2), PROT_READ fallback (1), unaligned fallback (1), 0 commit copies, dealloc lifetime OK\n");
    return 0;
}

static int test5_RingBufferConcurrent(id<MTLDevice> dev) {
    // 8 slices x 1 page each: CPU writes slice N+1 while GPU is processing slice N!
    size_t pageSz = (size_t)vm_page_size;
    const int N = 8;
    size_t totalSz = pageSz * N;
    void *ringMem = mmap(nullptr, totalSz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    void *outMem = mmap(nullptr, totalSz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    memset(ringMem, 0, totalSz);
    memset(outMem, 0, totalSz);

    id<MTLBuffer> ringBuf = [dev newBufferWithBytesNoCopy:ringMem length:totalSz options:MTLResourceStorageModeShared deallocator:nil];
    id<MTLBuffer> outBuf = [dev newBufferWithBytesNoCopy:outMem length:totalSz options:MTLResourceStorageModeShared deallocator:nil];

    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                     "kernel void scale_slice(device const uint *inS [[buffer(0)]], device uint *outS [[buffer(1)]], uint g [[thread_position_in_grid]]) {\n"
                     "  if (g < 256) { uint v = inS[g]; for (int k = 0; k < 200; k++) v = v ^ (uint)k; outS[g] = inS[g] * 3 + 7 + (v & 0); } }\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
    id<MTLComputePipelineState> pso = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"scale_slice"] error:&err];
    id<MTLCommandQueue> q = [dev newCommandQueue];

    NSMutableArray<id<MTLCommandBuffer>> *cbs = [NSMutableArray array];
    for (int s = 0; s < N; s++) {
        // CPU writes slice s while earlier CBs (slices 0..s-1) are still in flight on GPU!
        uint32_t *inSlice = (uint32_t *)((uint8_t *)ringBuf.contents + s * pageSz);
        for (int i = 0; i < 256; i++) inSlice[i] = (uint32_t)(s * 1000 + i);
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setBuffer:ringBuf offset:s * pageSz atIndex:0];
        [enc setBuffer:outBuf offset:s * pageSz atIndex:1];
        [enc dispatchThreads:MTLSizeMake(256, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [enc endEncoding];
        [cb commit];
        [cbs addObject:cb];
    }
    for (id<MTLCommandBuffer> cb in cbs) [cb waitUntilCompleted];

    for (int s = 0; s < N; s++) {
        uint32_t *outSlice = (uint32_t *)((uint8_t *)outMem + s * pageSz);
        for (int i = 0; i < 256; i++) {
            uint32_t exp = (uint32_t)(s * 1000 + i) * 3 + 7;
            if (outSlice[i] != exp) {
                fprintf(stderr, "FAIL [5/7]: ring slice %d idx %d got=%u exp=%u\n", s, i, outSlice[i], exp);
                munmap(ringMem, totalSz); munmap(outMem, totalSz);
                return 1;
            }
        }
    }
    ringBuf = nil; outBuf = nil;
    munmap(ringMem, totalSz);
    munmap(outMem, totalSz);
    printf("PASS [5/7]: ring buffer concurrent CPU write (slice N+1) + GPU compute (slice N) across %d slices OK\n", N);
    return 0;
}

static int test6_ContentsNeverBlocks(id<MTLDevice> dev) {
    size_t pageSz = (size_t)vm_page_size;
    void *mem = mmap(nullptr, pageSz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    ((uint32_t *)mem)[0] = 42;
    id<MTLBuffer> buf = [dev newBufferWithBytesNoCopy:mem length:pageSz options:MTLResourceStorageModeShared deallocator:nil];

    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    [blit fillBuffer:buf range:NSMakeRange(4, 4) value:0x7F];
    [blit endEncoding];

    // 6a. Calling [buf contents] BEFORE commit must not block!
    void *pBefore = buf.contents;
    if (pBefore != mem) { fprintf(stderr, "FAIL [6/7]: contents before commit != mem\n"); return 1; }

    // 6b. Calling [buf contents] INSIDE addCompletedHandler: must not deadlock!
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block uint32_t observedInHandler = 0;
    [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
        (void)c;
        void *pIn = buf.contents;
        observedInHandler = ((uint32_t *)pIn)[1];
        dispatch_semaphore_signal(sem);
    }];
    [cb commit];
    long timedOut = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
    if (timedOut != 0 || observedInHandler != 0x7F7F7F7Fu) {
        fprintf(stderr, "FAIL [6/7]: handler timedOut=%ld observed=0x%x\n", timedOut, observedInHandler);
        return 1;
    }
    buf = nil;
    munmap(mem, pageSz);
    printf("PASS [6/7]: [buf contents] before commit & inside completedHandler never blocks/deadlocks\n");
    return 0;
}

static int test7_Wallpaper33MBZeroCopy(id<MTLDevice> dev) {
    // 33 MB (33 * 1024 * 1024 = 34603008 bytes, multiple of 16KB & 4KB) submitted across 10 commits -> 0 per-commit copies!
    const size_t sz = 33 * 1024 * 1024;
    void *wpMem = mmap(nullptr, sz, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (wpMem == MAP_FAILED) { fprintf(stderr, "FAIL [7/7]: mmap 33MB failed\n"); return 1; }
    ((uint32_t *)wpMem)[0] = 0x11111111u;
    ((uint32_t *)wpMem)[sz / 4 - 1] = 0x99999999u;

    NSDictionary *s0 = getStats(dev);
    uint64_t aliased0 = [s0[@"aliased"] unsignedLongLongValue];
    uint64_t copies0 = [s0[@"commitSyncCopies"] unsignedLongLongValue];
    uint64_t bytes0 = [s0[@"commitSyncBytes"] unsignedLongLongValue];

    id<MTLBuffer> wpBuf = [dev newBufferWithBytesNoCopy:wpMem length:sz options:MTLResourceStorageModeShared deallocator:nil];
    if (!wpBuf || wpBuf.contents != wpMem) { fprintf(stderr, "FAIL [7/7]: 33MB NoCopy alias failed\n"); return 1; }

    id<MTLBuffer> readback = [dev newBufferWithLength:8 options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [dev newCommandQueue];
    for (int iter = 0; iter < 10; iter++) {
        // Mutate first & last uint32 directly via caller pointer, then GPU reads them with 0 commit copies!
        ((uint32_t *)wpMem)[0] = (uint32_t)(0x2000 + iter);
        ((uint32_t *)wpMem)[sz / 4 - 1] = (uint32_t)(0x8000 + iter);
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromBuffer:wpBuf sourceOffset:0 toBuffer:readback destinationOffset:0 size:4];
        [blit copyFromBuffer:wpBuf sourceOffset:sz - 4 toBuffer:readback destinationOffset:4 size:4];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        uint32_t *rb = (uint32_t *)readback.contents;
        if (rb[0] != (uint32_t)(0x2000 + iter) || rb[1] != (uint32_t)(0x8000 + iter)) {
            fprintf(stderr, "FAIL [7/7]: iter %d got (%u,%u)\n", iter, rb[0], rb[1]);
            return 1;
        }
    }

    NSDictionary *s1 = getStats(dev);
    uint64_t dAliased = [s1[@"aliased"] unsignedLongLongValue] - aliased0;
    uint64_t dCopies = [s1[@"commitSyncCopies"] unsignedLongLongValue] - copies0;
    uint64_t dBytes = [s1[@"commitSyncBytes"] unsignedLongLongValue] - bytes0;

    wpBuf = nil;
    munmap(wpMem, sz);

    if (dAliased != 1 || dCopies != 0 || dBytes != 0) {
        fprintf(stderr, "FAIL [7/7]: 33MB wallpaper stats dAliased=%llu dCopies=%llu dBytes=%llu\n",
                (unsigned long long)dAliased, (unsigned long long)dCopies, (unsigned long long)dBytes);
        return 1;
    }
    printf("PASS [7/7]: 33 MB wallpaper buffer aliased (1) across 10 commits with commitSyncCopies=0, commitSyncBytes=0\n");
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bundlePath = (argc > 1) ? argv[1] : getenv("XNU_CPU_METAL_BUNDLE");
        if (!bundlePath) { fprintf(stderr, "Usage: %s <XnuCpuMetal.bundle>\n", argv[0]); return 2; }
        id<MTLDevice> dev = loadBundleDevice(bundlePath);
        if (!dev) return 1;
        printf("Device: %s (vm_page_size=%zu)\n", dev.name.UTF8String, (size_t)vm_page_size);
        int rc = 0;
        rc |= test1_Alignment(dev);
        rc |= test2_YCbCrIOSurface(dev);
        rc |= test3_CIGaussianBlur(dev);
        rc |= test4_AliasAndFallbackAndLifetime(dev);
        rc |= test5_RingBufferConcurrent(dev);
        rc |= test6_ContentsNeverBlocks(dev);
        rc |= test7_Wallpaper33MBZeroCopy(dev);
        if (rc == 0) printf("ALL ROUND 20 TESTS PASSED!\n");
        return rc;
    }
}
