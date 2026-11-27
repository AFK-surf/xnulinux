// SPDX-License-Identifier: GPL-2.0-or-later
// A command buffer's way from commit to its handlers, as Metal's own device does it. Every case passes on Apple's device
// (give "default" for the bundle), which is what each expectation here was measured on:
// 1. presentDrawable: and its timed forms present the drawable, once, after the commit and not before; on this device
//    the frame is in the drawable's IOSurface by then. Then the same through a CAMetalLayer's own drawable.
// 2. enqueue: command buffers run in the order they were enqueued, whatever the order of their commits.
// 3. The scheduled and completed handlers of one queue's command buffers run one at a time, in commit order, also when
//    the program waits for some of the command buffers; waitUntilCompleted returns after the handlers; waitUntilScheduled
//    does not wait for the completed handler of the command buffer before it.
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
#include <mutex>
#include <pthread.h>
#include <vector>
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
        if (!tex) { fprintf(stderr, "FAIL [1/3]: no IOSurface texture\n"); if (surf) CFRelease(surf); return 1; }
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
        if (early.length) { fprintf(stderr, "FAIL [1/3]: %s: the drawable got \"%s\" before the commit\n", what, early.UTF8String); return 1; }
        if (![got isEqualToString:expect]) {
            fprintf(stderr, "FAIL [1/3]: %s: the drawable got \"%s\", expected \"%s\"\n", what, got.UTF8String, expect.UTF8String);
            return 1;
        }
        // A GPU's drawable is shown once its rendering is done, whenever present was called. Nothing waits for this
        // device: what the surface holds at present is what is shown.
        if (form == 0 && !gSystemDevice && px != 0xffff0000u) {
            fprintf(stderr, "FAIL [1/3]: at present the drawable's surface held 0x%08x, not the frame (0xffff0000)\n", px);
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
                fprintf(stderr, "FAIL [1/3]: a CAMetalLayer drawable given to presentDrawable: was presented %d time(s)\n", gLayerPresents.load());
                return 1;
            }
            layerResult = "presented once";
        }
    }
    printf("PASS [1/3]: presentDrawable: and its timed forms present the drawable after the commit; CAMetalLayer drawable: %s\n", layerResult);
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
        fprintf(stderr, "FAIL [2/3]: B, enqueued after A, ran at its commit while A was not committed yet (the buffer both fill held 0x%08x then)\n", early);
        return 1;
    }
    if (![order isEqualToString:@"AB"] || last != 0xBBBBBBBBu) {
        fprintf(stderr, "FAIL [2/3]: enqueued A, B and committed B, A: handlers ran \"%s\" (expected \"AB\"), the buffer both fill ends as 0x%08x (expected B's 0xbbbbbbbb)\n",
                order.UTF8String, last);
        return 1;
    }
    if (stNew != MTLCommandBufferStatusNotEnqueued || stA != MTLCommandBufferStatusEnqueued || stB != MTLCommandBufferStatusEnqueued ||
        stHeld != MTLCommandBufferStatusCommitted || a.status != MTLCommandBufferStatusCompleted || b.status != MTLCommandBufferStatusCompleted) {
        fprintf(stderr, "FAIL [2/3]: statuses: new %lu (expected 0), enqueued %lu and %lu (1), committed behind A %lu (2), at the end %lu and %lu (4)\n",
                (unsigned long)stNew, (unsigned long)stA, (unsigned long)stB, (unsigned long)stHeld, (unsigned long)a.status, (unsigned long)b.status);
        return 1;
    }
    printf("PASS [2/3]: command buffers enqueued A, B and committed B, A ran A, B (statuses Enqueued, then Committed while held back)\n");
    return 0;
}

/* ---- 3. completed handlers of one queue ---- */

