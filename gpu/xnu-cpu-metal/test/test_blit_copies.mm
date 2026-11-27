// SPDX-License-Identifier: GPL-2.0-or-later
// The blit encoder's copies the CPU device did not make, each judged by what the destination holds afterwards:
// 1. copyFromTexture:toTexture: over five pairs of textures: which level and slice of the source each level and slice of
//    the destination holds (as many levels and slices as both have, the levels paired by size, a cube's faces as slices).
// 2. copyFromTexture:sourceSlice:sourceLevel:toTexture:destinationSlice:destinationLevel:sliceCount:levelCount:.
// 3. The copies between a buffer and a texture with options:MTLBlitOptionNone (the forms ANGLE and WebGPU use).
// 4. options:MTLBlitOptionStencilFromDepthStencil and DepthFromDepthStencil: the stencil of a Depth32Float_Stencil8
//    texture read into a buffer and written from one, the depth read beside it.
//
//   clang++ -O2 -fobjc-arc test/test_blit_copies.mm -framework Foundation -framework Metal -o build/test_blit_copies
//   build/test_blit_copies dist/XnuCpuMetal.bundle        ("default" instead of the bundle: the Mac's own device)

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstring>

@interface NSObject (XnuCpuMetalPluginBlitCopies)
- (id)initWithAcceleratorPort:(unsigned)port;
@end

static id<MTLDevice> loadBundleDevice(const char *bundlePath) {
    if (strcmp(bundlePath, "default") == 0) return MTLCreateSystemDefaultDevice();
    NSBundle *b = [NSBundle bundleWithPath:[NSString stringWithUTF8String:bundlePath]];
    if (!b || ![b load]) { fprintf(stderr, "FAIL: cannot load bundle %s\n", bundlePath); return nil; }
    return [[[b principalClass] alloc] initWithAcceleratorPort:0];
}

struct Shape { MTLTextureType type; NSUInteger side, levels, layers; };   // layers: array slices, or 1 for a cube (6 slices)
static NSUInteger slicesOf(const Shape &s) { return s.type == MTLTextureTypeCube ? 6 : s.layers; }
static id<MTLTexture> texture(id<MTLDevice> dev, const Shape &s, MTLPixelFormat format) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = s.type; td.pixelFormat = format; td.width = s.side; td.height = s.side;
    td.mipmapLevelCount = s.levels; td.arrayLength = s.layers;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    return [dev newTextureWithDescriptor:td];
}
// Every texel of level l of slice s holds (tag, s, l, 255): tag 0xA0 marks a source, 0 an untouched destination.
static void fill(id<MTLTexture> t, const Shape &sh, uint8_t tag) {
    uint8_t px[8 * 8 * 4];
    for (NSUInteger s = 0; s < slicesOf(sh); s++) for (NSUInteger l = 0; l < sh.levels; l++) {
        NSUInteger w = sh.side >> l;
        for (NSUInteger i = 0; i < w * w; i++) { px[i * 4] = tag; px[i * 4 + 1] = tag ? (uint8_t)s : 0; px[i * 4 + 2] = tag ? (uint8_t)l : 0; px[i * 4 + 3] = tag ? 255 : 0; }
        [t replaceRegion:MTLRegionMake2D(0, 0, w, w) mipmapLevel:l slice:s withBytes:px bytesPerRow:w * 4 bytesPerImage:0];
    }
}
// What level l of slice s of t holds: -1 untouched, else source slice * 16 + source level; -2 anything else.
static int holds(id<MTLTexture> t, const Shape &sh, NSUInteger s, NSUInteger l) {
    uint8_t px[8 * 8 * 4]; memset(px, 0x77, sizeof px);
    NSUInteger w = sh.side >> l;
    [t getBytes:px bytesPerRow:w * 4 bytesPerImage:0 fromRegion:MTLRegionMake2D(0, 0, w, w) mipmapLevel:l slice:s];
    for (NSUInteger i = 1; i < w * w; i++) if (memcmp(px, px + i * 4, 4)) return -2;
    if (!px[0] && !px[1] && !px[2] && !px[3]) return -1;
    return px[0] == 0xA0 && px[3] == 255 ? px[1] * 16 + px[2] : -2;
}
// One blit encoder's work, committed and waited for; NO when a call raised (a selector the encoder does not have).
static BOOL blit(id<MTLCommandQueue> q, void (^work)(id<MTLBlitCommandEncoder>)) {
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLBlitCommandEncoder> enc = [cb blitCommandEncoder];
    BOOL raised = NO;
    @try { work(enc); } @catch (NSException *e) { fprintf(stderr, "    raised %s: %s\n", e.name.UTF8String, e.reason.UTF8String); raised = YES; }
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return !raised && cb.status == MTLCommandBufferStatusCompleted;
}

