# xnulinux 纯 CPU Metal 设备用户态构建报告

构建机：`tokyo-mac-studio-0`（macOS 27.0.1 / Build 26A434，Apple M5 Max 18 核 64 GB，Xcode 27.0，Rust 1.100.0）
工作目录：`/Users/admin/.stillfail/sessions/chat/c-73ef26e7b6/workspace`

---

## 1. 产物路径清单

| 组件 | 路径 | 大小 | 架构 | 外部运行时依赖 |
|---|---|---|---|---|
| Mesa lavapipe ICD | `dist/lavapipe/lib/libvulkan_lvp.dylib` | 125 MB | `arm64` | 仅 Apple 系统库（`libSystem.B`、`libz.1`、`libc++.1`）；LLVM 22.1.8 与 `libzstd.a` 已静态链入 |
| Khronos Vulkan Loader | `dist/lavapipe/lib/libvulkan.1.dylib` | 663 KB | `arm64` | 仅 Apple 系统库（`libSystem.B`、`CoreFoundation`） |
| Vulkan ICD 描述 | `dist/lavapipe/share/vulkan/icd.d/lvp_icd.aarch64.json` | 247 B | — | 指向 `libvulkan_lvp.dylib` |
| metal2vulkan C ABI 动态库 | `dist/m2v/lib/libxnu_m2v.dylib` | 32 MB | `arm64` | 仅 Apple 系统库（`libiconv.2`、`libSystem.B`）；基于上游 `steelbrain/metal2vulkan` 0.2.0 零补丁构建 |
| metal2vulkan C 头文件 | `dist/m2v/include/xnu_m2v.h` | 12 KB | — | — |
| **Metal 插件 Bundle（自包含可重定位）** | **`dist/XnuCpuMetal.bundle`** | ~158 MB | `arm64` | 仅 Apple 系统框架（`Foundation`、`Metal`、`IOKit`、`IOSurface`、`IOGPU`、`CoreFoundation`、`libobjc`、`libc++`、`libSystem`）及内置 `@loader_path/../Frameworks/libxnu_m2v.dylib` |

`dist/XnuCpuMetal.bundle` 内部布局（可直接拷贝到托管 macOS 的 `/Library/GPUBundles/XnuCpuMetal.bundle`，无硬编码宿主机路径）：
```
dist/XnuCpuMetal.bundle/
  Contents/
    Info.plist                      (NSPrincipalClass = XnuCpuMetalDevice)
    MacOS/XnuCpuMetal               (MH_BUNDLE, arm64)
    Frameworks/
      libxnu_m2v.dylib
      libvulkan.1.dylib
      libvulkan_lvp.dylib
    Resources/
      lvp_icd.aarch64.json          (library_path = "../Frameworks/libvulkan_lvp.dylib")
```

---

## 2. 可复现构建与验证脚本

所有脚本均在工作目录 `scripts/` 下，按顺序执行即可复现全部 3 步产物与验证：

1. **第 1 步（Mesa lavapipe）**：
   - 构建：`bash scripts/build-lavapipe.sh`
   - 验证：`bash scripts/test-lavapipe.sh`
   - 实测结果：`Vulkan device: llvmpipe (LLVM 22.1.8, 128 bits) (type=4, api=1.4.363, driver=0x6803001)`，`Compute vecadd N=1024: bad=0`
2. **第 2 步（metal2vulkan + AIR→SPIR-V）**：
   - 构建：`bash scripts/build-m2v.sh`
   - 验证：`bash scripts/test-m2v.sh`（使用 `xcrun -sdk macosx metal` + `metallib` 编译 `test/vecadd.metal`）
   - 实测结果：`m2v device: llvmpipe (LLVM 22.1.8, 128 bits) (maxBufferLength=2147483648)`，`pipeline: maxThreads=1024, simdWidth=32`，`Metal->metal2vulkan->lavapipe vecadd N=1024: status=4, bad=0`
3. **第 3 步（`XnuCpuMetal.bundle`）**：
   - 构建：`bash scripts/build-bundle.sh`
   - 验证：`bash scripts/test-bundle.sh`（通过 `NSBundle` 加载 `XnuCpuMetal.bundle`，检查 `principalClass == XnuCpuMetalDevice` 且为 `IOGPUMetalDevice` 子类，调用 `initWithAcceleratorPort:0` 并走标准 ObjC `MTLDevice` API 执行 `vecadd.metallib`）
   - 实测结果：`Bundle loaded: principalClass=XnuCpuMetalDevice, isSubclassOf(IOGPUMetalDevice)=YES`，`Bundle ObjC MTLDevice vecadd N=1024: status=4, completedHandler=1, bad=0`（进程干净退出，退出码 0）

---

## 3. 插件 Metal API 接入与空实现清单

### 已接入（经 `libxnu_m2v.dylib` 到达 `metal2vulkan-runtime` → `lavapipe`）
- **插件注册与 IOGPU 兼容层**（`XnuCpuMetalDevice` + `XnuCpuMetalShim.h`）：
  - `XnuCpuMetalDevice : IOGPUMetalDevice`、`initWithAcceleratorPort:`（保留自身避免 `-[IOGPUMetalDevice dealloc]` 破坏未初始化状态，返回动态创建的 `_MTLDevice` 子类 `XcmBackendDevice`）
  - IOGPU 必需 selector：`_setAcceleratorService:`、`acceleratorPort`、`_setDeviceWrapper:`、`_deviceWrapper`、`isBuiltIn`、`recommendedMaxWorkingSetSize`、`sharedMemorySize`、`gpuCoreCount`、`cmdBufArgsSize`、`featureProfile`、queue GPU priorities、`userDictionary`、`bitCodeHash` 及全部 `MTL*` 协议声明
- **MTLDevice**：`name`、`registryID`、`isLowPower`、`isHeadless`、`isRemovable`、`hasUnifiedMemory`、`maxBufferLength`、`maxThreadsPerThreadgroup`、`supportsFamily:`、`newCommandQueue`、`newCommandQueueWithMaxCommandBufferCount:`、`newBufferWithLength:options:`、`newBufferWithBytes:length:options:`、`newBufferWithBytesNoCopy:length:options:deallocator:`（失败自动回退拷贝）、`newTextureWithDescriptor:`、`newLibraryWithData:error:`、`newLibraryWithURL:error:`、`newLibraryWithFile:error:`、`newComputePipelineStateWithFunction:error:`（含 options/descriptor/completionHandler 重载）、`newRenderPipelineStateWithDescriptor:error:`（含 options 重载）、`newSamplerStateWithDescriptor:`、`newDepthStencilStateWithDescriptor:`、`newEvent`、`newFence`；并从 `_MTLDevice` 继承 `newDefaultLibrary` / `newLibraryWithSource:options:error:` 等上层框架入口
- **MTLBuffer**：`contents`、`length`、`gpuAddress`、`didModifyRange:`、storage/cache/hazard/options/allocatedSize 属性
- **MTLTexture**：基本元数据属性、`replaceRegion:...`、`getBytes:...`、`newTextureViewWithPixelFormat:...`（含 level/slice 重载）
- **MTLLibrary / MTLFunction**：`functionNames`、`newFunctionWithName:`、`functionType`、`name`
- **MTLComputePipelineState / MTLRenderPipelineState / MTLSamplerState / MTLDepthStencilState / MTLEvent / MTLFence**：创建、销毁与 compute 线程组查询属性
- **MTLCommandQueue / MTLCommandBuffer**：`commandBuffer`、`status`、`error`、`commit`、`waitUntilScheduled`、`waitUntilCompleted`、`addScheduledHandler:`、`addCompletedHandler:`、`computeCommandEncoder`、`renderCommandEncoderWithDescriptor:`、`blitCommandEncoder`、`encodeSignalEvent:value:`、`encodeWaitForEvent:value:`
- **MTLComputeCommandEncoder**：`setComputePipelineState:`、`setBuffer/setBuffers/setBufferOffset`、`setBytes`、`setTexture/setTextures`、`setSamplerState/setSamplerStates`、`setThreadgroupMemoryLength:atIndex:`、`dispatchThreadgroups:`、`dispatchThreads:`、`endEncoding`
- **MTLRenderCommandEncoder**：`setRenderPipelineState:`、`setDepthStencilState:`、`setViewport:`、`setScissorRect:`、`setCullMode:`、`setFrontFacingWinding:`、vertex/fragment buffer/bytes/texture/sampler 绑定、`drawPrimitives:...`、`drawIndexedPrimitives:...`、`endEncoding`
- **MTLBlitCommandEncoder**：buffer↔buffer、buffer↔texture、texture↔buffer、texture↔texture 拷贝、`fillBuffer:range:value:`、`generateMipmapsForTexture:`、`synchronizeResource:`、`endEncoding`

### 尚未实现 / 桩实现（Stub）
- **IOSurface 零拷贝导入**：`newTextureWithDescriptor:iosurface:plane:` 目前仅创建普通后端纹理并保存 `IOSurfaceRef` 引用，未将 IOSurface 内存直接映射/回写到纹理（CoreImage 若经 IOSurface 交付结果需要补齐锁面读写或 no-copy 导入）
- **Function Constants 特化**：`newFunctionWithName:constantValues:error:` 目前忽略 `constantValues`，直接按函数名查找（`metal2vulkan-runtime` 自身支持 `new_function_with_name_constant_values`，后续若 `ictool`/CoreImage 触发可直接补接线）
- **高级 Metal 对象**：`MTLHeap`、`MTLSharedEvent`、`MTLBinaryArchive`、`MTLIndirectCommandBuffer`、`MTLArgumentEncoder`、`MTLCounterSampleBuffer`、`MTLAccelerationStructure`、stitched library / dynamic library、render pipeline `vertexDescriptor`（目前 `Xm2vRenderPipelineDesc` 未传递 `MTLVertexDescriptor`）、`MTLComputePipelineReflection` / `MTLRenderPipelineReflection`（目前返回 `nil`）
- **Purgeable 内存真实回收**：`setPurgeableState:` 仅记录状态，不触发后端释放
- **兜底机制**：任何未覆盖的 `IOGPUMetal*` selector 由 `resolveInstanceMethod:` 拦截，打印一次 `XnuCpuMetal: <prog>: stubbed <class> <sel>` 到 stderr 并返回 0，便于托管系统联调时定位实际缺口

---

## 4. `arm64` vs `arm64e` 确认结论

1. **宿主与目标进程架构实测**：
   - Xcode 工具链进程（本次首要目标）均为 **`arm64`**（非 `arm64e`）：
     - `/Applications/Xcode_27.app/Contents/Developer/usr/bin/ictool` → `Mach-O 64-bit executable arm64`
     - `/Applications/Xcode_27.app/Contents/Developer/usr/bin/actool` → `Mach-O 64-bit executable arm64`
     - `/Applications/Xcode_27.app/Contents/Developer/usr/bin/xcodebuild` → `Mach-O 64-bit executable arm64`
   - macOS 系统工具与守护进程为 **`arm64e`**（例如 `/usr/bin/sips`、`WindowServer`、`iconservicesagent`）。
   - dyld shared cache 中的 `Metal.framework` 是 `arm64e`，但 **arm64 进程加载 dyld shared cache 中的 `arm64e` 系统框架时，dyld 要求进程内动态加载的 bundle 匹配进程自身架构（即 `arm64`）**——这已在本机 `test_bundle`（arm64 进程链接系统 `Metal.framework`）加载 `arm64` `XnuCpuMetal.bundle` 中实测通过。
