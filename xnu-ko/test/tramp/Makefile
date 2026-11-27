# SPDX-License-Identifier: APSL-2.0
# Built by run.sh, which cuts tramp.S out of ../../world.S first.
obj-m += tramptest.o
tramptest-y := main.o context.o tramp.o
ccflags-y += -I$(src)/fki-ko
