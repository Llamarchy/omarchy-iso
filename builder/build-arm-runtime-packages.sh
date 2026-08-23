#!/bin/bash

set -Eeuo pipefail
trap 'printf "ERROR: ARM runtime package build failed at %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

builder_root=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
cache_root="${OMARCHY_ARM_ARTIFACT_CACHE:-${1:-}}"
package_commit=81582c4b4c483e0c4000296f452f532d374865c6
compatibility_tag=mac10-vm-runtime-v1
source_repo="$cache_root/sources/omarchy-pkgs.git"
source_cache="$cache_root/sources/makepkg/arm-runtime"
cargo_cache="$cache_root/sources/cargo/arm-runtime"
work_root="$cache_root/work/arm-runtime"
build_root="$cache_root/builds/$compatibility_tag"
build_user=llamarchy-iso-build
build_home="$work_root/home"
makepkg_config="$work_root/makepkg.conf"
sudoers_file=/etc/sudoers.d/09-llamarchy-iso-build
source_packages=(asdcontrol hyprland-preview-share-picker omacut omawrite tensaku tobi-try tzupdate)
vendored_packages=(herdr omacalc ttfx voxtype-bin voxtype-model-base-en)
arm_arch_overrides=(asdcontrol hyprland-preview-share-picker tensaku tzupdate)

[[ -n $cache_root ]] || { echo "Usage: build-arm-runtime-packages.sh <cache-root>" >&2; exit 1; }
[[ $(uname -m) == "aarch64" ]] || { echo "ERROR: native AArch64 package builds require an AArch64 guest" >&2; exit 1; }
[[ $EUID == 0 ]] || { echo "ERROR: native package builds require root" >&2; exit 1; }
[[ -d $source_repo ]] || { echo "ERROR: pinned package source cache is unavailable: $source_repo" >&2; exit 1; }
git --git-dir="$source_repo" cat-file -e "$package_commit^{commit}"

install -d -m 0755 "$source_cache" "$cargo_cache" "$work_root" "$build_root"
if ! getent passwd "$build_user" >/dev/null; then
  useradd --system --create-home --home-dir "$build_home" --shell /bin/bash "$build_user"
fi
printf '%s ALL=(root) NOPASSWD: /usr/bin/pacman\n' "$build_user" >"$sudoers_file"
chmod 0440 "$sudoers_file"

install -m 0644 /etc/makepkg.conf "$makepkg_config"
cat >>"$makepkg_config" <<EOF

SRCDEST="$source_cache"
CARGO_HOME="$cargo_cache"
MAKEFLAGS="-j$(nproc)"
EOF
chown -R "$build_user:$build_user" "$source_cache" "$cargo_cache" "$work_root"

contains() {
  local needle="$1"
  shift
  local item

  for item in "$@"; do
    [[ $item == "$needle" ]] && return 0
  done
  return 1
}

build_package() {
  local package_name="$1"
  local package_work="$work_root/$package_name"
  local package_output="$build_root/$package_name"
  local archive archive_name archive_arch
  local valid_archive=""

  install -d -m 0755 "$package_output"
  for archive in "$package_output"/*.pkg.tar.*; do
    [[ -f $archive && $archive != *.sig ]] || continue
    read -r archive_name _ < <(pacman -Qp "$archive" 2>/dev/null) || continue
    archive_arch=$(bsdtar -xOf "$archive" .PKGINFO 2>/dev/null | sed -n 's/^arch = //p' | head -1)
    if [[ $archive_name == "$package_name" && ( $archive_arch == "aarch64" || $archive_arch == "any" ) ]]; then
      valid_archive="$archive"
      break
    fi
  done
  if [[ -n $valid_archive ]]; then
    echo "Reusing cached native package: $valid_archive"
    return
  fi

  rm -rf "$package_work"
  install -d -m 0755 "$package_work"
  if contains "$package_name" "${source_packages[@]}"; then
    git --git-dir="$source_repo" archive "$package_commit" "pkgbuilds/$package_name" |
      tar -xf - --strip-components=2 -C "$package_work"
  else
    cp -a "$builder_root/arm-packages/$package_name/." "$package_work/"
  fi

  if contains "$package_name" "${arm_arch_overrides[@]}"; then
    sed -i -E "s/^arch=\([^)]*\)$/arch=('aarch64')/" "$package_work/PKGBUILD"
    grep -Fxq "arch=('aarch64')" "$package_work/PKGBUILD"
  fi

  find "$package_output" -maxdepth 1 -type f -name '*.pkg.tar.*' -delete
  chown -R "$build_user:$build_user" "$package_work" "$package_output"
  echo "Building native AArch64 package: $package_name"
  runuser -u "$build_user" -- env \
    HOME="$build_home" \
    CARGO_HOME="$cargo_cache" \
    RUSTUP_TOOLCHAIN=stable \
    PKGDEST="$package_output" \
    SRCDEST="$source_cache" \
    bash -lc "cd '$package_work' && makepkg --config '$makepkg_config' --syncdeps --noconfirm --cleanbuild"

  mapfile -t archives < <(find "$package_output" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' -print)
  (( ${#archives[@]} == 1 )) || { echo "ERROR: expected one package archive for $package_name" >&2; exit 1; }
  read -r archive_name _ < <(pacman -Qp "${archives[0]}")
  [[ $archive_name == "$package_name" ]] || { echo "ERROR: built package identity mismatch for $package_name" >&2; exit 1; }
}

for package_name in "${source_packages[@]}" "${vendored_packages[@]}"; do
  build_package "$package_name"
done

echo "Native ARM runtime package cache is complete: $build_root"
