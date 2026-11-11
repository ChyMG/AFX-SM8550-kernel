#!/usr/bin/env bash
set -euo pipefail

WORKDIR=$PWD
KERNEL=$WORKDIR/kernel
DIST=$WORKDIR/dist
KSU_DIR=$WORKDIR/SukiSU-Ultra
TOOLCHAIN=$WORKDIR/toolchain/clang-r450784e
CLANG_URL="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/android-gs-bluejay-5.10-android13/clang-r450784e.tar.gz"
KERNEL_COMMIT=${KERNEL_COMMIT:?KERNEL_COMMIT is required}
EXPECTED_RELEASE="5.15.194-android13-8-00019-gf4321180a397-ab15212794"
EXPECTED_VERMAGIC="${EXPECTED_RELEASE} SMP preempt mod_unload modversions aarch64"
JOBS=${JOBS:-$(nproc)}
WITH_KPM=${WITH_KPM:-y}
case "$WITH_KPM" in
	true|1|yes|y) WITH_KPM=y ;;
	false|0|no|n) WITH_KPM=n ;;
esac

log() { echo -e "\n\033[1;34m[$(date +%H:%M:%S)] $*\033[0m"; }

log "Downloading clang-r450784e"
mkdir -p "$WORKDIR/toolchain"
if [ ! -x "$TOOLCHAIN/bin/clang" ]; then
	mkdir -p "$TOOLCHAIN"
	curl -fL -o /tmp/clang-r450784e.tar.gz "$CLANG_URL"
	tar -xzf /tmp/clang-r450784e.tar.gz -C "$TOOLCHAIN"
	rm -f /tmp/clang-r450784e.tar.gz
fi
export PATH="$TOOLCHAIN/bin:$PATH"
"$TOOLCHAIN/bin/clang" --version | head -1

log "Fetching kernel/common @ $KERNEL_COMMIT"
if [ ! -d "$KERNEL/.git" ]; then
	mkdir -p "$KERNEL"
	git -C "$KERNEL" init -q
	git -C "$KERNEL" remote add origin https://android.googlesource.com/kernel/common
fi
git -C "$KERNEL" fetch --depth=1 origin "$KERNEL_COMMIT"
git -C "$KERNEL" checkout -q FETCH_HEAD

log "Preparing config"
cp "$WORKDIR/config/current-5.15.194.config" "$KERNEL/.config"
cat "$WORKDIR/config/lkm-extra.config" >> "$KERNEL/.config"

MAKE_ARGS=(
	-C "$KERNEL"
	ARCH=arm64 LLVM=1 LLVM_IAS=1
	CROSS_COMPILE=aarch64-linux-gnu-
	CLANG_TRIPLE=aarch64-linux-gnu-
)

make "${MAKE_ARGS[@]}" olddefconfig

log "Pinning kernel release to $EXPECTED_RELEASE"
python3 - "$KERNEL/Makefile" "$EXPECTED_RELEASE" <<'PY'
import sys

path, release = sys.argv[1], sys.argv[2]
src = open(path).read()
start = src.index('filechk_kernel.release = \\\n')
end = src.index('\n\n', start)
new = 'filechk_kernel.release = \\\n\techo "%s"' % release
src = src[:start] + new + src[end:]
open(path, 'w').write(src)
print("patched filechk_kernel.release")
PY

log "Building kernel modules (Full LTO/CFI; this is the long step)"
make "${MAKE_ARGS[@]}" -j"$JOBS" modules

RELEASE_H="$KERNEL/include/generated/utsrelease.h"
grep -q "\"$EXPECTED_RELEASE\"" "$RELEASE_H" || {
	echo "Unexpected release in $RELEASE_H:" >&2
	cat "$RELEASE_H" >&2
	exit 1
}
echo "UTS_RELEASE OK: $(cat "$RELEASE_H")"

log "Building SukiSU LKM (kernelsu.ko)"
if [ ! -d "$KSU_DIR/.git" ]; then
	git clone --depth=1 https://github.com/SukiSU-Ultra/SukiSU-Ultra.git "$KSU_DIR"
fi
if [ -n "${KSU_COMMIT:-}" ]; then
	git -C "$KSU_DIR" fetch --depth=1 origin "$KSU_COMMIT"
	git -C "$KSU_DIR" checkout -q FETCH_HEAD
fi

# Make the external module build see the KernelSU tristate options.
grep -q '^CONFIG_KSU=' "$KERNEL/include/config/auto.conf" || echo 'CONFIG_KSU=m' >> "$KERNEL/include/config/auto.conf"
grep -q '^CONFIG_KPM=' "$KERNEL/include/config/auto.conf" || echo "CONFIG_KPM=$WITH_KPM" >> "$KERNEL/include/config/auto.conf"

