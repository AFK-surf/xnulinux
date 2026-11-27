// SPDX-License-Identifier: GPL-2.0-or-later
// Descriptor fields Metal honours that the CPU device dropped, each judged by what the textures hold afterwards:
// 1. depthAttachment.slice: one slice of a depth array (a shadow cascade), one face of a depth cube.
// 2. depthAttachment.level: one mip level of a depth texture.
// 3. stencilAttachment.level and .slice.
// 4. colorAttachments[0].depthPlane: one plane of a 3D texture.
// 5. MTLSamplerDescriptor.borderColor: what ClampToBorderColor samples outside the texture. Metal makes a sampler of any
//    raw value: 3, which names no colour, samples transparent black.
// Each pass only clears its attachment; the other subresources must keep what they held.
//
//   clang++ -O2 -fobjc-arc test/test_descriptor_fields.mm -framework Foundation -framework Metal -o build/test_descriptor_fields
//   build/test_descriptor_fields dist/XnuCpuMetal.bundle        ("default" instead of the bundle: the Mac's own device)

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cmath>
#include <cstdio>
#include <cstring>

@interface NSObject (XnuCpuMetalPluginDescriptorFields)
- (id)initWithAcceleratorPort:(unsigned)port;
@end

static id<MTLDevice> loadBundleDevice(const char *bundlePath) {
    if (strcmp(bundlePath, "default") == 0) return MTLCreateSystemDefaultDevice();
    NSBundle *b = [NSBundle bundleWithPath:[NSString stringWithUTF8String:bundlePath]];
    if (!b || ![b load]) { fprintf(stderr, "FAIL: cannot load bundle %s\n", bundlePath); return nil; }
    return [[[b principalClass] alloc] initWithAcceleratorPort:0];
}

static id<MTLTexture> texture(id<MTLDevice> dev, MTLTextureType type, MTLPixelFormat format, NSUInteger depth, NSUInteger levels, NSUInteger layers) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor new];
    td.textureType = type; td.pixelFormat = format; td.width = 4; td.height = 4; td.depth = depth;
    td.mipmapLevelCount = levels; td.arrayLength = layers;
    td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    td.storageMode = MTLStorageModeShared;
    return [dev newTextureWithDescriptor:td];
}
static BOOL clearPass(id<MTLCommandQueue> q, MTLRenderPassDescriptor *rp) {
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    if (!enc) return NO;
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return cb.status == MTLCommandBufferStatusCompleted;
}
static float depthOf(id<MTLTexture> t, NSUInteger level, NSUInteger slice) {
    float px[16]; for (int i = 0; i < 16; i++) px[i] = -1;
    [t getBytes:px bytesPerRow:(4 >> level) * 4 bytesPerImage:0 fromRegion:MTLRegionMake2D(0, 0, 4 >> level, 4 >> level) mipmapLevel:level slice:slice];
    return px[0];
}
// Clears the depth of d at (level, slice) to 0.25 where every subresource holds 0.5: only that one may change.
static BOOL depthPassWritesOnly(id<MTLCommandQueue> q, id<MTLTexture> d, NSUInteger levels, NSUInteger slices, NSUInteger level, NSUInteger slice, int n) {
    float half[16]; for (int i = 0; i < 16; i++) half[i] = 0.5f;
    for (NSUInteger s = 0; s < slices; s++) for (NSUInteger l = 0; l < levels; l++)
        [d replaceRegion:MTLRegionMake2D(0, 0, 4 >> l, 4 >> l) mipmapLevel:l slice:s withBytes:half bytesPerRow:(4 >> l) * 4 bytesPerImage:0];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = d;
    rp.depthAttachment.level = level;
    rp.depthAttachment.slice = slice;
    rp.depthAttachment.loadAction = MTLLoadActionClear;
    rp.depthAttachment.clearDepth = 0.25;
    rp.depthAttachment.storeAction = MTLStoreActionStore;
    if (!clearPass(q, rp)) { fprintf(stderr, "FAIL [%d/5]: no pass\n", n); return NO; }
    for (NSUInteger s = 0; s < slices; s++) for (NSUInteger l = 0; l < levels; l++)
        if (depthOf(d, l, s) != (l == level && s == slice ? 0.25f : 0.5f)) {
            fprintf(stderr, "FAIL [%d/5]: level %lu slice %lu holds %.2f after a pass that cleared level %lu slice %lu to 0.25\n", n,
                    (unsigned long)l, (unsigned long)s, depthOf(d, l, s), (unsigned long)level, (unsigned long)slice);
            return NO;
        }
    return YES;
}