2. **`arm64e` 进程的限制（已实测确认）**：
   - `arm64e` 进程无法 `dlopen` 仅含 `arm64` 切片的 `XnuCpuMetal.bundle`（dyld 拒绝：`incompatible architecture (have 'arm64', need 'arm64e')`）。
   - 若后续需要同时服务 `arm64`（`ictool`/`xcodebuild`）和 `arm64e`（`sips`/系统守护进程），需将整条链编成 **universal fat（`arm64` + `arm64e`）**：
     - `XnuCpuMetal`（ObjC++）：Xcode 27 `clang++ -arch arm64e` 已实测直接支持。
     - `libxnu_m2v.dylib`（Rust）：`rustc 1.100.0` 含 tier-3 目标 `arm64e-apple-darwin`（需 nightly `-Zbuild-std`，且需像 `AdrenoMetal/bridge/RustPacBoundary.c` 那样处理 Rust↔C 的 PAC 指针签名边界）。
     - `libvulkan_lvp.dylib` + `libvulkan.1.dylib`：Homebrew 预编译的 `llvm@22`、`zstd`、`vulkan-loader` 均为 `arm64`-only，编 `arm64e` 切片需从源码用 `-arch arm64e` 交叉/原生编译 LLVM、Vulkan-Loader 和 Mesa。
3. **建议**：当前阶段为了尽快在托管 XNU 里打通 `ictool`（本身是 `arm64` 进程）和 CoreImage 探针，**先用这份自包含的 `arm64` `XnuCpuMetal.bundle` 接入内核 stub kext 联调**；若联调发现 `ictool` 会经 XPC 调到某个 `arm64e` 守护进程或需要支持 `arm64e` 进程，再补 `arm64e` 切片做成 fat bundle。

---

## 5. 已知缺口与联调注意事项

- **CoreImage / `ictool` 常见需求**：CoreImage 常使用 `newLibraryWithSource:options:error:`（由 `_MTLDevice` 走 `MTLCompilerService` 产出 AIR/metallib 后回调 `newLibraryWithData:error:`）、`MTLVertexDescriptor`、Function Constants 以及 `IOSurface` 纹理。若联调日志中出现 `XnuCpuMetal: <prog>: stubbed ...` 或 `newTextureWithDescriptor:iosurface:plane:` 数据为空，优先补齐对应项。
- **lavapipe 精度降级提示**：`metal2vulkan` 在 stderr 会打印 2–4 条 `PrecisionNote` / `DegradeNotice`（llvmpipe 无 `VK_KHR_pipeline_binary`、denormals、NaN encoding、float tininess）；按 `metal2vulkan` 规则均为非致命提示。
- **许可证**：`src/mesa`、`src/metal2vulkan` 仅用于本机构建，未提交或推送至任何仓库。

---

## 6. 第二轮成果：整链 Universal（`arm64 + arm64e`）与 Render / CoreImage 冒烟测试

### 6.1 Universal (`arm64 + arm64e`) 产物与构建脚本
`dist/XnuCpuMetal.bundle` 现已全部合成为 **`arm64 + arm64e` universal fat**（`lipo -info` 全部确认为 `arm64 arm64e`，无任何 Homebrew 运行时依赖）：
- `dist/XnuCpuMetal.bundle/Contents/MacOS/XnuCpuMetal`（323 KB，`arm64 arm64e`）
- `dist/XnuCpuMetal.bundle/Contents/Frameworks/libxnu_m2v.dylib`（71 MB，`arm64 arm64e`）
- `dist/XnuCpuMetal.bundle/Contents/Frameworks/libvulkan.1.dylib`（1.4 MB，`arm64 arm64e`）
- `dist/XnuCpuMetal.bundle/Contents/Frameworks/libvulkan_lvp.dylib`（196 MB，`arm64 arm64e`）

新增可复现构建脚本：
1. `scripts/build-llvm-arm64e.sh`：从 `llvmorg-22.1.8`（sparse 仅 `llvm`/`cmake`/`third-party`）编译 `arm64e` AArch64 静态库与 `llvm-config`（关闭 zstd/libxml2/terminfo/tests）。
2. `scripts/build-vkloader-arm64e.sh`：从 Khronos `Vulkan-Loader` `vulkan-sdk-1.4.363.0` 编译 `arm64e` `libvulkan.1.dylib`。
3. `scripts/build-lavapipe-arm64e.sh`：基于 `arm64e` LLVM 22 编译 `arm64e` Mesa 26.3.1 lavapipe。
   - **关键 PAC 修复**（`src/mesa/src/gallium/auxiliary/gallivm/lp_bld_init.c` 与 `lp_bld_init_orc.cpp` 中的 `gallivm_jit_function`）：LLVM MCJIT/ORCJIT 返回未签名代码指针，`arm64e` 下 C 侧经 `blraaz` 调用 JIT shader 会触发 `SIGBUS`（多线程下表现为 `VkQueue` 超时 20.2s）。在 `gallivm_jit_function` 返回前用 `__builtin_ptrauth_sign_unauthenticated(__builtin_ptrauth_strip(code, 0), 0, 0)` 签名后，单线程与多线程 `arm64e` lavapipe 均一次通过。
4. `scripts/build-m2v-arm64e.sh` + `scripts/rust-pac-rewrite.py`：用 `nightly-aarch64-apple-darwin`（`rustc 1.102.0-nightly`）+ `-Zbuild-std=std,panic_unwind --target arm64e-apple-darwin` 编译 `libxnu_m2v.a`；实测 nightly 仍输出无 PAC 的 `blr`/`br`，因此按 `AdrenoMetal/bridge/RustPacBoundary.c` 方案：
   - 用 `llvm-objcopy --redefine-sym` 将 Rust 目标文件中 7 个接收 C 回调的导入（`_pthread_create`、`__tlv_atexit`、`_atexit`、`___cxa_atexit`、`__dyld_register_func_for_add_image`、`__Unwind_Backtrace`、`_dlsym`）重定向到 `nmb_pac_*` 包装器；
   - 链接 `RustPacBoundary.o` 后，由 `scripts/rust-pac-rewrite.py` 将 Rust `__TEXT,__text` 中的 `9528` 条 `blr` 与 `2734` 条 `br` 重写为 `bl`/`b _nmb_pac_call_xN`（跳过 40 个 PAC 边界函数），再 ad-hoc 签名。
5. `scripts/build-bundle-universal.sh`：编译 `arm64` + `arm64e` 两份 `XnuCpuMetal` 并用 `lipo -create` 合成全部 4 个 universal 二进制。

### 6.2 双架构验收实测结果
- **`arm64` 进程**（`bash scripts/test-bundle.sh arm64`）：
  `Bundle ObjC MTLDevice vecadd N=1024: status=4, completedHandler=1, bad=0 (c[0]=256.00, c[10]=283.50, c[1023]=3069.25)`，退出码 0。
- **`arm64e` 进程**（`bash scripts/test-bundle.sh arm64e`）：
  `Bundle ObjC MTLDevice vecadd N=1024: status=4, completedHandler=1, bad=0 (c[0]=256.00, c[10]=283.50, c[1023]=3069.25)`，退出码 0。

### 6.3 Render Pass + CoreImage `CIGaussianBlur` 冒烟测试（`bash scripts/test-render-ci.sh arm64|arm64e`）
1. **Render Pass（清蓝屏 + 画橙红三角形到 64×64 `RGBA8Unorm` 纹理 + Blit 读回校验）**：
   - `arm64` 与 `arm64e` **均 PASS**：
     `Render pass status=4: center=(255,51,0,255) corner=(0,0,255,255) triPx=1352 bluePx=2744 otherPx=0`
2. **CoreImage `CIContext(mtlDevice:)` + `CIGaussianBlur`**：
   - 进展：`CIContext` 成功创建并加载 CoreImage 预编译 metallib，通过 DAG 图优化（`CIBlurProcessor-4.000`），进入 Apple `Metal.framework` 的 stitched function graph 编译器（`MTLCompilerStitchingRequest::serializedRequest`）。
   - **本次过程中先补掉的 2 个阻塞点**：`XcmLibrary externFunctionNames`/`type`/`installName`，以及 `_MTLDevice` 基础限制（`recommendedMaxWorkingSetSize` 强制覆盖 + `maxTextureWidth2D`/`maxTextureHeight2D`/`maxThreadgroupMemoryLength`/`minimumLinearTextureAlignmentForPixelFormat:` 等，原默认返回 0 导致 CoreImage 报 `memory requirement of -1 too big`）。
   - **落到 `stubbed` 的完整调用清单（下一步待补清单）**：
     1. `XcmQueue setBackgroundGPUPriority:`（低优先级，可沿用 `XnuCpuMetalShim.h` 里的 `kBackgroundPriorityKey` 存值）
     2. `XcmTexture isDrawable`（返回 `NO` 即可）
     3. `XcmBackendDevice newHeapWithDescriptor:`（MPS 探测时调用，目前返回 `nil` 使 CoreImage 跳过 MPS 走自有 shader；如需 MPS 支持需接入 `metal2vulkan_runtime::Heap`）
     4. `XcmCommandBuffer protectionOptions`（返回 `0` 即可）
     5. **`XcmFunction libraryData` / `bitCodeOffset` / `bitCodeFileSize`**（**当前阻断点**：`MTLCompilerStitchingRequest::serializedRequest` 读取这 3 个私有属性构造 stitched library XPC 请求，`libraryData` 返回 NULL 导致崩溃；需参考 `AdrenoMetal/NativeBridgeMetalFrontend.mm:4804` 覆盖 `newLibraryWithStitchedDescriptor:error:`，同时在 `libxnu_m2v` 暴露 `extern_function_names()` + `new_extern_function_with_name()` 供 CoreImage 链接 `ci_stdlib` extern 函数）
     6. **`newTextureWithDescriptor:iosurface:plane:`**（CoreImage 的 `imageWithBitmapData:` / `render:toBitmap:` 路径依赖 IOSurface 纹理读写，后续需补 IOSurface 映射/同步）

## 7. Round 3：CoreImage `CIGaussianBlur` 端到端打通（`arm64` + `arm64e`）

### 7.1 实现改动
1. **Stitched library + `libxnu_m2v` extern/specialized function 接口**：
   - `src/xnu-m2v-bridge/include/xnu_m2v.h` 与 `src/xnu-m2v-bridge/src/lib.rs`：新增 `xm2v_library_extern_function_count`、`xm2v_library_extern_function_name_at`、`xm2v_library_new_extern_function`、`xm2v_library_new_function_specialized`，并重编 `arm64` + `arm64e` 双架构 `libxnu_m2v.dylib`。
   - `src/xnu-cpu-metal-bundle/XnuCpuMetalPlugin.mm`：实现 `newLibraryWithStitchedDescriptor:error:`（及 archive/async 重载），通过 `MTLCompiler.framework` 的 request 14（在 16 MiB 栈独立 pthread 上执行 `xcmCodeGenRequest`）把 CoreImage stitch graph 编译为 metallib，并实现 `externFunctionNames`、`newFunctionWithName:constantValues:error:`、`newFunctionWithDescriptor:error:` 与 `xcmExtractFunctionBitcode` / `xcmLookupCIKernelFunction`。
