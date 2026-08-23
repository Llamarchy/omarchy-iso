#!/bin/bash

set -Ee
trap 'printf "ERROR: ISO build failed at %s: %s\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

OMARCHY_ISO_REF="${OMARCHY_ISO_REF:-quattro}"
OMARCHY_MIRROR="${OMARCHY_MIRROR:-stable}"
OMARCHY_ARCH="${OMARCHY_ARCH:-x86_64}"

if [[ $OMARCHY_ARCH != "x86_64" && $OMARCHY_ARCH != "aarch64" ]]; then
  echo "ERROR: OMARCHY_ARCH must be x86_64 or aarch64" >&2
  exit 1
fi

if [[ -n ${OMARCHY_ISO_SOURCE_ROOT:-} ]]; then
  archiso_root="$OMARCHY_ISO_SOURCE_ROOT/archiso"
  builder_root="$OMARCHY_ISO_SOURCE_ROOT/builder"
  configs_root="$OMARCHY_ISO_SOURCE_ROOT/configs"
else
  archiso_root=/archiso
  builder_root=/builder
  configs_root=/configs
fi
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  online_pacman_conf="$configs_root/pacman-online-aarch64.conf"
  archinstall_package_file="$builder_root/archinstall.packages.aarch64"
else
  online_pacman_conf="$configs_root/pacman-online-${OMARCHY_MIRROR}.conf"
  archinstall_package_file="$builder_root/archinstall.packages"
fi

# Edge, dev, and local-source ISOs install the dev packages explicitly. Those
# package recipes track the quattro branch. This avoids relying on pacman's
# provides=omarchy resolution and shows the real package names being tested in
# the offline mirror and target install. Every other ref, the default quattro
# build included, installs the published omarchy packages.
case "$OMARCHY_ISO_REF" in
  edge|dev|local)
    : "${OMARCHY_RUNTIME_PACKAGE:=omarchy-dev}"
    : "${OMARCHY_SETTINGS_PACKAGE:=omarchy-settings-dev}"
    ;;
  *)
    : "${OMARCHY_RUNTIME_PACKAGE:=omarchy}"
    : "${OMARCHY_SETTINGS_PACKAGE:=omarchy-settings}"
    ;;
esac
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  OMARCHY_RUNTIME_PACKAGE=omarchy-dev
  OMARCHY_SETTINGS_PACKAGE=omarchy-settings-dev
fi
: "${OMARCHY_NVIM_PACKAGE:=omarchy-nvim}"
export OMARCHY_RUNTIME_PACKAGE OMARCHY_SETTINGS_PACKAGE OMARCHY_NVIM_PACKAGE

# Packages installed into the Arch container used to build the ISO.
pacman-key --init
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  [[ $(uname -m) == "aarch64" ]] || { echo "ERROR: aarch64 ISO builds require a native aarch64 builder" >&2; exit 1; }
  [[ -n ${OMARCHY_ARM_ARTIFACT_CACHE:-} ]] || { echo "ERROR: OMARCHY_ARM_ARTIFACT_CACHE is required" >&2; exit 1; }
  [[ -d $OMARCHY_ARM_ARTIFACT_CACHE ]] || { echo "ERROR: ARM artifact cache is unavailable: $OMARCHY_ARM_ARTIFACT_CACHE" >&2; exit 1; }
  export OMARCHY_ALLOW_DIRECT_PACMAN=1
  arm_pacman_cache="$OMARCHY_ARM_ARTIFACT_CACHE/pacman/pkg"
  mkdir -p "$arm_pacman_cache"

  pacman --config "$configs_root/pacman-online-aarch64.conf" --cachedir "$arm_pacman_cache" --noconfirm -Sy archlinuxarm-keyring
  pacman-key --populate archlinuxarm
  pacman --config "$configs_root/pacman-online-aarch64.conf" --cachedir "$arm_pacman_cache" --noconfirm -Syu \
    arch-install-scripts base-devel dosfstools e2fsprogs erofs-utils git gnupg grub \
    imagemagick jq libarchive libisoburn mtools neovim nodejs npm python-docutils \
    squashfs-tools sudo tree-sitter-cli
  install -m 0755 "$archiso_root/archiso/mkarchiso" /usr/local/bin/mkarchiso
  # ArchISO's shared UEFI module set includes legacy PC/USB keyboard modules.
  # Build the native ARM loader with the input modules that GRUB's arm64-efi
  # target actually publishes; UEFI supplies console input on this platform.
  sed -i \
    -e 's/ at_keyboard//' \
    -e 's/ keylayouts//' \
    -e 's/ usbserial_common//' \
    -e 's/ usbserial_ftdi//' \
    -e 's/ usbserial_pl2303//' \
    -e 's/ usbserial_usbdebug//' \
    -e 's/ usb / /' \
    /usr/local/bin/mkarchiso
  if sed -n '/grubmodules=(all_video/,/video xfs zstd)/p' /usr/local/bin/mkarchiso |
    grep -Eq '\b(at_keyboard|keylayouts|usb|usbserial_common|usbserial_ftdi|usbserial_pl2303|usbserial_usbdebug)\b'; then
    echo "ERROR: ArchISO still requests a GRUB module unavailable on arm64-efi" >&2
    exit 1
  fi
