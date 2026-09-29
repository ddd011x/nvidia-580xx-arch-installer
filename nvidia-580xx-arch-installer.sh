#!/usr/bin/env bash
# NVIDIA 580xx proprietary DKMS setup for Arch-family pacman systems.
# Run as a regular user: bash nvidia-580xx-arch-installer.sh
# This script never runs makepkg as root or uses pacman -Rdd/--overwrite.
# Sources: https://archlinux.org/news/nvidia-590-driver-drops-pascal-support-main-packages-switch-to-open-kernel-modules/
#          https://wiki.archlinux.org/title/NVIDIA
#          https://wiki.archlinux.org/title/Dynamic_Kernel_Module_Support
#          https://aur.archlinux.org/packages/nvidia-580xx-dkms
set -Eeuo pipefail

readonly MODPROBE_FILE=/etc/modprobe.d/90-nvidia-580xx-drm.conf
readonly MODPROBE_CONTENT=$'# NVIDIA 580xx: DRM KMS and framebuffer for Wayland and consoles.\noptions nvidia_drm modeset=1 fbdev=1\n'
changed=0
initramfs_tool=''
package_source=''
aur_helper=''
bootstrap_aur_helper=0
declare -a header_packages=() kernel_versions=() driver_packages=()

info() { printf '%s\n' "[INFO] $*"; }
warn() { printf '%s\n' "[WARN] $*" >&2; }
die() {
  printf '%s\n' "[ERROR] $*" >&2
  if (( changed )); then
    warn 'The operation stopped after changes. Do not reboot until you resolve the error and rerun this script.'
  fi
  exit 1
}
on_error() {
  local status=$1 line=$2
  warn "Command failed at line $line (exit $status)."
  if (( changed )); then
    warn 'Do not reboot until the error is resolved and DKMS/initramfs checks pass.'
  fi
  exit "$status"
}
trap 'on_error "$?" "$LINENO"' ERR

installed() { pacman -Qq "$1" &>/dev/null; }
in_repo() { pacman -Si "$1" &>/dev/null; }

check_platform() {
  [[ $(uname -m) == x86_64 ]] || die 'Only x86_64 is supported.'
  command -v pacman >/dev/null || die 'pacman was not found.'
  [[ -r /etc/os-release ]] || die '/etc/os-release is missing.'
  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ ${ID:-} == manjaro || " ${ID_LIKE:-} " == *' manjaro '* ]]; then
    die 'Manjaro manages NVIDIA profiles through mhwd. Use its supported 580xx profile; do not apply the Arch/AUR transaction here.'
  fi
  if [[ ${ID:-} != arch && " ${ID_LIKE:-} " != *' arch '* ]]; then
    die 'This installation is limited to Arch Linux and Arch-derived pacman systems.'
  fi
  [[ $EUID -ne 0 ]] || die 'Run this script as your normal user, without sudo. It calls sudo only for system changes.'
  command -v sudo >/dev/null || die 'sudo is required.'
  command -v modinfo >/dev/null || die 'modinfo (kmod) is required.'
  command -v dkms >/dev/null || info 'DKMS will be installed with the driver.'
  [[ ! -e /var/lib/pacman/db.lck ]] || die 'pacman is already running (db.lck exists).'
  [[ -d /sys/bus/pci/devices ]] || die 'PCI devices cannot be inspected.'

  local dev count=0 class vendor
  for dev in /sys/bus/pci/devices/*; do
    [[ -r $dev/vendor && -r $dev/class ]] || continue
    read -r vendor < "$dev/vendor"
    read -r class < "$dev/class"
    if [[ $vendor == 0x10de && $class == 0x03* ]]; then
      (( count += 1 ))
      if command -v lspci >/dev/null; then
        lspci -nn -s "${dev##*/}" || true
      else
        info "NVIDIA display GPU: PCI ${dev##*/}, device ID $(<"$dev/device")"
      fi
    fi
  done
  (( count == 1 )) || die "Expected exactly one NVIDIA display GPU, found $count. Check multi-GPU compatibility manually."
}