2. **IOSurface 纹理双向同步**：
   - `newTextureWithDescriptor:iosurface:plane:`（及 `slice:`）：内部强制 `MTLStorageModeShared` 创建纹理，`syncFromIOSurfaceIfNeeded` 按 `IOSurfaceGetSeed` 懒同步 CPU/IOSurface 写入到纹理；`XcmCommandBuffer` 记录 `_dirtyIOSurfaceTextures`，在命令提交完成后调用 `syncToIOSurface` 回写 IOSurface 内存。
   - 补齐 `_MTLDevice` 的内部 `limits` 结构体填充（`fillBaseLimits`）与 `iosurfaceTextureAlignmentBytes` / `linearTextureAlignmentBytes` / `readWriteTextureSupport` / `supportsSharedStorageTextures`。
3. **消除剩余桩调用**：
   - `XcmHeap`（`newHeapWithDescriptor:`，实现 `<MTLHeap>` 并代理分配到设备）
   - `setBackgroundGPUPriority:`、`isDrawable`、`protectionOptions`（command buffer 与 heap）、`GPUStartTime` / `GPUEndTime`、`globalTraceObjectID`。
4. **Mesa 26.3.1 `arm64e` gallivm JIT→C PAC 边界修复**：
   - Round 2 修复了 C→JIT 方向（`gallivm_jit_function` 对返回指针签名）；Round 3 跑 CoreImage 时发现 JIT→C 与 JIT→JIT 间接调用方向仍存在 PAC 签名未剥离问题（LLVM MCJIT 生成无 PAC 的 `blr`，跳转至 `arm64e` 签名指针触发 `SIGSEGV`，首次落点 `lp_texture_handle.c` 的 `get_size_function`）。
   - 修复（均受 `#if defined(__has_feature) && __has_feature(ptrauth_calls)` 保护，不影响 `arm64`）：
     - `src/gallium/drivers/llvmpipe/lp_texture_handle.c`：`compile_function` 返回的 JIT 纹理/图像采样函数表指针以及 `matrix->compile_{sample,fetch,size}_function` 均剥离 PAC。
     - `src/gallium/auxiliary/gallivm/lp_bld_const.c`（`lp_build_const_func_pointer_from_type`）、`lp_bld_format_aos.c`（`fetch_rgba_8unorm`）、`lp_bld_conv.c`（`_mesa_float_to_half`）、`lp_bld_init.c` & `lp_bld_init_orc.cpp`（`gallivm_add_global_mapping`）对传入 JIT 的 C 函数指针剥离 PAC。

### 7.2 验收实测结果（`arm64` + `arm64e`）
- `bash scripts/test-bundle.sh arm64`：`bad=0`，退出码 0。
- `bash scripts/test-bundle.sh arm64e`：`bad=0`，退出码 0。
- `bash scripts/test-render-ci.sh arm64`：
  - `Render pass status=4: center=(255,51,0,255) corner=(0,0,255,255) triPx=1352 bluePx=2744 otherPx=0`（PASS）
  - `CPU Metal (XnuCpuMetal (llvmpipe (LLVM 22.1.8, 128 bits))): center=(243,243,243,255) edge_2px_out=(148,148,148,255) corner=(0,0,0,120)`
  - `Native GPU (Apple M5 Max): center=(244,244,244,255) edge_2px_out=(157,157,157,255) corner=(0,0,0,137)`
  - `Pixel diff (64x64x4=16384 channels): maxErr=17, meanErr=2.4154, nonZeroDiff=6749`（PASS）
  - stderr `stubbed` 计数：**0**（除 `metal2vulkan` 精度说明外无任何其他输出）。
- `bash scripts/test-render-ci.sh arm64e`：
  - `Render pass status=4: center=(255,51,0,255) corner=(0,0,255,255) triPx=1352 bluePx=2744 otherPx=0`（PASS）
  - `CPU Metal (XnuCpuMetal (llvmpipe (LLVM 22.1.8, 128 bits))): center=(243,243,243,255) edge_2px_out=(148,148,148,255) corner=(0,0,0,120)`
  - `Native GPU (Apple M5 Max): center=(244,244,244,255) edge_2px_out=(157,157,157,255) corner=(0,0,0,137)`
  - `Pixel diff (64x64x4=16384 channels): maxErr=17, meanErr=2.4154, nonZeroDiff=6749`（PASS）
  - stderr `stubbed` 计数：**0**（除 `metal2vulkan` 精度说明外无任何其他输出）。

## 8. Round 4：macOS 27 设备发现机制静态分析与内核侧需求清单

### 8.1 macOS 27 `MTLCreateSystemDefaultDevice()` / `MTLCopyAllDevices()` 完整调用链（实机静态分析）
通过对宿主 macOS 27.0.1（26A434）的 `Metal.framework`、`IOGPU.framework`、`libsystem_sandbox.dylib` 反汇编与符号解析，确认设备发现完整路径如下：
1. **IORegistry 匹配**：`-[MTLIOAccelServiceGlobalContext init]` 调用 `IOServiceAddMatchingNotification(notifyPort, "IOServicePublish", IOServiceMatching("IOAccelerator"), ...)`，按 **IOKit 类名 `IOAccelerator`** 匹配（不是 `IOAcceleratorES`，后者为 iOS 专用）。
2. **读取的 IORegistry 属性**：
   - `getMetalPluginClassForService`（`Metal.framework`）与 `+[IOGPUMetalDevice registerAcceleratorService:]`（`IOGPU.framework`）均只读 2 个核心属性：
     - `MetalPluginName`（`CFString`，必填；若内部构建且设置了 `MTL_INTERNAL_BUNDLE`，会尝试 `%sInternal`）
     - `MetalPluginClassName`（`CFString`，可选；若缺失或未找到类，自动回退到 bundle 的 `NSPrincipalClass`）
   - `-[MTLIOAccelService initWithAcceleratorPort:deviceClass:]` 额外检查：
     - `IOObjectConformsTo(port, "IOServiceCompatibility")` — **必须为 false**（若为 true 直接丢弃返回 `nil`）
     - `IORegistryEntryGetRegistryEntryID(port, &rid)` + `IOServiceAddInterestNotification(notifyPort, port, "IOGeneralInterest", ...)`（普通 `IOService` 自带）
     - `"Removable"`（若 `_mtlAvoidRemovable()` 为真且属性为 true 则跳过）与 `"SafeEjectRequested"`
   - **`MetalStatisticsName`、`IOGLBundleName`、`IOGLESBundleName` 在 `MTLCreateSystemDefaultDevice()` / `MTLCopyAllDevices()` 路径中完全不读取**。
3. **Bundle 搜索目录与信任检查**（`libsystem_sandbox.dylib` `gpu_bundle_find_trusted`）：
   - 按顺序搜索 3 个目录（格式化为 `%s/%s.bundle`，须为目录 `S_IFDIR`）：
     1. `/Library/GPUBundles/<MetalPluginName>.bundle`（所有图形沙箱如 `system.sb` 均放行只读，推荐放此处）
     2. `/System/Library/Extensions/<MetalPluginName>.bundle`
     3. `/AppleInternal/Library/Extensions/<MetalPluginName>.bundle`（仅 internal build 允许非受信任路径）
   - 信任检查：`gpu_bundle_is_path_trusted(path)` 调用 `rootless_check_trusted_class(path, "KernelExtensionManagement")`，若返回 1 再回退 `_dyld_shared_cache_contains_path(path)`。托管环境关闭 SIP（`CSR_ALLOW_UNRESTRICTED_FS`）时 `rootless_check_trusted_class` 直接返回 0（受信任）。
4. **类校验与实例化**：
   - `Metal.framework` `getMetalPluginClassForService` 要求类 `[cls isSubclassOfClass:[_MTLDevice class]]`。
   - `IOGPU.framework` `+[IOGPUMetalDevice registerAcceleratorService:]` 要求类 `[cls isSubclassOfClass:[IOGPUMetalDevice class]]`（`IOGPUMetalDevice` 本身继承 `_MTLDevice`，我们的 `XnuCpuMetalDevice` 继承 `IOGPUMetalDevice`，两边同时满足）。
   - `-[MTLIOAccelService initWithAcceleratorPort:deviceClass:]` 调用 `[[cls alloc] initWithAcceleratorPort:port]` -> `[dev _setAcceleratorService:self]` -> `MTLAddDevice(dev)`。
5. **`IOServiceOpen` / User Client**：
   - `MTLCopyAllDevices` / `MTLIOAccelService` / `getMetalPluginClassForService` **全程不调用 `IOServiceOpen`**。
   - `IOServiceOpen(service, mach_task_self(), 5 | (options << 16), &connect)` 以及 `IOConnectCallStructMethod`（selector `2` 输出 536 字节、selector `0` 输出 64 字节）仅在 `IOGPU.framework` 的 `IOGPUDeviceCreateWithOptions` 中调用（由 `-[IOGPUMetalDevice initWithAcceleratorPort:options:]` 触发）。

### 8.2 插件无 User Client 验证
- `XnuCpuMetalDevice` 覆盖了 `-initWithAcceleratorPort:` 与 `-initWithAcceleratorPort:options:`，不调用 `super`，内部全部由进程内 Mesa lavapipe 完成；`port == 0` 时仅跳过 `IORegistryEntryGetRegistryEntryID` 使用默认 `registryID`。
- `nm -u dist/XnuCpuMetal.bundle/Contents/MacOS/XnuCpuMetal` 确认 **0 个 `IOServiceOpen` / `IOConnect*` / `IOGPUDevice*` 符号引用**；`test-bundle.sh arm64e` 以 `port=0` 实测 `bad=0`。

### 8.3 内核侧需求清单与最小 kext 草稿
- **父类与依赖 kext**：继承 `IOAccelerator`，来自 **`com.apple.iokit.IOGraphicsFamily`**（macOS 27.0.1 宿主 `kextstat` 已确认内置于 boot kernel collection，版本 `600`，`IOGPUFamily` 本身即依赖它；Apple Silicon 上未加载 `IOAcceleratorFamily2.kext`）。
- **必须发布的属性**：`MetalPluginName = "XnuCpuMetal"`、`MetalPluginClassName = "XnuCpuMetalDevice"`、`IOMatchCategory = "IOAccelerator"`（可选 `model`、`gpu-core-count`）。**绝不可**发布 `Removable` 或 `SafeEjectRequested`（哪怕设为 `false`，`-[MTLIOAccelService initWithAcceleratorPort:deviceClass:]` 仅检查属性存在即跳过设备），且不可继承 `IOServiceCompatibility`。
- **User Client**：**不需要**（默认 `IOService::newUserClient` 返回 `kIOReturnUnsupported` 即可）。
- **最小 kext 源码草稿**（全新编写，不依赖 PCI/DT 硬件节点，挂在 `IOResources` 上）：
  - `src/xnu-cpu-metal-kext/XnuCpuMetalAccelerator.hpp`
  - `src/xnu-cpu-metal-kext/XnuCpuMetalAccelerator.cpp`
  - `src/xnu-cpu-metal-kext/Info.plist`

## 9. Round 5：`ictool Stats.icon` 端到端出图打通（RenderBox + QuartzCore）

基于宿主 `gpub/src/xnu-cpu-metal-bundle/XnuCpuMetalPlugin.mm` 新基线，定位并修复了阻断 `ictool` → `icrtool`（RenderBox + QuartzCore）的全部问题：

