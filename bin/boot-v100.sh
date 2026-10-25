#!/usr/bin/env bash
# boot-v100.sh — bring up a Tesla V100 behind an OcuLink eGPU dock after a cold boot.
# The dock's power switch is bypassed through a DSD TECH SH-UR01A USB relay
# (CP2102N @ 9600 8N1, LCUS-style protocol, switch on the NO contacts).
#
# Usage:  boot-v100.sh        attach sequence (relay on -> S3 dance -> driver)
#         boot-v100.sh off    de-energize relay (dock off) — for shutdown units
#         boot-v100.sh on     energize relay only, no attach
#
# Sequence: relay ON -> settle -> S3 suspend (DXIO retrains the port on resume)
#           -> rescan -> BAR check -> load nvidia -> persistence -> power cap.

set -euo pipefail

SLEEP_SECS="${SLEEP_SECS:-8}"       # time spent in S3 while the link trains
RELAY_SETTLE="${RELAY_SETTLE:-0.5}" # relay close -> dock PSU/card rails up
POWER_CAP_W="${POWER_CAP_W:-200}"   # sustained cap for the passive heatsink
NV_VENDOR="10de"
# the relay's serial device: the first CP2102N by id unless RELAY_DEV names one
RELAY_DEV="${RELAY_DEV:-$(ls /dev/serial/by-id/usb-Silicon_Labs_CP2102N_*-if00-port0 2>/dev/null | head -n1)}"

log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }
die() { printf '[!] %s\n' "$*" >&2; exit 1; }

relay() {  # relay on|off — SH-UR01A AT protocol @ 9600 8N1:
           #   AT+CH1=1 = close channel 1 (NO contact closes -> dock ON)
           #   AT+CH1=0 = open channel 1  (dock OFF)
    [[ -e "${RELAY_DEV}" ]] || die "relay not found at ${RELAY_DEV}"
    stty -F "${RELAY_DEV}" 9600 raw -echo -crtscts -hupcl
    case "$1" in
        on)  printf 'AT+CH1=1\r\n' > "${RELAY_DEV}" ;;
        off) printf 'AT+CH1=0\r\n' > "${RELAY_DEV}" ;;
    esac
    log "relay ${1} (dock ${1})"
}

[[ ${EUID} -eq 0 ]] || die "run as root"

case "${1:-attach}" in
    off) relay off; exit 0 ;;   # NB: don't cut dock power with the driver bound
    on)  relay on;  exit 0 ;;
    attach) ;;
    *) die "usage: $0 [on|off]" ;;
esac

# Bail early if the card is already up (script is idempotent)
if lspci -n -d "${NV_VENDOR}:" | grep -q .; then
    log "NVIDIA device already enumerated, skipping power/suspend."
else
    relay on
    sleep "${RELAY_SETTLE}"

    log "Suspending for ${SLEEP_SECS}s while the port trains..."
    sleep 2
    rtcwake -m mem -s "${SLEEP_SECS}"
    log "Resumed. Settling..."
    sleep 2

    log "Rescanning PCI bus..."
    echo 1 > /sys/bus/pci/rescan
    sleep 2
fi

BDF="$(lspci -Dn -d "${NV_VENDOR}:" | awk '{print $1; exit}')"
[[ -n "${BDF}" ]] || die "no NVIDIA device after rescan — relay clicked? cable seated?"
log "GPU at ${BDF}"

# BAR1 (resource line 2) must have a nonzero base, i.e. the 32 GB window got assigned
read -r bar1_start _ _ < <(sed -n '2p' "/sys/bus/pci/devices/${BDF}/resource")
[[ "${bar1_start}" != "0x0000000000000000" ]] \
    || die "BAR1 unassigned — check 'pci=nocrs iommu=pt' on cmdline (dmesg | grep 'BAR 1')"
log "BAR1 @ ${bar1_start}"

log "Loading driver..."
modprobe nvidia
modprobe nvidia_uvm

sleep 1
nvidia-smi || die "nvidia-smi failed — check dmesg for RmInitAdapter errors"

# Persistence: prefer the daemon if installed, else legacy -pm
if systemctl list-unit-files nvidia-persistenced.service &>/dev/null; then
    systemctl start nvidia-persistenced
else
    nvidia-smi -pm 1
fi

nvidia-smi -pl "${POWER_CAP_W}" || log "power cap failed (non-fatal)"

log "V100 online."