// [blit copyFromTexture:src toTexture:dst]: the destination's (slice, level) must hold the source's (slice, level + shift)
// for `levels` levels from `first` of the first `slices` slices, and be untouched elsewhere.
static BOOL wholeCopy(id<MTLDevice> dev, id<MTLCommandQueue> q, const char *what, Shape ssh, Shape dsh, NSUInteger first, int shift, NSUInteger levels, NSUInteger slices) {
    id<MTLTexture> src = texture(dev, ssh, MTLPixelFormatRGBA8Unorm), dst = texture(dev, dsh, MTLPixelFormatRGBA8Unorm);
    fill(src, ssh, 0xA0); fill(dst, dsh, 0);
    BOOL ok = blit(q, ^(id<MTLBlitCommandEncoder> enc) { [enc copyFromTexture:src toTexture:dst]; });
    for (NSUInteger s = 0; s < slicesOf(dsh); s++) for (NSUInteger l = 0; l < dsh.levels; l++) {
        int want = s < slices && l >= first && l < first + levels ? (int)(s * 16 + l) + shift : -1, got = holds(dst, dsh, s, l);
        if (got != want) {
            fprintf(stderr, "FAIL [1/4]: %s: the destination's slice %lu level %lu holds %d, Metal's holds %d (-1 untouched, else source slice * 16 + level)\n",
                    what, (unsigned long)s, (unsigned long)l, got, want);
            return NO;
        }
    }
    return ok;
}

static int test1_WholeTextureCopy(id<MTLDevice> dev, id<MTLCommandQueue> q) {
    BOOL ok = wholeCopy(dev, q, "2D 8x8, 3 levels -> the same", {MTLTextureType2D, 8, 3, 1}, {MTLTextureType2D, 8, 3, 1}, 0, 0, 3, 1);
    ok = wholeCopy(dev, q, "2D array of 3, 2 levels -> array of 2", {MTLTextureType2DArray, 8, 2, 3}, {MTLTextureType2DArray, 8, 2, 2}, 0, 0, 2, 2) && ok;
    ok = wholeCopy(dev, q, "2D 8x8, 4 levels -> 4x4, 2 levels", {MTLTextureType2D, 8, 4, 1}, {MTLTextureType2D, 4, 2, 1}, 0, 1, 2, 1) && ok;
    ok = wholeCopy(dev, q, "2D 4x4, 2 levels -> 8x8, 4 levels", {MTLTextureType2D, 4, 2, 1}, {MTLTextureType2D, 8, 4, 1}, 1, -1, 2, 1) && ok;
    ok = wholeCopy(dev, q, "cube 4x4, 2 levels -> the same", {MTLTextureTypeCube, 4, 2, 1}, {MTLTextureTypeCube, 4, 2, 1}, 0, 0, 2, 6) && ok;
    if (!ok) return 1;
    printf("PASS [1/4]: copyFromTexture:toTexture: copies the levels and slices two textures share\n");
    return 0;
}

static int test2_SlicesAndLevels(id<MTLDevice> dev, id<MTLCommandQueue> q) {
    Shape ssh = {MTLTextureType2DArray, 8, 3, 3}, dsh = {MTLTextureType2DArray, 8, 3, 2};
    id<MTLTexture> src = texture(dev, ssh, MTLPixelFormatRGBA8Unorm), dst = texture(dev, dsh, MTLPixelFormatRGBA8Unorm);
    fill(src, ssh, 0xA0); fill(dst, dsh, 0);
    blit(q, ^(id<MTLBlitCommandEncoder> enc) {
        [enc copyFromTexture:src sourceSlice:1 sourceLevel:1 toTexture:dst destinationSlice:0 destinationLevel:1 sliceCount:2 levelCount:2];
    });
    for (NSUInteger s = 0; s < 2; s++) for (NSUInteger l = 0; l < 3; l++) {
        int want = l >= 1 ? (int)((s + 1) * 16 + l) : -1, got = holds(dst, dsh, s, l);
        if (got != want) {
            fprintf(stderr, "FAIL [2/4]: the destination's slice %lu level %lu holds %d, Metal's holds %d\n", (unsigned long)s, (unsigned long)l, got, want);
            return 1;
        }
    }
    printf("PASS [2/4]: the form with sliceCount: and levelCount: copies those slices and levels\n");
    return 0;
}

