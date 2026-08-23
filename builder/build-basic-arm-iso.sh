#!/bin/bash

set -Eeuo pipefail
trap 'printf "ERROR: basic ARM ISO build failed at %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

[[ $(uname -m) == "aarch64" ]] || {
  echo "ERROR: the basic Arch Linux ARM ISO must be built on native AArch64 Linux" >&2
  exit 1
}
(( EUID == 0 )) || {
  echo "ERROR: the basic Arch Linux ARM ISO build must run as root" >&2
  exit 1
}

source_root="${OMARCHY_ISO_SOURCE_ROOT:-$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)}"
cache_root="${OMARCHY_ARM_ARTIFACT_CACHE:-/var/cache/llamarchy/utm-arm}"
profile="$cache_root/basic-iso/profile"
work="$cache_root/basic-iso/work"
output="$cache_root/basic-iso/release"
package_cache="$cache_root/pacman/pkg"
mkarchiso=/usr/local/bin/mkarchiso

archiso_root="$source_root/archiso"
builder_root="$source_root/builder"
configs_root="$source_root/configs"

[[ $cache_root == /* && $cache_root != "/" ]] || {
  echo "ERROR: unsafe ARM artifact cache path: $cache_root" >&2
  exit 1
}
[[ -x $archiso_root/archiso/mkarchiso ]] || {
  echo "ERROR: initialized ArchISO sources are unavailable at $archiso_root" >&2
  exit 1
}
[[ -s $builder_root/basic-live.packages.aarch64 ]] || {
  echo "ERROR: the reviewed basic Arch Linux ARM package list is unavailable" >&2
  exit 1
}

mkdir -p "$cache_root/basic-iso" "$output" "$package_cache"
rm -rf "$profile" "$work"
mkdir -p "$profile"
cp -a "$archiso_root/configs/releng/." "$profile/"

# Use the ordinary ArchISO rescue environment with the generic Arch Linux ARM
# kernel. GRUB provides the complete UEFI boot path; the optional edk2 shell is
# absent from the Arch Linux ARM repositories.
{
  cat "$builder_root/basic-live.packages.aarch64"
  printf '%s\n' archlinuxarm-keyring
} | sort -u >"$profile/packages.aarch64"
rm -f "$profile/packages.x86_64"

cp "$configs_root/pacman-online-aarch64.conf" "$profile/pacman.conf"
sed -i "/^\[options\]$/a CacheDir = $package_cache" "$profile/pacman.conf"

rm -f \
  "$profile/airootfs/etc/mkinitcpio.d/linux.preset" \
  "$profile/airootfs/etc/modprobe.d/blacklist-applesmc.conf"
sed -i \
  -e 's/ microcode//' \
  -e 's/ memdisk//' \
  -e 's/ archiso_pxe_common//' \
  -e 's/ archiso_pxe_nbd//' \
  -e 's/ archiso_pxe_http//' \
  -e 's/ archiso_pxe_nfs//' \
  "$profile/airootfs/etc/mkinitcpio.conf.d/archiso.conf"
install -m 0755 "$builder_root/install-basic-arm.sh" \
  "$profile/airootfs/root/install-basic-arm.sh"

# Configure the ARM live preset before pacman's ordinary mkinitcpio hook runs.
# This produces the one initramfs the ISO actually boots and avoids building an
# unused default image followed by a second custom image.
mkdir -p \
  "$profile/airootfs/etc/pacman.d/hooks" \
  "$profile/airootfs/usr/local/bin"
cat >"$profile/airootfs/usr/local/bin/configure-archiso-arm-kernel" <<'SCRIPT'
#!/bin/bash

set -euo pipefail

cat >/etc/mkinitcpio.d/linux-aarch64.preset <<'PRESET'
PRESETS=('archiso')
ALL_kver='/boot/Image'
archiso_config='/etc/mkinitcpio.conf.d/archiso.conf'
archiso_image='/boot/initramfs-linux-aarch64.img'
PRESET
ln -sfn Image /boot/vmlinuz-linux-aarch64
SCRIPT
chmod 0755 "$profile/airootfs/usr/local/bin/configure-archiso-arm-kernel"
cat >"$profile/airootfs/etc/pacman.d/hooks/89-archiso-arm-kernel.hook" <<'HOOK'
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux-aarch64

[Action]
Description = Configuring the native ARM live kernel preset...
When = PostTransaction
Exec = /usr/local/bin/configure-archiso-arm-kernel
HOOK

mkdir -p "$profile/airootfs/etc/systemd/system/multi-user.target.wants"
ln -sfn /usr/lib/systemd/system/qemu-guest-agent.service \
  "$profile/airootfs/etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service"

# The generic AArch64 kernel package exposes Image through this compatibility
# name after customize_airootfs.sh builds the live initramfs.
sed -i \
  -e 's/vmlinuz-linux/vmlinuz-linux-aarch64/g' \
  -e 's/initramfs-linux\.img/initramfs-linux-aarch64.img/g' \
  "$profile/grub/grub.cfg" "$profile/grub/loopback.cfg"
sed -i \
  -e '/^insmod usbserial_/d' \
  -e 's/^timeout=15$/timeout=3/' \
  -e 's/ archisobasedir=/ console=ttyAMA0,115200 console=tty0 loglevel=4 archisobasedir=/' \
  "$profile/grub/grub.cfg" "$profile/grub/loopback.cfg"

cat >"$profile/profiledef.sh" <<'PROFILE'
#!/bin/bash
# shellcheck disable=SC2034

iso_name="archlinuxarm-basic"
iso_label="ALARM_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m%d)"
iso_publisher="Arch Linux ARM <https://archlinuxarm.org>"
iso_application="Arch Linux ARM AArch64 Live Environment"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
bootmodes=('uefi.grub')
arch="aarch64"
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-b' '1M' '-Xdict-size' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/.gnupg"]="0:0:700"
  ["/root/install-basic-arm.sh"]="0:0:755"
  ["/usr/local/bin/configure-archiso-arm-kernel"]="0:0:755"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/Installation_guide"]="0:0:755"
  ["/usr/local/bin/livecd-sound"]="0:0:755"
)
PROFILE
chmod 0755 "$profile/profiledef.sh"

pacman-key --init
pacman-key --populate archlinuxarm

# ArchISO's shared module list includes input and USB modules that GRUB's
# arm64-efi target does not publish. Keep one validated native copy of the
# builder executable for both basic and full offline images.
install -m 0755 "$archiso_root/archiso/mkarchiso" "$mkarchiso"
sed -i \
  -e 's/ at_keyboard//' \
  -e 's/ keylayouts//' \
  -e 's/ usbserial_common//' \
  -e 's/ usbserial_ftdi//' \
  -e 's/ usbserial_pl2303//' \
  -e 's/ usbserial_usbdebug//' \
  -e 's/ usb / /' \
  "$mkarchiso"
if sed -n '/grubmodules=(all_video/,/video xfs zstd)/p' "$mkarchiso" |
  grep -Eq '\b(at_keyboard|keylayouts|usb|usbserial_common|usbserial_ftdi|usbserial_pl2303|usbserial_usbdebug)\b'; then
  echo "ERROR: ArchISO still requests a GRUB module unavailable on arm64-efi" >&2
  exit 1
fi

"$mkarchiso" -v -w "$work" -o "$output" "$profile"

latest_iso=$(find "$output" -maxdepth 1 -type f -name 'archlinuxarm-basic-*.iso' -print | sort | tail -1)
[[ -s $latest_iso ]] || {
  echo "ERROR: the basic Arch Linux ARM ISO was not produced" >&2
  exit 1
}

echo
echo "Basic Arch Linux ARM ISO: $latest_iso"
sha256sum "$latest_iso"
