// SPDX-License-Identifier: MIT
/*
 * libxnudrm: Linux's virtio-gpu render node for Mesa's Venus driver inside the hosted macOS. The node is a user client of
 * kexts/XnuDrm; each DRM ioctl becomes one message to xnudrmd on the Linux host (xnudrm_proto.h), with the ioctl struct's
 * user pointers turned into offsets into the message. Buffer mappings are Linux's own pages, mapped into this process by
 * the kext. Fences are pipes whose read end stands for the fence (so dup'ed descriptors stay the same fence); poll() on
 * one asks xnudrmd, and once the fence signals the pipe is made readable for good.
 */
#ifdef XNUDRM_COMPAT_H	/* force-included into the whole driver: this file means the system's own calls */
#undef open
#undef close
#undef mmap
#undef munmap
#undef stat
#undef poll
#endif
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#include <IOKit/IOKitLib.h>
#include "drm-uapi/drm.h"
#include "drm-uapi/virtgpu_drm.h"
#include "xnudrm_proto.h"
#include "xf86drm.h"

#define NODE_RENDER "/dev/dri/renderD128"
#define NODE_PRIMARY "/dev/dri/card0"

static pthread_mutex_t lk = PTHREAD_MUTEX_INITIALIZER;
static io_connect_t conn;		/* the user client of the call in progress (under lk) */
static struct xnode { int fd; io_connect_t conn; } nodes[64];	/* open render nodes: a /dev/null fd each */
static unsigned nnodes;
static struct xmap { void *va; size_t len; uint64_t id; io_connect_t conn; } *maps;
static unsigned nmaps;
static struct xfence { dev_t dev; ino_t ino; int wfd; uint64_t id; io_connect_t conn; } *fences;
static unsigned nfences;
static uint8_t *buf;			/* message, then reply */

static int debug(void) { static int d = -1; if (d < 0) d = getenv("XNUDRM_DEBUG") != NULL; return d; }

static int open_conn(io_connect_t *c)
{
	io_service_t sv = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("XnuDrm"));
	if (!sv) { if (debug()) fprintf(stderr, "xnudrm: no XnuDrm service\n"); return -ENODEV; }
	kern_return_t kr = IOServiceOpen(sv, mach_task_self(), 0, c);
	IOObjectRelease(sv);
	if (kr != KERN_SUCCESS) { if (debug()) fprintf(stderr, "xnudrm: IOServiceOpen %#x\n", kr); return -EIO; }
	if (!buf) buf = malloc(sizeof(struct xnudrm_hdr) + XNUDRM_MAX_MSG);
	if (!buf) { IOServiceClose(*c); return -ENOMEM; }
	return 0;
}

/* The user client behind a render node descriptor (0: not one). Called with lk held. */
static io_connect_t node_conn(int fd)
{
	for (unsigned i = 0; i < nnodes; i++) if (nodes[i].fd == fd) return nodes[i].conn;
	return 0;
}

/* buf holds a header and plen bytes of payload; the reply replaces it. Returns the reply's status or -errno. */
static int call(uint32_t plen)
{
	uint64_t in[4] = { (uintptr_t)buf, sizeof(struct xnudrm_hdr) + plen, (uintptr_t)buf, sizeof(struct xnudrm_hdr) + XNUDRM_MAX_MSG };
	uint64_t out = 0;
	uint32_t nout = 1;
	kern_return_t kr = IOConnectCallScalarMethod(conn, 0, in, 4, &out, &nout);
	if (kr != KERN_SUCCESS) { if (debug()) fprintf(stderr, "xnudrm: call %#x\n", kr); return -EIO; }
	return ((struct xnudrm_hdr *)buf)->status;
}

static struct xnudrm_hdr *hdr(uint32_t op, uint64_t a0, uint64_t a1)
{
	struct xnudrm_hdr *h = (void *)buf;
	*h = (struct xnudrm_hdr){ .magic = XNUDRM_MAGIC, .op = op, .arg0 = a0, .arg1 = a1 };
	return h;
}

/* ---- the render node as a file ---- */

