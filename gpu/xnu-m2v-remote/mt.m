// SPDX-License-Identifier: GPL-2.0-or-later
// In the hosted macOS: a triangle through Metal itself (the plugin and whatever libxnu_m2v it has).
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
int main(int argc, char **argv) {
    @autoreleasepool {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("no Metal device\n"); return 1; }
        printf("device: %s\n", dev.name.UTF8String);
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&err];
        if (!lib) { printf("library: %s\n", err.description.UTF8String); return 1; }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"tri_vertex"]; pd.fragmentFunction = [lib newFunctionWithName:@"tri_fragment"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pso) { printf("pipeline: %s\n", err.description.UTF8String); return 1; }
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1280 height:800 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeManaged;
        id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
        id<MTLCommandQueue> q = [dev newCommandQueue];
        int frames = argc > 2 ? atoi(argv[2]) : 1;
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        for (int i = 0; i < frames; i++) {
            id<MTLCommandBuffer> cb = [q commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
            rp.colorAttachments[0].texture = tex; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0.3, 1);
            id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
            [e setRenderPipelineState:pso]; [e setViewport:(MTLViewport){0, 0, 1280, 800, 0, 1}];
            [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [e endEncoding]; [cb commit];
            if (i == frames - 1) { [cb waitUntilCompleted]; printf("status %lu error %s\n", (unsigned long)cb.status, cb.error.description.UTF8String ?: "none"); }
        }
        printf("%d frames, %.3f ms each\n", frames, (CFAbsoluteTimeGetCurrent() - t0) * 1e3 / frames);
        static uint8_t px[1280 * 800 * 4];
        t0 = CFAbsoluteTimeGetCurrent();
        [tex getBytes:px bytesPerRow:1280 * 4 fromRegion:MTLRegionMake2D(0, 0, 1280, 800) mipmapLevel:0];
        uint8_t *c = px + (400 * 1280 + 640) * 4;
        printf("getBytes %.1f ms; centre bgra %d %d %d %d, corner %d %d %d %d\n", (CFAbsoluteTimeGetCurrent() - t0) * 1e3, c[0], c[1], c[2], c[3], px[0], px[1], px[2], px[3]);
    }
    return 0;
}
