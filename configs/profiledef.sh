#!/bin/bash
# shellcheck disable=SC2034

iso_name="omarchy"
iso_label="OMARCHY_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Omarchy <https://omarchy.org>"
iso_application="Omarchy Installer"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
buildmodes=('iso')
arch="${OMARCHY_ARCH:-x86_64}"
if [[ $arch == "aarch64" ]]; then
  bootmodes=('uefi.grub')
else
  bootmodes=('bios.syslinux' 'uefi.grub')
fi
pacman_conf="pacman-offline.conf"
airootfs_image_type="squashfs"
# Package archives in the offline mirror are already zstd-compressed. Storing
# them in an outer stream saves little space but makes pacman decompress the
# outer layer while hashing and extracting every package during installation.
if [[ $arch == "aarch64" ]]; then
  # The generic Arch Linux ARM kernel exposes the SquashFS xz decompressor.
  # A plain xz stream keeps the image portable across native ARM machines and
  # VMs without applying the architecture-specific x86 BCJ filter.
  airootfs_image_tool_options=(
    '-comp' 'xz'
    '-b' '1M'
    '-Xdict-size' '1M'
    '-action' 'uncompressed@subpathname(var/cache/omarchy/mirror/offline)'
  )
else
  # The x86 live root uses fast zstd page-fault decompression.
  airootfs_image_tool_options=(
    '-comp' 'zstd'
    '-Xcompression-level' '19'
    '-b' '1M'
    '-action' 'uncompressed@subpathname(var/cache/omarchy/mirror/offline)'
  )
fi
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/.gnupg"]="0:0:700"
  ["/root/configurator"]="0:0:755"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/omarchy-cidata-load"]="0:0:755"
  ["/usr/local/bin/configure-archiso-arm-kernel"]="0:0:755"
  ["/usr/local/bin/omarchy-iso-cleanup-disk"]="0:0:755"
  ["/usr/local/bin/omarchy-install-dashboard"]="0:0:755"
  ["/usr/local/bin/omarchy-arm-install"]="0:0:755"
  ["/usr/local/bin/omarchy-iso-install"]="0:0:755"
  ["/var/cache/omarchy/mirror/offline/"]="0:0:775"
)
