import Foundation
import Metal
let p = "/Library/GPUBundles/XnuCpuMetal.bundle/Contents/MacOS/XnuCpuMetal"
let h = dlopen(p, RTLD_NOW)
print("dlopen:", h == nil ? "FAILED \(String(cString: dlerror()))" : "ok")
if let b = Bundle(path: "/Library/GPUBundles/XnuCpuMetal.bundle") {
  print("bundle principal load:", b.load(), "class:", NSClassFromString("XnuCpuMetalDevice") as Any)
  if let c: AnyClass = NSClassFromString("XnuCpuMetalDevice"), let s: AnyClass = NSClassFromString("IOGPUMetalDevice") {
    print("subclass of IOGPUMetalDevice:", c.isSubclass(of: s))
  }
}
print("metal device after load:", MTLCreateSystemDefaultDevice()?.name ?? "nil")
