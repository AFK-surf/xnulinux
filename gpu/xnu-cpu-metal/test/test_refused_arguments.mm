// SPDX-License-Identifier: GPL-2.0-or-later
// Arguments Metal takes that the CPU device refused, each judged by what the texture holds afterwards:
// 1. replaceRegion: and getBytes: of one row with bytesPerRow 0.
// 2. A PVRTC level, which Metal takes at no bytesPerRow but 0, written and read back.
// 3. A render pass whose descriptor leaves its store actions MTLStoreActionUnknown: setColorStoreAction:atIndex:,
//    setDepthStoreAction: and setStencilStoreAction: on the encoder decide them.
// 4. MTLStoreActionCustomSampleDepthStore on a depth attachment, which stores as Store does.
//
//   clang++ -O2 -fobjc-arc test/test_refused_arguments.mm -framework Foundation -framework Metal -o build/test_refused_arguments
//   build/test_refused_arguments dist/XnuCpuMetal.bundle        ("default" instead of the bundle: the Mac's own device)

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cstdio>
#include <cstring>

@interface NSObject (XnuCpuMetalPluginRefusedArguments)
- (id)initWithAcceleratorPort:(unsigned)port;
@end

static id<MTLDevice> loadBundleDevice(const char *bundlePath) {
    if (strcmp(bundlePath, "default") == 0) return MTLCreateSystemDefaultDevice();
    NSBundle *b = [NSBundle bundleWithPath:[NSString stringWithUTF8String:bundlePath]];
    if (!b || ![b load]) { fprintf(stderr, "FAIL: cannot load bundle %s\n", bundlePath); return nil; }
    return [[[b principalClass] alloc] initWithAcceleratorPort:0];
}

static const MTLPixelFormat kPVRTC_RGBA_4BPP = (MTLPixelFormat)166;   // MTLPixelFormatPVRTC_RGBA_4BPP, deprecated in the SDK

static id<MTLTexture> texture(id<MTLDevice> dev, MTLPixelFormat format, NSUInteger side) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:side height:side mipmapped:NO];
    td.usage = format == kPVRTC_RGBA_4BPP ? MTLTextureUsageShaderRead : MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    return [dev newTextureWithDescriptor:td];
}

