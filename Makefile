# SpacemiT K3 firmware build
#
# Builds the vendor OpenSBI and U-Boot firmware chain for the
# spacemit-k3 QEMU machine.
#
# Prerequisites: riscv64-linux-gnu- toolchain, lzop
#
# Targets:
#   all        - build opensbi and u-boot (default)
#   opensbi    - build vendor OpenSBI fw_dynamic.itb
#   uboot      - build vendor U-Boot (FSBL + bootinfo + u-boot.itb)
#   clean      - clean both trees
#   nor        - assemble nor.img (firmware at QEMU NOR offsets)
#   sd         - assemble sd.img (firmware at QEMU SD/EMMC offsets)
#   ufs        - assemble ufs.img (image with 4k block size)
#   help       - show this help

CROSS_COMPILE ?= riscv64-linux-gnu-
OPENSBI_SRC   := opensbi
UBOOT_SRC     := u-boot
LINUX_SRC     := linux
OUTPUT_DIR    := output
NPROC         := $(shell nproc)

OPENSBI_OUT   := $(OPENSBI_SRC)/build/platform/generic/firmware/fw_dynamic.itb
UBOOT_OUT     := $(UBOOT_SRC)/u-boot.itb
FSBL_OUT      := $(UBOOT_SRC)/FSBL.bin
BOOTINFO_BLK  := $(UBOOT_SRC)/bootinfo_block.bin
BOOTINFO_SPI  := $(UBOOT_SRC)/bootinfo_spinor.bin
NOR_IMG       := $(OUTPUT_DIR)/nor.img
SD_IMG        := $(OUTPUT_DIR)/sd.img
UFS_IMG       := $(OUTPUT_DIR)/ufs.img
LINUX_OUT     := $(LINUX_SRC)/arch/riscv/boot/Image
LINUX_DTB     := $(LINUX_SRC)/arch/riscv/boot/dts/spacemit/k3-pico-itx.dtb

# NOR flash layout (byte offsets)
NOR_BOOTINFO  := 0
NOR_FSBL       := 0x20000
NOR_OPENSBI    := 0x1b0000
NOR_UBOOT      := 0x210000
NOR_SIZE       := 8388608

# SD/EMMC layout (byte offsets, GPT with 512-byte sectors)
SD_BOOTINFO   := 0x100000
SD_FSBL        := 0x180000
SD_OPENSBI     := 0x700000
SD_UBOOT       := 0x800000
SD_SIZE        := 33554432

# UFS image
UFS_SIZE      := 33554432
UFS_SECTOR_SIZE := 4096
UFS_PART_START := 2048

.PHONY: all opensbi uboot linux nor sd ufs clean help

all: opensbi uboot nor sd linux ufs

# ---------------------------------------------------------------------------
# OpenSBI
# ---------------------------------------------------------------------------
# The vendor OpenSBI writes to an out-of-bounds address (store fault).
# Patch the offending call out before building, then enable logging.
# For the upstream OpenSBI, drop the sed and set FW_TEXT_START.

opensbi:
	sed -i 's|^\([[:space:]]*\)\(cci_enable_snoop_dvm_reqs([456]);\)|\1// \2|' \
		$(OPENSBI_SRC)/platform/generic/spacemit/spacemit_k3.c
	$(MAKE) -C $(OPENSBI_SRC) CROSS_COMPILE=$(CROSS_COMPILE) \
		PLATFORM_RISCV_XLEN=64 O=build PLATFORM=generic \
		PLATFORM_DEFCONFIG=k3_defconfig BUILD_INFO=y -j$(NPROC)
	cd $(OPENSBI_SRC) && KCONFIG_CONFIG=build/platform/generic/kconfig/.config \
		OPENSBI_PLATFORM_SRC_DIR=./platform/generic OPENSBI_SRC_DIR=./ \
		OPENSBI_PLATFORM=generic \
		./scripts/Kconfiglib/setconfig.py ENABLE_LOGGING=y
	$(MAKE) -C $(OPENSBI_SRC) CROSS_COMPILE=$(CROSS_COMPILE) \
		PLATFORM_RISCV_XLEN=64 O=build PLATFORM=generic BUILD_INFO=y -j$(NPROC)
	mkdir -p $(OUTPUT_DIR)
	cp $(OPENSBI_OUT) $(OUTPUT_DIR)/

# ---------------------------------------------------------------------------
# U-Boot: builds FSBL.bin, bootinfo_block.bin, bootinfo_spinor.bin,
# and u-boot.itb. Requires lzop (the build silently omits the ITB
# without it).
# ---------------------------------------------------------------------------
uboot:
	$(MAKE) -C $(UBOOT_SRC) CROSS_COMPILE=$(CROSS_COMPILE) k3_defconfig
	$(MAKE) -C $(UBOOT_SRC) CROSS_COMPILE=$(CROSS_COMPILE) -j$(NPROC)
	mkdir -p $(OUTPUT_DIR)
	cp $(UBOOT_OUT) $(FSBL_OUT) $(BOOTINFO_BLK) $(BOOTINFO_SPI) $(OUTPUT_DIR)/