else
  pacman --noconfirm -Sy archlinux-keyring
  # Full upgrade, not just -Sy: docker never re-pulls :latest once it's cached,
  # so this container can be months behind the mirror it installs from. A plain
  # -Sy install is then a partial upgrade — new packages linked against a glibc
  # the container doesn't have yet.
  pacman --noconfirm -Syu archiso git sudo base-devel jq grub imagemagick neovim nodejs npm tree-sitter-cli

  # Pre-import the omarchy signing key (so pacman trusts our [omarchy] repo
  # during the build without keyserver lookups).
  pacman-key --add "$builder_root/omarchy.gpg"
  pacman-key --lsign-key 40DFB630FF42BCFFB047046CF0134EE680CAC571

  # omarchy-keyring is needed inside the offline mirror too.
  pacman --config "$configs_root/pacman-online-${OMARCHY_MIRROR}.conf" --noconfirm -Sy omarchy-keyring
  pacman-key --populate omarchy

  # Append the [omarchy] repo to the container's /etc/pacman.conf so subsequent
  # tools (notably makepkg in build-omarchy-packages.sh) can resolve omarchy-
  # only build deps like limine-snapper-sync and limine-mkinitcpio-hook.
  if ! grep -q '^\[omarchy\]' /etc/pacman.conf; then
    awk '/^\[omarchy\]/,/^$/' "$configs_root/pacman-online-${OMARCHY_MIRROR}.conf" >> /etc/pacman.conf
  fi
fi

# Index the Arch Linux ARM repositories once. The index validates the explicit
# AArch64 live profile and filters Omarchy's hardware-oriented target lists
# without making one pacman metadata call per package.
declare -A arm_repository_packages=()
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  while IFS= read -r package; do
    [[ -n $package ]] && arm_repository_packages["$package"]=1
  done < <(pacman --config "$online_pacman_conf" -Slq)
fi

# Build locations
build_cache_dir="${ISO_BUILD_CACHE:-/var/cache}"
output_dir="${ISO_OUTPUT_DIR:-/out}"
offline_mirror_dir="$build_cache_dir/airootfs/var/cache/omarchy/mirror/offline"
mkdir -p "$build_cache_dir" "$offline_mirror_dir"

# Seed ArchISO's architecture-neutral releng filesystem and boot scaffolding.
# The package profile is replaced below by our reviewed AArch64 package list.
cp -r "$archiso_root/configs/releng/"* "$build_cache_dir/"
rm "$build_cache_dir/airootfs/etc/motd"

# We rely on the global CDN; drop reflector.
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/multi-user.target.wants/reflector.service"
rm -rf "$build_cache_dir/airootfs/etc/systemd/system/reflector.service.d"
rm -rf "$build_cache_dir/airootfs/etc/xdg/reflector"

# Bring in our archiso profile additions.
cp -r "$configs_root/"* "$build_cache_dir/"
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  cp "$builder_root/live.packages.aarch64" "$build_cache_dir/packages.aarch64"
  while IFS= read -r package; do
    [[ -n $package ]] || continue
    [[ -n ${arm_repository_packages[$package]+x} ]] || {
      echo "ERROR: ARM live-profile package is unavailable: $package" >&2
      exit 1
    }
  done <"$build_cache_dir/packages.aarch64"
  rm -f "$build_cache_dir/airootfs/etc/mkinitcpio.d/linux.preset" \
    "$build_cache_dir/airootfs/etc/mkinitcpio.d/linux-t2.preset" \
    "$build_cache_dir/airootfs/etc/modprobe.d/blacklist-applesmc.conf" \
    "$build_cache_dir/airootfs/root/customize_airootfs.sh" \
    "$build_cache_dir/airootfs/etc/systemd/system/dbus-org.freedesktop.ModemManager1.service"
  sed -i \
    -e 's/ microcode//' \
    -e 's/ memdisk//' \
    -e 's/ archiso_pxe_common//' \
    -e 's/ archiso_pxe_nbd//' \
    -e 's/ archiso_pxe_http//' \
    -e 's/ archiso_pxe_nfs//' \
    "$build_cache_dir/airootfs/etc/mkinitcpio.conf.d/archiso.conf"
  sed -i \
    -e 's/vmlinuz-linux-t2/vmlinuz-linux-aarch64/g' \
    -e 's/initramfs-linux-t2/initramfs-linux-aarch64/g' \
    "$build_cache_dir/grub/grub.cfg" "$build_cache_dir/grub/loopback.cfg"
  # Keep the runtime GRUB configuration aligned with the arm64-efi module set
  # embedded above. UEFI provides keyboard input, while the QEMU PL011 console
  # gives automated builders a reliable boot log alongside the graphical tty.
  sed -i \
    -e '/^insmod usbserial_/d' \
    -e 's/^timeout=0$/timeout=3/' \
    -e 's/^timeout_style=hidden$/timeout_style=menu/' \
    -e 's/ quiet splash xe.enable_panel_replay=0/ console=ttyAMA0,115200 console=tty0 loglevel=4 xe.enable_panel_replay=0/' \
    "$build_cache_dir/grub/grub.cfg" "$build_cache_dir/grub/loopback.cfg"
  if grep -Eq '^insmod usbserial_| quiet splash ' \
    "$build_cache_dir/grub/grub.cfg" "$build_cache_dir/grub/loopback.cfg"; then
    echo "ERROR: ARM GRUB configuration still requests unavailable serial modules or hidden boot output" >&2
    exit 1
  fi
  install -m 0755 "$builder_root/configure-archiso-arm-kernel.sh" \
    "$build_cache_dir/airootfs/usr/local/bin/configure-archiso-arm-kernel"
  mkdir -p "$build_cache_dir/airootfs/etc/pacman.d/hooks"
  cat >"$build_cache_dir/airootfs/etc/pacman.d/hooks/89-archiso-arm-kernel.hook" <<'HOOK'
