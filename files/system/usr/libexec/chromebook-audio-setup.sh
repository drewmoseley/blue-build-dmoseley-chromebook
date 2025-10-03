#!/bin/bash
# Create overlay working directories
mkdir -p /var/lib/alsa-ucm-upper /var/lib/alsa-ucm-work
mkdir -p /var/lib/audio-firmware-upper /var/lib/audio-firmware-work

# Mount overlays for writable locations (preserving existing content)
mount -t overlay overlay \
    -o lowerdir=/usr/share/alsa/ucm2,upperdir=/var/lib/alsa-ucm-upper,workdir=/var/lib/alsa-ucm-work \
    /usr/share/alsa/ucm2 2>/dev/null || true

mount -t overlay overlay \
    -o lowerdir=/lib/firmware,upperdir=/var/lib/audio-firmware-upper,workdir=/var/lib/audio-firmware-work \
    /lib/firmware 2>/dev/null || true

# Only run setup-audio if not already configured
if [ ! -f /var/lib/chromebook-audio-configured ]; then
    # Run the audio setup
    cp -r /usr/share/chromebook-linux-audio/alsa-ucm-conf-cros /tmp
    cd /usr/share/chromebook-linux-audio/chromebook-linux-audio
    ./setup-audio
    rm -rf /tmp/alsa-ucm-conf-cros

    # Mark as configured
    touch /var/lib/chromebook-audio-configured
fi
