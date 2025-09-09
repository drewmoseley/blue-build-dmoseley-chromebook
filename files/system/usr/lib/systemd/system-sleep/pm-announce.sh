#!/bin/sh
#

log() {
    logger -t auto-suspend "$*: $(date)"
    echo "$*: $(date)" >> /var/log/pm-auto-suspend.log
    wall "$*: $(date)"
}

sleep 5
log "$0 $@"