# ---------------------------------------------------------------------------
# Linux kernel and DTB: build the kernel Image and the K3 Pico-ITX DTB
# from the untouched mainline riscv64 defconfig.
# ---------------------------------------------------------------------------
linux:
	$(MAKE) -C $(LINUX_SRC) CROSS_COMPILE=$(CROSS_COMPILE) ARCH=riscv \
		defconfig
	$(MAKE) -C $(LINUX_SRC) CROSS_COMPILE=$(CROSS_COMPILE) ARCH=riscv \
		-j$(NPROC) Image dtbs
	mkdir -p $(OUTPUT_DIR)
	cp $(LINUX_OUT) $(LINUX_DTB) $(OUTPUT_DIR)/

# ---------------------------------------------------------------------------
# Assemble NOR image for the spacemit-k3 QEMU machine
# ---------------------------------------------------------------------------
nor: opensbi uboot
	truncate -s $(NOR_SIZE) $(NOR_IMG)
	dd if=$(OUTPUT_DIR)/bootinfo_spinor.bin of=$(NOR_IMG) \
		bs=1 seek=$(NOR_BOOTINFO) conv=notrunc status=none
	dd if=$(OUTPUT_DIR)/FSBL.bin of=$(NOR_IMG) \
		bs=1 seek=$$(( $(NOR_FSBL) )) conv=notrunc status=none
	dd if=$(OUTPUT_DIR)/fw_dynamic.itb of=$(NOR_IMG) \
		bs=1 seek=$$(( $(NOR_OPENSBI) )) conv=notrunc status=none
	dd if=$(OUTPUT_DIR)/u-boot.itb of=$(NOR_IMG) \
		bs=1 seek=$$(( $(NOR_UBOOT) )) conv=notrunc status=none

# ---------------------------------------------------------------------------
# Assemble SD/EMMC image for the spacemit-k3 QEMU machine. An empty GPT
# label (512-byte sectors) with the firmware written at the raw byte
# offsets the bootrom expects. Attach with -drive if=sd,...,index=0 (SD)
# or index=2 (EMMC, with boot-mode=emmc).
# ---------------------------------------------------------------------------
sd: opensbi uboot
	@mkdir -p $(OUTPUT_DIR)
	truncate -s $(SD_SIZE) $(SD_IMG)
	echo 'label: gpt' | sfdisk $(SD_IMG)
	dd if=$(OUTPUT_DIR)/bootinfo_block.bin of=$(SD_IMG) \
		bs=1 seek=$$(( $(SD_BOOTINFO) )) conv=notrunc status=none
	dd if=$(OUTPUT_DIR)/FSBL.bin of=$(SD_IMG) \
		bs=1 seek=$$(( $(SD_FSBL) )) conv=notrunc status=none
	dd if=$(OUTPUT_DIR)/fw_dynamic.itb of=$(SD_IMG) \
		bs=1 seek=$$(( $(SD_OPENSBI) )) conv=notrunc status=none
	dd if=$(OUTPUT_DIR)/u-boot.itb of=$(SD_IMG) \
		bs=1 seek=$$(( $(SD_UBOOT) )) conv=notrunc status=none


UFS_SECTOR_SIZE := 4096
UFS_PART_START := 2048

# ---------------------------------------------------------------------------
# Assemble UFS test image: a 32 MB GPT image with 4096-byte sectors,
# containing a single ext4 partition starting at LBA 2048 with a
# hello.txt file, for testing UFS block-device access on the
# spacemit-k3 QEMU machine.
# ---------------------------------------------------------------------------
ufs:
	@mkdir -p $(OUTPUT_DIR)
	truncate -s $(UFS_SIZE) $(UFS_IMG)
	echo "Hello World" > $(OUTPUT_DIR)/hello.txt
	set -e; \
	LOOP=$$(sudo losetup -f --show -b $(UFS_SECTOR_SIZE) -P $(UFS_IMG)); \
	trap 'sudo losetup -d $$LOOP' EXIT; \
	printf 'label: gpt\nstart=$(UFS_PART_START), type=linux\n' | sudo sfdisk $$LOOP; \
	sudo partx -u $$LOOP; \
	sudo mkfs.ext4 -b 4096 -F $${LOOP}p1; \
	sudo debugfs -w -R "write $(OUTPUT_DIR)/hello.txt hello.txt" $${LOOP}p1

# ---------------------------------------------------------------------------
clean:
	$(MAKE) -C $(OPENSBI_SRC) O=build clean || true
	rm -rf $(OPENSBI_SRC)/build
	$(MAKE) -C $(UBOOT_SRC) distclean || true
	$(MAKE) -C $(LINUX_SRC) ARCH=riscv mrproper || true
	rm -rf $(OUTPUT_DIR)

help:
	@echo "Targets:"
	@echo "  all      - build opensbi, uboot, and linux"
	@echo "  opensbi  - build vendor OpenSBI fw_dynamic.itb"
	@echo "  uboot    - build vendor U-Boot (FSBL, bootinfo, u-boot.itb)"
	@echo "  linux    - build Linux kernel Image and k3-pico-itx.dtb"
	@echo "  nor       - assemble nor.img with firmware at QEMU NOR offsets"
	@echo "  sd        - assemble sd.img with firmware at QEMU SD/EMMC offsets"
	@echo "  ufs       - assemble ufs.img with a 4k block size"
	@echo "  clean     - clean all build trees"
