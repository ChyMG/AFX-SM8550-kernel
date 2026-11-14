#!/usr/bin/env bash
set -euo pipefail

WORKDIR=$PWD
KERNEL=$WORKDIR/msm-kernel
CLANG=$WORKDIR/prebuilts/clang/host/linux-x86/clang-r450784e
RELEASE_STRING=${RELEASE_STRING:-5.15.78-AFX-zzz-k-suffix}
BOOT_PARTITION_SIZE=${BOOT_PARTITION_SIZE:-100663296}
KSU_COMMIT=de9bc7e6
export PATH="$WORKDIR/newbuild/tools:$PATH"

step() { echo -e "\n\033[1;34m[$(date +%H:%M:%S)] $*\033[0m"; }

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

step "Clone Xiaomi kernel source (bsp-vermeer-t-oss)"
if [ ! -d "$KERNEL/.git" ]; then
  git clone --depth 1 -b bsp-vermeer-t-oss \
    https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git "$KERNEL"
fi

step "Apply AFX hooks + SUSFS + uname spoof patch"
git -C "$KERNEL" apply "$WORKDIR/newbuild/patches/afx-hooks-susfs-uname.patch"
cp "$WORKDIR/newbuild/susfs/fs/susfs.c" "$KERNEL/fs/susfs.c"
cp "$WORKDIR/newbuild/susfs/include/linux/susfs.h" \
   "$WORKDIR/newbuild/susfs/include/linux/susfs_def.h" "$KERNEL/include/linux/"
mkdir -p "$KERNEL/drivers/misc/hwid"
cp "$WORKDIR/newbuild/stubs/hwid/"* "$KERNEL/drivers/misc/hwid/"

step "Integrate SukiSU-Ultra builtin (vendored $KSU_COMMIT)"
rm -rf "$KERNEL/drivers/kernelsu"
ln -sfn ../../newbuild/SukiSU/kernelsu "$KERNEL/drivers/kernelsu"

step "Set uname -r string: $RELEASE_STRING"
python3 - "$KERNEL/kernel/sys.c" "$RELEASE_STRING" <<'PY'
import sys
path, wanted = sys.argv[1], sys.argv[2]
src = open(path).read()
old = 'strscpy(tmp.release, "5.15.78-AFX-zzz-k-suffix", sizeof(tmp.release));'
new = 'strscpy(tmp.release, "%s", sizeof(tmp.release));' % wanted
if old not in src:
    raise SystemExit("uname spoof anchor not found in kernel/sys.c")
open(path, "w").write(src.replace(old, new, 1))
PY

step "Install build config and build with build/build.sh (new build system)"
cp "$WORKDIR/newbuild/configs/build.config.afx" "$KERNEL/build.config.afx"
mkdir -p "$WORKDIR/tmp"
export TMPDIR="$WORKDIR/tmp"
BUILD_CONFIG=msm-kernel/build.config.afx build/build.sh

step "Verify kernel release / spoofed uname"
RELEASE_FILE="$WORKDIR/out/android13-5.15/msm-kernel/include/config/kernel.release"
cat "$RELEASE_FILE"
DIST=$(find "$WORKDIR/out" -maxdepth 3 -type d -name dist | head -1)
[ -n "$DIST" ] && [ -f "$DIST/Image" ] || { echo "Image not found under $WORKDIR/out" >&2; exit 1; }
strings -a "$DIST/Image" | grep -m1 "Linux version"
strings -a "$DIST/Image" | grep -m1 -- "$RELEASE_STRING"

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
cp "$WORKDIR/out/android13-5.15/msm-kernel/.config" "$WORKDIR/artifacts/config"
[ -f "$DIST/System.map" ] && cp "$DIST/System.map" "$WORKDIR/artifacts/System.map" || true
sha256sum "$WORKDIR/artifacts/"* > "$WORKDIR/artifacts/SHA256SUMS.txt"
ls -lh "$WORKDIR/artifacts"
