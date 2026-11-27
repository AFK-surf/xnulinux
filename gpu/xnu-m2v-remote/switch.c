// SPDX-License-Identifier: GPL-2.0-or-later
// libxnu_m2v.dylib that is either: the real library (libxnu_m2v_local.dylib beside it: metal2vulkan in this process, on
// the Vulkan driver the plugin names) or the remote one (client.c, built in with XR_SWITCH). Which, is the host's choice
// for the whole hosted system: the boot-arg xm2v-remote=1 (scripts/xnulinux-boot.sh with GPU=remote). A process's own
// $XM2V_REMOTE (host:port) chooses the remote one too.
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include "xnu_m2v.h"
#include "gen_switch.inc"

static int xs_mode = -1;	// 1 remote, 0 local
static void xs_decide(void) {
    char args[1024] = ""; size_t n = sizeof args - 1;
    int remote = getenv("XM2V_REMOTE") != 0;
    if (!remote && sysctlbyname("kern.bootargs", args, &n, 0, 0) == 0) {
        const char *p = strstr(args, "xm2v-remote=");
        remote = p && (p == args || p[-1] == ' ') && p[12] != '0';
    }
    if (!remote) {	// the real one's functions, by name; one that is missing leaves the remote one in its place
        Dl_info me; char path[1024] = "libxnu_m2v_local.dylib";
        if (dladdr((void *)xs_decide, &me) && me.dli_fname) {
            const char *slash = strrchr(me.dli_fname, '/');
            if (slash) snprintf(path, sizeof path, "%.*s/libxnu_m2v_local.dylib", (int)(slash - me.dli_fname), me.dli_fname);
        }
        void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
        void **slot = (void **)&xs_local;
        for (size_t i = 0; lib && i < sizeof xs_names / sizeof *xs_names; i++) if (!(slot[i] = dlsym(lib, xs_names[i]))) lib = 0;
        if (!lib) { fprintf(stderr, "libxnu_m2v: %s: %s; no local renderer\n", path, dlerror() ?: "a function is missing"); remote = 1; }
    }
    xs_mode = remote;
}
static int xs_remote(void) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, xs_decide);
    return xs_mode;
}