int xnudrm_open(const char *path, int flags, ...)
{
	if (path && !strcmp(path, NODE_RENDER)) {
		io_connect_t c = 0;
		pthread_mutex_lock(&lk);
		int r = nnodes < sizeof(nodes) / sizeof(nodes[0]) ? open_conn(&c) : -EMFILE;
		int fd = r ? -1 : open("/dev/null", O_RDWR | O_CLOEXEC);
		if (!r && fd < 0) { IOServiceClose(c); r = -errno; }
		if (!r) nodes[nnodes++] = (struct xnode){ fd, c };
		pthread_mutex_unlock(&lk);
		if (r) { errno = -r; return -1; }
		return fd;
	}
	if (flags & O_CREAT) {
		va_list ap; va_start(ap, flags); int mode = va_arg(ap, int); va_end(ap);
		return open(path, flags, mode);
	}
	return open(path, flags);
}

int xnudrm_close(int fd)
{
	pthread_mutex_lock(&lk);
	for (unsigned i = 0; i < nnodes; i++) {
		if (nodes[i].fd == fd) {
			/* closing the user client drops what is still mapped from it and its DRM file on Linux */
			io_connect_t c = nodes[i].conn;
			nodes[i] = nodes[--nnodes];
			for (unsigned j = 0; j < nmaps; ) { if (maps[j].conn == c) maps[j] = maps[--nmaps]; else j++; }
			for (unsigned j = 0; j < nfences; j++) if (fences[j].conn == c && fences[j].id) fences[j].id = 0;
			IOServiceClose(c);
			break;
		}
	}
	pthread_mutex_unlock(&lk);
	return close(fd);
}

int xnudrm_stat(const char *path, struct stat *st)
{
	if (path && !strcmp(path, NODE_RENDER)) {
		memset(st, 0, sizeof(*st));
		st->st_mode = S_IFCHR | 0666;
		st->st_rdev = makedev(226, 128);
		return 0;
	}
	if (path && !strcmp(path, NODE_PRIMARY)) { errno = ENOENT; return -1; }
	return stat(path, st);
}

/* ---- ioctls ---- */

/* Append len bytes at p (or zeros) to the payload; the field becomes the offset. */
static int put(uint32_t *plen, uint64_t *field, const void *p, uint64_t len)
{
	if (!len) { *field = 0; return 0; }
	if (*plen + len > XNUDRM_MAX_MSG) return -E2BIG;
	uint8_t *pl = buf + sizeof(struct xnudrm_hdr);
	if (p) memcpy(pl + *plen, p, len); else memset(pl + *plen, 0, len);
	*field = *plen;
	*plen += (uint32_t)((len + 7) & ~7ull);
	return 0;
}

static int new_fence(uint64_t id)	/* for conn */
{
	int p[2];
	if (pipe(p)) return -1;
	fcntl(p[0], F_SETFD, FD_CLOEXEC); fcntl(p[1], F_SETFD, FD_CLOEXEC);
	struct stat st; fstat(p[0], &st);
	/* a pipe's inode number is reused once every descriptor of an earlier pipe is closed: an entry for that dead pipe
	 * would answer for this one */
	for (unsigned i = 0; i < nfences; ) {
		if (fences[i].ino == st.st_ino && fences[i].dev == st.st_dev) {
			/* (an unsignalled one's fence stays with xnudrmd until the node closes: no host call here, buf holds the
			 * reply being copied out) */
			if (fences[i].wfd >= 0) close(fences[i].wfd);
			fences[i] = fences[--nfences];
		} else i++;
	}
	struct xfence *nf = realloc(fences, (nfences + 1) * sizeof(*fences));
	if (!nf) { close(p[0]); close(p[1]); return -1; }
	fences = nf;
	fences[nfences++] = (struct xfence){ st.st_dev, st.st_ino, p[1], id, conn };
	return p[0];
}