static int test1_DepthSlice(id<MTLDevice> dev, id<MTLCommandQueue> q) {
    if (!depthPassWritesOnly(q, texture(dev, MTLTextureType2DArray, MTLPixelFormatDepth32Float, 1, 1, 2), 1, 2, 0, 1, 1)) return 1;
    if (!depthPassWritesOnly(q, texture(dev, MTLTextureTypeCube, MTLPixelFormatDepth32Float, 1, 1, 1), 1, 6, 0, 3, 1)) return 1;
    printf("PASS [1/5]: a depth attachment's slice: slice 1 of an array, face 3 of a cube\n");
    return 0;
}

static int test2_DepthLevel(id<MTLDevice> dev, id<MTLCommandQueue> q) {
    if (!depthPassWritesOnly(q, texture(dev, MTLTextureType2D, MTLPixelFormatDepth32Float, 1, 3, 1), 3, 1, 1, 0, 2)) return 1;
    printf("PASS [2/5]: a depth attachment's level\n");
    return 0;
}

static int test3_StencilLevelAndSlice(id<MTLDevice> dev, id<MTLCommandQueue> q) {
    id<MTLTexture> s = texture(dev, MTLTextureType2DArray, MTLPixelFormatStencil8, 1, 2, 2);
    uint8_t px[16] = {0};
    for (NSUInteger sl = 0; sl < 2; sl++) for (NSUInteger l = 0; l < 2; l++)
        [s replaceRegion:MTLRegionMake2D(0, 0, 4 >> l, 4 >> l) mipmapLevel:l slice:sl withBytes:px bytesPerRow:4 >> l bytesPerImage:0];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.stencilAttachment.texture = s;
    rp.stencilAttachment.level = 1;
    rp.stencilAttachment.slice = 1;
    rp.stencilAttachment.loadAction = MTLLoadActionClear;
    rp.stencilAttachment.clearStencil = 7;
    rp.stencilAttachment.storeAction = MTLStoreActionStore;
    if (!clearPass(q, rp)) { fprintf(stderr, "FAIL [3/5]: no pass\n"); return 1; }
    for (NSUInteger sl = 0; sl < 2; sl++) for (NSUInteger l = 0; l < 2; l++) {
        memset(px, 0xEE, sizeof px);
        [s getBytes:px bytesPerRow:4 >> l bytesPerImage:0 fromRegion:MTLRegionMake2D(0, 0, 4 >> l, 4 >> l) mipmapLevel:l slice:sl];
        if (px[0] != (l == 1 && sl == 1 ? 7 : 0)) {
            fprintf(stderr, "FAIL [3/5]: level %lu slice %lu holds stencil %u after a pass that cleared level 1 slice 1 to 7\n", (unsigned long)l, (unsigned long)sl, px[0]);
            return 1;
        }
    }
    printf("PASS [3/5]: a stencil attachment's level and slice\n");
    return 0;
}

static int test4_ColorDepthPlane(id<MTLDevice> dev, id<MTLCommandQueue> q) {
    id<MTLTexture> c = texture(dev, MTLTextureType3D, MTLPixelFormatRGBA8Unorm, 2, 1, 1);
    uint8_t px[128] = {0};
    [c replaceRegion:MTLRegionMake3D(0, 0, 0, 4, 4, 2) mipmapLevel:0 slice:0 withBytes:px bytesPerRow:16 bytesPerImage:64];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = c;
    rp.colorAttachments[0].depthPlane = 1;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    if (!clearPass(q, rp)) { fprintf(stderr, "FAIL [4/5]: no pass\n"); return 1; }
    memset(px, 0x77, sizeof px);
    [c getBytes:px bytesPerRow:16 bytesPerImage:64 fromRegion:MTLRegionMake3D(0, 0, 0, 4, 4, 2) mipmapLevel:0 slice:0];
    if (px[0] != 0 || px[63] != 0 || px[64] != 255 || px[127] != 255) {
        fprintf(stderr, "FAIL [4/5]: plane 0 holds red %u, plane 1 red %u after a pass that cleared plane 1 to white\n", px[0], px[64]);
        return 1;
    }
    printf("PASS [4/5]: a colour attachment's depth plane\n");
    return 0;
}

