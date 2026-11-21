// 47-bit user address space: a fixed mapping above 2^39, where nano malloc puts small blocks, and the advertised width
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
int main(void) {
    int bits = 0; size_t len = sizeof(bits);
    sysctlbyname("machdep.virtual_address_size", &bits, &len, NULL, 0);
    printf("machdep.virtual_address_size: %d\n", bits);
    void *want = (void *)0x7f0000000000ULL;
    char *p = mmap(want, 1 << 20, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0);
    if (p == MAP_FAILED) { perror("mmap 0x7f0000000000"); } else { memset(p, 0x5a, 1 << 20); printf("mmap fixed %p: ok, byte %x\n", (void *)p, p[12345] & 0xff); }
    void *s = malloc(16), *m = malloc(100);
    printf("malloc(16) = %p, malloc(100) = %p\n", s, m);
    return 0;
}