static int do_ioctl(unsigned long request, void *arg)
{
	uint32_t nr = request & 0xff, size = (request >> 16) & 0x1fff, plen = 0;
	uint8_t *pl = buf + sizeof(struct xnudrm_hdr);
	uint64_t f0 = 0, f1 = 0;
	int r;

	if (size > 256) return -EINVAL;
	if (nr == DRM_COMMAND_BASE + DRM_VIRTGPU_MAP) {	/* answered here: see xnudrm_mmap */
		struct drm_virtgpu_map *m = arg;
		m->offset = (uint64_t)m->handle << 12;
		return 0;
	}
	hdr(XNUDRM_IOCTL, nr, 0);
	memcpy(pl, arg, size);
	plen = (size + 7) & ~7u;
	switch (nr) {
	case DRM_COMMAND_BASE + DRM_VIRTGPU_GETPARAM: {
		struct drm_virtgpu_getparam *a = (void *)pl;
		f0 = a->value; if ((r = put(&plen, &a->value, NULL, 8))) return r;
		break;
	}
	case DRM_COMMAND_BASE + DRM_VIRTGPU_GET_CAPS: {
		struct drm_virtgpu_get_caps *a = (void *)pl;
		f0 = a->addr; if ((r = put(&plen, &a->addr, NULL, a->size))) return r;
		break;
	}
	case DRM_COMMAND_BASE + DRM_VIRTGPU_CONTEXT_INIT: {
		struct drm_virtgpu_context_init *a = (void *)pl;
		if ((r = put(&plen, &a->ctx_set_params, (void *)(uintptr_t)a->ctx_set_params, (uint64_t)a->num_params * sizeof(struct drm_virtgpu_context_set_param)))) return r;
		break;
	}
	case DRM_COMMAND_BASE + DRM_VIRTGPU_RESOURCE_CREATE_BLOB: {
		struct drm_virtgpu_resource_create_blob *a = (void *)pl;
		if ((r = put(&plen, &a->cmd, (void *)(uintptr_t)a->cmd, a->cmd_size))) return r;
		break;
	}
	case DRM_COMMAND_BASE + DRM_VIRTGPU_EXECBUFFER: {
		struct drm_virtgpu_execbuffer *a = (void *)pl;
		if (a->num_in_syncobjs || a->num_out_syncobjs || (a->flags & VIRTGPU_EXECBUF_FENCE_FD_IN)) return -EOPNOTSUPP;
		if ((r = put(&plen, &a->command, (void *)(uintptr_t)a->command, a->size))) return r;
		if ((r = put(&plen, &a->bo_handles, (void *)(uintptr_t)a->bo_handles, (uint64_t)a->num_bo_handles * 4))) return r;
		break;
	}
	case DRM_COMMAND_BASE + DRM_VIRTGPU_RESOURCE_INFO:
	case DRM_COMMAND_BASE + DRM_VIRTGPU_WAIT:
	case 0x09:	/* GEM_CLOSE */
		break;
	default:
		return -ENOTTY;	/* PRIME, syncobj: not over the bridge */
	}
	r = call(plen);
	if (r && r != -EINTR) { if (debug()) fprintf(stderr, "xnudrm: ioctl %#x: %d\n", nr, r); }
	/* copy the outputs back: the struct, then the out-buffers its pointers named */
	switch (nr) {
	case DRM_COMMAND_BASE + DRM_VIRTGPU_GETPARAM: {
		struct drm_virtgpu_getparam *a = (void *)pl;
		if (!r) memcpy((void *)(uintptr_t)f0, pl + a->value, sizeof(int));
		a->value = f0;
		break;
	}
	case DRM_COMMAND_BASE + DRM_VIRTGPU_GET_CAPS: {
		struct drm_virtgpu_get_caps *a = (void *)pl;
		if (!r) memcpy((void *)(uintptr_t)f0, pl + a->addr, a->size);
		a->addr = f0;
		break;
	}
	case DRM_COMMAND_BASE + DRM_VIRTGPU_CONTEXT_INIT:
	case DRM_COMMAND_BASE + DRM_VIRTGPU_RESOURCE_CREATE_BLOB:
	case DRM_COMMAND_BASE + DRM_VIRTGPU_EXECBUFFER: {
		/* pointer fields go back to the caller's values */
		uint8_t saved[256];
		memcpy(saved, arg, size);
		if (nr == DRM_COMMAND_BASE + DRM_VIRTGPU_CONTEXT_INIT) ((struct drm_virtgpu_context_init *)pl)->ctx_set_params = ((struct drm_virtgpu_context_init *)saved)->ctx_set_params;
		if (nr == DRM_COMMAND_BASE + DRM_VIRTGPU_RESOURCE_CREATE_BLOB) ((struct drm_virtgpu_resource_create_blob *)pl)->cmd = ((struct drm_virtgpu_resource_create_blob *)saved)->cmd;
		if (nr == DRM_COMMAND_BASE + DRM_VIRTGPU_EXECBUFFER) {
			struct drm_virtgpu_execbuffer *a = (void *)pl, *s = (void *)saved;
			a->command = s->command; a->bo_handles = s->bo_handles;
			if (!r && (a->flags & VIRTGPU_EXECBUF_FENCE_FD_OUT)) a->fence_fd = new_fence((uint32_t)a->fence_fd);
			if (debug()) fprintf(stderr, "xnudrm: execbuffer flags %#x size %u ring %u -> %d, fence fd %d\n", a->flags, a->size, a->ring_idx, r, a->fence_fd);
		}
		break;
	}
	}
	(void)f1;
	memcpy(arg, pl, size);
	return r;
}

