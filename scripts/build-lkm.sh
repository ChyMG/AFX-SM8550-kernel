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
BUILD_KSU=${BUILD_KSU:-0}
case "$BUILD_KSU" in
	true|1|yes|y) BUILD_KSU=1 ;;
	*) BUILD_KSU=0 ;;
esac

log() { echo -e "\n\033[1;34m[$(date +%H:%M:%S)] $*\033[0m"; }

log "Downloading clang-r450784e"
mkdir -p "$WORKDIR/toolchain"
download_clang() {
	for i in 1 2 3 4 5; do
		if curl -fL --retry 3 --retry-all-errors -o /tmp/clang-r450784e.tar.gz "$CLANG_URL" &&
		   tar -tzf /tmp/clang-r450784e.tar.gz >/dev/null 2>&1; then
			return 0
		fi
		rm -f /tmp/clang-r450784e.tar.gz
		sleep 5
	done
	return 1
}
if [ ! -x "$TOOLCHAIN/bin/clang" ]; then
	mkdir -p "$TOOLCHAIN"
	if download_clang; then
		tar -xzf /tmp/clang-r450784e.tar.gz -C "$TOOLCHAIN"
		rm -f /tmp/clang-r450784e.tar.gz
	else
		echo "gitiles archive failed; falling back to sparse git clone" >&2
		rm -rf "$WORKDIR/toolchain/clang-repo"
		git clone --depth=1 --filter=blob:none --sparse \
			-b android-gs-bluejay-5.10-android13 \
			https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86 \
			"$WORKDIR/toolchain/clang-repo"
		(cd "$WORKDIR/toolchain/clang-repo" && git sparse-checkout set clang-r450784e)
		TOOLCHAIN="$WORKDIR/toolchain/clang-repo/clang-r450784e"
	fi
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

log "Applying vendor cfg80211/mac80211 CRCs for MT76"
python3 "$WORKDIR/scripts/extract_exports.py" \
	"$WORKDIR/vendor/cfg80211.ko" "$WORKDIR/vendor/mac80211.ko" \
	> /tmp/vendor_exports.txt 2>/tmp/vendor_exports.meta
cat /tmp/vendor_exports.meta

python3 - "$KERNEL/Module.symvers" /tmp/vendor_exports.txt <<'PY'
import sys
symvers, vendor = sys.argv[1], sys.argv[2]
drop_mods = {"net/wireless/cfg80211", "net/mac80211/mac80211"}
out = []
for line in open(symvers):
    parts = line.rstrip("\n").split("\t")
    if len(parts) >= 3 and parts[2] in drop_mods:
        continue
    out.append(line.rstrip("\n"))
for line in open(vendor):
    line = line.strip()
    if line and not line.startswith("#"):
        out.append(line)
open(symvers, "w").write("\n".join(out) + "\n")
PY

# Force modpost to regenerate MT76's __versions with the vendor CRCs.
find "$KERNEL/drivers/net/wireless/mediatek/mt76" -maxdepth 1 \
	\( -name '*.ko' -o -name '*.mod' -o -name '*.mod.c' -o -name '*.mod.o' \) -delete
make "${MAKE_ARGS[@]}" -j"$JOBS" modules

if grep -qP '\t(net/wireless/cfg80211|net/mac80211/mac80211)\t' "$KERNEL/Module.symvers"; then
	echo "Module.symvers was regenerated; vendor CRC override lost" >&2
	exit 1
fi

log "Verifying MT76 imports use vendor cfg80211/mac80211 CRCs"
python3 - <<'PY'
import glob, re, sys
want = {
    "wiphy_new_nm": "0x73f25646",
    "ieee80211_alloc_hw_nm": "0xa260f321",
    "ieee80211_register_hw": "0x3726616f",
}
found = {}
for path in glob.glob("kernel/drivers/net/wireless/mediatek/mt76/*.mod.c"):
    text = open(path).read()
    for m in re.finditer(r'\{\s*(0x[0-9a-fA-F]+)\s*,\s*"([^"]+)"\s*\}', text):
        crc, name = m.group(1), m.group(2)
        if name in want:
            found[name] = crc
print("found vendor CRCs in MT76:", found)
if not found:
    sys.exit("no MT76 vendor symbol found in .mod.c; cannot verify")
for name, expected in found.items():
    if expected.lower() != want[name].lower():
        sys.exit(f"CRC mismatch for {name}: {expected} != {want[name]}")
print("MT76 vendor CRC check OK")
PY