# remove from airootfs!
# This hook prepares the live image during mkarchiso's pacstrap transaction.
# ArchISO removes it before packing the live root so target pacstrap operations
# use the installed kernel package's ordinary preset.
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
fi
mkdir -p "$build_cache_dir/airootfs/usr/share/omarchy-iso"
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  cp "$builder_root/archinstall.packages.aarch64" \
    "$build_cache_dir/airootfs/usr/share/omarchy-iso/archinstall.packages"
fi
echo "$OMARCHY_MIRROR" > "$build_cache_dir/airootfs/root/omarchy_mirror"
echo "$OMARCHY_ISO_REF" > "$build_cache_dir/airootfs/root/omarchy_iso_ref"
cat > "$build_cache_dir/airootfs/usr/share/omarchy-iso/package-targets" <<EOF
OMARCHY_RUNTIME_PACKAGE=$OMARCHY_RUNTIME_PACKAGE
OMARCHY_SETTINGS_PACKAGE=$OMARCHY_SETTINGS_PACKAGE
OMARCHY_NVIM_PACKAGE=$OMARCHY_NVIM_PACKAGE
EOF

if [[ ${OMARCHY_INSTALL_DEBUG:-} == "1" ]]; then
  touch "$build_cache_dir/airootfs/usr/share/omarchy-iso/install-debug"
  {
    echo "debug=1"
    echo "built_at=$(date -Is)"
    echo "ref=$OMARCHY_ISO_REF"
    echo "mirror=$OMARCHY_MIRROR"
    echo "runtime_package=$OMARCHY_RUNTIME_PACKAGE"
    echo "settings_package=$OMARCHY_SETTINGS_PACKAGE"
    echo "nvim_package=$OMARCHY_NVIM_PACKAGE"
    if [[ -d /omarchy-source ]]; then
      echo "omarchy_source=/omarchy-source"
      git -c safe.directory=/omarchy-source -C /omarchy-source rev-parse HEAD 2>/dev/null | sed 's/^/omarchy_commit=/' || true
      git -c safe.directory=/omarchy-source -C /omarchy-source status --short 2>/dev/null | sed 's/^/omarchy_status=/' || true
    fi
    if [[ -d /omarchy-pkgs ]]; then
      echo "omarchy_pkgs_source=/omarchy-pkgs"
      git -c safe.directory=/omarchy-pkgs -C /omarchy-pkgs rev-parse HEAD 2>/dev/null | sed 's/^/omarchy_pkgs_commit=/' || true
      git -c safe.directory=/omarchy-pkgs -C /omarchy-pkgs status --short 2>/dev/null | sed 's/^/omarchy_pkgs_status=/' || true
    fi
  } > "$build_cache_dir/airootfs/usr/share/omarchy-iso/build-info"
fi

# When --local-source is in effect, build omarchy* from the mounted source
# trees and drop them in the offline mirror. Otherwise pacman -Syw below
# downloads the published versions from the omarchy network mirror.
if [[ -d /omarchy-source && -d /omarchy-pkgs ]]; then
  bash "$builder_root/build-omarchy-packages.sh" "$offline_mirror_dir"
  LOCAL_OMARCHY_BUILD=1
fi

if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  bash "$builder_root/import-arm-cache.sh" "$OMARCHY_ARM_ARTIFACT_CACHE" "$offline_mirror_dir"
  LOCAL_OMARCHY_BUILD=1
fi

# Node.js binary for offline mise install.
NODE_DIST_URL="https://nodejs.org/dist/latest"
NODE_SHASUMS=$(curl -fsSL "$NODE_DIST_URL/SHASUMS256.txt")
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  node_platform=linux-arm64.tar.gz
else
  node_platform=linux-x64.tar.gz
fi
NODE_FILENAME=$(echo "$NODE_SHASUMS" | grep "$node_platform" | awk '{print $2}')
NODE_SHA=$(echo "$NODE_SHASUMS" | grep "$node_platform" | awk '{print $1}')
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  node_cache_dir="$OMARCHY_ARM_ARTIFACT_CACHE/releases/node"
  mkdir -p "$node_cache_dir"
  node_archive="$node_cache_dir/$NODE_FILENAME"
