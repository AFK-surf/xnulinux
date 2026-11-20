/* Minimal Mach-O definitions (written from the public format, no Apple headers). */
#pragma once
#include "../fki-ko/fki.h"
typedef unsigned int u32_t;
typedef unsigned long long u64_t;

#define MH_MAGIC_64 0xfeedfacf
#define LC_SEGMENT_64 0x19
#define LC_SYMTAB 0x2
#define LC_UNIXTHREAD 0x5

struct mh64 { u32_t magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved; };
struct lc { u32_t cmd, cmdsize; };
struct seg64 { u32_t cmd, cmdsize; char segname[16]; u64_t vmaddr, vmsize, fileoff, filesize; u32_t maxprot, initprot, nsects, flags; };
struct sect64 { char sectname[16], segname[16]; u64_t addr, size; u32_t offset, align, reloff, nreloc, flags, r1, r2, r3; };
struct symtab_lc { u32_t cmd, cmdsize, symoff, nsyms, stroff, strsize; };
struct nlist64 { u32_t n_strx; unsigned char n_type, n_sect; unsigned short n_desc; u64_t n_value; };

struct xnu_image {
	const unsigned char *file; unsigned long file_size;
	u64_t vmlow, vmhigh;		/* unslid */
	struct fki_region region;
	u64_t slide;			/* runtime = unslid + slide */
	const struct symtab_lc *symtab;
	u64_t thread_starts, thread_starts_size;	/* unslid vmaddr */
	u64_t entry;			/* unslid */
};

int macho_load(struct xnu_image *img, const void *file, unsigned long size, unsigned long extra);
int macho_rebase(struct xnu_image *img);
int macho_slide_header(struct xnu_image *img, u64_t *mh_unslid);
u64_t macho_sym(struct xnu_image *img, const char *name);	/* runtime address or 0 */