log "Building SukiSU LKM (optional)"
if [ "${BUILD_KSU:-0}" = "1" ]; then
	if [ ! -d "$KSU_DIR/.git" ]; then
		git clone --depth=1 https://github.com/SukiSU-Ultra/SukiSU-Ultra.git "$KSU_DIR"
	fi
	if [ -n "${KSU_COMMIT:-}" ]; then
		git -C "$KSU_DIR" fetch --depth=1 origin "$KSU_COMMIT"
		git -C "$KSU_DIR" checkout -q FETCH_HEAD
	fi
	grep -q '^CONFIG_KSU=' "$KERNEL/include/config/auto.conf" || echo 'CONFIG_KSU=m' >> "$KERNEL/include/config/auto.conf"
	grep -q '^CONFIG_KPM=' "$KERNEL/include/config/auto.conf" || echo "CONFIG_KPM=$WITH_KPM" >> "$KERNEL/include/config/auto.conf"
	make "${MAKE_ARGS[@]}" M="$KSU_DIR/kernel" CONFIG_KSU=m CONFIG_KPM="$WITH_KPM" -j"$JOBS" modules
	[ -f "$KSU_DIR/kernel/kernelsu.ko" ] || { echo "kernelsu.ko not found" >&2; exit 1; }
else
	log "Skipping kernelsu.ko (target already has it loaded)"
fi

log "Collecting only the modules the target does not have"
mkdir -p "$DIST"
copy_one() {
	[ -n "$1" ] && cp -f "$1" "$DIST/"
}
find "$KERNEL" -name '*.ko' -type f | while IFS= read -r f; do
	base=$(basename "$f")
	case "$base" in
		usbserial.ko|ch341.ko|cp210x.ko|pl2303.ko|ftdi_sio.ko|xt_set.ko|mt76*.ko|ip_set*.ko)
			copy_one "$f" ;;
	esac
done
if [ "${BUILD_KSU:-0}" = "1" ] && [ -f "$KSU_DIR/kernel/kernelsu.ko" ]; then
	cp -f "$KSU_DIR/kernel/kernelsu.ko" "$DIST/"
fi
cp -r "$WORKDIR/firmware" "$DIST/"

log "Verifying vermagic"
modinfo -F vermagic "$DIST/mt76.ko" | tee "$DIST/vermagic.txt"
grep -q "$EXPECTED_VERMAGIC" "$DIST/vermagic.txt" || {
	echo "mt76.ko vermagic mismatch (expected: $EXPECTED_VERMAGIC)" >&2
	exit 1
}
for f in usbserial.ko ch341.ko cp210x.ko pl2303.ko ftdi_sio.ko ip_set.ko xt_set.ko mt76-usb.ko mt76x0u.ko mt76x2u.ko; do
	[ -f "$DIST/$f" ] || continue
	modinfo -F vermagic "$DIST/$f" | tee -a "$DIST/vermagic.txt"
done

log "Writing load script"
cat > "$DIST/load.sh" <<'EOF'
#!/system/bin/sh
# Load AFX modules on the running 5.15.194 GKI kernel.
# cfg80211/mac80211 are already loaded from vendor_dlkm; do NOT load them again.
MODDIR=${MODDIR:-/data/local/tmp/afx-lkm}
load() {
	[ -f "$MODDIR/$1" ] || return 0
	insmod "$MODDIR/$1" 2>/dev/null && echo "ok: $1" || echo "skip/fail: $1"
}

# MT76 depends on the already-loaded cfg80211/mac80211
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
EOF
chmod +x "$DIST/load.sh"

cat > "$DIST/README.txt" <<EOF
AFX modules for running kernel:
  ${EXPECTED_RELEASE}

Expected vermagic:
  ${EXPECTED_VERMAGIC}

Included (target does NOT have these):
  - usbserial/ch341/cp210x/pl2303/ftdi_sio : USB serial
  - ip_set*/xt_set                       : IPSet + iptables set target
  - mt76/mt76-usb/mt76x0u/mt76x2u        : MediaTek MT76 USB WiFi
  - firmware/rtl_nic/rtl8156b-2.fw       : r8152 USB Ethernet firmware

NOT included (already present/loaded on the target):
  - cfg80211.ko, mac80211.ko, zram.ko, zsmalloc.ko, kernelsu.ko
  - r8152 (built into the kernel)

MT76 note:
  MT76 was linked against the factory 5.15.78 cfg80211/mac80211 CRCs
  extracted from the vendor modules you uploaded.

SUSFS:
  Cannot be a .ko; it patches core kernel paths and needs a kernel build.

Load:
  adb push <dir> /data/local/tmp/afx-lkm
  adb shell su -c 'MODDIR=/data/local/tmp/afx-lkm sh /data/local/tmp/afx-lkm/load.sh'

r8152 firmware:
  adb push firmware/rtl_nic/rtl8156b-2.fw /vendor/firmware/rtl_nic/
EOF

log "Packaging"
tar -C "$DIST" -czf "$WORKDIR/AFX-LKM-5.15.194-vendor-crc.tar.gz" .
ls -lh "$DIST" "$WORKDIR/AFX-LKM-5.15.194-vendor-crc.tar.gz"
