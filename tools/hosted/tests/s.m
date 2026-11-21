// Trace Metal's device discovery: wrap the methods on the path from IORegistry to the plugin's device and log each call.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>

static void wrapInst(const char *cls, const char *sel) {
  Class c = objc_getClass(cls);
  Method m = c ? class_getInstanceMethod(c, sel_registerName(sel)) : NULL;
  printf("wrap -[%s %s]: %s\n", cls, sel, m ? "ok" : "missing");
  if (!m) return;
  IMP orig = method_getImplementation(m);
  if (!strcmp(sel, "initWithAcceleratorPort:deviceClass:")) {
    method_setImplementation(m, imp_implementationWithBlock(^id(id self, unsigned port, Class dc) {
      printf("-> -[%s initWithAcceleratorPort:%u deviceClass:%s]\n", cls, port, dc ? class_getName(dc) : "nil");
      id r = ((id (*)(id, SEL, unsigned, Class))orig)(self, sel_registerName(sel), port, dc);
      printf("<- %p\n", (void *)r);
      if (r) { unsigned n = 0; Ivar *iv = class_copyIvarList(object_getClass(r), &n);
        for (unsigned i = 0; i < n; i++) { const char *t = ivar_getTypeEncoding(iv[i]); ptrdiff_t o = ivar_getOffset(iv[i]);
          unsigned long long v = *(unsigned long long *)((char *)r + o);
          printf("   ivar %s %s = 0x%llx%s%s\n", ivar_getName(iv[i]), t, v, t[0] == '@' && v ? " " : "", t[0] == '@' && v ? [[[(id)v description] substringToIndex:MIN((NSUInteger)80, [[(id)v description] length])] UTF8String] : ""); } }
      return r; }));
  } else if (!strcmp(sel, "processPendingCreateIOAccelServiceRequests")) {
    method_setImplementation(m, imp_implementationWithBlock(^void(id self) {
      printf("-> -[%s %s]\n", cls, sel); ((void (*)(id, SEL))orig)(self, sel_registerName(sel)); printf("<- done\n"); }));
  } else if (!strcmp(sel, "deviceNotifyQueue")) {
    method_setImplementation(m, imp_implementationWithBlock(^id(id self) {
      id q = ((id (*)(id, SEL))orig)(self, sel_registerName(sel));
      printf("   deviceNotifyQueue -> %s\n", q ? dispatch_queue_get_label((dispatch_queue_t)q) : "nil"); return q; }));
  } else if (!strcmp(sel, "registerService:deviceClass:")) {
    method_setImplementation(m, imp_implementationWithBlock(^id(id self, unsigned port, Class dc) {
      printf("-> -[%s registerService:%u deviceClass:%s]\n", cls, port, dc ? class_getName(dc) : "nil");
      id r = ((id (*)(id, SEL, unsigned, Class))orig)(self, sel_registerName(sel), port, dc);
      printf("<- %p\n", (void *)r); return r; }));
  } else if (!strcmp(sel, "initWithAcceleratorPort:")) {
    method_setImplementation(m, imp_implementationWithBlock(^id(id self, unsigned port) {
      printf("-> -[%s initWithAcceleratorPort:%u]\n", cls, port);
      id r = ((id (*)(id, SEL, unsigned))orig)(self, sel_registerName(sel), port);
      printf("<- %p\n", (void *)r); return r; }));
  } else if (!strcmp(sel, "init")) {
    method_setImplementation(m, imp_implementationWithBlock(^id(id self) {
      printf("-> -[%s init]\n", cls);
      id r = ((id (*)(id, SEL))orig)(self, sel_registerName(sel));
      printf("<- %p\n", (void *)r); return r; }));
  }
}

static void wrapClass(const char *cls, const char *sel) {
  Class c = objc_getClass(cls);
  Method m = c ? class_getClassMethod(c, sel_registerName(sel)) : NULL;
  printf("wrap +[%s %s]: %s\n", cls, sel, m ? "ok" : "missing");
  if (!m) return;
  IMP orig = method_getImplementation(m);
  method_setImplementation(m, imp_implementationWithBlock(^id(id self, unsigned port) {
    printf("-> +[%s %s %u]\n", cls, sel, port);
    id r = ((id (*)(id, SEL, unsigned))orig)(self, sel_registerName(sel), port);
    printf("<- %p\n", (void *)r); return r; }));
}

int main(void) {
  {
    setvbuf(stdout, NULL, _IONBF, 0);
    dlopen("/System/Library/PrivateFrameworks/IOGPU.framework/IOGPU", RTLD_NOW);
    [[NSBundle bundleWithPath:@"/Library/GPUBundles/XnuCpuMetal.bundle"] load];
    { Class meta = object_getClass(objc_getClass("XnuCpuMetalDevice"));
      class_addMethod(meta, @selector(resolveClassMethod:), imp_implementationWithBlock(^BOOL(id self, SEL q) {
        printf("?? +[XnuCpuMetalDevice %s] looked up, not implemented\n", sel_getName(q)); return NO; }), "c@::");
      class_addMethod(objc_getClass("XnuCpuMetalDevice") ? meta : nil, @selector(resolveInstanceMethod:), imp_implementationWithBlock(^BOOL(id self, SEL q) {
        printf("?? -[XnuCpuMetalDevice %s] looked up, not implemented\n", sel_getName(q)); return NO; }), "c@::"); }
    wrapInst("MTLIOAccelServiceGlobalContext", "init");
    wrapInst("MTLIOAccelService", "initWithAcceleratorPort:deviceClass:");
    wrapInst("XnuCpuMetalDevice", "initWithAcceleratorPort:");
    wrapClass("IOGPUMetalDevice", "registerAcceleratorService:");
    wrapInst("MTLIOAccelServiceGlobalContext", "processPendingCreateIOAccelServiceRequests");
    wrapInst("MTLIOAccelServiceGlobalContext", "registerService:deviceClass:");
    wrapInst("MTLIOAccelServiceGlobalContext", "deviceNotifyQueue");
    { unsigned n = 0; Method *ms = class_copyMethodList(objc_getClass("MTLIOAccelService"), &n);
      for (unsigned i = 0; i < n; i++) printf("  -MTLIOAccelService %s\n", sel_getName(method_getName(ms[i]))); }
    NSArray *all = MTLCopyAllDevices();
    printf("MTLCopyAllDevices: %lu\n", (unsigned long)all.count);
    id gc = nil; { Class c = objc_getClass("MTLIOAccelServiceGlobalContext"); (void)c; }
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:2]];
    printf("after run loop: %lu\n", (unsigned long)MTLCopyAllDevices().count);
    dispatch_sync(dispatch_get_global_queue(0, 0), ^{ printf("global queue alive\n"); });
    (void)gc;
    printf("after 2 s: %lu, default: %p\n", (unsigned long)MTLCopyAllDevices().count, (void *)MTLCreateSystemDefaultDevice());
  }
  return 0;
}
