# blue-build-dmoseley-chromebook

Thin [BlueBuild](https://blue-build.org/) OCI image layered on top of
[`ghcr.io/drewmoseley/blue-build-dmoseley:latest`](https://github.com/drewmoseley/blue-build-dmoseley)
— the personal desktop image. Adds only what is specific to an HP Chromebook:
audio hardware setup, keyboard remapping, and the packages they require.

All Flatpaks, Homebrew, Docker, NUT, restic, GNOME settings, and other
base functionality are inherited from the parent image.

Published to `ghcr.io/drewmoseley/blue-build-dmoseley-chromebook` via GitHub
Actions on every push to `main`.

## Repository layout

| Path | Purpose |
|------|---------|
| `recipes/recipe.yml` | Chromebook-specific modules layered on the parent image |
| `files/system/` | Copied verbatim to `/` in the image |
| `files/system/usr/lib/chromebook-audio/` | Platform audio config (`platform-landia.conf`) |
| `files/system/usr/lib/systemd/system/` | `chromebook-audio-setup.service` unit |
| `files/system/usr/libexec/` | `chromebook-audio-setup.sh` runtime script |
| `scripts/` | Local helper scripts (`validate.sh`) |

## What this image adds over the parent

| Addition | Source | Purpose |
|----------|--------|---------|
| `chromebook-linux-audio` | COPR `pvermeer/chromebook-linux-audio` | Audio hardware support for Chromebook |
| `keyd` | COPR `alternateved/keyd` | Kernel-level key remapping daemon |
| `cros-keyboard-map` | COPR `alternateved/keyd` | ChromeOS keyboard layout for keyd |
| `python3-libfdt` | Terra repo (`terrapkg/subatomic-repos`) | Dependency for audio setup |
| `chromebook-audio-setup.service` | `files/system` | One-shot service; probes hardware at boot and writes audio config |

The audio setup **must** run at boot (hardware probe + writable overlay writes)
— this is why it lives in the image rather than brew or distrobox.

## User-space configuration

Inherited from the parent image. Same preference order applies:

1. **Linuxbrew** — install CLI tools here first
2. **Distrobox** (`~/SyncThing/mackup/.bluefin-distrobox.ini`) — for tools that cannot go in brew
3. **Image** — only for kernel/system integration, services, or hardware-specific packages

See the [parent image CLAUDE.md](https://github.com/drewmoseley/blue-build-dmoseley/blob/main/CLAUDE.md)
for full details.

## Building and validating

```bash
./scripts/validate.sh

blue-build build recipes/recipe.yml
```

**YAML edits — watch the line-length cap.** CI's `validate.yml` runs `yamllint`
on `.github/workflows/` + `recipes/recipe.yml` against `.yamllint.yml`, which
enforces an **80-char line limit** (characters, so a multi-byte `—` still
costs 1). `validate.sh` now runs the same yamllint locally — run it before
pushing a workflow/recipe change; YAML-syntax-valid still red-X's CI on length.

## Rebasing an existing install

```bash
# Step 1 — unsigned (installs signing keys)
rpm-ostree rebase ostree-unverified-registry:ghcr.io/drewmoseley/blue-build-dmoseley-chromebook:latest
systemctl reboot

# Step 2 — signed
rpm-ostree rebase ostree-image-signed:docker://ghcr.io/drewmoseley/blue-build-dmoseley-chromebook:latest
systemctl reboot
```

## Signing

```bash
cosign verify --key cosign.pub ghcr.io/drewmoseley/blue-build-dmoseley-chromebook
```

The private key (`cosign.key`) is **never committed**; it lives in a GitHub
Actions secret.
