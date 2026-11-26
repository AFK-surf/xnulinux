// SPDX-License-Identifier: GPL-2.0-only
// Read-only x86-64 CPU report for porting research. See docs/x86-amd-cpu-report.md.
#if !defined(__x86_64__)
#error "cpu-probe requires an x86-64 target and a GCC-compatible cpuid.h"
#endif
#include <cpuid.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned max_basic, max_extended;

static int query(unsigned leaf, unsigned subleaf, unsigned regs[4])
{
    memset(regs, 0, 4 * sizeof(*regs));
    if ((leaf < 0x80000000u && leaf > max_basic) ||
        (leaf >= 0x80000000u && leaf > max_extended))
        return 0;
    __cpuid_count(leaf, subleaf, regs[0], regs[1], regs[2], regs[3]);
    return 1;
}

static void feature(const char *name, unsigned leaf, unsigned subleaf, unsigned reg, unsigned bit)
{
    unsigned r[4];
    int known = query(leaf, subleaf, r);
    printf("%-20s %s\n", name, !known ? "leaf unavailable" :
           (r[reg] & (1u << bit)) ? "advertised" : "not advertised");
}

static void raw(unsigned leaf, unsigned subleaf)
{
    unsigned r[4];
    if (query(leaf, subleaf, r))
        printf("CPUID %08x:%02x EAX=%08x EBX=%08x ECX=%08x EDX=%08x\n",
               leaf, subleaf, r[0], r[1], r[2], r[3]);
}

int main(void)
{
    unsigned r[4];
    max_basic = __get_cpuid_max(0, NULL);
    max_extended = __get_cpuid_max(0x80000000u, NULL);
    query(0, 0, r);
    char vendor[13] = {0};
    memcpy(vendor, &r[1], 4);
    memcpy(vendor + 4, &r[3], 4);
    memcpy(vendor + 8, &r[2], 4);
    printf("Vendor: %s\n", vendor);
    if (max_extended >= 0x80000004u) {
        char brand[49] = {0};
        for (unsigned i = 0; i < 3; ++i) {
            query(0x80000002u + i, 0, r);
            memcpy(brand + 16 * i, r, 16);
        }
        printf("Brand: %s\n", brand);
    }
    query(1, 0, r);
    unsigned family = (r[0] >> 8) & 15u;
    unsigned model = (r[0] >> 4) & 15u;
    if (family == 6 || family == 15) model |= ((r[0] >> 16) & 15u) << 4;
    if (family == 15) family += (r[0] >> 20) & 255u;
    printf("Family: %u (0x%x), model: %u (0x%x), stepping: %u\n",
           family, family, model, model, r[0] & 15u);
    int xsave = !!(r[2] & bit_XSAVE);
    int osxsave = !!(r[2] & bit_OSXSAVE);
    int hypervisor = !!(r[2] & (1u << 31));
    printf("Hypervisor present: %s\n", hypervisor ? "yes" : "no");
    if (hypervisor) {
        __cpuid_count(0x40000000u, 0, r[0], r[1], r[2], r[3]);
        char hyper_vendor[13] = {0};
        memcpy(hyper_vendor, &r[1], 4);
        memcpy(hyper_vendor + 4, &r[2], 4);
        memcpy(hyper_vendor + 8, &r[3], 4);
        printf("Hypervisor vendor: %s\n", hyper_vendor);
    }
    puts("\nCurrent execution environment's advertised features:");
    feature("SSE2", 1, 0, 3, 26);
    feature("SSSE3", 1, 0, 2, 9);
    feature("SSE4.1", 1, 0, 2, 19);
    feature("SSE4.2", 1, 0, 2, 20);
    feature("CMPXCHG16B", 1, 0, 2, 13);
    feature("XSAVE", 1, 0, 2, 26);
    feature("OSXSAVE", 1, 0, 2, 27);
    feature("AVX", 1, 0, 2, 28);
    feature("AVX2", 7, 0, 1, 5);
    feature("AVX512F", 7, 0, 1, 16);
    feature("FSGSBASE", 7, 0, 1, 0);
    feature("PCID", 1, 0, 2, 17);
    feature("INVPCID", 7, 0, 1, 10);
    feature("SMEP", 7, 0, 1, 7);
    feature("SMAP", 7, 0, 1, 20);
    feature("CET shadow stack", 7, 0, 2, 7);
    feature("CET IBT", 7, 0, 3, 20);
    feature("Intel VMX", 1, 0, 2, 5);
    feature("AMD SVM", 0x80000001u, 0, 2, 2);
    feature("SYSCALL/SYSRET", 0x80000001u, 0, 3, 11);
    feature("NX", 0x80000001u, 0, 3, 20);
    feature("RDTSCP", 0x80000001u, 0, 3, 27);
    feature("Invariant TSC", 0x80000007u, 0, 3, 8);
    if (xsave && max_basic >= 0xdu) {
        feature("XSAVEOPT", 0xd, 1, 0, 0);
        feature("XSAVEC", 0xd, 1, 0, 1);
        feature("XSAVES", 0xd, 1, 0, 3);
        query(0xd, 0, r);
        printf("XCR0 supported mask: 0x%08x%08x\n", r[3], r[0]);
        printf("XSAVE enabled bytes: %u; all supported XCR0 components: %u bytes\n", r[1], r[2]);
    }
    if (xsave && osxsave) {
        unsigned lo, hi;
        __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
        uint64_t xcr0 = ((uint64_t)hi << 32) | lo;
        printf("XCR0 enabled mask: 0x%016" PRIx64 "\n", xcr0);
        printf("OS-enabled XMM/YMM state: %s\n", (xcr0 & 6u) == 6u ? "yes" : "no");
    }
    puts("\nRaw leaves (reproduction evidence):");
    raw(0, 0); raw(1, 0); raw(7, 0);
    if (xsave) { raw(0xd, 0); raw(0xd, 1); }
    raw(0x80000000u, 0); raw(0x80000001u, 0);
    raw(0x80000007u, 0); raw(0x80000008u, 0);
    puts("\nFeature presence is not proof that hosted XNU works. A hypervisor may filter CPUID."
         " This program only reads CPUID/XCR0; it does not load drivers or write control registers.");
    return ferror(stdout) ? 1 : 0;
}