static int test3_HandlersOneAtATimeInOrder(id<MTLDevice> dev) {
    static std::atomic<int> active{0}, most{0}, ran{0};
    static std::mutex lock;
    static std::vector<int> order;
    auto handler = ^(int index, dispatch_semaphore_t second, bool first) {
        int now = active.fetch_add(1) + 1;
        for (int seen = most.load(); now > seen && !most.compare_exchange_weak(seen, now);) {}
        { std::lock_guard<std::mutex> g(lock); order.push_back(index); }
        // The first handler stays until another one starts, for at most 300 ms: if two can run at once, two do.
        if (first) dispatch_semaphore_wait(second, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC));
        else dispatch_semaphore_signal(second);
        usleep(500);
        active.fetch_sub(1);
        ran.fetch_add(1);
    };

    // 3a. one thread commits 32 command buffers in a row and waits for none
    const int N = 32;
    {
        id<MTLCommandQueue> q = [dev newCommandQueue];
        dispatch_semaphore_t second = dispatch_semaphore_create(0);
        for (int i = 0; i < N; i++) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            [cb addScheduledHandler:^(id<MTLCommandBuffer> c) {   // these count too: no handler of either kind beside another
                (void)c;
                int now = active.fetch_add(1) + 1;
                for (int seen = most.load(); now > seen && !most.compare_exchange_weak(seen, now);) {}
                usleep(200);
                active.fetch_sub(1);
            }];
            [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c; handler(i, second, i == 0); }];
            [cb commit];
        }
        if (!waitFor(20000, ^bool { return ran.load() == N; })) {
            fprintf(stderr, "FAIL [3/3]: %d of %d completed handlers ran\n", ran.load(), N);
            return 1;
        }
        std::lock_guard<std::mutex> g(lock);
        int outOfOrder = 0;
        for (int i = 0; i < N; i++) if (order[i] != i) outOfOrder++;
        if (most.load() != 1 || outOfOrder) {
            fprintf(stderr, "FAIL [3/3]: %d command buffers committed in a row on one queue: %d handlers ran at the same time (expected 1), %d completed handlers out of commit order\n",
                    N, most.load(), outOfOrder);
            return 1;
        }
    }

    // 3b. four threads commit to one queue; the order of the commits is the order the test's own lock gave them.
    // Then the same with a wait for every other command buffer: a wait must not run its handlers ahead of their turn.
    const int T = 4, M = 16;
    for (int waits = 0; waits < 2; waits++) {
        active = 0; most = 0; ran = 0;
        { std::lock_guard<std::mutex> g(lock); order.clear(); }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        dispatch_semaphore_t second = dispatch_semaphore_create(0);
        static std::mutex commitLock;
        static int commits;
        commits = 0;
        dispatch_group_t grp = dispatch_group_create();
        dispatch_queue_t conc = dispatch_queue_create("test.cb.commit", DISPATCH_QUEUE_CONCURRENT);
        for (int t = 0; t < T; t++) {
            dispatch_group_async(grp, conc, ^{
                for (int i = 0; i < M; i++) {
                    @autoreleasepool {
                        id<MTLCommandBuffer> cb = [q commandBuffer];
                        int seq;
                        {
                            std::lock_guard<std::mutex> g(commitLock);
                            seq = commits++;
                            [cb addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c; handler(seq, second, false); }];
                            [cb commit];
                        }
                        if (waits && seq % 2) [cb waitUntilCompleted];
                    }
                }
            });
        }
        dispatch_group_wait(grp, DISPATCH_TIME_FOREVER);
        if (!waitFor(20000, ^bool { return ran.load() == T * M; })) {
            fprintf(stderr, "FAIL [3/3]: %d of %d completed handlers ran (commits from %d threads)\n", ran.load(), T * M, T);
            return 1;
        }
        std::lock_guard<std::mutex> g(lock);
        int outOfOrder = 0;
        for (int i = 0; i < T * M; i++) if (order[i] != i) outOfOrder++;
        if (most.load() != 1 || outOfOrder) {
            fprintf(stderr, "FAIL [3/3]: %d command buffers committed to one queue from %d threads%s: %d completed handlers ran at the same time (expected 1), %d out of commit order\n",
                    T * M, T, waits ? ", every other one waited for" : "", most.load(), outOfOrder);
            return 1;
        }
    }

    // 3c. waitUntilCompleted returns once the completed handler ran, which is on another thread than the waiting one
    {
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        static std::atomic<int> finished{0}, onWaiter{0};
        pthread_t me = pthread_self();
        [cb addCompletedHandler:^(id<MTLCommandBuffer> c) {
            (void)c;
            if (pthread_equal(pthread_self(), me)) onWaiter = 1;
            usleep(50000);
            finished = 1;
        }];
        [cb commit];
        [cb waitUntilCompleted];
        if (!finished.load() || onWaiter.load()) {
            fprintf(stderr, "FAIL [3/3]: waitUntilCompleted returned %s the completed handler finished; the handler ran on %s thread\n",
                    finished.load() ? "after" : "before", onWaiter.load() ? "the waiting" : "another");
            return 1;
        }
    }

    // 3d. On Metal a completed handler's wait for its own command buffer, or for a later one of its queue, never
    // returns. This device has always let such a wait return, and must go on doing so (not run on Apple's device).
    if (!gSystemDevice) {
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLCommandBuffer> a = [q commandBuffer], b = [q commandBuffer];
        static std::atomic<int> returned{0}, later{0};
        [b addCompletedHandler:^(id<MTLCommandBuffer> c) { (void)c; later = 1; }];
        [a addCompletedHandler:^(id<MTLCommandBuffer> c) {
            [c waitUntilCompleted];
            returned = 1;
            [b waitUntilCompleted];
            returned = 2;
        }];
        [a commit];
        [b commit];
        if (!waitFor(5000, ^bool { return returned.load() == 2 && later.load() == 1; })) {
            fprintf(stderr, "FAIL [3/3]: a completed handler's wait for %s did not return in 5 s\n",
                    returned.load() == 0 ? "its own command buffer" : "the next command buffer of its queue");
            return 1;
        }
    }

    // 3e. a handler that takes its time holds back the handlers behind it, not what the next command buffer drew:
    // that is in its IOSurface as soon as the command buffer is done
    {
        const int W = 16, H = 16;
        NSDictionary *props = @{
            (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H),
            (id)kIOSurfaceBytesPerElement: @4, (id)kIOSurfacePixelFormat: @(0x42475241u),
        };
        IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                      width:W height:H mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> tex = surf ? [dev newTextureWithDescriptor:td iosurface:surf plane:0] : nil;
        if (!tex) { fprintf(stderr, "FAIL [3/3]: no IOSurface texture\n"); if (surf) CFRelease(surf); return 1; }
        id<MTLCommandQueue> q = [dev newCommandQueue];
        dispatch_semaphore_t started = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
        id<MTLCommandBuffer> slow = [q commandBuffer];
        [slow addCompletedHandler:^(id<MTLCommandBuffer> c) {
            (void)c;
            dispatch_semaphore_signal(started);
            dispatch_semaphore_wait(release, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        }];
        [slow commit];
        id<MTLCommandBuffer> draws = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = tex;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 1, 0, 1);
        [[draws renderCommandEncoderWithDescriptor:rp] endEncoding];
        [draws commit];
        bool handlerRunning = dispatch_semaphore_wait(started, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
        bool drawn = waitFor(2000, ^bool { return firstPixel(surf) == 0xff00ff00u; });
        dispatch_semaphore_signal(release);
        [draws waitUntilCompleted];
        uint32_t px = firstPixel(surf);
        CFRelease(surf);
        if (!handlerRunning || !drawn) {
            fprintf(stderr, "FAIL [3/3]: while the completed handler of the command buffer before it ran (%s), what a command buffer drew was not in its IOSurface within 2 s (0x%08x once the handler returned)\n",
                    handlerRunning ? "it did" : "it never started", px);
            return 1;
        }
    }

    // 3f. waitUntilScheduled does not wait for the completed handler of the command buffer before it: that handler may
    // need the waiting thread (a dispatch_sync to the main queue here, and this is the main thread). B is committed
    // while A still runs (A fills 64 MB), as a frame is committed while the one before it renders.
    {
        id<MTLCommandQueue> q = [dev newCommandQueue];
        const NSUInteger big = 64u << 20;
        id<MTLBuffer> filled = [dev newBufferWithLength:big options:MTLResourceStorageModePrivate];
        id<MTLCommandBuffer> a = [q commandBuffer], b = [q commandBuffer];
        static std::atomic<int> aEnded{0}, bScheduled{0}, back{0};
        if (filled) {
            id<MTLBlitCommandEncoder> blit = [a blitCommandEncoder];
            [blit fillBuffer:filled range:NSMakeRange(0, big) value:0x5A];
            [blit endEncoding];
        }
        [a addCompletedHandler:^(id<MTLCommandBuffer> c) {
            (void)c;
            dispatch_sync(dispatch_get_main_queue(), ^{});
            aEnded = 1;
        }];
        [b addScheduledHandler:^(id<MTLCommandBuffer> c) { (void)c; bScheduled = 1; }];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{   // the main thread could not say so itself
            if (waitFor(5000, ^bool { return back.load() != 0; })) return;
            fprintf(stderr, "FAIL [3/3]: waitUntilScheduled did not return in 5 s while the completed handler of the command buffer before it waited for the calling thread\n");
            _exit(1);
        });
        [a commit];
        [b commit];
        [b waitUntilScheduled];
        int scheduled = bScheduled.load();
        back = 1;
        for (int i = 0; i < 250 && !aEnded.load(); i++) CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.02, true);   // now that handler gets the main queue
        [b waitUntilCompleted];
        if (!scheduled || !aEnded.load()) {
            fprintf(stderr, "FAIL [3/3]: waitUntilScheduled returned %s the command buffer's scheduled handler ran; the completed handler of the one before it %s\n",
                    scheduled ? "after" : "before", aEnded.load() ? "ended" : "never got the main queue");
            return 1;
        }
    }
    printf("PASS [3/3]: completed handlers of one queue ran one at a time and in commit order (%d from one thread, %d from %d threads, %d more with a wait for every other one); a slow one did not hold back the next command buffer's IOSurface, nor one that needs the waiting thread waitUntilScheduled\n", N, T * M, T, T * M);
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
        rc |= test3_HandlersOneAtATimeInOrder(dev);
        if (rc == 0) printf("ALL COMMAND BUFFER TESTS PASSED!\n");
        return rc;
    }
}
