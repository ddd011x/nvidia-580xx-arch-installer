# NVIDIA 580xx Arch Installer

An interactive installer for the proprietary NVIDIA 580xx DKMS driver on Arch Linux and compatible derivatives. It is intended for supported older GPUs, including the GeForce GTX 10 series.

## Usage

Run as a regular user, without `sudo`:

```bash
bash nvidia-580xx-arch-installer.sh --check
bash nvidia-580xx-arch-installer.sh
```

The installer checks the GPU and kernel headers, offers matching 32-bit libraries for Steam and Wine, sets DRM modesetting, rebuilds the initramfs, and checks the DKMS modules. It uses configured repository packages when available; otherwise it offers `paru` or `yay` and can build the selected helper from the AUR after showing its `PKGBUILD`.

Enable `[multilib]` before selecting 32-bit libraries. Secure Boot and Manjaro require separate driver setup and are excluded from the automated installation.

Reboot only after the installer reports success. Run `--check` again after reboot.