### 9.1 根因与修复清单
1. **函数常量 UAF 与 `std::vector` 重分配悬垂指针（解决 `FunctionConstantType { index: 0 }` 与 `ColorAttachment { index: 1/2 }` / `VertexAttribute { attribute: 4 }`）**：
   - 原 `newFunctionWithName:constantValues:error:` 中 `std::vector<std::string> nameStorage` 在 `push_back` 时可能扩容导致已存入的 `c.name` 悬垂（60 个命名常量下触发 `FunctionConstantType { index: 0 }`）；且提取函数返回后 ARC 释放 `[constantValues copy]` 与 `named`/`indexed` 数组导致 `c.bytes` 成为 UAF 脏内存，使 QuartzCore 的 `fc_has_attachment_1/2 = false` 被读成 `true`。
   - 修复：改用 `std::deque<std::string>` + `std::deque<std::vector<uint8_t>>` 持久化拷贝常量名与字节，同时补齐 `xm2v_library_new_function_specialized_zero_rest`（`zeroRest` 重试）与缺失 `VertexAttribute`/`ColorAttachment` 的安全回退。修复后 `Stats.icon` 全部 11 条 RenderPSO 一次编译通过（0 次重试）。
2. **Linked Functions + 默认库/源码库覆盖（解决 `NeedsInput(LinkedFunction { symbol: "custom_fn" })`）**：
   - 补齐 `newDefaultLibrary`、`newDefaultLibraryWithBundle:error:`、`newLibraryWithSource:options:error:`（经 `MTLCompiler.framework` request 13）及异步重载（均加 `NS_RETURNS_RETAINED`），防止 `_MTLDevice` 默认实现返回 `_MTLFunctionInternal`。
   - `libxnu_m2v` 新增 `xm2v_library_new_function_with_descriptor`（传递 `specializedName`、`constantValues`、`options`）、`xm2v_compute_pipeline_new_with_linked` 以及 `Xm2vRenderPipelineDesc` 的 `vertex/fragment` public+private linked functions。
3. **VertexDescriptor、DepthStencil（前/背面 Stencil）、StencilRef 与 BlendColor**：
   - `Xm2vRenderPipelineDesc` 新增 `vertex_attributes` / `vertex_layouts` 透传到 `metal2vulkan::pipeline::VertexDescriptor`。
   - `Xm2vDepthStencilDesc` 新增 `front_face_stencil` / `back_face_stencil`，`XcmRenderEncoder` 接入 `xm2v_render_encoder_set_stencil_reference_values` 与 `xm2v_render_encoder_set_blend_color`。
4. **无有效 Pipeline 时安全空操作 + 异步 `commit` + 跨 `XcmTexture` 的 IOSurface 写后读同步**：
   - `XcmRenderEncoder` 跟踪 `_hasPipeline`，无有效 pipeline 时 `drawPrimitives*` / `drawIndexedPrimitives*` 安全空操作，不再崩溃。
   - `XcmCommandBuffer commit` 改为异步等待完成并触发 handlers 与 `syncToIOSurface`（消除多命令缓冲区事件等待 5s 死锁），并记录 `IOSurfaceID -> lastWriter`，在 `syncFromIOSurfaceIfNeeded` 中先等待已提交的写命令缓冲区完成再读 IOSurface（解决 RenderBox 跨 pass 复用同一 `IOSurface` 读到空白的问题）。
5. **消除剩余 stubbed 调用**：
   - 补齐 `XcmTexture` `protectionOptions` / `allocatedSize`、`XcmRenderEncoder` `memoryBarrierWithScope:afterStages:beforeStages:` / `memoryBarrierWithResources:...`、`XcmQueue` `setSubmissionQueue:` / `setCompletionQueue:`、`XcmCommandBuffer` `setProtectionOptions:` / `commitAndWaitUntilSubmitted`。

### 9.2 宿主复现与全量回归验收
- **宿主 `ictool Stats.icon` 复现**（`DYLD_INSERT_LIBRARIES=build/ic-repro/libforce_xcm.dylib` 强制走 `dist/XnuCpuMetal.bundle`，执行 `ictool Stats.icon --export-image --output-file build/ic-repro/test.png --platform macOS --rendition Default --width 16 --height 16 --scale 2`）：
  - 退出码 **`0`**，stderr 除 `metal2vulkan` 精度说明外 **0 行错误、0 行 `stubbed`**。
  - 与真 Mac 原生 GPU（Apple M5 Max）导出图 `build/stats_native.png` 逐像素比对（`32×32×4 = 4096` 通道）：
    - 原生 GPU：`nonZero=3944/4096, max=255, center=(64,144,255,255)`
    - CPU Metal：`nonZero=3944/4096, max=255, center=(50,123,237,255)`
    - 误差：**`meanErr=3.7783, maxErr=51`**（轮廓与红/蓝波形条完全一致）。
- **双架构回归全通过**：
  - `bash scripts/test-bundle.sh arm64` / `arm64e`：`bad=0`，退出码 0。
  - `bash scripts/test-render-ci.sh arm64` / `arm64e`：Render Pass PASS，CoreImage `CIGaussianBlur` 误差随常量 UAF 修复进一步降至 **`maxErr=1, meanErr=0.0161`**（`nonZeroDiff=264/16384`）！

---

## Round 6: `MTLArgumentEncoder` + `useResource(s):`（Stats `MenuBarIcon.icon` scale 1 & 2）

### 根因
- Stats 的 "Generate menu bar icon" 阶段将 `Stats.icon` 的 `fill` 改为线性渐变并把 `grid.svg` 替换为 `#D8D8D8` 后，分别以 `--scale 1` 和 `--scale 2` 调用 `ictool`。
- `--scale 2` 在 `ImageIO` 的 `-[HDRImageConverter_Metal encodeInputImage:transform:toBuffer:offset:withArgumentEncoder:computeEncoder:index:textures:]` 路径中调用 `-[XcmFunction newArgumentEncoderWithBufferIndex:]`；此前该函数被 `XnuCpuMetalShim.h` stub 返回 `nil`，导致 `[argEnc constantDataAtIndex:]` 返回 `NULL` 并在 `offset 0x20` 处 `SIGSEGV`（exit 139）。

### 修复
1. **Rust C ABI 桥（`src/xnu-m2v-bridge/include/xnu_m2v.h`、`src/xnu-m2v-bridge/src/lib.rs`）**：
   - 暴露 `metal2vulkan_runtime::ArgumentEncoder`：`xm2v_function_new_argument_encoder`、`xm2v_argument_encoder_release` / `encoded_length` / `alignment` / `set_argument_buffer` / `set_argument_buffer_array_element` / `set_buffer` / `set_texture` / `set_sampler` / `set_compute_pipeline` / `set_render_pipeline` / `constant_data` / `new_nested`。
   - 暴露 `xm2v_texture_gpu_resource_id`、`xm2v_sampler_gpu_resource_id`。
   - 暴露真实资源驻留接口：`xm2v_compute_encoder_use_buffer` / `xm2v_compute_encoder_use_texture` 与 `xm2v_render_encoder_use_buffer` / `xm2v_render_encoder_use_texture`（直连 `ComputeCommandEncoder::use_resource` 与 `RenderCommandEncoder::use_resource`）。
2. **ObjC 插件（`src/xnu-cpu-metal-bundle/XnuCpuMetalPlugin.mm`、`XnuCpuMetalShim.h`）**：
   - 新增 `XcmArgumentEncoder` 实现 `<MTLArgumentEncoder>`（并在 `XnuCpuMetalShim.h` 注册协议与参考类 `_MTLArgumentEncoder`），写入 texture 时自动触发 `syncFromIOSurfaceIfNeeded`。
   - `XcmFunction` 实现 `newArgumentEncoderWithBufferIndex:` 与 `newArgumentEncoderWithBufferIndex:reflection:`。
   - `XcmComputeEncoder` 与 `XcmRenderEncoder` 的 `useResource:` / `useResources:` 接入真实 `xm2v_*_use_buffer` / `use_texture`，并同步处理 IOSurface 读写（读前 `syncFromIOSurfaceIfNeeded`，写后 `markDirtyIOSurfaceTexture:`）。
   - `XcmTexture` / `XcmSampler` 暴露 `gpuResourceID`；`XcmBackendDevice` 暴露 `argumentBuffersSupport`（`MTLArgumentBuffersTier2`）。

### 验证结果（通用 `arm64 + arm64e` `dist/XnuCpuMetal.bundle`）
- **Modified `MenuBarIcon.icon`（`build/ic-repro/MenuBarIcon.icon`）**：
  - `--scale 1`：`EXIT=0`，无任何 `stubbed` / 错误日志；`16×16` `nonZero=1008/1024`，对比原生 GPU `MenuBarIcon1_native.png`：`maxErr=42, meanErr=7.8740`。
  - `--scale 2`：`EXIT=0`，无任何 `stubbed` / 错误日志；`32×32` `nonZero=3968/4096`，对比原生 GPU `MenuBarIcon2_native.png`：`maxErr=38, meanErr=4.3428`。
- **全量回归**：
  - `bash scripts/test-bundle.sh arm64` / `arm64e`：`vecadd N=1024, status=4, completedHandler=1, bad=0`。
  - `bash scripts/test-render-ci.sh arm64` / `arm64e`：Render Pass PASS，CoreImage `CIGaussianBlur` PASS（`maxErr=1, meanErr=0.0161, nonZeroDiff=264/16384`）。
  - Plain `Stats.icon` `--scale 2`：`EXIT=0`，无 `stubbed` 日志；`32×32` `nonZero=3944/4096`，对比 `build/stats_native.png`：`maxErr=51, meanErr=3.7783`。

---

## Round 7: 性能、资源占用与多项目 macOS CI 用例基线/优化

### 约束与测量方式
- 宿主机 Apple M5 Max（macOS 27.0.1），使用 `taskpolicy -c utility` + `RAYON_NUM_THREADS=1` + `LP_NUM_THREADS=1`（优化前）/ `LP_NUM_THREADS=0`（优化后，单核内联执行、无额外 worker 线程）模拟单核托管 VM 与多 VM 并发 CI 环境。
- 所有改动均基于 `xnulinux` commit `04d3386`（`gpu/xnu-cpu-metal/`），未修改任何 GPL/LGPL 上游源码。

### 性能剖析排序（`icrtool` WARM，200Hz `SIGPROF` PC 采样，3,600 samples）
1. **Mesa `llvmpipe` LLVM JIT 编译（~97%）**：`59.4%` LLVM (`SpillPlacement`, `ScheduleDAGSDNodes`, `RAGreedy`, `InterferenceCache`) + `13.5%` `memmove`/`memset` + `13.0%` `madvise` + `11.1%` `malloc`（根因：`build-lavapipe*.sh` 此前传了 `-Dshader-cache=disabled`，每次进程启动都从零重编译所有 LLVM JIT 着色器，并产生 500–700 MB 临时峰值 RSS）。
2. `lavapipe` 其余 + `dyld`：`2.7%`
3. `metal2vulkan` AIR→SPIR-V 翻译：`0.1%`（热运行已命中磁盘缓存；冷运行约占 ~14s）
4. `llvmpipe` JIT 光栅化/计算执行：`< 0.1%`
5. IOSurface 同步拷贝 / `XnuCpuMetal` 插件 / command buffer 等待：`< 0.1%`

