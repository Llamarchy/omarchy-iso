#!/bin/bash

set -Eeuo pipefail
trap 'printf "ERROR: ARM cache import failed at %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

builder_root=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
cache_root="${1:-}"
offline_mirror_dir="${2:-}"
release_tag=asahi-quattro-dbc89b00
release_commit=dbc89b0048682334b572e1f32538bf2fe3f3f2d1
package_commit=81582c4b4c483e0c4000296f452f532d374865c6
compatibility_tag=mac10-vm-runtime-v1
release_fingerprint=5983B1CA32CB778F4D74D24ECFF35022CA5B5959
wayland_sha256=637f924c48a75afe11d673f33c664e95bb3540172f972ce5d3c597463ed45360
release_dir="$cache_root/releases/$release_tag"
key_file="$cache_root/releases/omarchy-release.gpg"
source_packages=(aether cliamp localsend mise quickshell-git ttf-ia-writer ufw-docker xdg-terminal-exec yaru-icon-theme yay)
compatibility_packages=(asdcontrol herdr hyprland-preview-share-picker omacalc omacut omawrite tensaku tobi-try ttfx tzupdate voxtype-bin voxtype-model-base-en)

if [[ -z $cache_root || -z $offline_mirror_dir ]]; then
  echo "Usage: import-arm-cache.sh <cache-root> <offline-mirror-dir>" >&2
  exit 1
fi

for required in "$key_file" "$release_dir/asahi-quattro-release" "$release_dir/asahi-quattro-release.sig" \
  "$release_dir/asahi-quattro-bundle.manifest" "$release_dir/asahi-quattro-bundle.manifest.sig"; do
  [[ -s $required ]] || { echo "ERROR: required signed ARM release asset is missing: $required" >&2; exit 1; }
done

verify_dir=$(mktemp -d /tmp/llamarchy-arm-release.XXXXXXXX)
package_dir=$(mktemp -d /tmp/llamarchy-wayland-package.XXXXXXXX)
trap 'rm -rf "$verify_dir" "$package_dir"' EXIT
chmod 0700 "$verify_dir"

actual_fingerprint=$(gpg --batch --show-keys --with-colons "$key_file" | sed -n 's/^fpr:::::::::\([^:]*\):$/\1/p' | head -1)
[[ $actual_fingerprint == "$release_fingerprint" ]] || { echo "ERROR: ARM release-key fingerprint mismatch" >&2; exit 1; }
gpg --batch --homedir "$verify_dir" --import "$key_file" >/dev/null 2>&1
gpg --batch --homedir "$verify_dir" --verify "$release_dir/asahi-quattro-release.sig" "$release_dir/asahi-quattro-release" >/dev/null 2>&1
gpg --batch --homedir "$verify_dir" --verify "$release_dir/asahi-quattro-bundle.manifest.sig" "$release_dir/asahi-quattro-bundle.manifest" >/dev/null 2>&1

grep -Fxq "release_tag=$release_tag" "$release_dir/asahi-quattro-release"
grep -Fxq "source_commit=$release_commit" "$release_dir/asahi-quattro-release"
grep -Fxq "package_source_commit=$package_commit" "$release_dir/asahi-quattro-release"
expected_manifest_sha256=$(sed -n 's/^manifest_sha256=//p' "$release_dir/asahi-quattro-release")
printf '%s  %s\n' "$expected_manifest_sha256" "$release_dir/asahi-quattro-bundle.manifest" | sha256sum --check --status -

