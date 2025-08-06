#!/bin/sh
#
# Bluefin specific mechanism to add groups to a user
#

USERNAME=dmoseley
SUPPLEMENTAL_GROUPS="dialout docker libvirt kvm"

for GROUP in ${SUPPLEMENTAL_GROUPS}; do
    if ! grep -q "^${GROUP}" /etc/group; then
        echo "Adding ${GROUP} to /etc/group"
        grep ^${GROUP} /usr/lib/group >> /etc/group
    fi
done

/usr/sbin/usermod -aG $(echo ${SUPPLEMENTAL_GROUPS} | tr ' ' ',') ${USERNAME}
