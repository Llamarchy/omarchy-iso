#!/bin/bash

set -Eeuo pipefail
trap 'printf "ERROR: native Quickshell build failed at %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

[[ $(uname -m) == "aarch64" ]] || { echo "ERROR: Quickshell must be built on native AArch64 Linux" >&2; exit 1; }
(( EUID == 0 )) || { echo "ERROR: the native Quickshell build must run as root" >&2; exit 1; }

source_root="${OMARCHY_ISO_SOURCE_ROOT:-$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)}"
cache_root="${OMARCHY_ARM_ARTIFACT_CACHE:-/var/cache/llamarchy/utm-arm}"
package_commit=81582c4b4c483e0c4000296f452f532d374865c6
recipe="$source_root/builder/quickshell-git"
package_output="$cache_root/builds/$package_commit/quickshell-git"
source_cache="$cache_root/sources/makepkg"
build_root="$cache_root/work/quickshell-git"
pacman_conf="$source_root/configs/pacman-online-aarch64.conf"

[[ -s $recipe/PKGBUILD && -s $recipe/quickshell-check.hook ]] || {
  echo "ERROR: tracked Quickshell build recipe is incomplete" >&2
  exit 1
}
install -d -m 0755 \
  "$cache_root/builds" \
  "$cache_root/builds/$package_commit" \
  "$package_output" \
  "$cache_root/sources" \
  "$source_cache" \
  "$cache_root/work" \
  "$build_root" \
  "$cache_root/pacman/pkg"

pacman --config "$pacman_conf" --cachedir "$cache_root/pacman/pkg" --noconfirm -Syu --needed \
  base-devel cli11 cmake cpptrace git jemalloc libdrm libpipewire libxcb mesa ninja polkit \
  qt6-base qt6-declarative qt6-shadertools qt6-svg spirv-tools vulkan-headers wayland wayland-protocols

qt_base_version=$(pacman -Q qt6-base | awk '{print $2}')
qt_declarative_version=$(pacman -Q qt6-declarative | awk '{print $2}')

cached_package=""
for candidate in "$package_output"/quickshell-git-*.pkg.tar.*; do
  [[ -f $candidate && $candidate != *.sig ]] || continue
  [[ -z $cached_package ]] || { echo "ERROR: multiple cached native Quickshell packages found" >&2; exit 1; }
  cached_package="$candidate"
done
if [[ -n $cached_package ]] && \
  bsdtar -xOf "$cached_package" .BUILDINFO | grep -Fqx "installed = qt6-base-$qt_base_version-aarch64" && \
  bsdtar -xOf "$cached_package" .BUILDINFO | grep -Fqx "installed = qt6-declarative-$qt_declarative_version-aarch64"; then
  echo "Reusing Qt-matched native Quickshell package: $cached_package"
  pacman --noconfirm -U "$cached_package"
  quickshell --private-check-compat
  exit 0
fi

rm -rf "$build_root/source"
mkdir -p "$build_root/source"
cp "$recipe/PKGBUILD" "$recipe/quickshell-check.hook" "$build_root/source/"
chown -R nobody:nobody "$build_root" "$source_cache" "$package_output"
runuser -u nobody -- env \
  HOME="$build_root" \
  SRCDEST="$source_cache" \
  PKGDEST="$package_output" \
  MAKEFLAGS="-j$(nproc)" \
  bash -lc "cd '$build_root/source' && makepkg --noconfirm --cleanbuild --clean"

mapfile -t packages < <(find "$package_output" -maxdepth 1 -type f -name 'quickshell-git-*.pkg.tar.*' ! -name '*.sig' -print)
(( ${#packages[@]} == 1 )) || { echo "ERROR: native Quickshell build produced an ambiguous package set" >&2; exit 1; }
bsdtar -xOf "${packages[0]}" .BUILDINFO | grep -Fqx "installed = qt6-base-$qt_base_version-aarch64"
bsdtar -xOf "${packages[0]}" .BUILDINFO | grep -Fqx "installed = qt6-declarative-$qt_declarative_version-aarch64"
pacman --noconfirm -U "${packages[0]}"
quickshell --private-check-compat
echo "Native Quickshell package: ${packages[0]}"