int drmIoctl(int fd, unsigned long request, void *arg)
{
	pthread_mutex_lock(&lk);
	conn = node_conn(fd);
	int r = conn ? do_ioctl(request, arg) : -EBADF;
	pthread_mutex_unlock(&lk);
	if (r) { errno = -r; return -1; }
	return 0;
}

/* ---- mappings: mmap(node fd, offset) after DRM_IOCTL_VIRTGPU_MAP ---- */

/*
 * VIRTGPU_MAP's offset is the GEM handle's mmap cookie on Linux; xnudrmd maps by handle, so the shim answers MAP itself
 * with the handle as the offset (MAP is never forwarded) and mmap() maps that handle.
 */
void *xnudrm_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
	pthread_mutex_lock(&lk);
	io_connect_t c = fd >= 0 ? node_conn(fd) : 0;
	if (!c) { pthread_mutex_unlock(&lk); return mmap(addr, len, prot, flags, fd, off); }
	uint64_t in[2] = { (uint64_t)off >> 12, len }, out[2] = { 0, 0 };
	uint32_t nout = 2;
	kern_return_t kr = IOConnectCallScalarMethod(c, 1, in, 2, out, &nout);
	if (kr == KERN_SUCCESS) {
		struct xmap *nm = realloc(maps, (nmaps + 1) * sizeof(*maps));
		if (nm) { maps = nm; maps[nmaps++] = (struct xmap){ (void *)(uintptr_t)out[0], len, out[1], c }; }
	}
	pthread_mutex_unlock(&lk);
	if (kr != KERN_SUCCESS) { if (debug()) fprintf(stderr, "xnudrm: map handle %llu: %#x\n", (unsigned long long)in[0], kr); errno = ENOMEM; return MAP_FAILED; }
	if (addr && (flags & MAP_FIXED) && addr != (void *)(uintptr_t)out[0]) {
		/* a placed mapping (VkPhysicalDeviceMapMemoryPlacedFeaturesEXT): not supported over the bridge */
		xnudrm_munmap((void *)(uintptr_t)out[0], len);
		errno = EINVAL;
		return MAP_FAILED;
	}
	return (void *)(uintptr_t)out[0];
}

int xnudrm_munmap(void *addr, size_t len)
{
	pthread_mutex_lock(&lk);
	for (unsigned i = 0; i < nmaps; i++) {
		if (maps[i].va == addr) {
			uint64_t id = maps[i].id;
			io_connect_t c = maps[i].conn;
			maps[i] = maps[--nmaps];
			IOConnectCallScalarMethod(c, 2, &id, 1, NULL, NULL);
			pthread_mutex_unlock(&lk);
			return 0;
		}
	}
	pthread_mutex_unlock(&lk);
	return munmap(addr, len);
}

/* ---- fences ---- */

static struct xfence *fence_of(int fd)
{
	struct stat st;
	if (fstat(fd, &st)) return NULL;
	for (unsigned i = 0; i < nfences; i++)
		if (fences[i].ino == st.st_ino && fences[i].dev == st.st_dev) return &fences[i];
	return NULL;
}

