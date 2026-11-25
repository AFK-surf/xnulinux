# SPDX-License-Identifier: APSL-2.0
# xnu.ko: the APSL side. Out-of-tree, non-GPL module that only uses fki.h.
obj-m += xnu.o
ifdef CONFIG_X86_64
xnu-y := xnu_main.o macho.o adt.o world_x86.o
else
xnu-y := xnu_main.o macho.o adt.o world.o
endif
ccflags-y += -Wno-declaration-after-statement