else
  node_archive="/tmp/$NODE_FILENAME"
fi
if [[ ! -s $node_archive ]] || ! printf '%s  %s\n' "$NODE_SHA" "$node_archive" | sha256sum --check --status -; then
  rm -f "$node_archive"
  curl -fsSL "$NODE_DIST_URL/$NODE_FILENAME" -o "$node_archive"
fi
printf '%s  %s\n' "$NODE_SHA" "$node_archive" | sha256sum --check --status -
mkdir -p "$build_cache_dir/airootfs/opt/packages/"
cp "$node_archive" "$build_cache_dir/airootfs/opt/packages/"

# Packages installed into the live ISO environment itself (NOT the target system).
# The selected omarchy-settings package is needed here so its post_install hook
# drops Omarchy's plymouthd.conf into /etc/plymouth before mkarchiso builds the
# live initramfs.
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  arch_packages=(linux-aarch64 archinstall mkinitcpio-archiso git gum jq openssl plymouth ttfx omarchy-keyring "$OMARCHY_SETTINGS_PACKAGE" lvm2 cryptsetup parted btrfs-progs)
else
  arch_packages=(linux-t2 git gum jq openssl plymouth ttfx tzupdate omarchy-keyring "$OMARCHY_SETTINGS_PACKAGE" lvm2 cryptsetup parted)
fi
printf '%s\n' "${arch_packages[@]}" >> "$build_cache_dir/packages.$OMARCHY_ARCH"

# The live ISO boots linux-t2 (see airootfs/etc/mkinitcpio.d/linux-t2.preset), so
# stock linux is a second kernel nobody boots: ~147MB of ISO, plus its own archiso
# initramfs, copied into both the ISO tree and the size-constrained FAT EFI image.
#
# It cannot just be deleted — releng's broadcom-wl hard-depends on it, and it is
# the only releng package that does, so pacman would drag the kernel straight back
# in. broadcom-wl is a prebuilt module for stock linux and cannot load on the
# kernel we boot, so it has done nothing since we started booting T2 anyway. The
# install is entirely offline and the live environment needs no Wi-Fi driver.
#
# Anchored so linux-t2 and linux-firmware are untouched.
if [[ $OMARCHY_ARCH == "x86_64" ]]; then
  sed -i -E '/^(linux|broadcom-wl)$/d' "$build_cache_dir/packages.x86_64"
fi

# Build the offline mirror: everything pacstrap might want during the target
# install. With --local-source, the omarchy* packages we just built are
# already in the mirror and we filter them out below. Without it, pacman -Syw
# pulls the published omarchy* from the network mirror like any other package.
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  rm -rf /tmp/omarchy-pkglists
  mkdir -p /tmp/omarchy-pkglists
  omarchy_pkg=$(find "$offline_mirror_dir" -maxdepth 1 -type f -name 'omarchy-dev-*.pkg.tar.*' ! -name '*.sig' -print -quit)
  [[ -n $omarchy_pkg ]] || { echo "ERROR: signed ARM Omarchy runtime is absent from the offline mirror" >&2; exit 1; }
  bsdtar -xOf "$omarchy_pkg" usr/share/omarchy/install/omarchy-base.packages \
    >/tmp/omarchy-pkglists/omarchy-base-generic.packages
  bsdtar -xOf "$omarchy_pkg" usr/share/omarchy/install/omarchy-base-asahi.packages \
    >/tmp/omarchy-pkglists/omarchy-base-asahi.packages

  # mac.10's Asahi list predates its runtime scripts. Keep this exact audit next
  # to the compatibility policy: if the signed bundle ever changes, the build
  # must classify each new difference instead of silently shipping stale tools.
  expected_generic_only=(
    asdcontrol dotnet-runtime gpu-screen-recorder herdr
    hyprland-preview-share-picker libreoffice-fresh moonlight-qt nvim
    obs-studio obsidian omacalc omacut omawrite pinta
    qemu-user-static-binfmt tensaku tobi-try ttfx tzupdate
  )
  expected_asahi_only=(
    asahi-desktop-meta asahi-fwextract fwupd gnome-calculator linux-asahi
    linux-asahi-headers mesa mesa-demos mesa-utils neovim
    python-terminaltexteffects wf-recorder widevine
  )
  mapfile -t actual_generic_only < <(
    comm -23 \
      <(grep -Ev '^($|#)' /tmp/omarchy-pkglists/omarchy-base-generic.packages | sort -u) \
      <(grep -Ev '^($|#)' /tmp/omarchy-pkglists/omarchy-base-asahi.packages | sort -u)
  )
  mapfile -t actual_asahi_only < <(
    comm -13 \
      <(grep -Ev '^($|#)' /tmp/omarchy-pkglists/omarchy-base-generic.packages | sort -u) \
      <(grep -Ev '^($|#)' /tmp/omarchy-pkglists/omarchy-base-asahi.packages | sort -u)
  )
  [[ $(printf '%s\n' "${actual_generic_only[@]}") == $(printf '%s\n' "${expected_generic_only[@]}" | sort) ]] || {
    echo "ERROR: unclassified generic-only mac.10 package-list discrepancy" >&2
    printf '       %s\n' "${actual_generic_only[@]}" >&2
    exit 1
  }
  [[ $(printf '%s\n' "${actual_asahi_only[@]}") == $(printf '%s\n' "${expected_asahi_only[@]}" | sort) ]] || {
    echo "ERROR: unclassified Asahi-only mac.10 package-list discrepancy" >&2
    printf '       %s\n' "${actual_asahi_only[@]}" >&2
    exit 1
  }

  # Construct the VM list from the matching generic runtime manifest. Native
  # substitutes preserve commands where package names differ; the small omit
  # set is limited to applications without a usable AArch64 build.
  grep -Fxv \
    -e dotnet-runtime \
    -e nvim \
    -e obs-studio \
    -e obsidian \
    -e pinta \
    -e qemu-user-static-binfmt \
    /tmp/omarchy-pkglists/omarchy-base-generic.packages \
    >/tmp/omarchy-pkglists/omarchy-base.packages
  printf '%s\n' neovim voxtype-bin voxtype-model-base-en \
    >>/tmp/omarchy-pkglists/omarchy-base.packages
  bsdtar -xOf "$omarchy_pkg" usr/share/omarchy/install/omarchy-other.packages \
    >/tmp/omarchy-pkglists/omarchy-other.packages
  bsdtar -xOf "$omarchy_pkg" usr/share/omarchy/install/provisioning/setup-form.sh \
    >/tmp/omarchy-pkglists/setup-form.sh
  base_pkg_lists=(/tmp/omarchy-pkglists/omarchy-base.packages /tmp/omarchy-pkglists/omarchy-other.packages)
  setup_form=/tmp/omarchy-pkglists/setup-form.sh