check_secure_boot() {
  [[ -d /sys/firmware/efi ]] || return 0
  local state='' f
  if command -v mokutil >/dev/null; then
    state=$(mokutil --sb-state 2>/dev/null || true)
    case $state in
      *'SecureBoot enabled'*|*'Secure Boot enabled'*)
        die 'Secure Boot is enabled. This automated path cannot verify DKMS module signing and enrollment; use a manual signing workflow.' ;;
      *'SecureBoot disabled'*|*'Secure Boot disabled'*) return 0 ;;
    esac
  fi
  for f in /sys/firmware/efi/efivars/SecureBoot-*; do
    [[ -r $f ]] || continue
    state=$(od -An -tu1 -j4 -N1 "$f" | tr -d '[:space:]')
    case $state in
      0) return 0 ;;
      1) die 'Secure Boot is enabled. This automated path cannot verify DKMS module signing and enrollment; use a manual signing workflow.' ;;
    esac
  done
  die 'UEFI Secure Boot state could not be verified; refusing to install an unsigned DKMS module.'
}

detect_initramfs() {
  local presets=0
  compgen -G '/etc/mkinitcpio.d/*.preset' >/dev/null && presets=1
  if (( presets )) && command -v mkinitcpio >/dev/null && command -v dracut >/dev/null; then
    die 'Both mkinitcpio presets and dracut are present. Identify the active boot image generator before changing drivers.'
  fi
  if (( presets )) && command -v mkinitcpio >/dev/null; then
    initramfs_tool=mkinitcpio
  elif command -v dracut >/dev/null; then
    initramfs_tool=dracut
  else
    die 'No supported initramfs generator found (mkinitcpio presets or dracut).'
  fi
  info "Initramfs generator: $initramfs_tool"
}

check_boot_mounts() {
  local target
  command -v findmnt >/dev/null || die 'findmnt (util-linux) is required.'
  while IFS= read -r target; do
    case $target in
      /boot|/boot/efi|/efi)
        findmnt --mountpoint "$target" >/dev/null || die "$target is listed in fstab but is not mounted. Mount it before rebuilding images." ;;
    esac
  done < <(findmnt --fstab --raw --noheadings --output TARGET 2>/dev/null || true)
}

