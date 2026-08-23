#!/bin/bash

set -euo pipefail

root_shell=$(getent passwd root | cut -d: -f7)
if [[ ! -x $root_shell ]]; then
  echo "ERROR: the live root login shell is not installed: $root_shell" >&2
  exit 1
fi

required_commands=(
  arch-chroot
  blkid
  btrfs
  genfstab
  grub-install
  gum
  jq
  locale-gen
  mkfs.btrfs
  mkfs.ext4
  mkfs.fat
  omarchy-arm-install
  omarchy-cidata-load
  omarchy-install-dashboard
  pacstrap
  parted
  partprobe
  rsync
  tput
  udevadm
  wipefs
)

for command in "${required_commands[@]}"; do
  if ! command -v "$command" >/dev/null; then
    echo "ERROR: required live installer command is unavailable: $command" >&2
    exit 1
  fi
done

cat >/etc/mkinitcpio.d/linux-aarch64.preset <<'PRESET'
PRESETS=('archiso')
ALL_kver='/boot/Image'
archiso_config='/etc/mkinitcpio.conf.d/archiso.conf'
archiso_image='/boot/initramfs-linux-aarch64.img'
PRESET

ln -sfn Image /boot/vmlinuz-linux-aarch64