elif [[ -d /omarchy-source ]]; then
  base_pkg_lists=(/omarchy-source/install/omarchy-base.packages /omarchy-source/install/omarchy-other.packages)
  setup_form=/omarchy-source/install/provisioning/setup-form.sh
else
  # Pull the same package lists out of the freshly-downloaded Omarchy runtime
  # package so we don't need a local checkout in the non-local-source path.
  bootstrap_cache_dir=/tmp/omarchy-pkg-bootstrap
  rm -rf "$bootstrap_cache_dir" /tmp/offlinedb-bootstrap /tmp/omarchy-pkglists
  mkdir -p "$bootstrap_cache_dir" /tmp/offlinedb-bootstrap
  pacman --config "$configs_root/pacman-online-${OMARCHY_MIRROR}.conf" --noconfirm -Syw "$OMARCHY_RUNTIME_PACKAGE" --cachedir "$bootstrap_cache_dir" --dbpath /tmp/offlinedb-bootstrap >/dev/null
  omarchy_pkg=$(find "$bootstrap_cache_dir" -maxdepth 1 -type f -name "$OMARCHY_RUNTIME_PACKAGE-*.pkg.tar.zst" | sort | head -1)
  if [[ -z $omarchy_pkg ]]; then
    echo "ERROR: downloaded package for $OMARCHY_RUNTIME_PACKAGE not found in $bootstrap_cache_dir" >&2
    exit 1
  fi
  mkdir -p /tmp/omarchy-pkglists
  bsdtar -xf "$omarchy_pkg" -C /tmp/omarchy-pkglists usr/share/omarchy/install/omarchy-base.packages usr/share/omarchy/install/omarchy-other.packages
  base_pkg_lists=(/tmp/omarchy-pkglists/usr/share/omarchy/install/omarchy-base.packages /tmp/omarchy-pkglists/usr/share/omarchy/install/omarchy-other.packages)
  # Extracted on its own, tolerating a miss: bsdtar exits non-zero for a member
  # it can't find, so asking for this alongside the package lists would abort the
  # build here (set -e) with a bare "Not found in archive" instead of the
  # actionable error below.
  bsdtar -xf "$omarchy_pkg" -C /tmp/omarchy-pkglists usr/share/omarchy/install/provisioning/setup-form.sh 2>/dev/null || true
  setup_form=/tmp/omarchy-pkglists/usr/share/omarchy/install/provisioning/setup-form.sh
fi

mkdir -p "$build_cache_dir/airootfs/usr/share/omarchy-iso"
cp "${base_pkg_lists[0]}" "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-base.packages"
cp "${base_pkg_lists[1]}" "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-other.packages"

# The configurator's setup form comes from the runtime this ISO bundles, so the
# installer and the first-boot setup that finishes a deferred install can never
# disagree. A runtime predating the split ships no such file, which would leave
# the configurator with no prompts at all.
if [[ ! -f $setup_form ]]; then
  if [[ -d /omarchy-source ]]; then
    echo "ERROR: the --local-source checkout ships no install/provisioning/setup-form.sh" >&2
    remedy="Update the checkout to a revision carrying the shared setup form."
  else
    echo "ERROR: $OMARCHY_RUNTIME_PACKAGE does not ship install/provisioning/setup-form.sh" >&2
    remedy="Publish a runtime carrying the shared setup form, or build with --local-source against a checkout that has it."
  fi
  echo "       The configurator sources its prompts from that file, so this ISO" >&2
  echo "       would boot into an installer with no questions to ask." >&2
  echo "       $remedy" >&2
  exit 1