static int test3_OptionsNone(id<MTLDevice> dev, id<MTLCommandQueue> q) {
    Shape sh = {MTLTextureType2DArray, 8, 1, 3};
    id<MTLTexture> src = texture(dev, sh, MTLPixelFormatRGBA8Unorm), dst = texture(dev, sh, MTLPixelFormatRGBA8Unorm);
    fill(src, sh, 0xA0); fill(dst, sh, 0);
    id<MTLBuffer> buf = [dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    BOOL ok = blit(q, ^(id<MTLBlitCommandEncoder> enc) {
        [enc copyFromTexture:src sourceSlice:2 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 8, 1)
                    toBuffer:buf destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256 options:MTLBlitOptionNone];
        [enc copyFromBuffer:buf sourceOffset:0 sourceBytesPerRow:32 sourceBytesPerImage:256 sourceSize:MTLSizeMake(8, 8, 1)
                  toTexture:dst destinationSlice:1 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0) options:MTLBlitOptionNone];
    });
    if (!ok || holds(dst, sh, 1, 0) != 2 * 16 || holds(dst, sh, 0, 0) != -1) {
        fprintf(stderr, "FAIL [3/4]: after texture to buffer to texture with options:None the destination's slice 1 holds %d (32), slice 0 %d (-1)\n",
                holds(dst, sh, 1, 0), holds(dst, sh, 0, 0));
        return 1;
    }
    printf("PASS [3/4]: texture to buffer to texture with options:MTLBlitOptionNone\n");
    return 0;
}

static int test4_DepthStencilOptions(id<MTLDevice> dev, id<MTLCommandQueue> q) {
    id<MTLTexture> ds = texture(dev, {MTLTextureType2D, 4, 1, 1}, MTLPixelFormatDepth32Float_Stencil8);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = ds; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.clearDepth = 0.25;
    rp.depthAttachment.storeAction = MTLStoreActionStore;
    rp.stencilAttachment.texture = ds; rp.stencilAttachment.loadAction = MTLLoadActionClear; rp.stencilAttachment.clearStencil = 7;
    rp.stencilAttachment.storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> cb = [q commandBuffer];
    [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    id<MTLBuffer> sb = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared], db = [dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
    id<MTLBuffer> nine = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    uint8_t *sp = (uint8_t *)sb.contents; float *dp = (float *)db.contents;
    memset(sp, 0xEE, 64); memset(dp, 0xEE, 64); memset(nine.contents, 9, 16);
    const MTLOrigin o = MTLOriginMake(0, 0, 0); const MTLSize sz = MTLSizeMake(4, 4, 1);
    void (^readBoth)(id<MTLBlitCommandEncoder>) = ^(id<MTLBlitCommandEncoder> enc) {
        [enc copyFromTexture:ds sourceSlice:0 sourceLevel:0 sourceOrigin:o sourceSize:sz toBuffer:sb destinationOffset:0
              destinationBytesPerRow:4 destinationBytesPerImage:16 options:MTLBlitOptionStencilFromDepthStencil];
        [enc copyFromTexture:ds sourceSlice:0 sourceLevel:0 sourceOrigin:o sourceSize:sz toBuffer:db destinationOffset:0
              destinationBytesPerRow:16 destinationBytesPerImage:64 options:MTLBlitOptionDepthFromDepthStencil];
    };
    BOOL ok = blit(q, readBoth);
    if (!ok || sp[0] != 7 || sp[15] != 7 || sp[16] != 0xEE || dp[0] != 0.25f || dp[15] != 0.25f) {
        fprintf(stderr, "FAIL [4/4]: the stencil plane read %02x %02x (7 7), the byte after it %02x (ee); the depth plane read %.2f (0.25)\n", sp[0], sp[15], sp[16], dp[0]);
        return 1;
    }
    ok = blit(q, ^(id<MTLBlitCommandEncoder> enc) {
        [enc copyFromBuffer:nine sourceOffset:0 sourceBytesPerRow:4 sourceBytesPerImage:16 sourceSize:sz
                  toTexture:ds destinationSlice:0 destinationLevel:0 destinationOrigin:o options:MTLBlitOptionStencilFromDepthStencil];
        readBoth(enc);
    });
    if (!ok || sp[0] != 9 || sp[15] != 9 || dp[0] != 0.25f) {
        fprintf(stderr, "FAIL [4/4]: after 9s were copied into the stencil it reads %02x (9), the depth %.2f (0.25)\n", sp[0], dp[0]);
        return 1;
    }
    printf("PASS [4/4]: the stencil and the depth of a depth/stencil texture read and written by their MTLBlitOption\n");
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        const char *bundlePath = (argc > 1) ? argv[1] : getenv("XNU_CPU_METAL_BUNDLE");
        if (!bundlePath) { fprintf(stderr, "Usage: %s <XnuCpuMetal.bundle | default>\n", argv[0]); return 2; }
        id<MTLDevice> dev = loadBundleDevice(bundlePath);
        if (!dev) { fprintf(stderr, "FAIL: no device\n"); return 1; }
        printf("Device: %s\n", dev.name.UTF8String);
        id<MTLCommandQueue> q = [dev newCommandQueue];
        int rc = 0;
        rc |= test1_WholeTextureCopy(dev, q);
        rc |= test2_SlicesAndLevels(dev, q);
        rc |= test3_OptionsNone(dev, q);
        rc |= test4_DepthStencilOptions(dev, q);
        if (rc == 0) printf("ALL BLIT COPY TESTS PASSED\n");
        return rc;
    }
}
