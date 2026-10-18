obj-m := droid_lkm.o

KDIR := $(KDIR)
MDIR := $(realpath $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
# a missing VER must not point at out/ itself
# make clean would wipe every target
ODIR := $(MDIR)/out/$(if $(VER),$(VER),unknown)

DEPS := Type_info KernCall HooKern
include $(MDIR)/mk/deps.mk

# Build only the main module for the verified Y70 kernel.
DEPS_OBJS_ALL := $(filter-out deps/HooKern/lib/hk_binder.o deps/HooKern/lib/hk_lsm.o,$(DEPS_OBJS_ALL))
MUNMAP_UNIT := src/ipcns/munmap_vmi.o

droid_lkm-y := src/core/main.o src/core/ds_hook.o \
	$(MUNMAP_UNIT) \
	src/core/ds_ksym.o \
	src/core/ds_caps.o \
	src/core/ds_ti.o \
	src/slot/ds_slot.o \
	src/pidns/pidns.o \
	src/pidns/ds_nsops.o \
	src/pidns/ds_proc.o \
	src/pidns/ds_status.o \
	src/ipcns/ipcns.o \
	src/ipcns/ksym_shim.o \
	src/ipcns/ipc_shim.o \
	src/ipcns/ipc_util.o \
	src/ipcns/ipc_syscall.o \
	src/ipcns/sysv/ipc_msg.o \
	src/ipcns/sysv/ipc_sem.o \
	src/ipcns/sysv/ipc_shm.o \
	src/ipcns/sysv/ipc_msgutil.o \
	src/ipcns/mqueue/ipc_mqueue.o \
	src/ipcns/mqueue/ipc_mqueue_shim.o \
	src/ipcns/mqueue/ipc_mq_sysctl.o \
	src/ipcns/sysctl/ipc_sysctl.o \
	src/ipcns/compat/ipc_compat32.o \
	$(DEPS_OBJS_ALL)

ccflags-y += -std=gnu11
ccflags-y += -Wno-declaration-after-statement
# dead static hk_build_jump in HooKern
ccflags-y += -Wno-unused-function
ccflags-y += -Wno-strict-prototypes
ccflags-y += -I$(src)/src
ccflags-y += -I$(src)/src/core -I$(src)/src/slot -I$(src)/src/pidns
ccflags-y += -I$(src)/src/ipcns -I$(src)/src/ipcns/sysv
ccflags-y += -I$(src)/src/ipcns/mqueue -I$(src)/src/ipcns/sysctl
ccflags-y += -I$(src)/src/ipcns/compat
ccflags-y += $(addprefix -I$(src)/,$(DEPS_INCS_ALL))

# 6.18 turns on -Wmissing-prototypes, and this module both defines kernel
# names the newer kernel stops declaring and exposes entry points through
# headers the shim files do not include; older compilers ignore the flag
ccflags-y += -Wno-missing-prototypes

# KernCall: enable sys_call_table slot patching
ccflags-y += -DCONFIG_KERNSC_PATCH -DCONFIG_KERNSC_DISCOVER

all:
	@mkdir -p $(sort $(dir $(addprefix $(ODIR)/,$(droid_lkm-y))))
	# 6.18 kbuild derives src from srcroot, older kernels ignore it
	make -C $(KDIR) M=$(ODIR) src=$(MDIR) srcroot=$(MDIR) modules
clean:
	make -C $(KDIR) M=$(ODIR) src=$(MDIR) srcroot=$(MDIR) clean

$(obj)/%.o: $(src)/%.c $(recordmcount_source) FORCE
	$(call if_changed_rule,cc_o_c)
	$(call cmd,force_checksrc)

$(obj)/%.o: $(src)/%.S FORCE
	$(call if_changed_rule,as_o_S)