### 实施的优化（4 文件，+91/-20 行）
1. **启用 Mesa `llvmpipe` 持久化 LLVM JIT 磁盘缓存**：`scripts/build-lavapipe.sh` 与 `scripts/build-lavapipe-arm64e.sh` 改为 `-Dshader-cache=enabled -Dshader-cache-max-size=256M`（arm64 与 arm64e 均生效，ORC JIT `LPObjectCacheORC` 直接复用 `gallivm_jit_function` PAC 签名）。
2. **Root/CI 安全的缓存目录与多 VM 并发默认上限**（`XnuCpuMetalPlugin.mm`、`lib.rs`）：
   - 缓存目录按 `XNU_CPU_METAL_CACHE_DIR` → `_CS_DARWIN_USER_CACHE_DIR` → `/var/tmp/xnu-cpu-metal-<uid>` → `/tmp/xnu-cpu-metal-<uid>` 回退并校验可写（适配 root 托管环境）。
   - 默认设置 `MESA_SHADER_CACHE_DIR=<cacheDir>/mesa`、`MESA_SHADER_CACHE_MAX_SIZE=256M`（均可由环境变量覆盖）。
   - `metal2vulkan` 缓存上限从默认 `25 GiB` 磁盘 / `256 MiB` 内存收紧为 `512 MiB` 磁盘 / `32 MiB` 内存（可通过 `XNU_CPU_METAL_CACHE_MAX_MB`、`XNU_CPU_METAL_MEM_CACHE_MB` 覆盖）。
   - `LP_NUM_THREADS` 默认值：`hw.ncpu <= 1` 时为 `0`（内联执行、零额外 worker 线程），多核时上限为 `2`（多 VM 友好，可由 `LP_NUM_THREADS` 覆盖）。
3. **修复 `VK_ICD_FILENAMES` / `VK_DRIVER_FILES` 环境变量污染**（`lib.rs`）：`xm2v_device_open` 打开设备后恢复原环境变量，避免同进程内 Chromium SwANGLE 被劫持到无 `VK_EXT_metal_surface` 的 lavapipe ICD。
4. **修复 `XcmCommandBuffer _fireHandlersOnce` 竞态**（`XnuCpuMetalPlugin.mm`）：在 `@synchronized(self)` 内执行 `completedHandler`，防止缓存加速后 `waitUntilCompleted` 早于后台回调返回。

### 优化前后对比（单核约束，含多项目 CI 简化用例）
| 用例 | 来源 CI | 兼容性（vs 原生 GPU） | 优化前 Wall / User / Peak RSS | 优化后 Wall / User / Peak RSS | 提升 |
|---|---|---|---|---|---|
| `ictool Stats.icon --scale 2` (COLD) | Stats / Cue / AFFiNE | PASS (`maxErr=51, meanErr=3.7783`) | 61.72s / 24.30s / 893 MB | 33.75s / 24.86s / 1158 MB | Wall **1.83x** |
| `ictool Stats.icon --scale 2` (WARM1 → WARM2 → 稳态) | Stats / Cue / AFFiNE | PASS (`maxErr=51, meanErr=3.7783`) | 47.69s / 25.79s / 918 MB | 11.19s → 5.04s → **1.21s** / **1.09s** / 781–980 MB | Wall **4.3x → 39.4x**，CPU **23.7x** |
| `ictool MenuBarIcon.icon --scale 1` (WARM) | Stats | PASS (`maxErr=42, meanErr=7.8740`) | — | **1.22s** / 1.15s / 983 MB | 零 `stubbed` |
| `ictool MenuBarIcon.icon --scale 2` (WARM) | Stats | PASS (`maxErr=38, meanErr=4.3428`) | — | **2.35s** / 2.15s / **534 MB** | 零 `stubbed` |
| `CIGaussianBlur` 64×64 (WARM) | CoreImage | PASS (`maxErr=1, meanErr=0.0161`) | 0.45s (render 250.3ms) / 0.36s / 276 MB | **0.32s (render 108.6ms)** / 0.22s / **257 MB** | render **2.30x**，RSS -19 MB |
| `vecadd` 1M floats (WARM) | Compute | PASS (`bad=0`) | 0.16s (exec 9.5ms) / 0.14s / 179 MB | 0.22s / 0.15s / **160 MB** | RSS **-19 MB** |
| `mbui_offscreen` 800×600×5f (WARM) | `AFK-surf/monoid` (`mbui`) | PASS (`maxErr=2, meanErr=0.0784`) | 0.31s (render 65.7ms) / 0.25s / 195 MB | **0.23s (render 28.4ms)** / 0.17s / **186 MB** | render **2.31x**，RSS -9 MB |
| `gpui_offscreen` 800×600×5f (WARM) | `longbridge/gpui-component` | PASS (`maxErr=1, meanErr=0.0001`) | 0.25s (render 57.3ms) / 0.21s / 196 MB | **0.20s (render 24.0ms)** / 0.16s / **180 MB** | render **2.39x**，RSS -16 MB |
| `actool` minimal `.xcassets` | Cue / AFFiNE / monoid | PASS (21,720 B 完全一致) | 0.31s / 0.00s / 2.5 MB | 0.31s / 0.00s / 2.5 MB | 无回归 |
| Playwright Chromium headless Metal (`400×300`) | Cue / AFFiNE | PASS (`maxErr=2, meanErr=0.2256`) | SwANGLE 因 `VK_ICD_FILENAMES` 污染报错 | **零 SwANGLE/Vulkan 报错**，12.07s / 2.00s / 298 MB | 兼容性修复 |
| 空闲占用 (`idle_probe`, 3s idle) | 多 VM 并发 | 0.0% 空闲 CPU | RSS 160.5 MB / phys 98.9 MB / 14 线程 / 0.000s CPU | RSS **157.5 MB** / phys 101.7 MB / **13 线程** / **0.000s CPU** | 零空闲线程耗电 |

### 明确不做项及原因
- **不默认开启 `GALLIVM_PERF=no_opt`**：实测虽可降冷编译 ~40%，但使热渲染慢 **2.9x–3.1x**（`CIGaussianBlur` 108.6→316.0ms、`mbui` 28.4→87.6ms、`gpui` 24.0→73.5ms）；配合磁盘缓存一次编译 `-O2` 复用显著更优。
- **不做零拷贝 IOSurface Vulkan 导入**：剖析显示 IOSurface 同步耗时 `< 0.1%`，800×600×5 帧 `gpui` 含 IOSurface 仅 24ms（4.8ms/帧）；lavapipe 导入 IOSurface 需要线性布局与 `VK_EXT_external_memory_host`，与 `metal2vulkan-runtime` 的 tiled/shadowed 纹理模型冲突且收益微弱。
- **不改 `metal2vulkan-runtime` 64 MiB 内存 slab（`BLOCK_BYTES`）**：`metal2vulkan` 属 GPL/LGPL 上游（构建时拉取、不入库）；我们在自研桥接层收紧了 `ShaderCacheOptions` 内存/磁盘上限。
- **不做 commit 去阻塞 / 无管线 draw 跳过**：插件此前已异步 `commit` 且已跳过 `!_hasPipeline` 的 draw。

---

## Round 8: WindowServer / SkyLight Metal 设备筛选分析与合成器适配

### SkyLight 静态反汇编证据（macOS 27.0.1 dyld cache `SkyLight.framework`）
1. **`__WSSystemCanCompositeWithMetal_block_invoke` (`SkyLight @ 0x19365f508`)**：
   - `+0x088`: `BL MTLCopyAllDevicesWithObserver(&observer, handler)`（observer block 在 `+0x1e0` 检查 `MTLDeviceWasAddedNotification`）。
   - `+0x090`: `BL objc_msgSend("count")`；`+0x094`: `cbz x0, +0x0a4`。
   - **此处本身没有任何设备属性过滤**——只要 `[devices count] == 0`，就记录 `"Metal device initially absent."`（`+0x0c8`），在 `dispatch_semaphore_wait` 上等 30 秒，超时后记录 `"No suitable Metal devices present after %llu seconds."`（`+0x168`）并 `abort()`。
   - **托管系统 WindowServer 触发该错误的直接根因**：commit `04d3386` 的插件在 `confstr(_CS_DARWIN_USER_CACHE_DIR)` 失败时回退到共享路径 `/tmp/xnu-cpu-metal-m2v`；先前以 `root` (uid=0) 运行时 `metal2vulkan` `ShaderCache` 以 `0700` 创建了该目录，随后 `WindowServer` 以 `_windowserver` (uid=88) 启动时 `ShaderCache::open` 报 `PermissionDenied` → `xm2v_device_open` 返回 `NULL` → `initWithAcceleratorPort:` 返回 `nil` → `MTLCopyAllDevicesWithObserver` 返回空数组 (`count == 0`)。
2. **通过 `WSSystemCanCompositeWithMetal` 后 SkyLight 紧接着检查的接口**：
   - `__WSGetDefaultMetalAccelerator_block_invoke` (`0x19366a14c`)：`MTLCopyAllDevices` → `firstObject` → `acceleratorPort`（必须非 0）。
   - `CompositorMetal::new_compositor` (`0x193663944`)：`acceleratorPort`、`isRemovable` (`NO`)、`supportPriorityBand` (`NO`)、`MPSSupportsMTLDevice` (`YES`)、`registryID`、`compilerPropagatesThreadPriority:`、队列 `setCompletionQueue:` / `setSubmissionQueue:` / `setGPUPriority:`。
   - `SLSCreateDefaultMetalDevice` (`0x19387fc08`)：`acceleratorPort`、`isLowPower`。

### 插件修改（`XnuCpuMetalPlugin.mm`、`XnuCpuMetalShim.h`）
1. **Per-UID 真实可写探测的缓存目录回退**：按 `XNU_CPU_METAL_CACHE_DIR` → `_CS_DARWIN_USER_CACHE_DIR` → `_CS_DARWIN_USER_TEMP_DIR` → `NSTemporaryDirectory()` → `/var/tmp/xnu-cpu-metal-<uid>` → `/tmp/xnu-cpu-metal-<uid>` 逐级用实际 `open(O_CREAT|O_WRONLY)` 探测可写性，杜绝 uid=0 与 uid=88 (`_windowserver`) 互锁；打开失败时同步写入 `os_log_error`。
2. **对齐 DroidVM WindowServer 设备属性与 IOSurface 策略**：
   - `isHeadless = NO`、`isLowPower = NO`（原为 `YES`/`YES`），保持 `isRemovable = NO`、`hasUnifiedMemory = YES`、`isBuiltIn = YES`。
   - 启动时设置 `CFPreferencesSetAppValue(CFSTR("CAEnableIOSurfaceCompression"), kCFBooleanFalse, kCFPreferencesCurrentApplication)`，确保 QuartzCore/WindowServer 分配线性未压缩 IOSurface。
3. **补齐 WindowServer 合成器接口**：
   - `XnuCpuMetalShim.h` 新增设备 `compilerPropagatesThreadPriority:` 与队列 `setCompletionQueue:` / `setSubmissionQueue:`（消除 `CompositorMetal::new_compositor` 的 stub 警告）。
   - `XcmTexture` 多平面 IOSurface 同步增加 `plane < planeCount` 越界保护，并将 `_iosurface` / `_iosurfacePlane` 传递到 `newTextureViewWithPixelFormat:` 视图纹理（支持对 IOSurface 的 sRGB/格式视图渲染回写）。

### 宿主机验证结果（通用 `arm64 + arm64e` `XnuCpuMetal.bundle`）
- `test_ws_full`：`isHeadless=0, isLowPower=0, isRemovable=0, hasUnified=1, MPSSupportsMTLDevice=1`；2-plane YCbCr `420v` IOSurface (`R8Unorm` + `RG8Unorm`) 读写 PASS；`MPSImageGaussianBlur` + `setCompletionQueue:`/`setSubmissionQueue:` PASS（`status=4, center=(229,229,229,229)`）。
- 全量回归全部 PASS：`test-bundle.sh arm64/arm64e` (`bad=0, completedHandler=1`)、`test-render-ci.sh arm64/arm64e` (`CIGaussianBlur maxErr=1, meanErr=0.0161`)、`ictool Stats.icon` (`maxErr=51`)、`MenuBarIcon.icon` scale 1 & 2 (`maxErr=42/38`)、`mbui_offscreen` (`maxErr=2`)、`gpui_offscreen` (`maxErr=1`)，全部零 `stubbed`。