make "${MAKE_ARGS[@]}" M="$KSU_DIR/kernel" \
	CONFIG_KSU=m CONFIG_KPM="$WITH_KPM" -j"$JOBS" modules || {
		echo "kernelsu.ko build failed" >&2
		exit 1
	}

if [ ! -f "$KSU_DIR/kernel/kernelsu.ko" ]; then
	echo "kernelsu.ko not found" >&2
	find "$KSU_DIR" -name 'kernelsu.ko' -o -name '*.ko' | head -20 >&2
	exit 1
fi

log "Collecting modules"
mkdir -p "$DIST"
find "$KERNEL" -name '*.ko' -type f -exec cp -f {} "$DIST/" \;
cp -f "$KSU_DIR/kernel/kernelsu.ko" "$DIST/"
cp -r "$WORKDIR/firmware" "$DIST/"

log "Verifying vermagic"
modinfo -F vermagic "$DIST/cfg80211.ko" | tee "$DIST/vermagic.txt"
grep -q "$EXPECTED_VERMAGIC" "$DIST/vermagic.txt" || {
	echo "cfg80211.ko vermagic mismatch (expected: $EXPECTED_VERMAGIC)" >&2
	exit 1
}
modinfo -F vermagic "$DIST/kernelsu.ko" | tee -a "$DIST/vermagic.txt"

log "Writing load script"
cat > "$DIST/load.sh" <<'EOF'
#!/system/bin/sh
# Load AFX modules on the running 5.15.194 GKI kernel.
# Usage: su -c 'MODDIR=/data/local/tmp/afx-lkm sh load.sh'
MODDIR=${MODDIR:-/data/local/tmp/afx-lkm}
load() {
	[ -f "$MODDIR/$1" ] || return 0
	insmod "$MODDIR/$1" 2>/dev/null && echo "ok: $1" || echo "skip/fail: $1"
}

# wireless (order matters)
load cfg80211.ko
load mac80211.ko
load mt76.ko
load mt76-usb.ko
load mt76x0u.ko
load mt76x2u.ko

# USB serial
load usbserial.ko
load ch341.ko
load cp210x.ko
load pl2303.ko
load ftdi_sio.ko

# ipset
load ip_set.ko
for m in ip_set_bitmap_ip ip_set_bitmap_ipmac ip_set_bitmap_port \
         ip_set_hash_ip ip_set_hash_ipmark ip_set_hash_ipport \
         ip_set_hash_ipportip ip_set_hash_ipportnet ip_set_hash_mac \
         ip_set_hash_net ip_set_hash_netiface ip_set_hash_netnet \
         ip_set_hash_netport ip_set_hash_netportnet ip_set_list_set; do
	load "$m.ko"
done
load xt_set.ko

# already present as modules on stock GKI; harmless if loaded
load zram.ko
load zsmalloc.ko

# KernelSU LKM (or let the SukiSU manager load it)
load kernelsu.ko
EOF
chmod +x "$DIST/load.sh"

cat > "$DIST/README.txt" <<EOF
AFX LKM modules for running kernel:
  ${EXPECTED_RELEASE}

Expected vermagic:
  ${EXPECTED_VERMAGIC}

Contents:
  - usbserial/ch341/cp210x/pl2303/ftdi_sio : USB serial drivers
  - ip_set*/xt_set                      : IPSet + iptables set target
  - cfg80211/mac80211/mt76*             : MediaTek MT76 USB WiFi
  - kernelsu.ko                         : SukiSU Ultra LKM
  - firmware/rtl_nic/rtl8156b-2.fw      : r8152 USB Ethernet firmware

NOTES:
  - SUSFS is NOT included: it patches core kernel paths and cannot be a .ko.
  - KPM is built into kernelsu.ko when WITH_KPM=y, but may need the
    Image KPM patch on some GKI kernels.
  - MODULE_SIG_FORCE is off in your kernel, so modules signed with a
    different key should still load (with a taint warning).

Load:
  adb push <dir> /data/local/tmp/afx-lkm
  adb shell su -c 'MODDIR=/data/local/tmp/afx-lkm sh /data/local/tmp/afx-lkm/load.sh'

r8152 firmware:
  adb push firmware/rtl_nic/rtl8156b-2.fw /vendor/firmware/rtl_nic/
  (or /lib/firmware/rtl_nic/ on your ROM)
EOF

log "Packaging"
tar -C "$DIST" -czf "$WORKDIR/AFX-LKM-5.15.194.tar.gz" .
ls -lh "$DIST" "$WORKDIR/AFX-LKM-5.15.194.tar.gz"