fi
cp "$setup_form" "$build_cache_dir/airootfs/usr/share/omarchy-iso/setup-form.sh"

# Collect every package we want available in the offline mirror.
declare -a all_packages
mapfile -t all_packages < <(
  {
    cat "$build_cache_dir/packages.$OMARCHY_ARCH"
    grep -hv '^#\|^$' "${base_pkg_lists[@]}"
    if [[ $OMARCHY_ARCH == "aarch64" ]]; then
      grep -hv '^#\|^$' "$builder_root/archinstall.packages.aarch64"
    else
      grep -hv '^#\|^$' "$builder_root/archinstall.packages"
    fi
    # Always include the selected Omarchy packages so the target install can
    # find the runtime and companion packages in the offline mirror.
    printf '%s\n' "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE"
  } | sort -u
)

# With --local-source we already built these omarchy* packages directly into
# the mirror; strip them from the pacman -Syw list so it doesn't try to fetch
# the published versions on top.
if [[ -n ${LOCAL_OMARCHY_BUILD:-} ]]; then
  local_package_names=("$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" "$OMARCHY_NVIM_PACKAGE")
  if [[ $OMARCHY_ARCH == "aarch64" ]]; then
    local_package_names+=(
      omarchy-keyring quickshell-git ttf-jetbrains-mono-nerd-basic
      aether asdcontrol cliamp herdr hyprland-preview-share-picker localsend mise
      omacalc omacut omawrite tensaku tobi-try ttf-ia-writer ttfx tzupdate
      ufw-docker voxtype-bin voxtype-model-base-en xdg-terminal-exec
      yaru-icon-theme yay wayland-vdagent-llamarchy
    )
  fi
  filtered_packages=("${all_packages[@]}")
  for local_package_name in "${local_package_names[@]}"; do
    mapfile -t filtered_packages < <(printf '%s\n' "${filtered_packages[@]}" | grep -Fxv "$local_package_name" || true)
  done
  all_packages=("${filtered_packages[@]}")
fi

if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  rm -rf /tmp/offlinedb
  mkdir -p /tmp/offlinedb
  pacman --config "$online_pacman_conf" --dbpath /tmp/offlinedb --noconfirm -Sy

  if [[ -n ${LOCAL_OMARCHY_BUILD:-} ]]; then
    declare -A local_package_name_set=()
    local_archives=()
    for local_package_name in "${local_package_names[@]}"; do
      local_package_name_set["$local_package_name"]=1
      local_package_file=""
      for candidate in "$offline_mirror_dir/$local_package_name-"*.pkg.tar.*; do
        [[ -f $candidate && $candidate != *.sig ]] || continue
        read -r candidate_name _ < <(pacman -Qp "$candidate" 2>/dev/null) || continue
        [[ $candidate_name == "$local_package_name" ]] || continue
        [[ -z $local_package_file ]] || { echo "ERROR: multiple local builds found for $local_package_name" >&2; exit 1; }
        local_package_file="$candidate"
      done
      [[ -n $local_package_file ]] || { echo "ERROR: local build not found for $local_package_name" >&2; exit 1; }
      local_archives+=("$local_package_file")
    done

    if ! local_dependency_names="$(
      pacman --config "$online_pacman_conf" --dbpath /tmp/offlinedb --noconfirm \
        -U --print --print-format '%n' "${local_archives[@]}"
    )"; then
      echo "ERROR: could not resolve dependencies for the local ARM packages" >&2
      exit 1
    fi
    while IFS= read -r package; do
      [[ -n $package && -z ${local_package_name_set[$package]+x} ]] && all_packages+=("$package")
    done <<<"$local_dependency_names"
  fi

  arm_package_omissions="$build_cache_dir/airootfs/usr/share/omarchy-iso/aarch64-package-omissions"
  : >"$arm_package_omissions"
  filtered_packages=()
  for package in "${all_packages[@]}"; do
    case $package in
      linux) package=linux-aarch64 ;;
      linux-headers) package=linux-aarch64-headers ;;
    esac
    if [[ -n ${arm_repository_packages[$package]+x} ]]; then
      filtered_packages+=("$package")
    else
      printf '%s\n' "$package" >>"$arm_package_omissions"
    fi
  done
  mapfile -t all_packages < <(printf '%s\n' "${filtered_packages[@]}" | sort -u)
  sort -u -o "$arm_package_omissions" "$arm_package_omissions"
fi

