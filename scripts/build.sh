#!/usr/bin/env bash
set -euo pipefail

WORKDIR=$PWD
KERNEL_DIR=$WORKDIR/kernel
OUT=$WORKDIR/out
DIST=$WORKDIR/dist
LTO_MODE=${LTO_MODE:-full}
LOCALVERSION_INPUT=${LOCALVERSION_INPUT:-+AFX-SM8550}
JOBS=${JOBS:-$(nproc)}

TOOLCHAIN=$WORKDIR/toolchain/clang-r450784e
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android-gs-bluejay-5.10-android13/clang-r450784e.tar.gz"
FW_DIR=$WORKDIR/firmware/rtl_nic
FW_URL="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain/rtl_nic/rtl8156b-2.fw"

log() { echo -e "\n\033[1;34m[$(date +%H:%M:%S)] $*\033[0m"; }

log "Downloading clang-r450784e"
mkdir -p "$WORKDIR/toolchain"
if [ ! -x "$TOOLCHAIN/bin/clang" ]; then
	curl -fL -o /tmp/clang-r450784e.tar.gz "$CLANG_URL"
	tar -xzf /tmp/clang-r450784e.tar.gz -C "$WORKDIR/toolchain"
	rm -f /tmp/clang-r450784e.tar.gz
fi
"$TOOLCHAIN/bin/clang" --version | head -1

log "Downloading EXTRA_FIRMWARE rtl8156b-2.fw"
mkdir -p "$FW_DIR"
if [ ! -s "$FW_DIR/rtl8156b-2.fw" ]; then
	curl -fL -o "$FW_DIR/rtl8156b-2.fw" "$FW_URL"
fi

log "Cloning Xiaomi kernel source (bsp-vermeer-t-oss)"
if [ ! -d "$KERNEL_DIR/.git" ]; then
	git clone --depth=1 -b bsp-vermeer-t-oss \
		https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git "$KERNEL_DIR"
fi

log "Cloning SukiSU-Ultra (builtin branch)"
if [ ! -d "$WORKDIR/SukiSU-Ultra/.git" ]; then
	git clone --depth=1 -b builtin \
		https://github.com/SukiSU-Ultra/SukiSU-Ultra.git "$WORKDIR/SukiSU-Ultra"
fi

log "Cloning susfs4ksu (gki-android14-5.15)"
if [ ! -d "$WORKDIR/susfs4ksu/.git" ]; then
	git clone --depth=1 -b gki-android14-5.15 \
		https://gitlab.com/simonpunk/susfs4ksu.git "$WORKDIR/susfs4ksu"
fi

log "Integrating SukiSU-Ultra"
ln -sfn ../../SukiSU-Ultra/kernel "$KERNEL_DIR/drivers/kernelsu"
if ! grep -q 'drivers/kernelsu/Kconfig' "$KERNEL_DIR/drivers/Kconfig"; then
	sed -i 's#^source "drivers/xiaomi/Kconfig"#source "drivers/xiaomi/Kconfig"\nsource "drivers/kernelsu/Kconfig"#' \
		"$KERNEL_DIR/drivers/Kconfig"
fi
if ! grep -q 'CONFIG_KSU.*kernelsu/' "$KERNEL_DIR/drivers/Makefile"; then
	sed -i '/^obj-y[[:space:]]*+= xiaomi\/$/i obj-$(CONFIG_KSU)\t\t+= kernelsu/' \
		"$KERNEL_DIR/drivers/Makefile"
fi

log "Applying SUSFS v2.4.0 kernel patch"
cp "$WORKDIR/susfs4ksu/kernel_patches/fs/susfs.c" "$KERNEL_DIR/fs/susfs.c"
cp "$WORKDIR/susfs4ksu/kernel_patches/include/linux/susfs.h" "$KERNEL_DIR/include/linux/susfs.h"
cp "$WORKDIR/susfs4ksu/kernel_patches/include/linux/susfs_def.h" "$KERNEL_DIR/include/linux/susfs_def.h"
(
	cd "$KERNEL_DIR"
	patch -p1 --batch --forward --no-backup-if-mismatch \
		< "$WORKDIR/susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-5.15.patch"
)

log "Applying tree fixups for this trimmed source drop"
mkdir -p "$KERNEL_DIR/drivers/misc/hwid"
cp "$WORKDIR/stubs/hwid/"* "$KERNEL_DIR/drivers/misc/hwid/"

# VMA_PAD_START comes from newer ACK page-migration work and is absent here.
sed -i 's/end = VMA_PAD_START(vma);/end = vma->vm_end;/' "$KERNEL_DIR/fs/proc/task_mmu.c"

# dump_display.c builds a ~2.4K stack frame; raise the warning limit for this file only.
if ! grep -q 'CFLAGS_dump_display.o' "$KERNEL_DIR/drivers/xiaomi/Makefile"; then
	sed -i '1i CFLAGS_dump_display.o                     += -Wframe-larger-than=4096' \
		"$KERNEL_DIR/drivers/xiaomi/Makefile"
fi

