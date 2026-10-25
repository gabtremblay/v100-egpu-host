#!/usr/bin/env bash
# v100-fan.sh -- host-side thermal daemon for a passive Tesla V100 on an eGPU dock.
# Drives the PWM fan on the Aquacomputer QUADRO (hwmon "quadro", kernel driver
# aquacomputer_d5next) from the GPU temperature nvidia-smi reports. Standalone:
# runs as a systemd service and does not care which container (llama.cpp,
# 1Cat-vLLM, nothing) is using the card.
#
# Policy = the llama.cpp launcher's in-container daemon, lifted out:
#   FAN_MIN_PCT floor below FAN_ON_C, linear to 100% at FAN_MAX_C, 100% above.
#   With FAN_ON_C == FAN_MAX_C (the current setting) that is a step: 40% / 100%.
#   Never 0%. Spin-up kick (1 s at 100%) on the first write. Duty re-asserted
#   every 60 s so the QUADRO's own stored curve can't reclaim the channel.
#   GPU present but temperature unreadable -> 100% failsafe.
#   No GPU visible (dock not attached yet / driver down) -> floor, keep polling.
#   Power cap + persistence mode applied each time the GPU (re)appears.
#   On SIGTERM: keep following the curve until the card is under FAN_ON_C
#   (max PARK_MAX_S), then leave the fan at the floor and exit.
set -u

GPU_INDEX=${GPU_INDEX:-0}
FAN_SLOT=${FAN_SLOT:-1}            # QUADRO header -> pwm1..pwm4
FAN_ON_C=${FAN_ON_C:-65}
FAN_MAX_C=${FAN_MAX_C:-65}
FAN_MIN_PCT=${FAN_MIN_PCT:-40}
FAN_POLL_S=${FAN_POLL_S:-3}
LOG_EVERY_S=${LOG_EVERY_S:-60}     # telemetry line cadence (journal)
GPU_POWER_CAP_W=${GPU_POWER_CAP_W:-200}   # empty = leave the power limit alone
PARK_MAX_S=${PARK_MAX_S:-300}
HWMON_ROOT=${HWMON_ROOT:-/sys/class/hwmon}
NVIDIA_SMI=${NVIDIA_SMI:-nvidia-smi}

log() { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }

PWMF=""; RPMF=""
FAN_PCT=-1          # -1 = channel not owned yet (forces first write + kick)
ASSERT_T=0
LAST_LOG_T=0
GPU_UP=-1
PARKING=0

find_quadro() {
    local h
    for h in "$HWMON_ROOT"/hwmon*; do
        [ -r "$h/name" ] || continue
        [ "$(cat "$h/name" 2>/dev/null)" = "quadro" ] || continue
        [ -e "$h/pwm${FAN_SLOT}" ] || continue
        PWMF="$h/pwm${FAN_SLOT}"
        RPMF="$h/fan${FAN_SLOT}_input"
        return 0
    done
    return 1
}

fan_write() { # $1 = duty percent 0..100
    local pct=$1
    [ "$pct" -lt "$FAN_MIN_PCT" ] && pct=$FAN_MIN_PCT
    [ "$pct" -gt 100 ] && pct=100
    if { printf '%s' $(( pct * 255 / 100 )) > "$PWMF"; } 2>/dev/null; then
        FAN_PCT=$pct
        return 0
    fi
    log "fan: write to ${PWMF} FAILED (QUADRO unplugged?) -- rediscovering"
    PWMF=""
    return 1
}

gpu_temp() { # prints an integer or nothing
    local t
    t=$("$NVIDIA_SMI" -i "$GPU_INDEX" --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d '[:space:]')
    [[ "$t" =~ ^[0-9]+$ ]] && printf '%s' "$t"
}

gpu_present() { [ -n "$("$NVIDIA_SMI" -i "$GPU_INDEX" --query-gpu=name --format=csv,noheader 2>/dev/null)" ]; }

apply_power_cap() {
    "$NVIDIA_SMI" -i "$GPU_INDEX" -pm 1 >/dev/null 2>&1 || true
    if [ -n "$GPU_POWER_CAP_W" ]; then
        if "$NVIDIA_SMI" -i "$GPU_INDEX" -pl "$GPU_POWER_CAP_W" >/dev/null 2>&1; then
            log "gpu: persistence on, power limit ${GPU_POWER_CAP_W} W"
        else
            log "gpu: could not set power limit ${GPU_POWER_CAP_W} W (not root? unsupported?)"
        fi
    fi
}