---

## Round 9: Vulkan-Loader secure-mode ICD 自包含加载 + `&BGA`/`&RhA`/`&b3a` 压缩 IOSurface 线性处理

### 修改内容
1. **彻底消除 `VK_ICD_FILENAMES` 环境变量依赖与构建目录 `sysconfdir` 硬编码**：
   - `scripts/build-vkloader-arm64e.sh` 改为同时构建 `arm64` 与 `arm64e` 两个 slice，并传入 `-DSYSCONFDIR=/Library/GPUBundles/XnuCpuMetal.bundle/Contents/Resources`。
   - `scripts/build-bundle-universal.sh` 将双架构 `libvulkan.1.dylib` 合并进 bundle，并在 bundle 内放入 `Contents/Resources/vulkan/icd.d/lvp_icd.aarch64.json`（`library_path: "../../../Frameworks/libvulkan_lvp.dylib"`）。在 `WindowServer` 等高权限/secure 模式下，Vulkan-Loader 自动搜索 `<SYSCONFDIR>/vulkan/icd.d` 并加载 bundle 内的 lavapipe，无需环境变量也无需在 `/usr/local/share/vulkan/icd.d` 写外部清单。
   - `strings` 验证 `libvulkan.1.dylib` 中零 `/Users/admin` 硬编码路径，仅含 `/Library/GPUBundles/XnuCpuMetal.bundle/Contents/Resources`。
2. **`&BGA` / `&RhA` / `&b3a` / `b3a8` 压缩 IOSurface 格式的线性处理**（`XnuCpuMetalPlugin.mm`）：
   - 新增 `xcmPixelFormatBpp`（含 `BGRA10_XR` 8 Bpp）与 `xcmIOSurfacePlaneLayout`，在 `syncFromIOSurfaceIfNeeded` / `syncToIOSurface` 中统一将 `&` 开头的无损压缩 IOSurface 按线性未压缩行读取/回写；针对 `b3a8`/`&b3a` 双平面 `IOSurfaceGetBytesPerRowOfPlane == 0` 情形按 64B 对齐自动计算双平面偏移与 stride（并做 `allocSize` 越界保护）。
   - `XcmTexture` 的 `replaceRegion:` 与 `getBytes:` 同步补齐 IOSurface 双向同步。

### 验证结果
- 端到端 `&BGA` (1280×720, `bpr=5120`)、`&RhA` (`RGBA16Float`)、`&b3a` (`BGR10_XR`) 渲染 + 采样 + Blit + IOSurface 线性回读测试 (`test_compressed_full`)：**全部 PASS**（线性 BGRA 精确匹配 `(204,153,51,255)`）。
- 全量 `arm64` + `arm64e` 回归（`test-bundle.sh`、`test-render-ci.sh`）：**全部 PASS**（`vecadd bad=0, completedHandler=1`；Render Pass PASS；CoreImage `CIGaussianBlur maxErr=1, meanErr=0.0161`）。

---

## Round 10: Buffer-Backed Linear Textures + `MTLSharedEvent`/`MTLFence` + 内存态 `CAEnableIOSurfaceCompression`

### 根因分析（QuartzCore macOS 27.0.1 dyld cache 静态反汇编）
1. **`nil linear texture from buffer`**：`CA::OGL::MetalContext::copy_image_to_texture` 将客户端共享内存 backing store 通过 `newBufferWithBytesNoCopy:length:options:deallocator:` 包装为 `MTLBuffer` 后，调用 SPI `-[MTLBuffer newLinearTextureWithDescriptor:offset:bytesPerRow:bytesPerImage:]`。此前 `XcmBuffer` 未实现该 SPI（被 `resolveStub` 桩返回 `0`），且 `newTextureWithDescriptor:offset:bytesPerRow:` 忽略 `offset`/`bytesPerRow` 新建了独立纹理。
2. **`timed out fence` + `Command buffer failed (Error code = 0x1)`**：`XcmBackendDevice` 缺失 `newSharedEvent` / `newSharedEventWithOptions:` / `newSharedEventWithHandle:`，`XcmCommandBuffer` 的 `encodeSignalEvent:`/`encodeWaitForEvent:` 仅处理 `XcmEvent` 未处理 `MTLSharedEvent`，三类 Encoder 缺失 `updateFence:`/`waitForFence:`，且 `XcmCommandBuffer.error` 硬编码 `"Command buffer failed"` 未透出底层 `metal2vulkan` 失败原因。
3. **非持久化 `CAEnableIOSurfaceCompression`**：`CFPreferencesSetAppValue` 会把偏好落盘到各 App 的 plist。反汇编 `__CADeviceUseCompression_block_invoke` 确认 QuartzCore 调用 `CFPreferencesGetAppBooleanValue`，改用 `[[NSUserDefaults standardUserDefaults] registerDefaults:@{@"CAEnableIOSurfaceCompression": @NO}]` 仅在内存 `NSRegistrationDomain` 生效，绝不落盘。

### 修改内容
- **`src/xnu-m2v-bridge/include/xnu_m2v.h` & `src/lib.rs`**：
  - 导出 `xm2v_buffer_new_no_copy_dealloc`（支持 `Deallocator` 回调）、`xm2v_buffer_new_texture`、`xm2v_buffer_new_linear_texture`（直接对接 `metal2vulkan_runtime::Buffer::new_texture` / `new_linear_texture`，原生别名共享内存并在需要时自动走 `shadowed-texture` 双向同步）。
  - 导出完整 `Xm2vSharedEvent` / `Xm2vSharedEventHandle` C ABI（`new`、`new_with_handle`、`signaled_value`、`set_signaled_value`、`wait_until`、`notify`、`new_handle`）及 `xm2v_command_buffer_encode_{signal,signal_scheduled,wait}_shared_event`。
  - 导出 Compute/Render/Blit Encoder 的 `update_fence` / `wait_fence` 与 `xm2v_command_buffer_error`（透出 `cb.error()` / `cb.refusal()` / `cb.error_description()`）。
- **`src/xnu-cpu-metal-bundle/XnuCpuMetalPlugin.mm` & `XnuCpuMetalShim.h`**：
  - 实现 `-[XcmBuffer newTextureWithDescriptor:offset:bytesPerRow:]` 与 `-[XcmBuffer newLinearTextureWithDescriptor:offset:bytesPerRow:bytesPerImage:]`，在 `XcmTexture` 上维护并透传 `buffer` / `bufferOffset` / `bufferBytesPerRow`；`newBufferWithBytesNoCopy:` 完整透传 `deallocator`。
  - 新增 `XcmSharedEvent`（声明遵循 `MTLSharedEvent`/`MTLEvent`，参考类 `IOGPUMetalSharedEvent`）与 `XcmSharedEventHandle`，支持 `MTLSharedEventListener` 在其 `dispatchQueue` 异步回调；补齐 `XcmCommandBuffer` 事件编码与 `os_log_error` 详细错误日志、三类 Encoder 的 `MTLFence` 编码。
  - 将 `CFPreferencesSetAppValue` 替换为纯内存 `NSUserDefaults registerDefaults:`。

### 宿主机验证结果（通用 `arm64 + arm64e` `XnuCpuMetal.bundle`）
- **`test_round10`（`arm64` & `arm64e` 双架构全部 PASS）**：
  - `CAEnableIOSurfaceCompression` 通过 `CFPreferencesGetAppBooleanValue` 读到 `valid=1, val=0` 且无任何 plist 落盘。
  - WindowServer 日志全部 4 种线性纹理规格（`84x103 bpr=192 o=0`、`234x18 bpr=960 o=0x100`、`256x1 bpr=2048 o=0`、`1x1 bpr=64 o=0x100 bpi=4`）均成功创建并校验 `buffer`/`bufferOffset`/`bufferBytesPerRow` 与 `deallocator` 调用；CPU 原地覆写共享内存（`0xff112233` → `0xff44cc88`）不重建纹理，GPU Shader 连续两帧渲染结果精确一致。
  - `MTLSharedEvent` GPU signal → `MTLSharedEventListener` 回调及时触发、CPU `setSignaledValue:` 解除 GPU `encodeWaitForEvent:` 阻塞、`newSharedEventHandle`/`newSharedEventWithHandle:` 别名与 `MTLFence` 均 PASS。
- **全量回归（`arm64` & `arm64e`）**：`test-bundle.sh`、`test-render-ci.sh`（Render Pass + `CIGaussianBlur maxErr=1, meanErr=0.0161`）、`test_compressed_full`（`&BGA`/`&RhA`/`&b3a`）全部 PASS。

---

## Round 11: 修复 QuartzCore `VfxXg/Xgc` 合成全黑（`minConstantBufferAlignmentBytes` 环缓冲归零 + `isFramebufferReadSupported`）

### 根因定位（宿主机 `CARenderer rendererWithMTLTexture:options:` 复现 + `QuartzCore` 反汇编）
用 `CARenderer` 对比本插件与 Apple M5 Max 原生 Metal，在 `rounded_only` 与 `rounded_shadow` 场景中稳定复现全黑/大面积 `(0,0,0,0)`，并定位到两个耦合的设备能力缺口：
1. **`minConstantBufferAlignmentBytes` 返回 `0` 导致 `MetalBufferPool` 环缓冲偏移归零覆写**：
   - 反汇编 `CA::OGL::MetalBufferPool::encode_vertex_arg`（`+0x3c..+0x58`）确认其用 `align = max(req_align, pool->min_alignment)` 计算对齐偏移 `aligned = (cur + align - 1) & (-align)`。
   - 当 `VfxXg/Xgc` 编码 0 字节占位参数（`req_align = 0`）且 `_MTLDevice` limits 中 `minConstantBufferAlignmentBytes == 0` 时，`align = 0`，`aligned = (cur - 1) & 0 = 0`，导致 `pool->current_offset` 在同一个 RenderPass 中被重置为 `0`，后续 draw 直接从偏移 `0` 覆写同一个 256 KiB 缓冲，摧毁前面所有 draw 的顶点、索引和颜色常量。
2. **`isFramebufferReadSupported` 返回 `NO` 导致 `VfxXg/Xgc` 混合输出 `(0,0,0,0)`**：
   - `VfxXg/Xgc`（`fixed_vert_lph_gen` + `fixed_frag_lph_cpf`）是 QuartzCore 的通用 uber-shader，其管线固定为 `blend=0` 并依赖 `[[color(0)]]` 可编程混合（`fc_framebuffer_fetch = Bool 01`）。此前插件未返回 `isFramebufferReadSupported = YES`，导致 QuartzCore 以 `fc_framebuffer_fetch = Bool 00` 且 `blend=0` 编译 `Xgc`，所有半透明/圆角/阴影/窗口合成 draw 均输出 `(0,0,0,0)`。开启后 `metal2vulkan-runtime` 通过 lavapipe 的 `rasterizationOrderColorAttachmentAccess` 精确执行 framebuffer fetch。

