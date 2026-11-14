#!/usr/bin/env bash
set -euo pipefail

WORKDIR=$PWD
COMMON=$WORKDIR/common
CLANG=$WORKDIR/prebuilts/clang/host/linux-x86/clang-r450784e
LOCALVERSION_INPUT=${LOCALVERSION_INPUT:--AFX-MiSM8550}
HOSTNAME_INPUT=${HOSTNAME_INPUT:-SM8550}
BOOT_PARTITION_SIZE=${BOOT_PARTITION_SIZE:-100663296}
COMMON_TAG=${COMMON_TAG:-android13-5.15-2023-02_r1}

step() { echo -e "\n\033[1;34m[$(date +%H:%M:%S)] $*\033[0m"; }

export PATH="$WORKDIR/newbuild/tools:$PATH"

step "Clone kernel/build (Android build.config / build.sh system)"
if [ ! -d "$WORKDIR/build/kernel/.git" ]; then
  git clone --depth 1 -b master-kernel-build-2022 \
    https://android.googlesource.com/kernel/build "$WORKDIR/build/kernel"
fi
cd "$WORKDIR/build"
for f in build.sh build_utils.sh _setup_env.sh build_abi.sh config.sh envsetup.sh \
         multi-switcher.sh gettop.sh abi static_analysis kleaf; do
  [ -e "kernel/$f" ] && ln -sfn "kernel/$f" "$f"
done
cd "$WORKDIR"

step "Download clang r450784e"
if [ ! -x "$CLANG/bin/clang" ]; then
  mkdir -p "$CLANG"
  curl -fL --retry 5 --retry-delay 5 -o "$WORKDIR/clang.tar.gz" \
    "https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/master-kernel-build-2022/clang-r450784e.tar.gz"
  tar -xzf "$WORKDIR/clang.tar.gz" -C "$CLANG"
  rm -f "$WORKDIR/clang.tar.gz"
fi
"$CLANG/bin/clang" --version | head -1

step "Clone ACK common ($COMMON_TAG, 5.15.78)"
rm -rf "$COMMON"
git clone --depth 1 --branch "$COMMON_TAG" \
  https://android.googlesource.com/kernel/common.git "$COMMON"
grep -q '^SUBLEVEL = 78' "$COMMON/Makefile"

step "Apply SUSFS v2.4.0 GKI patch (also carries the KSU manual hooks)"
cp "$WORKDIR/newbuild/susfs-gki/50_add_susfs_in_gki-android13-5.15.patch" "$COMMON/"
cp "$WORKDIR/newbuild/susfs-gki/fs/susfs.c" "$COMMON/fs/susfs.c"
cp "$WORKDIR/newbuild/susfs-gki/include/linux/susfs.h" \
   "$WORKDIR/newbuild/susfs-gki/include/linux/susfs_def.h" "$COMMON/include/linux/"
( cd "$COMMON" && patch -p1 --batch --forward --fuzz=3 \
    < "$WORKDIR/newbuild/susfs-gki/50_add_susfs_in_gki-android13-5.15.patch" ) || true

# This ACK tag has no <trace/hooks/blk.h>, so the first fs/namespace.c hunk
# rejects. Insert the same block using a 5.15.78-compatible anchor.
python3 - "$COMMON/fs/namespace.c" <<'PYFIX'
import sys
p = sys.argv[1]
s = open(p).read()
if '#include <linux/susfs_def.h>' not in s:
    s = s.replace('#include <linux/mnt_idmapping.h>\n',
                  '#include <linux/mnt_idmapping.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs_def.h>\n#endif\n', 1)
if '#define CL_COPY_MNT_NS' not in s:
    s = s.replace('/* Maximum number of mounts in a mount namespace */',
                  '#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\nextern bool susfs_is_current_ksu_domain(void);\nextern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n\n#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */\n#endif\n\n/* Maximum number of mounts in a mount namespace */', 1)
open(p, 'w').write(s)
PYFIX
rm -f "$COMMON/fs/namespace.c.rej"
if find "$COMMON" -name '*.rej' | grep -q .; then
  echo "Unhandled rejected hunks:" >&2
  find "$COMMON" -name '*.rej' >&2
  exit 1
fi
find "$COMMON" -name '*.orig' -delete
# 5.15.78 predates VMA_PAD_START; SUSFS uses it in task_mmu.c.
python3 - "$COMMON/fs/proc/task_mmu.c" <<'PYVMA'
import sys
p = sys.argv[1]
s = open(p).read()
if 'VMA_PAD_START' in s and '#define VMA_PAD_START' not in s:
    s = s.replace('#include <linux/pkeys.h>\n',
                  '#include <linux/pkeys.h>\n#ifndef VMA_PAD_START\n#define VMA_PAD_START(vma) ((vma)->vm_end)\n#endif\n', 1)
open(p, 'w').write(s)
PYVMA

step "Integrate SukiSU-Ultra builtin (vendored de9bc7e6)"
rm -rf "$COMMON/drivers/kernelsu"
ln -sfn ../../newbuild/SukiSU/kernelsu "$COMMON/drivers/kernelsu"
grep -q 'source "drivers/kernelsu/Kconfig"' "$COMMON/drivers/Kconfig" || \
  sed -i '/^endmenu/i source "drivers/kernelsu/Kconfig"' "$COMMON/drivers/Kconfig"
