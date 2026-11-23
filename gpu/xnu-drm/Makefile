# SPDX-License-Identifier: GPL-2.0-only
# The Linux end (xnudrmd); the macOS ends are kexts/XnuDrm and darwin/ (libxnudrm, built with Mesa).
CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter
xnudrmd: xnudrmd.c xnudrm_proto.h
	$(CC) $(CFLAGS) -o $@ xnudrmd.c
clean:
	rm -f xnudrmd