static int test1_OneRowBytesPerRowZero(id<MTLDevice> dev) {
    uint8_t in[16], out[64], zero[64] = {0};
    for (int i = 0; i < 16; i++) in[i] = (uint8_t)(i + 1);
    id<MTLTexture> t = texture(dev, MTLPixelFormatRGBA8Unorm, 4);
    [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:zero bytesPerRow:16];
    [t replaceRegion:MTLRegionMake2D(0, 2, 4, 1) mipmapLevel:0 withBytes:in bytesPerRow:0];
    memset(out, 0xEE, sizeof out);
    [t getBytes:out bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
    if (memcmp(out + 32, in, 16) || memcmp(out, zero, 32)) { fprintf(stderr, "FAIL [1/4]: replaceRegion: of one row with bytesPerRow 0 wrote nothing\n"); return 1; }
    memset(out, 0xEE, sizeof out);
    [t getBytes:out bytesPerRow:0 fromRegion:MTLRegionMake2D(0, 2, 4, 1) mipmapLevel:0];
    if (memcmp(out, in, 16)) { fprintf(stderr, "FAIL [1/4]: getBytes: of one row with bytesPerRow 0 read nothing\n"); return 1; }
    printf("PASS [1/4]: one row written and read with bytesPerRow 0\n");
    return 0;
}

static int test2_PVRTCLevel(id<MTLDevice> dev) {
    // 8 x 8 at 4 bits a pixel: 2 x 2 blocks of 8 bytes. Metal's validation: "bytesPerRow must be 0 for MTLPixelFormatPVRTC_RGBA_4BPP".
    uint8_t in[32], out[64];
    for (int i = 0; i < 32; i++) in[i] = (uint8_t)(i + 1);
    id<MTLTexture> t = texture(dev, kPVRTC_RGBA_4BPP, 8);
    if (!t) { fprintf(stderr, "FAIL [2/4]: no PVRTC texture\n"); return 1; }
    [t replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 slice:0 withBytes:in bytesPerRow:0 bytesPerImage:0];
    memset(out, 0xEE, sizeof out);
    [t getBytes:out bytesPerRow:0 bytesPerImage:0 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 slice:0];
    if (memcmp(out, in, 32)) { fprintf(stderr, "FAIL [2/4]: the PVRTC level does not read back as written\n"); return 1; }
    printf("PASS [2/4]: a PVRTC level written and read (bytesPerRow 0)\n");
    return 0;
}

// One pass, nothing drawn: every attachment cleared, stored as the descriptor or (where it says Unknown) the encoder says.
static BOOL clearPass(id<MTLCommandQueue> q, MTLRenderPassDescriptor *rp, MTLStoreAction late) {
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    if (!enc) return NO;
    if (rp.colorAttachments[0].texture && rp.colorAttachments[0].storeAction == MTLStoreActionUnknown) [enc setColorStoreAction:late atIndex:0];
    if (rp.depthAttachment.texture && rp.depthAttachment.storeAction == MTLStoreActionUnknown) [enc setDepthStoreAction:late];
    if (rp.stencilAttachment.texture && rp.stencilAttachment.storeAction == MTLStoreActionUnknown) [enc setStencilStoreAction:late];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return cb.status == MTLCommandBufferStatusCompleted;
}
static float depthOf(id<MTLTexture> t) {
    float px[16]; for (int i = 0; i < 16; i++) px[i] = -1;
    [t getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
    return px[15];
}
static void fillDepth(id<MTLTexture> t, float v) {
    float px[16]; for (int i = 0; i < 16; i++) px[i] = v;
    [t replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:px bytesPerRow:16];
}

static int test3_StoreActionsSetOnTheEncoder(id<MTLDevice> dev, id<MTLCommandQueue> q) {
    uint8_t px[64] = {0};
    id<MTLTexture> c = texture(dev, MTLPixelFormatRGBA8Unorm, 4), d = texture(dev, MTLPixelFormatDepth32Float, 4);
    id<MTLTexture> s = texture(dev, MTLPixelFormatStencil8, 4);
    [c replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:px bytesPerRow:16];
    [s replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:px bytesPerRow:4];
    fillDepth(d, 0.5f);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = c;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionUnknown;
    rp.depthAttachment.texture = d;
    rp.depthAttachment.loadAction = MTLLoadActionClear;
    rp.depthAttachment.clearDepth = 0.25;
    rp.depthAttachment.storeAction = MTLStoreActionUnknown;
    if (!clearPass(q, rp, MTLStoreActionStore)) { fprintf(stderr, "FAIL [3/4]: no pass with storeAction Unknown (colour, depth)\n"); return 1; }
    [c getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
    if (px[0] != 255 || px[63] != 255 || depthOf(d) != 0.25f) {
        fprintf(stderr, "FAIL [3/4]: after Unknown then Store: colour red %u (255), depth %.2f (0.25)\n", px[0], depthOf(d));
        return 1;
    }
    rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.stencilAttachment.texture = s;
    rp.stencilAttachment.loadAction = MTLLoadActionClear;
    rp.stencilAttachment.clearStencil = 7;
    rp.stencilAttachment.storeAction = MTLStoreActionUnknown;
    if (!clearPass(q, rp, MTLStoreActionStore)) { fprintf(stderr, "FAIL [3/4]: no pass with storeAction Unknown (stencil)\n"); return 1; }
    memset(px, 0, sizeof px);
    [s getBytes:px bytesPerRow:4 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
    if (px[0] != 7 || px[15] != 7) { fprintf(stderr, "FAIL [3/4]: after Unknown then Store: stencil %u (7)\n", px[0]); return 1; }
    printf("PASS [3/4]: store actions left Unknown and set to Store on the encoder: colour, depth and stencil kept\n");
    return 0;
}

static int test4_CustomSampleDepthStore(id<MTLDevice> dev, id<MTLCommandQueue> q) {
    id<MTLTexture> d = texture(dev, MTLPixelFormatDepth32Float, 4);
    fillDepth(d, 0.5f);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = d;
    rp.depthAttachment.loadAction = MTLLoadActionClear;
    rp.depthAttachment.clearDepth = 0.75;
    rp.depthAttachment.storeAction = MTLStoreActionCustomSampleDepthStore;
    if (!clearPass(q, rp, MTLStoreActionStore)) { fprintf(stderr, "FAIL [4/4]: no pass with storeAction CustomSampleDepthStore\n"); return 1; }
    if (depthOf(d) != 0.75f) { fprintf(stderr, "FAIL [4/4]: depth %.2f after CustomSampleDepthStore (0.75)\n", depthOf(d)); return 1; }
    printf("PASS [4/4]: a depth attachment stored with CustomSampleDepthStore\n");
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
        rc |= test1_OneRowBytesPerRowZero(dev);
        rc |= test2_PVRTCLevel(dev);
        rc |= test3_StoreActionsSetOnTheEncoder(dev, q);
        rc |= test4_CustomSampleDepthStore(dev, q);
        if (rc == 0) printf("ALL REFUSED ARGUMENT TESTS PASSED\n");
        return rc;
    }
}