grep -q 'drivers/kernelsu/Kconfig' "$COMMON/drivers/Kconfig"
grep -q 'kernelsu/' "$COMMON/drivers/Makefile" || \
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$COMMON/drivers/Makefile"

step "Write config overrides (localversion=$LOCALVERSION_INPUT, hostname=$HOSTNAME_INPUT)"
cat > "$WORKDIR/newbuild/configs/gki-override.config" <<EOF
CONFIG_LOCALVERSION="$LOCALVERSION_INPUT"
# CONFIG_LOCALVERSION_AUTO is not set
CONFIG_DEFAULT_HOSTNAME="$HOSTNAME_INPUT"
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KALLSYMS=y
CONFIG_KALLSYMS_ALL=y
CONFIG_KPM=y
# CONFIG_DEBUG_INFO is not set
# CONFIG_DEBUG_INFO_BTF is not set
# CONFIG_DEBUG_INFO_BTF_MODULES is not set
# CONFIG_TRIM_UNUSED_KSYMS is not set
# CONFIG_UNUSED_KSYMS_WHITELIST is not set
EOF

step "Write build.sh fragment"
cat > "$WORKDIR/newbuild/configs/gki-build.fragment" <<'EOF'
MAKE_GOALS="Image"
FILES="arch/arm64/boot/Image vmlinux System.map"
KMI_SYMBOL_LIST_STRICT_MODE=0
KMI_ENFORCED=0
TRIM_NONLISTED_KMI=0
ABI_DEFINITION=
KMI_SYMBOL_LIST=
ADDITIONAL_KMI_SYMBOL_LISTS=
BUILD_GKI_ARTIFACTS=
BUILD_GKI_CERTIFICATION_TOOLS=
BUILD_SYSTEM_DLKM=0
IN_KERNEL_MODULES=
BUILD_INITRAMFS=0
MODULES_ORDER=
GKI_MODULES_LIST=
LTO=thin
NDK_TRIPLE=
HERMETIC_TOOLCHAIN=0
BUILDTOOLS_PREBUILT_BIN=
DTC=
CLANG_PREBUILT_BIN=prebuilts/clang/host/linux-x86/clang-r450784e/bin
KLEAF_SUPPRESS_BUILD_SH_DEPRECATION_WARNING=1
function afx_gki_config() {
  local K="${ROOT_DIR}/${KERNEL_DIR}"
  set -x
  "${K}/scripts/kconfig/merge_config.sh" -m -O "${OUT_DIR}" "${OUT_DIR}/.config" \
    "${ROOT_DIR}/newbuild/configs/device-gki.config" \
    "${ROOT_DIR}/newbuild/configs/gki-override.config"
  ( cd "${OUT_DIR}" && make ${TOOL_ARGS} O="${OUT_DIR}" olddefconfig )
}
POST_DEFCONFIG_CMDS="afx_gki_config"
EOF

step "Build GKI Image with build/build.sh (new build system)"
mkdir -p "$WORKDIR/tmp"
export TMPDIR="$WORKDIR/tmp"
BUILD_CONFIG=common/build.config.gki.aarch64 \
BUILD_CONFIG_FRAGMENTS=newbuild/configs/gki-build.fragment \
build/build.sh

OUT="$WORKDIR/out/android13-5.15/common"
RELEASE_FILE="$OUT/include/config/kernel.release"
DIST=$(find "$WORKDIR/out" -maxdepth 3 -type d -name dist | head -1)
[ -n "$DIST" ] && [ -f "$DIST/Image" ] || { echo "Image not found under $WORKDIR/out" >&2; exit 1; }

step "Verify release / module_layout CRC"
echo "kernel.release: $(cat "$RELEASE_FILE")"
strings -a "$DIST/Image" | grep -m1 "Linux version"
strings -a "$DIST/Image" | grep -m1 -- "$(cat "$RELEASE_FILE")"
grep -m1 "module_layout" "$OUT/Module.symvers" || true

step "Create boot.img (header v4, kernel-only, pad to factory partition size)"
if [ ! -d "$WORKDIR/tools/mkbootimg/.git" ]; then
  git clone --depth 1 https://android.googlesource.com/platform/system/tools/mkbootimg \
    "$WORKDIR/tools/mkbootimg"
fi
python3 "$WORKDIR/tools/mkbootimg/mkbootimg.py" --header_version 4 \
  --kernel "$DIST/Image" --output "$WORKDIR/boot-AFX.img"
truncate -s "$BOOT_PARTITION_SIZE" "$WORKDIR/boot-AFX.img"

step "Collect artifacts"
rm -rf "$WORKDIR/artifacts"
mkdir -p "$WORKDIR/artifacts"
cp "$DIST/Image" "$WORKDIR/artifacts/Image"
cp "$WORKDIR/boot-AFX.img" "$WORKDIR/artifacts/boot-AFX.img"
cp "$RELEASE_FILE" "$WORKDIR/artifacts/kernel.release"
cp "$OUT/.config" "$WORKDIR/artifacts/config"
[ -f "$DIST/System.map" ] && cp "$DIST/System.map" "$WORKDIR/artifacts/System.map" || true
cp "$OUT/Module.symvers" "$WORKDIR/artifacts/Module.symvers"
sha256sum "$WORKDIR/artifacts/"* > "$WORKDIR/artifacts/SHA256SUMS.txt"
ls -lh "$WORKDIR/artifacts"
