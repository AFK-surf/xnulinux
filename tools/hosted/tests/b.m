#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
@interface NSObject (X)
- (id)initWithAcceleratorPort:(unsigned)port;
@end
int main(void) {
  @autoreleasepool {
    NSBundle *b = [NSBundle bundleWithPath:@"/Library/GPUBundles/XnuCpuMetal.bundle"];
    NSError *e = nil;
    printf("load: %d %s\n", [b loadAndReturnError:&e], e ? e.description.UTF8String : "");
    Class c = [b principalClass];
    printf("principal: %s\n", c ? class_getName(c) : "nil");
    id<MTLDevice> d = [[c alloc] initWithAcceleratorPort:0];
    printf("direct init: %s\n", d ? d.name.UTF8String : "nil");
    if (d) {
      id<MTLBuffer> buf = [d newBufferWithLength:4096 options:0];
      id<MTLCommandQueue> q = [d newCommandQueue];
      id<MTLCommandBuffer> cb = [q commandBuffer];
      id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
      [be fillBuffer:buf range:NSMakeRange(0, 4096) value:7];
      [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
      unsigned char *p = buf.contents;
      printf("blit fill: %d %d status %ld\n", p[0], p[4095], (long)cb.status);
    }
  }
  return 0;
}