static int test5_SamplerBorderColor(id<MTLDevice> dev, id<MTLCommandQueue> q) {
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
                     "kernel void border_probe(texture2d<float, access::sample> t [[texture(0)]], sampler s [[sampler(0)]],\n"
                     "                         device float4 *o [[buffer(0)]], uint g [[thread_position_in_grid]]) {\n"
                     "  const float u[3] = { -0.5f, 0.5f, 1.5f };\n"
                     "  o[g] = t.sample(s, float2(u[g], 0.5f), level(0.0f)); }\n";
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
    id<MTLComputePipelineState> pso = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"border_probe"] error:&err] : nil;
    if (!pso) { fprintf(stderr, "FAIL [5/5]: no pipeline: %s\n", err.localizedDescription.UTF8String); return 1; }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:2 height:2 mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    uint8_t px[16]; memset(px, 0x33, sizeof px);   // 0.2 in every channel of every texel
    [t replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0 withBytes:px bytesPerRow:8];
    const MTLSamplerBorderColor colors[3] = { MTLSamplerBorderColorOpaqueBlack, MTLSamplerBorderColorOpaqueWhite, (MTLSamplerBorderColor)3 };
    for (MTLSamplerBorderColor color : colors) {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.sAddressMode = sd.tAddressMode = sd.rAddressMode = MTLSamplerAddressModeClampToBorderColor;
        sd.borderColor = color;
        id<MTLSamplerState> smp = [dev newSamplerStateWithDescriptor:sd];
        if (!smp) { fprintf(stderr, "FAIL [5/5]: no sampler for border colour %lu\n", (unsigned long)color); return 1; }
        id<MTLBuffer> out = [dev newBufferWithLength:48 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:pso];
        [enc setTexture:t atIndex:0];
        [enc setSamplerState:smp atIndex:0];
        [enc setBuffer:out offset:0 atIndex:0];
        [enc dispatchThreads:MTLSizeMake(3, 1, 1) threadsPerThreadgroup:MTLSizeMake(3, 1, 1)];
        [enc endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        const float *v = (const float *)out.contents;
        const float rgb = color == MTLSamplerBorderColorOpaqueWhite ? 1.0f : 0.0f, a = color == 3 ? 0.0f : 1.0f;
        const float want[3][4] = { {rgb, rgb, rgb, a}, {0.2f, 0.2f, 0.2f, 0.2f}, {rgb, rgb, rgb, a} };   // left of, in, right of the texture
        for (int i = 0; i < 3; i++) for (int ch = 0; ch < 4; ch++)
            if (fabsf(v[i * 4 + ch] - want[i][ch]) > 0.01f) {
                fprintf(stderr, "FAIL [5/5]: border colour %lu: sample %d is %.2f %.2f %.2f %.2f, Metal's is %.2f %.2f %.2f %.2f\n", (unsigned long)color, i,
                        v[i * 4], v[i * 4 + 1], v[i * 4 + 2], v[i * 4 + 3], want[i][0], want[i][1], want[i][2], want[i][3]);
                return 1;
            }
    }
    printf("PASS [5/5]: ClampToBorderColor samples the sampler's border colour (OpaqueBlack, OpaqueWhite, 3 as transparent black)\n");
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
        rc |= test1_DepthSlice(dev, q);
        rc |= test2_DepthLevel(dev, q);
        rc |= test3_StencilLevelAndSlice(dev, q);
        rc |= test4_ColorDepthPlane(dev, q);
        rc |= test5_SamplerBorderColor(dev, q);
        if (rc == 0) printf("ALL DESCRIPTOR FIELD TESTS PASSED\n");
        return rc;
    }
}
