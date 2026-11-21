#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <dlfcn.h>
int main(void) {
  MTLCreateSystemDefaultDevice();
  Dl_info info; dladdr((void *)MTLCreateSystemDefaultDevice, &info);
  unsigned n = 0; const char **names = objc_copyClassNamesForImage(info.dli_fname, &n);
  for (unsigned i = 0; i < n; i++) {
    Class c = objc_getClass(names[i]);
    if (!class_getInstanceMethod(c, sel_registerName("subType"))) continue;
    printf("class %s : %s\n", names[i], class_getName(class_getSuperclass(c)));
    unsigned m = 0; Method *ms = class_copyMethodList(c, &m);
    for (unsigned j = 0; j < m; j++) printf("  - %s %s\n", sel_getName(method_getName(ms[j])), method_getTypeEncoding(ms[j]));
    ms = class_copyMethodList(object_getClass(c), &m);
    for (unsigned j = 0; j < m; j++) printf("  + %s %s\n", sel_getName(method_getName(ms[j])), method_getTypeEncoding(ms[j]));
    unsigned k = 0; Ivar *iv = class_copyIvarList(c, &k);
    for (unsigned j = 0; j < k; j++) printf("  ivar %s %s @%td\n", ivar_getName(iv[j]), ivar_getTypeEncoding(iv[j]), ivar_getOffset(iv[j]));
  }
  return 0;
}