mkdir -p "$offline_mirror_dir"
package_count=0
while IFS='|' read -r prefix package_name _ package_arch package_file checksum extra; do
  [[ $prefix == package=* ]] || continue
  [[ -z $extra && $checksum =~ ^[0-9a-f]{64}$ ]] || { echo "ERROR: invalid release manifest entry for $package_name" >&2; exit 1; }
  [[ $package_arch == "aarch64" || $package_arch == "any" ]] || { echo "ERROR: incompatible package architecture for $package_name: $package_arch" >&2; exit 1; }
  package_path="$release_dir/$package_file"
  [[ -s $package_path && -s $package_path.sig ]] || { echo "ERROR: signed package is missing: $package_file" >&2; exit 1; }
  gpg --batch --homedir "$verify_dir" --verify "$package_path.sig" "$package_path" >/dev/null 2>&1
  printf '%s  %s\n' "$checksum" "$package_path" | sha256sum --check --status -
  if [[ $package_name != "quickshell-git" ]]; then
    install -m 0644 "$package_path" "$offline_mirror_dir/"
  fi
  package_count=$((package_count + 1))
done <"$release_dir/asahi-quattro-bundle.manifest"
(( package_count == 6 )) || { echo "ERROR: expected six signed ARM release packages" >&2; exit 1; }

# The signed Quickshell source remains authoritative, while the binary must be
# rebuilt against the Qt private ABI selected by the current ARM repositories.
for candidate in "$offline_mirror_dir"/quickshell-git-*.pkg.tar.*; do
  [[ -f $candidate && $candidate != *.sig ]] || continue
  read -r candidate_name _ < <(pacman -Qp "$candidate" 2>/dev/null) || continue
  [[ $candidate_name == "quickshell-git" ]] && rm -f "$candidate"
done

for package_name in "${source_packages[@]}"; do
  mapfile -t candidates < <(find "$cache_root/builds/$package_commit/$package_name" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' -print 2>/dev/null)
  (( ${#candidates[@]} == 1 )) || { echo "ERROR: expected one cached AArch64 build for $package_name" >&2; exit 1; }
  read -r archive_name archive_version < <(pacman -Qp "${candidates[0]}")
  [[ $archive_name == "$package_name" && -n $archive_version ]] || { echo "ERROR: cached package identity mismatch for $package_name" >&2; exit 1; }
  install -m 0644 "${candidates[0]}" "$offline_mirror_dir/"
done

for package_name in "${compatibility_packages[@]}"; do
  mapfile -t candidates < <(find "$cache_root/builds/$compatibility_tag/$package_name" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' -print 2>/dev/null)
  (( ${#candidates[@]} == 1 )) || { echo "ERROR: expected one cached AArch64 compatibility build for $package_name" >&2; exit 1; }
  read -r archive_name archive_version < <(pacman -Qp "${candidates[0]}")
  archive_arch=$(bsdtar -xOf "${candidates[0]}" .PKGINFO | sed -n 's/^arch = //p' | head -1)
  [[ $archive_name == "$package_name" && -n $archive_version ]] || { echo "ERROR: cached package identity mismatch for $package_name" >&2; exit 1; }
  [[ $archive_arch == "aarch64" || $archive_arch == "any" ]] || { echo "ERROR: cached package architecture mismatch for $package_name: $archive_arch" >&2; exit 1; }
  install -m 0644 "${candidates[0]}" "$offline_mirror_dir/"
done

agent_binary="$cache_root/releases/wayland-vdagent-v0.3.4-llamarchy.1-aarch64"
[[ -s $agent_binary ]] || { echo "ERROR: cached patched Wayland agent is missing: $agent_binary" >&2; exit 1; }
printf '%s  %s\n' "$wayland_sha256" "$agent_binary" | sha256sum --check --status -
cp "$builder_root/wayland-vdagent-llamarchy/PKGBUILD" "$package_dir/"
cp "$builder_root/wayland-vdagent-llamarchy/wayland-vdagent.service" "$package_dir/"
cp "$agent_binary" "$package_dir/wayland-vdagent-aarch64-linux"
chown -R nobody:nobody "$package_dir"
runuser -u nobody -- env HOME="$package_dir" bash -lc "cd '$package_dir' && makepkg --noconfirm --cleanbuild --nodeps"
install -m 0644 "$package_dir"/wayland-vdagent-llamarchy-*.pkg.tar.* "$offline_mirror_dir/"

printf 'Verified six signed release packages and imported five ABI-stable packages, ten pinned builds, twelve ARM compatibility packages, and the patched Wayland agent.\n'