target_for() { # $1 = temp C -> duty %
    local t=$1
    if [ "$t" -ge "$FAN_MAX_C" ]; then
        printf '100'
    elif [ "$t" -ge "$FAN_ON_C" ] && [ "$FAN_MAX_C" -gt "$FAN_ON_C" ]; then
        printf '%s' $(( FAN_MIN_PCT + (t - FAN_ON_C) * (100 - FAN_MIN_PCT) / (FAN_MAX_C - FAN_ON_C) ))
    else
        printf '%s' "$FAN_MIN_PCT"
    fi
}

fan_step() {
    local t target
    [ -n "$PWMF" ] || { find_quadro || return 0; log "fan: QUADRO at ${PWMF%/pwm*}, header pwm${FAN_SLOT}"; FAN_PCT=-1; }
    if gpu_present; then
        if [ "$GPU_UP" -ne 1 ]; then GPU_UP=1; log "gpu: visible"; apply_power_cap; fi
        t=$(gpu_temp)
        if [ -z "$t" ]; then
            target=100   # failsafe: card is there, we can't see its temperature
        else
            target=$(target_for "$t")
        fi
    else
        if [ "$GPU_UP" -ne 0 ]; then GPU_UP=0; log "gpu: not visible (dock detached / driver down) -- holding floor"; fi
        t=""; target=$FAN_MIN_PCT
    fi
    if [ "$FAN_PCT" -lt 0 ]; then
        fan_write 100 && sleep 1    # spin-up kick from an unknown state
    fi
    if [ -n "$PWMF" ] && { [ "$target" -ne "$FAN_PCT" ] || [ $((SECONDS - ASSERT_T)) -ge 60 ]; }; then
        fan_write "$target" && ASSERT_T=$SECONDS
    fi
    if [ $((SECONDS - LAST_LOG_T)) -ge "$LOG_EVERY_S" ]; then
        LAST_LOG_T=$SECONDS
        local rpm='?' tele=''
        [ -n "$RPMF" ] && rpm=$(cat "$RPMF" 2>/dev/null || printf '?')
        [ "$GPU_UP" -eq 1 ] && tele=$("$NVIDIA_SMI" -i "$GPU_INDEX" --format=csv,noheader,nounits \
            --query-gpu=power.draw,temperature.gpu,clocks.sm,utilization.gpu,memory.used 2>/dev/null | tr -d ' ')
        log "[gpu] ${tele:-no-gpu}  fan ${FAN_PCT}%/${rpm}rpm"
    fi
}

park() {
    PARKING=1
    local t0=$SECONDS t target
    log "stop: cooling down on the curve until <${FAN_ON_C}C (max ${PARK_MAX_S}s), then floor ${FAN_MIN_PCT}%"
    while [ $((SECONDS - t0)) -lt "$PARK_MAX_S" ]; do
        [ -n "$PWMF" ] || break
        t=$(gpu_temp)
        [ -z "$t" ] && { log "stop: GPU temp unreadable -- leaving floor"; break; }
        [ "$t" -lt "$FAN_ON_C" ] && { log "stop: ${t}C < ${FAN_ON_C}C"; break; }
        target=$(target_for "$t"); fan_write "$target"
        sleep 5
    done
    [ -n "$PWMF" ] && fan_write "$FAN_MIN_PCT" && log "stop: fan left at ${FAN_MIN_PCT}%"
    exit 0
}
trap park TERM INT

log "v100-fan: floor ${FAN_MIN_PCT}% <${FAN_ON_C}C, ${FAN_MIN_PCT}-100% over ${FAN_ON_C}-${FAN_MAX_C}C, poll ${FAN_POLL_S}s, cap ${GPU_POWER_CAP_W:-none} W"
until find_quadro; do
    log "fan: no 'quadro' hwmon yet (aquacomputer_d5next bound? QUADRO on USB?) -- retrying in 10 s"
    sleep 10
done
log "fan: QUADRO at ${PWMF%/pwm*}, header pwm${FAN_SLOT}"

while :; do
    fan_step
    sleep "$FAN_POLL_S" &
    wait $!   # interruptible sleep so SIGTERM parks promptly
done