/* 1 signalled, 0 not yet, <0 error. Called with lk held. */
static int fence_check(struct xfence *f)
{
	if (!f->id) return 1;
	conn = f->conn;
	hdr(XNUDRM_FENCE_WAIT, f->id, 0);
	int r = call(0);
	if (r == -XNUDRM_ETIME) return 0;
	if (debug() && r) fprintf(stderr, "xnudrm: fence %llu wait: %d\n", (unsigned long long)f->id, r);
	hdr(XNUDRM_FENCE_CLOSE, f->id, 0);
	call(0);
	f->id = 0;
	(void)!write(f->wfd, "s", 1);	/* signalled for good */
	close(f->wfd);
	f->wfd = -1;
	return r ? r : 1;
}

int xnudrm_poll(struct pollfd *fds, nfds_t n, int timeout)
{
	struct timespec t0, now;
	clock_gettime(CLOCK_MONOTONIC, &t0);
	for (;;) {
		int pending = 0;
		pthread_mutex_lock(&lk);
		for (nfds_t i = 0; i < n; i++) {
			struct xfence *f = nfences ? fence_of(fds[i].fd) : NULL;
			if (f && f->id && fence_check(f) == 0) pending = 1;
		}
		pthread_mutex_unlock(&lk);
		if (debug()) {
			fprintf(stderr, "xnudrm: poll %u fds, timeout %d: %s;", (unsigned)n, timeout, pending ? "pending" : "ready");
			for (nfds_t i = 0; i < n; i++) { struct xfence *f = nfences ? fence_of(fds[i].fd) : NULL; fprintf(stderr, " fd %d -> %s id %llu", fds[i].fd, f ? "fence" : "other", f ? (unsigned long long)f->id : 0ull); }
			fprintf(stderr, "\n");
		}
		if (!pending) return poll(fds, n, timeout);	/* signalled fences are readable pipes now */
		clock_gettime(CLOCK_MONOTONIC, &now);
		long ms = (now.tv_sec - t0.tv_sec) * 1000 + (now.tv_nsec - t0.tv_nsec) / 1000000;
		if (timeout >= 0 && ms >= timeout) return poll(fds, n, 0);
		/* each check stops the hosted CPU for one host call: back off a little */
		struct timespec d = { 0, 200000 };
		nanosleep(&d, NULL);
	}
}

/* ---- device discovery ---- */

int drmGetDevices2(uint32_t flags, drmDevicePtr devices[], int max)
{
	if (!devices) return 1;
	if (max < 1) return 0;
	drmDevicePtr d = calloc(1, sizeof(*d) + DRM_NODE_MAX * sizeof(char *) + sizeof(drmPciBusInfo) + sizeof(drmPciDeviceInfo));
	if (!d) return -ENOMEM;
	d->nodes = (char **)(d + 1);
	d->nodes[DRM_NODE_PRIMARY] = NODE_PRIMARY;
	d->nodes[DRM_NODE_RENDER] = NODE_RENDER;
	d->available_nodes = 1 << DRM_NODE_RENDER;
	d->bustype = DRM_BUS_PCI;
	d->businfo.pci = (drmPciBusInfoPtr)(d->nodes + DRM_NODE_MAX);
	d->deviceinfo.pci = (drmPciDeviceInfoPtr)(d->businfo.pci + 1);
	d->deviceinfo.pci->vendor_id = 0x1af4;	/* virtio */
	d->deviceinfo.pci->device_id = 0x1050;	/* virtio-gpu */
	devices[0] = d;
	return 1;
}

void drmFreeDevices(drmDevicePtr devices[], int count)
{
	for (int i = 0; i < count; i++) free(devices[i]);
}

drmVersionPtr drmGetVersion(int fd)
{
	pthread_mutex_lock(&lk);
	io_connect_t c = node_conn(fd);
	pthread_mutex_unlock(&lk);
	if (!c) return NULL;
	drmVersionPtr v = calloc(1, sizeof(*v));
	if (!v) return NULL;
	v->name = "virtio_gpu";
	v->name_len = 10;
	v->desc = "virtio GPU over the xnulinux DRM bridge";
	v->date = "0";
	return v;
}

void drmFreeVersion(drmVersionPtr v) { free(v); }