detect_kernels() {
  local dir base header version
  declare -A seen=()
  kernel_versions=()
  header_packages=()
  for dir in /usr/lib/modules/*; do
    [[ -f $dir/pkgbase ]] || continue
    read -r base < "$dir/pkgbase"
    version=${dir##*/}
    [[ $base =~ ^[a-zA-Z0-9@._+-]+$ ]] || die "Invalid kernel package base in $dir/pkgbase."
    installed "$base" || continue
    header="${base}-headers"
    if ! installed "$header" && ! in_repo "$header"; then
      die "Kernel $version needs $header. Install matching headers from your kernel's repository first."
    fi
    kernel_versions+=("$version")
    if [[ ! -v seen[$header] ]]; then
      header_packages+=("$header")
      seen[$header]=1
    fi
  done
  ((${#kernel_versions[@]})) || die 'No installed kernel with /usr/lib/modules/*/pkgbase was found.'
  info "Installed kernels: ${kernel_versions[*]}"
  info "Required headers: ${header_packages[*]}"
}

check_conflicting_config() {
  local tmp
  [[ ! -L $MODPROBE_FILE ]] || die "$MODPROBE_FILE is a symbolic link. Review it manually before continuing."
  tmp=$(mktemp)
  printf '%s' "$MODPROBE_CONTENT" > "$tmp"
  if [[ -e $MODPROBE_FILE ]] && ! cmp -s "$tmp" "$MODPROBE_FILE"; then
    rm -f "$tmp"
    die "$MODPROBE_FILE already contains different settings. Review it manually before continuing."
  fi
  rm -f "$tmp"
  if [[ -r /proc/cmdline ]] &&
     grep -Eq '(^|[[:space:]])(nomodeset|nvidia[-_]drm\.(modeset|fbdev)=0|module_blacklist=nvidia)([[:space:]]|$)' /proc/cmdline; then
    die 'The current kernel command line disables NVIDIA/KMS. Remove that setting from your boot configuration first.'
  fi
  if grep -REiq '^[[:space:]]*options[[:space:]]+nvidia_drm[[:space:]].*(modeset|fbdev)=0' \
      /etc/modprobe.d /usr/lib/modprobe.d 2>/dev/null; then
    die 'An existing modprobe configuration disables NVIDIA DRM KMS/fbdev. Resolve it first.'
  fi
}

select_source() {
  local require_helper=${1:-yes}
  local dkms_repo=0 utils_repo=0 choice
  in_repo nvidia-580xx-dkms && dkms_repo=1
  in_repo nvidia-580xx-utils && utils_repo=1
  if (( dkms_repo != utils_repo )); then
    die 'Only part of the 580xx driver is in configured repositories. Fix repository consistency before proceeding.'
  fi
  if (( dkms_repo )); then
    package_source=repo
    info 'Matching 580xx packages are available from configured pacman repositories.'
  else
    package_source=aur
    if [[ $require_helper == no ]]; then
      if command -v paru >/dev/null; then info 'paru is installed.'; fi
      if command -v yay >/dev/null; then info 'yay is installed.'; fi
      if ! command -v paru >/dev/null && ! command -v yay >/dev/null; then
        info 'No AUR helper is installed. The installer can build paru or yay before installing the driver.'
      fi
      return 0
    fi
    printf '\n%s\n' 'Choose an AUR helper for this installation:'
    if command -v paru >/dev/null; then
      printf '%s\n' '1) paru (installed)'
    else
      printf '%s\n' '1) paru (build and install first)'
    fi
    if command -v yay >/dev/null; then
      printf '%s\n' '2) yay (installed)'
    else
      printf '%s\n' '2) yay (build and install first)'
    fi
    read -r -p 'Choose [1/2, default 1]: ' choice
    case $choice in
      ''|1) aur_helper=paru ;;
      2) aur_helper=yay ;;
      *) die 'Invalid AUR helper selection.' ;;
    esac
    if ! command -v "$aur_helper" >/dev/null; then
      bootstrap_aur_helper=1
    fi
    info "Selected AUR helper: $aur_helper"
  fi
}

install_aur_helper() {
  local cache_dir build_root source_dir answer
  [[ $aur_helper == paru || $aur_helper == yay ]] || die 'Invalid AUR helper name.'
  cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}
  mkdir -p -m 700 "$cache_dir"
  build_root=$(mktemp -d "$cache_dir/nvidia-580xx-helper.XXXXXXXX")
  source_dir="$build_root/$aur_helper"
  info "Cloning the $aur_helper AUR package into $source_dir"
  git clone --depth 1 "https://aur.archlinux.org/${aur_helper}.git" "$source_dir"
  [[ -f $source_dir/PKGBUILD ]] || die "The $aur_helper AUR repository has no PKGBUILD."
  printf '\n%s\n' "Files in the $aur_helper AUR package:"
  git -C "$source_dir" ls-files
  printf '\n%s\n' "Review $source_dir/PKGBUILD and any files it uses:"
  cat "$source_dir/PKGBUILD"
  printf '\n%s\n' "The package above will be built by your normal user, then installed through makepkg."
  read -r -p "Type BUILD to build and install $aur_helper: " answer
  [[ $answer == BUILD ]] || die 'AUR helper build cancelled.'
  (cd "$source_dir" && makepkg -si)
  command -v "$aur_helper" >/dev/null || die "$aur_helper was not found after its package installation."
  rm -rf -- "$build_root"
  info "$aur_helper is installed. Continuing with the NVIDIA 580xx packages."
}

multilib_enabled() {
  local repos
  command -v pacman-conf >/dev/null || return 1
  repos=$(pacman-conf --repo-list) || return 1
  [[ $'\n'${repos}$'\n' == *$'\nmultilib\n'* ]]
}