mkdir -p /tmp/offlinedb
download_offline_packages() {
  if [[ $OMARCHY_ARCH == "aarch64" ]]; then
    mkdir -p "$OMARCHY_ARM_ARTIFACT_CACHE/pacman/pkg"
    pacman --config "$online_pacman_conf" --noconfirm -Sw \
      "${all_packages[@]}" --cachedir "$OMARCHY_ARM_ARTIFACT_CACHE/pacman/pkg/" --dbpath /tmp/offlinedb
  else
    pacman --config "$online_pacman_conf" --noconfirm -Syw \
      "${all_packages[@]}" --cachedir "$offline_mirror_dir/" --dbpath /tmp/offlinedb --needed
  fi
}

# A repository may occasionally republish a package without changing its
# filename. Pacman detects that the persistent cached copy no longer matches
# the refreshed repository checksum and deletes it, but still fails the
# transaction. Retry once so the now-missing package is downloaded.
if ! download_offline_packages; then
  echo "Offline package download failed; retrying after pacman cleaned invalid cached files..." >&2
  download_offline_packages
fi

# Resolve the exact filenames chosen by the same synced package databases used
# for the download. Pruning by this transaction (rather than merely keeping the
# newest version of every cached package name) removes packages that have left
# the lists or dependency closure, such as an old Electron major version.
if ! resolved_package_files="$(
  pacman --config "$online_pacman_conf" --noconfirm \
    --dbpath /tmp/offlinedb -S --print --print-format '%f' "${all_packages[@]}"
)"; then
  echo "ERROR: could not resolve the package files required by the offline mirror" >&2
  exit 1
fi
mapfile -t required_package_files <<< "$resolved_package_files"
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  for required_package_file in "${required_package_files[@]}"; do
    source_package="$OMARCHY_ARM_ARTIFACT_CACHE/pacman/pkg/$required_package_file"
    [[ -s $source_package ]] || { echo "ERROR: resolved ARM package is absent from the persistent cache: $required_package_file" >&2; exit 1; }
    install -m 0644 "$source_package" "$offline_mirror_dir/"
  done
fi

# The online transaction intentionally excludes packages built from the local
# checkouts. Add those exact artifacts back to the keep-set after verifying
# that the local build left exactly one file for each selected package name.
if [[ -n ${LOCAL_OMARCHY_BUILD:-} ]]; then
  for local_package_name in "${local_package_names[@]}"; do
    local_package_file=""
    for candidate in "$offline_mirror_dir/$local_package_name-"*.pkg.tar.*; do
      [[ -f $candidate && $candidate != *.sig ]] || continue
      read -r candidate_name _ < <(pacman -Qp "$candidate" 2>/dev/null) || continue
      [[ $candidate_name == "$local_package_name" ]] || continue
      if [[ -n $local_package_file ]]; then
        echo "ERROR: multiple local builds found for $local_package_name" >&2
        exit 1
      fi
      local_package_file="${candidate##*/}"
    done
    if [[ -z $local_package_file ]]; then
      echo "ERROR: local build not found for $local_package_name" >&2
      exit 1
    fi
    required_package_files+=("$local_package_file")
  done
fi

printf '%s\n' "${required_package_files[@]}" |
  bash "$builder_root/prune-offline-mirror.sh" "$offline_mirror_dir"