# The vendor Makefile hardcodes kernel.release to VERSION.PATCHLEVEL.SUBLEVEL.
python3 - "$KERNEL_DIR/Makefile" <<'PY'
import sys

path = sys.argv[1]
src = open(path).read()
old = 'filechk_kernel.release = \\\n\techo "$(KERNELVERSION)"'
new = (
    'filechk_kernel.release = \\\n'
    '\techo "$(KERNELVERSION)$$($(CONFIG_SHELL) $(srctree)/scripts/setlocalversion \\\n'
    '\t\t$(srctree))"'
)
if old not in src:
    raise SystemExit("filechk_kernel.release pattern not found")
open(path, 'w').write(src.replace(old, new, 1))
PY

log "Generating kernel config (LTO=$LTO_MODE)"
mkdir -p "$OUT"
export PATH="$TOOLCHAIN/bin:$PATH"
MAKE_ARGS=(
	O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1
	CROSS_COMPILE=aarch64-linux-gnu- CLANG_TRIPLE=aarch64-linux-gnu-
)

make -C "$KERNEL_DIR" "${MAKE_ARGS[@]}" gki_defconfig

EXTRA=$WORKDIR/extra.config
{
	echo "CONFIG_LOCALVERSION=\"$LOCALVERSION_INPUT\""
	echo "CONFIG_LOCALVERSION_AUTO=n"
	echo "CONFIG_EXTRA_FIRMWARE=\"rtl8156b-2.fw\""
	echo "CONFIG_EXTRA_FIRMWARE_DIR=\"$FW_DIR\""
	echo "CONFIG_KSU=y"
	echo "CONFIG_KSU_SUSFS=y"
	echo "CONFIG_KALLSYMS=y"
	echo "CONFIG_KALLSYMS_ALL=y"
	echo "CONFIG_KPM=y"
	echo "CONFIG_KSU_MANUAL_SU=y"
	echo "# CONFIG_MI_HARDWARE_ID is not set"
	echo "# CONFIG_DEBUG_INFO is not set"
	case "$LTO_MODE" in
	full)
		echo "CONFIG_LTO_CLANG_FULL=y"
		echo "# CONFIG_LTO_CLANG_THIN is not set"
		echo "# CONFIG_LTO_NONE is not set"
		echo "CONFIG_CFI_CLANG=y"
		;;
	thin)
		echo "# CONFIG_LTO_CLANG_FULL is not set"
		echo "CONFIG_LTO_CLANG_THIN=y"
		echo "# CONFIG_LTO_NONE is not set"
		echo "CONFIG_CFI_CLANG=y"
		;;
	none)
		echo "# CONFIG_LTO_CLANG_FULL is not set"
		echo "# CONFIG_LTO_CLANG_THIN is not set"
		echo "CONFIG_LTO_NONE=y"
		echo "# CONFIG_CFI_CLANG is not set"
		;;
	*)
		echo "Unknown LTO_MODE: $LTO_MODE" >&2
		exit 1
		;;
	esac
} >"$EXTRA"

(
	cd "$KERNEL_DIR"
	ARCH=arm64 scripts/kconfig/merge_config.sh -m -O "$OUT" "$OUT/.config" \
		arch/arm64/configs/vendor/vermeer_GKI.config \
		"$WORKDIR/config/user.config" \
		"$EXTRA"
)
rm -f "$OUT/include/config/auto.conf"
make -C "$KERNEL_DIR" "${MAKE_ARGS[@]}" olddefconfig
make -C "$KERNEL_DIR" "${MAKE_ARGS[@]}" syncconfig

RELEASE=$(make -s -C "$KERNEL_DIR" "${MAKE_ARGS[@]}" LOCALVERSION= kernelrelease | tail -1)
echo "Kernel release: $RELEASE"
[ "$RELEASE" = "5.15.78${LOCALVERSION_INPUT}" ] || {
	echo "Unexpected kernel release: $RELEASE" >&2
	exit 1
}

log "Building Image/modules/dtbs (this is the long step)"
make -C "$KERNEL_DIR" "${MAKE_ARGS[@]}" LOCALVERSION= -j"$JOBS" Image modules dtbs

log "Packaging"
rm -rf "$DIST"
mkdir -p "$DIST"
make -C "$KERNEL_DIR" "${MAKE_ARGS[@]}" LOCALVERSION= \
	INSTALL_MOD_PATH="$DIST" INSTALL_MOD_STRIP=1 modules_install
make -C "$KERNEL_DIR" "${MAKE_ARGS[@]}" LOCALVERSION= \
	INSTALL_DTBS_PATH="$DIST/dtb" dtbs_install
cp "$OUT/arch/arm64/boot/Image" "$DIST/Image"
cp "$OUT/System.map" "$DIST/System.map"
cp "$OUT/.config" "$DIST/config"
cp "$OUT/Module.symvers" "$DIST/Module.symvers"
cp "$OUT/vmlinux" "$DIST/vmlinux"
tar -C "$DIST" --exclude="AFX-${RELEASE}.tar.gz" -czf "$DIST/AFX-${RELEASE}.tar.gz" .
ls -lh "$DIST"
