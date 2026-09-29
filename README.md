# NVIDIA 580xx Arch Installer

An interactive installer for the proprietary NVIDIA 580xx DKMS driver on Arch Linux and compatible derivatives. It is intended for supported older GPUs, including the GeForce GTX 10 series.

## Usage

Run as a regular user, without `sudo`:

```bash
bash nvidia-580xx-arch-installer.sh --check
bash nvidia-580xx-arch-installer.sh
```

The installer checks the GPU and kernel headers, offers matching 32-bit libraries for Steam and Wine, sets DRM modesetting, rebuilds the initramfs, and checks the DKMS modules. It uses configured repository packages when available; otherwise it offers `paru` or `yay` and can build the selected helper from the AUR after showing its `PKGBUILD`. Builds run as a regular user; installing packages and build dependencies uses `sudo`.

If 32-bit libraries are selected and `[multilib]` is disabled, the installer offers to enable it in `/etc/pacman.conf` after final confirmation. It backs up the original file, validates the new configuration, and runs a full system upgrade with the package installation. Unusual `[multilib]` sections must be edited manually. Secure Boot and Manjaro require separate driver setup and are excluded from the automated installation.

Reboot only after the installer reports success. Run `--check` again after reboot.