mapfile -t offline_archives < <(find "$offline_mirror_dir" -maxdepth 1 -type f -name '*.pkg.tar.*' ! -name '*.sig' -print | sort)
(( ${#offline_archives[@]} > 0 )) || { echo "ERROR: offline mirror contains no package archives" >&2; exit 1; }

# The repository metadata is deterministic for an exact set of package
# archives. Keep its input-addressed copy with the persistent ARM artifacts so
# profile-only rebuilds can go directly to mkarchiso while retaining a content
# checksum gate over every archive.
reuse_offline_index=0
if [[ $OMARCHY_ARCH == "aarch64" ]]; then
  offline_index_cache="$OMARCHY_ARM_ARTIFACT_CACHE/repo-index"
  mkdir -p "$offline_index_cache"
  mapfile -t offline_archive_names < <(printf '%s\n' "${offline_archives[@]##*/}")
  offline_index_hash=$(
    cd "$offline_mirror_dir"
    sha256sum "${offline_archive_names[@]}" | sha256sum | awk '{print $1}'
  )
  if [[ -s $offline_index_cache/inputs.sha256 ]] &&
    [[ $(<"$offline_index_cache/inputs.sha256") == "$offline_index_hash" ]] &&
    [[ -s $offline_index_cache/offline.db.tar.gz ]] &&
    [[ -s $offline_index_cache/offline.files.tar.gz ]]; then
    install -m 0644 "$offline_index_cache/offline.db.tar.gz" "$offline_mirror_dir/offline.db.tar.gz"
    install -m 0644 "$offline_index_cache/offline.files.tar.gz" "$offline_mirror_dir/offline.files.tar.gz"
    ln -sfn offline.db.tar.gz "$offline_mirror_dir/offline.db"
    ln -sfn offline.files.tar.gz "$offline_mirror_dir/offline.files"
    reuse_offline_index=1
    echo "Reused content-matched offline repository index."
  fi
fi

if (( reuse_offline_index == 0 )); then
  rm -f "$offline_mirror_dir"/offline.db* "$offline_mirror_dir"/offline.files*
  repo-add "$offline_mirror_dir/offline.db.tar.gz" "${offline_archives[@]}"
  if [[ $OMARCHY_ARCH == "aarch64" ]]; then
    install -m 0644 "$offline_mirror_dir/offline.db.tar.gz" "$offline_index_cache/offline.db.tar.gz"
    install -m 0644 "$offline_mirror_dir/offline.files.tar.gz" "$offline_index_cache/offline.files.tar.gz"
    printf '%s\n' "$offline_index_hash" >"$offline_index_cache/inputs.sha256"
  fi
fi

# mkarchiso expects the mirror at /var/cache/omarchy/mirror/offline inside the
# container (the airootfs path); symlink rather than duplicate.
mkdir -p /var/cache/omarchy/mirror
ln -sf "$offline_mirror_dir" /var/cache/omarchy/mirror/offline

# Denominator for the install dashboard's progress bar. Resolving the mirror's
# own package lists against the mirror we just indexed, with an empty local db,
# is the question pacstrap asks at install time — same resolver, same repo, same
# lists — so no hand-kept constant can drift.
#
# phases.py records expected and actual in the timing JSON, so growing drift
# shows up in acceptance runs. The early-bootstrap set is already inside this
# closure, so restating it would only add a second list to drift.
resolve_expected_packages() {
  local resolve_root=/tmp/omarchy-expected-packages
  local resolved
  local -a targets

  rm -rf "$resolve_root"
  mkdir -p "$resolve_root/var/lib/pacman"

  mapfile -t targets < <(
    {
      grep -hv '^#\|^$' "$archinstall_package_file"
      # Read the shipped copy, which is what _runtime_package_list reads at
      # install time, not the build-time source it came from.
      grep -hv '^#\|^$' \
        "$build_cache_dir/airootfs/usr/share/omarchy-iso/omarchy-base.packages"
      printf '%s\n' "$OMARCHY_RUNTIME_PACKAGE" "$OMARCHY_SETTINGS_PACKAGE" \
        "$OMARCHY_NVIM_PACKAGE"
    } | sort -u
  )

  printf '%s\n' "${targets[@]}" \
    >"$build_cache_dir/airootfs/usr/share/omarchy-iso/target-packages"
  install -m 0644 "$builder_root/required-runtime-commands.aarch64" \
    "$build_cache_dir/airootfs/usr/share/omarchy-iso/required-runtime-commands"

  pacman --config "$build_cache_dir/pacman-offline.conf" \
    --root "$resolve_root" --dbpath "$resolve_root/var/lib/pacman" \
    --noconfirm -Sy >/dev/null || return 1

  # Capture before counting: no pipefail here, so a pacman failure inside a
  # pipeline would become a plausible partial count, which never trips the
  # dashboard's fallback.
  resolved="$(pacman --config "$build_cache_dir/pacman-offline.conf" \
    --root "$resolve_root" --dbpath "$resolve_root/var/lib/pacman" \
    --noconfirm -S --print --print-format '%n' "${targets[@]}")" || return 1

  printf '%s\n' "$resolved" | sort -u | grep -c .
}

# Worth failing the build over: -S --print only aborts when a target is missing
# from the offline repo, which would fail pacstrap the same way. A count that
# merely looks wrong is not — the dashboard falls back without the file.
if ! expected_packages="$(resolve_expected_packages)"; then
  echo "ERROR: could not resolve the target package count from the offline mirror." >&2
  echo "       pacman -S --print aborts the whole transaction if any single target" >&2
  echo "       is missing, so this almost certainly means pacstrap would fail the" >&2
  echo "       same way at install time." >&2
  exit 1
fi
if (( expected_packages < 600 || expected_packages > 2000 )); then
  echo "WARNING: resolved target package count $expected_packages is outside the" >&2
  echo "         expected 600-2000 range; shipping no denominator so the install" >&2
  echo "         dashboard falls back to its time-based curve." >&2
else
  printf '%s\n' "$expected_packages" \
    >"$build_cache_dir/airootfs/usr/share/omarchy-iso/expected-packages"
  echo "Target install resolves to $expected_packages packages."
fi

# Live ISO uses the same offline pacman.conf.
cp "$build_cache_dir/pacman-offline.conf" "$build_cache_dir/airootfs/etc/pacman.conf"

# Reassemble the live root from the current profile on every run. Package,
# release, and native-build caches live outside this directory and remain
# reusable; keeping a failed mkarchiso work tree can retain obsolete initramfs
# hooks or installer files from an earlier profile.
[[ $build_cache_dir == /* && $build_cache_dir != "/" ]] || {
  echo "ERROR: unsafe ISO build cache path: $build_cache_dir" >&2
  exit 1
}
rm -rf "$build_cache_dir/work"

# Build the ISO.
mkarchiso -v -w "$build_cache_dir/work/" -o "$output_dir/" "$build_cache_dir/"

# Match host UID/GID on output.
if [[ -n $HOST_UID && -n $HOST_GID ]]; then
  chown -R "$HOST_UID:$HOST_GID" "$output_dir/"
fi
