#!/bin/bash

set -Eeuo pipefail

target_disk="${1:-/dev/vda}"
hostname="${2:-arch-arm}"
install_root=/mnt
state_file=/run/basic-arm-install.state
log_file=/run/basic-arm-install.log

exec > >(tee "$log_file") 2>&1

set_state() {
  printf '%s\n' "$1" >"$state_file"
}

fail() {
  local line=$1 command=$2

  printf 'failed:%s:%s\n' "$line" "$command" >"$state_file"
  printf 'ERROR: basic Arch ARM installation failed at %s: %s\n' "$line" "$command" >&2
}

trap 'fail "$LINENO" "$BASH_COMMAND"' ERR
set_state validating

[[ $(uname -m) == "aarch64" ]] || {
  echo "ERROR: this installer must run in the native AArch64 live environment" >&2
  exit 1
}
(( EUID == 0 )) || {
  echo "ERROR: this installer must run as root" >&2
  exit 1
}
[[ -b $target_disk ]] || {
  echo "ERROR: target disk is not a block device: $target_disk" >&2
  exit 1
}
[[ $hostname =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || {
  echo "ERROR: invalid hostname: $hostname" >&2
  exit 1
}
[[ $(findmnt -n -o SOURCE /) == "airootfs" ]] || {
  echo "ERROR: run this installer from the ArchISO live environment" >&2
  exit 1
}
[[ -f /run/archiso/bootmnt/arch/boot/aarch64/vmlinuz-linux-aarch64 ]] || {
  echo "ERROR: the AArch64 kernel is unavailable on the live ISO" >&2
  exit 1
}

mapfile -t network_devices < <(ls /sys/class/net)
(( ${#network_devices[@]} == 1 )) && [[ ${network_devices[0]} == "lo" ]] || {
  echo "ERROR: this acceptance installation requires a zero-network VM" >&2
  printf 'Detected interfaces: %s\n' "${network_devices[*]}" >&2
  exit 1
}

disk_bytes=$(blockdev --getsize64 "$target_disk")
(( disk_bytes >= 8 * 1024 * 1024 * 1024 )) || {
  echo "ERROR: target disk must be at least 8 GiB" >&2
  exit 1
}

if [[ $target_disk =~ [0-9]$ ]]; then
  efi_partition="${target_disk}p1"
  root_partition="${target_disk}p2"
else
  efi_partition="${target_disk}1"
  root_partition="${target_disk}2"
fi

cleanup() {
  if mountpoint -q "$install_root"; then
    umount -R "$install_root"
  fi
}
trap cleanup EXIT

echo "Partitioning $target_disk for UEFI Arch Linux ARM..."
set_state partitioning
sgdisk --zap-all "$target_disk"
sgdisk --new=1:0:+1G --typecode=1:EF00 --change-name=1:EFI "$target_disk"
sgdisk --new=2:0:0 --typecode=2:8300 --change-name=2:ArchLinuxARM "$target_disk"
partprobe "$target_disk"
udevadm settle --timeout=30
[[ -b $efi_partition && -b $root_partition ]] || {
  echo "ERROR: target partitions did not appear after udev settled" >&2
  exit 1
}

mkfs.fat -F 32 -n ARCH_EFI "$efi_partition"
mkfs.ext4 -F -L ArchLinuxARM "$root_partition"

mount "$root_partition" "$install_root"
mkdir -p "$install_root/boot/efi"
mount "$efi_partition" "$install_root/boot/efi"

echo "Copying the complete basic Arch system from the offline ISO..."
set_state copying
rsync -aHAX --numeric-ids \
  --exclude=/boot/ \
  --exclude=/dev/ \
  --exclude=/mnt/ \
  --exclude=/proc/ \
  --exclude=/run/ \
  --exclude=/sys/ \
  --exclude=/tmp/ \
  / "$install_root/"
install -d -m 0755 \
  "$install_root/dev" \
  "$install_root/mnt" \
  "$install_root/proc" \
  "$install_root/run" \
  "$install_root/sys" \
  "$install_root/tmp"
chmod 1777 "$install_root/tmp"

echo "Configuring the installed system..."
set_state configuring
printf '%s\n' "$hostname" >"$install_root/etc/hostname"
printf '%s\n' 'LANG=en_US.UTF-8' >"$install_root/etc/locale.conf"
printf '%s\n' 'KEYMAP=us' >"$install_root/etc/vconsole.conf"
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' "$install_root/etc/locale.gen"
ln -sfn /usr/share/zoneinfo/UTC "$install_root/etc/localtime"
printf '%s\n' 'root:arch' | arch-chroot "$install_root" chpasswd
arch-chroot "$install_root" locale-gen

rm -f \
  "$install_root/etc/machine-id" \
  "$install_root/etc/mkinitcpio.conf.d/archiso.conf" \
  "$install_root/etc/pacman.d/hooks/89-archiso-arm-kernel.hook" \
  "$install_root/etc/systemd/system/multi-user.target.wants/choose-mirror.service" \
  "$install_root/etc/systemd/system/multi-user.target.wants/pacman-init.service" \
  "$install_root/etc/systemd/system/getty@tty1.service.d/autologin.conf" \
  "$install_root/etc/systemd/system/serial-getty@ttyAMA0.service.d/autologin.conf"
touch "$install_root/etc/machine-id"

cat >"$install_root/etc/systemd/network/20-wired.network" <<'NETWORK'
[Match]
Name=en* eth*

[Network]
DHCP=yes
NETWORK

systemctl --root="$install_root" enable \
  qemu-guest-agent.service \
  serial-getty@ttyAMA0.service \
  sshd.service \
  systemd-networkd.service \
  systemd-resolved.service
ln -sfn /run/systemd/resolve/stub-resolv.conf "$install_root/etc/resolv.conf"

echo "Installing the native ARM kernel and initramfs..."
set_state initramfs
install -m 0644 \
  /run/archiso/bootmnt/arch/boot/aarch64/vmlinuz-linux-aarch64 \
  "$install_root/boot/Image"
ln -sfn Image "$install_root/boot/vmlinuz-linux-aarch64"
cat >"$install_root/etc/mkinitcpio.d/linux-aarch64.preset" <<'PRESET'
PRESETS=('default')
ALL_kver='/boot/Image'
default_image='/boot/initramfs-linux-aarch64.img'
PRESET
sed -i \
  -e 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard block filesystems fsck)/' \
  "$install_root/etc/mkinitcpio.conf"
arch-chroot "$install_root" mkinitcpio -p linux-aarch64

echo "Installing the removable-media AArch64 UEFI bootloader..."
set_state bootloader
arch-chroot "$install_root" grub-install \
  --target=arm64-efi \
  --efi-directory=/boot/efi \
  --bootloader-id=ArchLinuxARM \
  --removable \
  --no-nvram

root_uuid=$(blkid -s UUID -o value "$root_partition")
mkdir -p "$install_root/boot/grub"
cat >"$install_root/boot/grub/grub.cfg" <<GRUB
set default=0
set timeout=2

menuentry 'Arch Linux ARM' {
  search --no-floppy --fs-uuid --set=root $root_uuid
  linux /boot/Image root=UUID=$root_uuid rw console=ttyAMA0,115200 console=tty0
  initrd /boot/initramfs-linux-aarch64.img
}
GRUB

genfstab -U "$install_root" >"$install_root/etc/fstab"

echo "Validating the offline basic installation..."
set_state final-validation
for command in bash cat cp grep ls mount mv pacman sed ssh systemctl; do
  [[ -x $install_root/usr/bin/$command ]] || {
    echo "ERROR: installed basic command is missing: $command" >&2
    exit 1
  }
done
[[ -s $install_root/boot/Image ]]
[[ -s $install_root/boot/initramfs-linux-aarch64.img ]]
[[ -s $install_root/boot/efi/EFI/BOOT/BOOTAA64.EFI ]]
[[ -s $install_root/boot/grub/grub.cfg ]]

sync
set_state complete
echo "BASIC_ARM_INSTALL_COMPLETE"
