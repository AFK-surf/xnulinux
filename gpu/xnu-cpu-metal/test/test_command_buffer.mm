// SPDX-License-Identifier: GPL-2.0-or-later
// A command buffer's way from commit to its handlers, as Metal's own device does it. Every case passes on Apple's device
// (give "default" for the bundle), which is what each expectation here was measured on:
// 1. presentDrawable: and its timed forms present the drawable, once, after the commit and not before; on this device
//    the frame is in the drawable's IOSurface by then. Then the same through a CAMetalLayer's own drawable.
// 2. enqueue: command buffers run in the order they were enqueued, whatever the order of their commits.
//
//   clang++ -arch arm64 -O2 -fobjc-arc -isysroot "$(xcrun --show-sdk-path)" test/test_command_buffer.mm \
//       -framework Foundation -framework Metal -framework IOSurface -framework QuartzCore -o build/test_command_buffer
//   build/test_command_buffer dist/XnuCpuMetal.bundle

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <IOSurface/IOSurface.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

@interface NSObject (XnuCpuMetalPluginCB)
- (id)initWithAcceleratorPort:(unsigned)port;
@end

static bool gSystemDevice;

static id<MTLDevice> loadBundleDevice(const char *bundlePath) {
    if (strcmp(bundlePath, "default") == 0) {
        gSystemDevice = true;
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

// Waits until `done` says so, at most `ms` milliseconds: whether it did.
static bool waitFor(int ms, bool (^done)(void)) {
    for (int i = 0; i < ms && !done(); i++) usleep(1000);
    return done();
}

/* ---- 1. presentDrawable: ---- */

static uint32_t firstPixel(IOSurfaceRef surf) {
    uint32_t px = 0;
    IOSurfaceLock(surf, kIOSurfaceLockReadOnly, nullptr);
    memcpy(&px, IOSurfaceGetBaseAddress(surf), 4);
    IOSurfaceUnlock(surf, kIOSurfaceLockReadOnly, nullptr);
    return px;
}

// A drawable that records what it is sent, and what its surface held when it was told to present.
@interface TestDrawable : NSObject <MTLDrawable> {
@public
    NSMutableArray<NSString *> *_calls;
    IOSurfaceRef _surface;
    uint32_t _pixelAtPresent;
}
@end
@implementation TestDrawable
- (instancetype)init { if ((self = [super init])) _calls = [NSMutableArray array]; return self; }
- (void)note:(NSString *)s { @synchronized(self) { [_calls addObject:s]; } }
- (void)present {
    if (_surface) _pixelAtPresent = firstPixel(_surface);
    [self note:@"present"];
}
- (void)presentAtTime:(CFTimeInterval)t { [self note:[NSString stringWithFormat:@"presentAtTime:%g", t]]; }
- (void)presentAfterMinimumDuration:(CFTimeInterval)d { [self note:[NSString stringWithFormat:@"presentAfterMinimumDuration:%g", d]]; }
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)block { (void)block; }
- (void)addPresentScheduledHandler:(id)block { (void)block; }   // private; Metal's own presentDrawable: sends it to the drawable
- (CFTimeInterval)presentedTime { return 0; }
- (NSUInteger)drawableID { return 1; }
- (NSString *)calls { @synchronized(self) { return [_calls componentsJoinedByString:@", "]; } }
@end

static std::atomic<int> gLayerPresents{0};
static IMP gLayerPresent;
static void countLayerPresent(id self, SEL _cmd) { gLayerPresents++; ((void (*)(id, SEL))gLayerPresent)(self, _cmd); }

static int test1_PresentDrawable(id<MTLDevice> dev) {
    const int W = 16, H = 16;
    for (int form = 0; form < 3; form++) {
        const char *what = form == 0 ? "presentDrawable:" : form == 1 ? "presentDrawable:atTime:" : "presentDrawable:afterMinimumDuration:";
        NSString *expect = form == 0 ? @"present" : form == 1 ? @"presentAtTime:5" : @"presentAfterMinimumDuration:0.25";
        NSDictionary *props = @{
            (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H),
            (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @(0x42475241u),
        };
        IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> tex = surf ? [dev newTextureWithDescriptor:td iosurface:surf plane:0] : nil;
        if (!tex) { fprintf(stderr, "FAIL [1/2]: no IOSurface texture\n"); if (surf) CFRelease(surf); return 1; }
        TestDrawable *d = [TestDrawable new];
        d->_surface = surf;

        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = tex;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
        [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
        if (form == 0) [cb presentDrawable:d];
        else if (form == 1) [cb presentDrawable:d atTime:5.0];
        else [cb presentDrawable:d afterMinimumDuration:0.25];
        NSString *early = [d calls];
        [cb commit];
        [cb waitUntilCompleted];
        waitFor(2000, ^bool { return [d calls].length != 0; });
        NSString *got = [d calls];
        uint32_t px = d->_pixelAtPresent;
        d->_surface = nullptr;
        CFRelease(surf);
        if (early.length) { fprintf(stderr, "FAIL [1/2]: %s: the drawable got \"%s\" before the commit\n", what, early.UTF8String); return 1; }
        if (![got isEqualToString:expect]) {
            fprintf(stderr, "FAIL [1/2]: %s: the drawable got \"%s\", expected \"%s\"\n", what, got.UTF8String, expect.UTF8String);
            return 1;
        }
        // A GPU's drawable is shown once its rendering is done, whenever present was called. Nothing waits for this
        // device: what the surface holds at present is what is shown.
        if (form == 0 && !gSystemDevice && px != 0xffff0000u) {
            fprintf(stderr, "FAIL [1/2]: at present the drawable's surface held 0x%08x, not the frame (0xffff0000)\n", px);
            return 1;
        }
    }

    // The same through CoreAnimation: a layer nobody shows still hands out drawables.
    const char *layerResult = "skipped (the layer gave no drawable)";
    @autoreleasepool {
        CAMetalLayer *layer = [CAMetalLayer layer];
        layer.device = dev;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.drawableSize = CGSizeMake(64, 64);
        id<CAMetalDrawable> d = [layer nextDrawable];
        Method m = d ? class_getInstanceMethod(object_getClass(d), @selector(present)) : nullptr;
        if (d && d.texture && m) {
            gLayerPresent = method_setImplementation(m, (IMP)countLayerPresent);
            id<MTLCommandQueue> q = [dev newCommandQueue];
            id<MTLCommandBuffer> cb = [q commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = d.texture;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1);
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            [cb presentDrawable:d];
            [cb commit];
            [cb waitUntilCompleted];
            waitFor(2000, ^bool { return gLayerPresents.load() != 0; });
            usleep(20000);
            method_setImplementation(m, gLayerPresent);
            if (gLayerPresents.load() != 1) {
                fprintf(stderr, "FAIL [1/2]: a CAMetalLayer drawable given to presentDrawable: was presented %d time(s)\n", gLayerPresents.load());
                return 1;
            }
            layerResult = "presented once";
        }
    }
    printf("PASS [1/2]: presentDrawable: and its timed forms present the drawable after the commit; CAMetalLayer drawable: %s\n", layerResult);
    return 0;
}

/* ---- 2. enqueue ---- */

static int test2_EnqueueOrder(id<MTLDevice> dev) {
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLBuffer> buf = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    memset(buf.contents, 0, 16);
    NSMutableString *order = [NSMutableString string];
    id<MTLCommandBuffer> cbs[2];
    for (int i = 0; i < 2; i++) {
        cbs[i] = [q commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cbs[i] blitCommandEncoder];
        [blit fillBuffer:buf range:NSMakeRange(0, 4) value:(i == 0 ? 0xAA : 0xBB)];
        [blit endEncoding];
        [cbs[i] addCompletedHandler:^(id<MTLCommandBuffer> c) {
            (void)c;
            @synchronized(order) { [order appendString:(i == 0 ? @"A" : @"B")]; }
        }];
    }
    id<MTLCommandBuffer> a = cbs[0], b = cbs[1];
    MTLCommandBufferStatus stNew = a.status;
    [a enqueue];
    [b enqueue];
    MTLCommandBufferStatus stA = a.status, stB = b.status;
    // B is committed first. A has the place before it and is not committed yet: B must not run.
    [b commit];
    bool ranEarly = waitFor(300, ^bool { @synchronized(order) { return order.length != 0; } });
    uint32_t early = 0;
    memcpy(&early, buf.contents, 4);
    MTLCommandBufferStatus stHeld = b.status;
    [a commit];
    [a waitUntilCompleted];
    [b waitUntilCompleted];
    waitFor(2000, ^bool { @synchronized(order) { return order.length == 2; } });
    uint32_t last = 0;
    memcpy(&last, buf.contents, 4);
    if (ranEarly || early != 0) {
        fprintf(stderr, "FAIL [2/2]: B, enqueued after A, ran at its commit while A was not committed yet (the buffer both fill held 0x%08x then)\n", early);
        return 1;
    }
    if (![order isEqualToString:@"AB"] || last != 0xBBBBBBBBu) {
        fprintf(stderr, "FAIL [2/2]: enqueued A, B and committed B, A: handlers ran \"%s\" (expected \"AB\"), the buffer both fill ends as 0x%08x (expected B's 0xbbbbbbbb)\n",
                order.UTF8String, last);
        return 1;
    }
    if (stNew != MTLCommandBufferStatusNotEnqueued || stA != MTLCommandBufferStatusEnqueued || stB != MTLCommandBufferStatusEnqueued ||
        stHeld != MTLCommandBufferStatusCommitted || a.status != MTLCommandBufferStatusCompleted || b.status != MTLCommandBufferStatusCompleted) {
        fprintf(stderr, "FAIL [2/2]: statuses: new %lu (expected 0), enqueued %lu and %lu (1), committed behind A %lu (2), at the end %lu and %lu (4)\n",
                (unsigned long)stNew, (unsigned long)stA, (unsigned long)stB, (unsigned long)stHeld, (unsigned long)a.status, (unsigned long)b.status);
        return 1;
    }
    printf("PASS [2/2]: command buffers enqueued A, B and committed B, A ran A, B (statuses Enqueued, then Committed while held back)\n");
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
        int rc = 0;
        rc |= test1_PresentDrawable(dev);
        rc |= test2_EnqueueOrder(dev);
        if (rc == 0) printf("ALL COMMAND BUFFER TESTS PASSED!\n");
        return rc;
    }
}