select_packages() {
  local need32=0 answer old32=0 repo32=0 repo_info
  if installed lib32-nvidia-utils || installed lib32-nvidia-580xx-utils ||
     installed lib32-opencl-nvidia || installed lib32-opencl-nvidia-580xx; then
    old32=1
  fi
  if [[ $package_source == repo ]]; then
    repo_info=$(LC_ALL=C pacman -Si nvidia-580xx-utils)
    [[ $repo_info != *lib32-nvidia-580xx-utils* ]] || repo32=1
  fi
  printf '\n%s\n' '32-bit NVIDIA libraries are needed for Steam, Wine, and other 32-bit graphics programs.'
  if (( old32 || repo32 )); then
    need32=1
    info '32-bit support is required by installed packages or this repository package.'
  else
    read -r -p 'Install matching 32-bit libraries? [y/N] ' answer
    [[ $answer == [yY] || $answer == [yY][eE][sS] ]] && need32=1
  fi
  if (( need32 )) && ! multilib_enabled; then
    die 'Enable [multilib] in /etc/pacman.conf, refresh repositories, and rerun. This script does not rewrite pacman.conf.'
  fi
  if (( need32 )) && [[ $package_source == repo ]] && ! in_repo lib32-nvidia-580xx-utils; then
    die 'The 64-bit 580xx packages are in repositories, but matching 32-bit packages are missing.'
  fi

  driver_packages=(nvidia-580xx-utils nvidia-580xx-dkms)
  if installed opencl-nvidia || installed opencl-nvidia-580xx; then
    driver_packages+=(opencl-nvidia-580xx)
  fi
  if (( need32 )); then
    driver_packages+=(lib32-nvidia-580xx-utils)
    if installed lib32-opencl-nvidia || installed lib32-opencl-nvidia-580xx; then
      driver_packages+=(lib32-opencl-nvidia-580xx)
    fi
  fi
  info "Driver packages: ${driver_packages[*]}"
}

confirm_hardware() {
  local answer
  printf '\n%s\n' 'NVIDIA 580xx is the legacy branch for Maxwell, Pascal, and Volta. GTX 1650 and RTX 20 series are Turing; use the current driver for those.'
  printf '%s\n' "Check your exact GPU against NVIDIA's supported-products list before proceeding."
  printf '%s\n' 'https://www.nvidia.com/en-us/drivers/unix/'
  read -r -p 'Is the NVIDIA GPU shown above supported by the 580xx proprietary driver? [y/N] ' answer
  [[ $answer == [yY] || $answer == [yY][eE][sS] ]] || die 'GPU compatibility was not confirmed.'
}

install_driver() {
  check_platform
  check_secure_boot
  detect_initramfs
  check_boot_mounts
  detect_kernels
  check_conflicting_config
  select_source
  confirm_hardware
  select_packages

  printf '\n%s\n' 'Installation will upgrade the system, install kernel headers and NVIDIA 580xx, then rebuild initramfs images.'
  printf '%s\n' 'Review all package conflicts and AUR build files shown by your package manager.'
  local answer
  read -r -p 'Type INSTALL to continue: ' answer
  [[ $answer == INSTALL ]] || die 'Installation cancelled.'
  sudo -v
  if [[ $package_source == repo ]]; then
    changed=1
    sudo pacman -Syu --needed "${header_packages[@]}" "${driver_packages[@]}"
  else
    changed=1
    sudo pacman -Syu --needed base-devel git "${header_packages[@]}"
    if (( bootstrap_aur_helper )); then install_aur_helper; fi
    "$aur_helper" -S --needed "${driver_packages[@]}"
  fi
  installed nvidia-580xx-utils && installed nvidia-580xx-dkms || die 'The 580xx driver packages were not installed.'

  if [[ ! -e $MODPROBE_FILE ]]; then
    local tmp
    tmp=$(mktemp)
    printf '%s' "$MODPROBE_CONTENT" > "$tmp"
    sudo install -D -m 644 "$tmp" "$MODPROBE_FILE"
    rm -f "$tmp"
  fi
  if [[ $initramfs_tool == mkinitcpio ]]; then
    sudo mkinitcpio -P
  else
    sudo dracut --regenerate-all --force
  fi
  verify_modules
  info 'Installation complete. Reboot, then run this script with --check and inspect nvidia-smi.'
}

