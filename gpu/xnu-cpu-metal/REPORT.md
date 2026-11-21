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