### 修改内容（`src/xnu-cpu-metal-bundle/XnuCpuMetalPlugin.mm`）
- 在 `fillBaseLimits` 补齐缺失的对齐字段：`minConstantBufferAlignmentBytes = 4`、`minBufferNoCopyAlignmentBytes = 4096`、`linearTextureArrayAlignmentBytes = 16`、`linearTextureArrayAlignmentSlice = 128`、`maxComputeThreadgroupMemoryAlignmentBytes = 16`、`linearTextureAlignmentBytes = 64`。
- 在 `XcmBackendDevice` 补齐 `isFramebufferReadSupported = YES`、`supportsProgrammableBlending = YES`、`supportsUnalignedVertexFetch = YES`，并在 `supportsFamily:` 放行 `Apple1..2` / `Mac1..2` / `Common1..3`。
- 在 `XNU_CPU_METAL_TRACE=1` 下新增每次 `renderCommandEncoderWithDescriptor:`（`c0`、load/store/clear、depth/stencil）、`newRenderPSO`（`blend` 参数与 `writeMask`）、`drawPrimitives`/`drawIndexedPrimitives`（图元类型、顶点数、绑定的 `vb`/`fb`/`ft`/`fs` 掩码、`fbytes`、`viewport`、`scissor`）及 `cb-done` 状态日志。

### 宿主机验证结果（通用 `arm64 + arm64e` `XnuCpuMetal.bundle`）
- **`CARenderer` 对比 Apple M5 Max（`build/test_carenderer.mm`，`arm64` & `arm64e` 双架构全部 PASS，覆盖 `VfxXg/Xgc` 路径）**：
  - `color`（纯红 backgroundColor）：`maxErr=0, meanErr=0.000`
  - `image`（四象限 CGImage）：`maxErr=0, meanErr=0.000`
  - `two_layers`（双层叠加）：`maxErr=0, meanErr=0.000`
  - `rounded_only`（圆角 layer，触发 `VfxXg/Xgc`）：`maxErr=1, meanErr=0.000`
  - `rounded_shadow`（圆角 + 阴影，多 pass 模糊 + `VfxXg/Xgc`）：`maxErr=3, meanErr=0.092`
- **全量回归（`arm64` & `arm64e`）**：`test_round10`、`test-bundle.sh`、`test-render-ci.sh`、`test_compressed_full` 全部 PASS。

---

## Round 12: `XcmCommandBuffer` / Encoder 并发资源生命周期与线程安全加固（`iconservicesagent` 崩溃排查）

### 审计发现与修复（`src/xnu-cpu-metal-bundle/XnuCpuMetalPlugin.mm`）
1. **Encoder 资源过早释放（违反 `retainedReferences = YES`）**：
   - 此前 `XcmRenderEncoder`、`XcmComputeEncoder`、`XcmBlitEncoder` 在 `endEncoding` 时立刻清空 `_retained`，且 `renderCommandEncoderWithDescriptor:` 未强引用非 IOSurface 的 color/depth/stencil attachment 纹理，导致调用方在 `endEncoding` + `commit` 后立即释放 `XcmBuffer`（含 `_fallbackDeallocator`）或 `XcmTexture` 时，对象可能在 GPU（`llvmpipe` 光栅化线程）仍在执行期间提前 `dealloc`。
   - 修复：在 `XcmCommandBuffer` 新增 `_retainedResources` 与 `retainResource:`（`@synchronized(self)` 保护），将三类 Encoder 绑定资源、RenderPass attachment 纹理与 Event 全部挂到 `XcmCommandBuffer`，仅在 `wait_until_completed` + IOSurface 同步 + handlers 完成后于锁外 `_releaseRetainedResourcesOnce` 释放。
2. **`XcmCommandBuffer` 并发竞争与 Handler 顺序保证**：
   - `addScheduledHandler:`、`addCompletedHandler:`、`markDirtyIOSurfaceTexture:`、`commit`（`_committed` 防重入）全部加 `@synchronized(self)` 保护。
   - `_fireHandlersOnce` 在锁内快照清空回调列表，**锁外**执行用户回调避免死锁，同时用 `dispatch_group_t`（带同线程重入检测）保证任意并发调用 `waitUntilCompleted` 的线程在所有 completed handler 执行完之前绝不提前返回。
3. **`XcmTexture` IOSurface 并发同步与类型校验**：
   - `syncFromIOSurfaceIfNeeded`（先 `xcmFlushIOSurfaceWriter` 再取 `@synchronized(self)`，保持严格锁序 `XcmCommandBuffer -> XcmTexture`）与 `syncToIOSurface` 加 `@synchronized(self)` 保护；`gIOSurfaceLastWriter` 超过 256 项时自动清理失效 `__weak` 项。
   - 三类 Encoder 对 buffer/texture/sampler/depthStencil/pipeline 参数补齐 `isKindOfClass:` 校验，避免非法对象强转解引用 `_handle`。

### 验证结果（通用 `arm64 + arm64e` `dist/XnuCpuMetal.bundle`）
- **新增多线程并发压测**（`build/test_stress_mt.mm`，`arm64` & `arm64e`，`LP_NUM_THREADS=2` 与 `LP_NUM_THREADS=0`）：
  - Phase 1（8 线程 × 60 = 480 次并发 `commit` + IOSurface + `addCompletedHandler:` + 交替 `waitUntilCompleted` + 立即释放）：`submitted=480 handlers=480 failures=0`
  - Phase 2（4 线程 × 15 = 60 次并发 `CARenderer` 含圆角阴影）：`caDone=60 failures=0`
  - Phase 3（4 线程 × 40 = 160 次 `newBufferWithBytesNoCopy:` + `munmap` deallocator + `commit` 后立即释放）：`noCopyDone=160 deallocCount=160 failures=0`
  - Phase 4（40 轮双线程并发 `waitUntilCompleted` 与 `completedHandler` 完成顺序及单次触发校验）：`failures=0`
  - 4 进程并发 `ictool MenuBarIcon.icon`：全部退出 0 且输出一致（`114801` 字节）。
- **全量回归（`arm64` & `arm64e`）**：
  - `test_carenderer`（5 项对比 Apple M5 Max）、`test_round10`（4/4 PASS）、`test-bundle.sh`（`bad=0`）、`test-render-ci.sh`（`CIGaussianBlur maxErr=1, meanErr=0.0161`）全部 PASS。

---

## Round 13: Safari 打开时 `WindowServer` `GpuHang` → `AccessRevoked` → `llvmpipe_draw_vbo` UAF `SIGSEGV` 与 0 长度 NoCopy 修复

### 根因
1. **CPU 设备套用了 20.2s 硬件 GPU watchdog**：`metal2vulkan-runtime/src/command_buffer/stall.rs` 对所有设备硬编码 `WATCHDOG = 20.2s`、`STALL = 10s`。Safari 启动时 CPU 光栅化 + LLVM JIT 负载骤增，单批超过 20.2s 即被判 `GpuHang` 并 park `VkDevice`；累计 2 次后触发 `revocation.rs`（`REVOKING = 2`）永久吊销队列，后续提交全部 `AccessRevoked`。
2. **Parked 设备仍执行 host memory deallocator 导致 `llvmpipe_draw_vbo` 顶点 fetch UAF**：`VkDevice` 被 park 后 `release::object` 跳过 `vkFreeMemory`，但 `metal2vulkan-runtime/src/buffer.rs` 的 `Imported::drop` 与 `HostPages::drop` 仍会执行调用方的 `deallocator`（`munmap`），且 `XcmCommandBuffer` 仍释放 `_retainedResources`，导致 `lavapipe` 后台线程执行 `llvmpipe_draw_vbo` 读取已取消映射的页边界（`0x...c000`）而 `SIGSEGV`。同时 `XcmCommandBuffer` 的 `wait_until_completed` 存在 60s 硬超时。
3. **`newBufferWithBytesNoCopy(ptr=0, len=0)` 语义偏差**：实测宿主机 Apple M5 Max 上 `newBufferWithBytesNoCopy(NULL, 0)`、`newBufferWithLength(0)`、`newBufferWithBytes(NULL, 0)` 均直接返回 `nil` 且不调用 `deallocator`；原插件会报错并回退到 `xm2v_buffer_new(..., 0, ...)`。

### 修复
1. `src/metal2vulkan/crates/metal2vulkan-runtime/src/command_buffer/stall.rs`：对 `DeviceKind::Cpu` 将 `watchdog_after` 与 `stall_after` 放宽至 `3600s`（支持 `XNU_CPU_METAL_WATCHDOG_MS` 覆盖用于测试）。
2. `src/metal2vulkan/crates/metal2vulkan-runtime/src/buffer.rs`：`Imported::drop` 与 `HostPages::drop` 在 `release::parked(vk_device)` 时跳过 deallocator / keep_alive 释放（与 `vkFreeMemory` 一致地保持映射），彻底杜绝 parked 设备的 `munmap` UAF。
3. `src/xnu-cpu-metal-bundle/XnuCpuMetalPlugin.mm`：
   - `XcmCommandBuffer` `wait_until_completed` 改为无限等待（`timeout_ms = 0`）；若遇到 `GpuHang`/`DeviceLost` 则将 `_retainedResources` 存入静态 park 列表不提前释放。
   - `xcmDev_newBufferNoCopy`、`xcmDev_newBufferLen`、`xcmDev_newBufferBytes` 对 `ptr == nullptr || length == 0` 直接返回 `nil` 且不触发 `deallocator`。

### 验证（通用 `arm64 + arm64e` `dist/XnuCpuMetal.bundle`）
- `build/test_round13.mm`（`arm64` & `arm64e`，`LP_NUM_THREADS=0`）：
  - `PASS [1]`：`newBufferWithBytesNoCopy(NULL, 0)` / `newBufferWithLength(0)` / `newBufferWithBytes(NULL, 0)` 全返回 `nil` 且 `dealloc=0`。
  - `PASS [2]`：单 CB 26 次重负载 draw 连续运行 **25.02s**（超过原 20.2s watchdog）正常完成，`0 GpuHang / 0 AccessRevoked`，`dealloced=1/1`；3 连重负载 CB（9.75s）全过。
  - `PASS [hang_uaf]`（`XNU_CPU_METAL_WATCHDOG_MS=1000` 强制触发 `GpuHang` 并 park 设备）：`arm64` 与 `arm64e` 均在 `llvmpipe_draw_vbo` 继续读 `mmap` 顶点缓冲期间零 `SIGSEGV`（`dealloced=0`）。
- 全量回归：`test_carenderer_arm64e`、`test_round10_arm64e`、`test_stress_mt_arm64e`（Phase 1-4 `failures=0`）、`test-bundle.sh arm64e` 全部 PASS。

---

## Round 14: 锁屏 `loginwindow` → `AvatarKit` / `VFX` `MTLDevice` Selector 差集补齐

