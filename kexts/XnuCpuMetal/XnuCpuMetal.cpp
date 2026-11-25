// SPDX-License-Identifier: APSL-2.0
// XnuCpuMetal: the hosted macOS's Metal device, as a kext of the kernel collection (written for xnulinux, clean room).
// Metal.framework finds GPUs by watching IOServiceMatching("IOAccelerator") and loads the plugin bundle named by the service's
// MetalPluginName from /Library/GPUBundles, taking MetalPluginClassName (an IOGPUMetalDevice subclass) as the device class.
// XnuCpuMetalDevice runs its work in the calling process (Metal -> metal2vulkan -> Mesa lavapipe on the CPU), so the service
// is only a registry entry: no user client, no hardware. It matches IOResources, so no device tree node is needed.
#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <mach/kmod.h>

// IOGraphicsFamily's abstract accelerator class; scripts/kclink fills the subclass's vtable from it (the JSON's "vtable").
class IOAccelerator : public IOService {
	OSDeclareAbstractStructors(IOAccelerator)
};

class XnuCpuMetalAccelerator : public IOAccelerator {
	OSDeclareDefaultStructors(XnuCpuMetalAccelerator)
public:
	bool start(IOService *provider) override;
};

OSDefineMetaClassAndStructors(XnuCpuMetalAccelerator, IOAccelerator)

bool XnuCpuMetalAccelerator::start(IOService *provider)
{
	if (!IOService::start(provider)) return false;
	setProperty("MetalPluginName", "XnuCpuMetal");
	setProperty("MetalPluginClassName", "XnuCpuMetalDevice");
	// No "Removable" / "SafeEjectRequested": Metal (-[MTLIOAccelService initWithAcceleratorPort:deviceClass:]) skips
	// a service on which either is present at all, whatever the value.
	setProperty("model", "XnuCpuMetal (lavapipe)");
	// The GPU bridge's user client (kexts/XnuDrm) hangs off this service: the sandbox's system-graphics rules let
	// processes that draw open user clients of an IOAccelerator ((iokit-connection "IOAccelerator")), whatever their class.
	setProperty("IOUserClientClass", "AGXDeviceUserClient");
	registerService();
	IOLog("xnucpumetal: Metal accelerator published on %s\n", provider->getName());
	return true;
}

extern "C" {
kern_return_t native_kext_start(kmod_info_t *, void *) { return KERN_SUCCESS; }
kern_return_t native_kext_stop(kmod_info_t *, void *) { return KERN_SUCCESS; }
}