verify_modules() {
  local dir base version module_version pkg_version failures=0
  pkg_version=$(pacman -Q nvidia-580xx-utils | awk '{print $2}')
  pkg_version=${pkg_version%-*}
  [[ $pkg_version == 580.* ]] || die "Unexpected version for nvidia-580xx-utils: $pkg_version"
  for dir in /usr/lib/modules/*; do
    [[ -f $dir/pkgbase ]] || continue
    read -r base < "$dir/pkgbase"
    installed "$base" || continue
    version=${dir##*/}
    if [[ ! -e $dir/build ]]; then
      warn "No usable headers for $version ($base)."
      (( failures += 1 ))
      continue
    fi
    module_version=$(modinfo -k "$version" -F version nvidia 2>/dev/null || true)
    if [[ $module_version != "$pkg_version" ]]; then
      warn "Kernel $version has NVIDIA module version '${module_version:-missing}'; expected $pkg_version."
      (( failures += 1 ))
    else
      info "Kernel $version: NVIDIA module $module_version found."
    fi
  done
  (( failures == 0 )) || die 'At least one kernel lacks a matching NVIDIA DKMS module.'
}

check_only() {
  local parameter value
  check_platform
  check_secure_boot
  detect_initramfs
  check_boot_mounts
  detect_kernels
  select_source no
  printf '\n%s\n' 'Installed 580xx packages:'
  pacman -Q nvidia-580xx-utils nvidia-580xx-dkms lib32-nvidia-580xx-utils 2>/dev/null || true
  if installed nvidia-580xx-utils && installed nvidia-580xx-dkms; then
    verify_modules
    if [[ -f $MODPROBE_FILE && $(<"$MODPROBE_FILE") == "${MODPROBE_CONTENT%$'\n'}" ]]; then
      info 'Persistent DRM KMS/fbdev configuration is present.'
    else
      warn 'The persistent DRM KMS/fbdev configuration is missing or differs from this script.'
    fi
    for parameter in modeset fbdev; do
      if [[ -r /sys/module/nvidia_drm/parameters/$parameter ]]; then
        read -r value < "/sys/module/nvidia_drm/parameters/$parameter"
        info "Loaded nvidia_drm $parameter: $value"
      fi
    done
    if command -v nvidia-smi >/dev/null; then nvidia-smi || warn 'nvidia-smi did not work; reboot if the driver was just changed.'; fi
  else
    info '580xx is not fully installed yet.'
  fi
}

usage() {
  cat <<'HELP'
NVIDIA 580xx installer for Arch-based systems

Run as a normal user (not with sudo):
  bash nvidia-580xx-arch-installer.sh
  bash nvidia-580xx-arch-installer.sh --check

The interactive menu uses English. Installation needs sudo, a supported NVIDIA
GPU, and kernel headers. If AUR packages are needed, choose paru or yay; if
the selected helper is missing, the script offers to build and install it.
For Steam/Wine, enable [multilib] before selecting 32-bit driver libraries.
Manjaro is excluded because its mhwd NVIDIA profiles require a separate flow.
Secure Boot systems are stopped because signing and key enrollment need
separate verification.
HELP
}

main() {
  local choice
  case ${1:-} in
    --help|-h) usage ;;
    --check) check_only ;;
    '')
      printf '%s\n' 'NVIDIA 580xx setup for Arch-based systems' '' \
        '1) Check this system' '2) Install/configure NVIDIA 580xx DKMS' '3) Exit'
      read -r -p 'Choose an option [1-3]: ' choice
      case $choice in
        1) check_only ;;
        2) install_driver ;;
        3) exit 0 ;;
        *) die 'Invalid option.' ;;
      esac ;;
    *) usage; exit 2 ;;
  esac
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