### 根因与审计
- 锁屏时 `loginwindow` 的 `AVTView` 进入 `VFX`，调用 `-[XcmBackendDevice isDepth24Stencil8PixelFormatSupported]` 抛出 `NSInvalidArgumentException` 导致 `loginwindow` 退出、会话重启。
- 对照宿主机 macOS 27 `AGXG17CDevice`（Apple M5 Max）全量扫描 `@protocol(MTLDevice)`、`@protocol(MTLDeviceSPI)` 以及 7 个框架（`VFX`、`AvatarKit`、`SceneKit`、`CoreRE`、`QuartzCore`、`RenderBox`、`CoreImage`）共 **25,589 条 `__objc_selrefs`**，发现：
  - `@protocol(MTLDevice)` 缺失 3 项：`isDepth24Stencil8PixelFormatSupported`、`sparseTileSizeWithTextureType:pixelFormat:sampleCount:`、`sparseTileSizeWithTextureType:pixelFormat:sampleCount:sparsePageSize:`（3 项均被 `VFX` / `SceneKit` 引用）。
  - `@protocol(MTLDeviceSPI)` 缺失 23 项（含 `newBufferWithDescriptor:`、`newVisibleFunctionTableWithDescriptor:`、`newTextureWithBytesNoCopy:length:descriptor:deallocator:`、`supportsSampleCount:`、`singleFPConfig`/`doubleFPConfig`/`halfFPConfig`、`metalAssertionsEnabled`/`setMetalAssertionsEnabled:`、`tileSizeWithSparsePageSize:...`、`newRenderPipelineStateWithTileDescriptor:*` 等）。
  - 另发现 VFX 初始化查询 `maxViewportCount` 返回了 `0`（应为 `16`），`maxArgumentBufferSamplerCount` 为 `0`（应为 `16`）。

### 修复（`src/xnu-cpu-metal-bundle/XnuCpuMetalPlugin.mm`）
- 在 `XcmBackendDevice` 补齐上述全部 26 个 `MTLDevice` + `MTLDeviceSPI` 方法（`isDepth24Stencil8PixelFormatSupported` 按 Apple Silicon 实测返回 `NO`；`newBufferWithDescriptor:` 标 `NS_RETURNS_RETAINED` 并完整转发至 `newBuffer*`），并补齐 `maxViewportCount = 16`、`maxArgumentBufferSamplerCount = 16`、`supportsBaseVertexInstanceDrawing` / `supportsDepthClipMode` / `supportsTextureCubeArray` / `supportsNonUniformThreadgroupSize = YES`。

### 验证（通用 `arm64 + arm64e` `dist/XnuCpuMetal.bundle`）
- 新增 `build/test_round14_vfx.mm`（`arm64` & `arm64e` 均 6/6 PASS）：
  1. `isDepth24Stencil8PixelFormatSupported == NO`
  2. `@protocol(MTLDevice)` + `@protocol(MTLDeviceSPI)` 对照 Apple M5 Max **0 缺失**
  3. `Depth32Float_Stencil8` 纹理创建 + 深度/模板 RenderPass 完成
  4. `SCNRenderer rendererWithDevice:dev options:nil` 正常初始化
  5. `VFXRenderer rendererWithDevice:dev options:nil` 与 `AVTView initWithFrame:options:` 正常初始化（0 `unrecognized selector`）
  6. 7 个框架（`VFX`/`AvatarKit`/`SceneKit`/`CoreRE`/`QuartzCore`/`RenderBox`/`CoreImage`）25,589 条 `__objc_selrefs` **0 缺失**
- 全量回归：`test_carenderer_arm64e`、`test_round10_arm64e`、`test_round13_arm64e`、`test-bundle.sh arm64e` 全部 PASS。

---

## Round 16: 双后端 Bundle（Venus 真 GPU + lavapipe 回退）与 MoltenVK 预演

### 改动内容
1. **双 ICD 打包（`scripts/build-bundle-universal.sh`）**：
   - 将宿主机编译好的 universal (`arm64 + arm64e`) `libvulkan_virtio.dylib`（默认 `/Users/admin/w/venus-darwin/out/lib/libvulkan_virtio.dylib`，可通过 `VENUS_DYLIB` 覆盖）打入 `XnuCpuMetal.bundle/Contents/Frameworks/libvulkan_virtio.dylib`，修正 `install_name` 为 `@rpath/libvulkan_virtio.dylib` 并 ad-hoc 重签。
   - 同时生成 `Contents/Resources/virtio_icd.aarch64.json` 与 `Contents/Resources/vulkan/icd.d/virtio_icd.aarch64.json`（后者供 `WindowServer` 等 secure-mode 进程在忽略 `VK_ICD_FILENAMES` 时由 Vulkan-Loader 自动扫描；`metal2vulkan` 内部按 `Discrete < Integrated < Virtual < Cpu` 优先级自动优先选 Venus、无 Venus 设备时回退 lavapipe）。
   - 确认 bundle 内全部 5 个 Mach-O 二进制（`XnuCpuMetal`、`libxnu_m2v.dylib`、`libvulkan.1.dylib`、`libvulkan_lvp.dylib`、`libvulkan_virtio.dylib`）均为 `arm64 + arm64e` universal fat。
2. **启动自动探测与环境变量覆盖（`src/xnu-cpu-metal-bundle/XnuCpuMetalPlugin.mm`）**：
   - 后端选择优先级：`XNU_CPU_METAL_ICD`（指定任意自定义 ICD JSON，便于宿主机用 MoltenVK 测试）> `XNU_CPU_METAL_BACKEND=venus|lavapipe` > 自动探测 `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("XnuDrm"))`（存在则选 Venus，否则选 lavapipe）。
   - 选择 Venus 或自定义 ICD 时**跳过**所有 lavapipe 专用设置（`MESA_SHADER_CACHE_DIR`、`MESA_SHADER_CACHE_MAX_SIZE`、`LP_NUM_THREADS`）；`metal2vulkan-runtime` 的 3600s CPU watchdog 补丁本就仅对 `DeviceKind::Cpu` 生效，Venus 自动保持标准 GPU watchdog（20.2s）。
   - 自动探测选中 Venus 但打开失败时自动回退 lavapipe；若通过 `XNU_CPU_METAL_BACKEND=venus` 强制指定则不回退并返回 `nil`。
3. **设备名与型号（`XnuCpuMetalPlugin.mm`）**：
   - `name` 直接返回 Vulkan physical device 的 `deviceName`（如 Venus 下的 `"Virtio-GPU Venus (Apple M5 Max)"`、MoltenVK 下的 `"Apple M5 Max"`、lavapipe 下的 `"llvmpipe (LLVM 22.1.8, 128 bits)"`），不再包装 `"XnuCpuMetal (...)"` 前缀。
   - 同步在 `XcmBackendDevice` 上注册 `model` 与 `productName`（均返回真实 Vulkan `deviceName`）。

### 宿主机 MoltenVK（`1.4.2`, Apple M5 Max）全套测试与缺口审计
通过 `XNU_CPU_METAL_ICD=/Users/admin/.local/krunkit/Cellar/molten-vk/1.4.2/etc/vulkan/icd.d/MoltenVK_icd.json`（注：krunkit 的 `libMoltenVK.dylib` 为 `arm64`-only，而我们打包的 `libvulkan_virtio.dylib` 为 `arm64 + arm64e`）对完整测试套件进行预演，同时对比 `lavapipe`（`arm64e`）：

| 测试项 | lavapipe (`arm64e`) | MoltenVK (`arm64`, Apple M5 Max) | 说明 |
|---|---|---|---|
| `test-bundle.sh` (`vecadd N=1024`) | PASS (`bad=0`) | PASS (`bad=0`) | `name` / `model` 均正确反映真实后端 |
| `test-render-ci.sh` (Render Pass) | PASS | PASS | 64×64 RGBA8 三角形完全匹配 |
| `test-render-ci.sh` (`CIGaussianBlur`) | PASS (`maxErr=1, meanErr=0.0161`) | **PASS (`maxErr=0, meanErr=0.0000, nonZeroDiff=0`)** | 与原生 Apple M5 Max 逐字节完全一致 |
| `test_round10` (Linear Tex + SharedEvent + Fence) | PASS (4/4) | PASS (4/4) | 4 种 WindowServer 线性纹理 + CPU 原地覆写全过 |
| `test_carenderer` (5 项含 `VfxXg/Xgc`) | PASS (`rounded_only=1`, `rounded_shadow=3 / 0.092`) | **PASS (`rounded_only=0`, `rounded_shadow=3 / 0.018`)** | 全部 5 项通过 |
| `test_round13` (0-len NoCopy + 2 heavy CBs) | PASS (`1.93s`, `dealloced=2/2`) | **PASS (`0.34s`, `dealloced=2/2`)** | 耗时快 5.7× |
| `test_round14_vfx` (VFX/AvatarKit/25,589 selrefs) | PASS (6/6) | PASS (6/6) | 0 missing selectors |
| `test_stress_mt` (4 阶段并发压测) | PASS (Phase 1–4 `failures=0`) | PASS (Phase 1–4 `failures=0`) | 8 线程并发 commit / CARenderer / NoCopy |
| `XNU_CPU_METAL_BACKEND=lavapipe` / `venus` | `lavapipe` PASS；宿主机无 `XnuDrm` 强选 `venus` 干净返回 `nil` (`VkResult(-3)`) | — | 环境变量覆盖与无回退语义已验证 |

**MoltenVK 非阻塞降级提示与 Venus 预期注意事项**（无功能性失败）：
- `metal2vulkan-driver-pipeline-cache-kept`：驱动未暴露 `VK_KHR_pipeline_binary`（使用驱动自身管线缓存，功能等价）。
- `metal2vulkan-degrade-shadowed-texture`：宿主指针导入（`VK_EXT_external_memory_host`）的线性纹理在行距不匹配或无 `VK_EXT_image_drm_format_modifier` 时采用 shadow-image 拷贝；若托管 Venus 不暴露 `VK_EXT_external_memory_host`，`metal2vulkan` 会自动退回到 host-visible staging/copy 路径（`test_round10` 已覆盖）。
- `metal2vulkan-degrade-render-pass-split`：可编程混合（`[[color(0)]]` framebuffer fetch）在无原生 raster-order color attachment 时拆分为子 RenderPass（功能正常，仅多一次 tile flush）。
- `metal2vulkan-degrade-dont-care-store`：`Depth32Float_Stencil8` 的 `DontCare` storeOp 降级为 `STORE`（功能正常）。

### IOSurface 帧拷贝开销实测（`test/test_iosurface_bench.mm`）
在 `XcmTexture` 当前基于 `IOSurfaceLock` + `replaceRegion`/`getBytes` 的双向同步路径下，测量不同分辨率（`BGRA8Unorm`，10 轮取平均）：

| 分辨率 (单帧大小) | lavapipe (`arm64e`) RenderPass+`syncToIOSurface` | lavapipe `upload+download` | MoltenVK (`Apple M5 Max`) RenderPass+`syncToIOSurface` | MoltenVK `upload+download` |
|---|---|---|---|---|
| `512×512` (1.00 MB) | `0.29 ms` (3476 MB/s) | `0.23 ms` | `0.65 ms` (1542 MB/s) | `0.37 ms` |
| `1920×1080` (7.91 MB) | `0.76 ms` (10436 MB/s) | `0.47 ms` | `1.59 ms` (4969 MB/s) | `2.37 ms` (est upload `0.78 ms`) |
| `2560×1440` (14.06 MB) | `1.12 ms` (12530 MB/s) | `0.66 ms` | `2.77 ms` (5078 MB/s) | `4.26 ms` (est upload `1.49 ms`) |

结论：在真 GPU（MoltenVK）上，1080p 单帧 `syncToIOSurface` 约 `1.59 ms`、双向约 `2.37 ms`；1440p 单帧回写约 `2.77 ms`、双向约 `4.26 ms`。托管 VM 中经 Venus（virtio-gpu 共享内存）预计在 `2–5 ms/帧` 量级，首版接入可直接复用现有 IOSurface 同步路径满足 60fps 交互基线，后续如出现高分辨率合成瓶颈再评估基于共享内存 / `VK_EXT_external_memory_host` 的零拷贝优化。
