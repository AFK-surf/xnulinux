import Metal
let d = MTLCreateSystemDefaultDevice()
print("metal device:", d?.name ?? "nil")
print("all devices:", MTLCopyAllDevices().count)
if let d = d {
  let b = d.makeBuffer(length: 4096)!
  let q = d.makeCommandQueue()!
  let c = q.makeCommandBuffer()!
  let e = c.makeBlitCommandEncoder()!
  e.fill(buffer: b, range: 0..<4096, value: 7)
  e.endEncoding(); c.commit(); c.waitUntilCompleted()
  let p = b.contents().bindMemory(to: UInt8.self, capacity: 4096)
  print("blit fill:", p[0], p[4095], "status", c.status.rawValue)
}
