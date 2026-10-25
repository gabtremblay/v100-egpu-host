#!/usr/bin/env bash
# v100-throttle.sh -- watches whether the GPU throttles during long jobs, and says why.
#
# Samples nvidia-smi every INTERVAL_S seconds: temperature, SM/memory clocks, power, utilization and the driver's
# clock-event reasons. Three things come out of it:
#   - the journal: a line when a throttle episode starts or ends (thermal slowdown, HW slowdown / power brake), and a
#     summary every SUMMARY_S while the card is busy: busy share, SM clock while busy, max temperature, seconds spent
#     thermal-throttled / HW-throttled / at the power cap. Thermal throttling and temperatures at or above WARN_TEMP_C
#     are logged as warnings; sitting at the power cap is normal for a 200 W-capped card and is only counted.
#   - a CSV per day under STATE_DIR (samples-YYYY-MM-DD.csv), every sample, kept KEEP_DAYS days.
#   - `v100-throttle.sh report [today|yesterday|YYYY-MM-DD]`: busy time, throttle seconds, temperature distribution
#     against the card's own thresholds (83 C max operating, 87 C slowdown, 90 C shutdown on a V100), the episodes.
#
# Throttle reasons as nvidia-smi names them: hw_thermal_slowdown / sw_thermal_slowdown (the card is too hot: the
# problem this watches for), hw_slowdown and hw_power_brake_slowdown (board-level: a power rail or the brake pin),
# sw_power_cap (the configured limit, expected), gpu_idle (nothing to do).
set -u

INTERVAL_S=${INTERVAL_S:-5}
SUMMARY_S=${SUMMARY_S:-600}
BUSY_UTIL=${BUSY_UTIL:-20}           # utilization.gpu at or above this counts as busy
WARN_TEMP_C=${WARN_TEMP_C:-80}       # below the V100's 83 C max operating temperature
STATE_DIR=${STATE_DIR:-/var/lib/v100-throttle}
KEEP_DAYS=${KEEP_DAYS:-30}
GPU_INDEX=${GPU_INDEX:-0}
NVIDIA_SMI=${NVIDIA_SMI:-nvidia-smi}

FIELDS=temperature.gpu,clocks.sm,clocks.mem,power.draw,utilization.gpu,memory.used,clocks_event_reasons.hw_thermal_slowdown,clocks_event_reasons.sw_thermal_slowdown,clocks_event_reasons.hw_slowdown,clocks_event_reasons.hw_power_brake_slowdown,clocks_event_reasons.sw_power_cap,clocks_event_reasons.gpu_idle
HEADER="time,temp_c,sm_mhz,mem_mhz,power_w,util_pct,mem_used_mib,thermal,hw_slowdown,power_cap,idle"

log()  { printf '%s %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '%s WARN %s\n' "$(date '+%H:%M:%S')" "$*"; }

csv_path() { printf '%s/samples-%s.csv' "$STATE_DIR" "$1"; }

# ---------------------------------------------------------------- report
report() {
    local day=${1:-today}
    case "$day" in
        today)     day=$(date +%F) ;;
        yesterday) day=$(date -d yesterday +%F) ;;
    esac
    local f; f=$(csv_path "$day")
    [ -r "$f" ] || { echo "no samples for $day ($f)"; return 1; }
    awk -F, -v day="$day" -v busy_util="$BUSY_UTIL" -v warn_c="$WARN_TEMP_C" '
        NR == 1 { next }
        { n++; dt = (prev_t ? $1 - prev_t : 0); if (dt < 0 || dt > 60) dt = 0; prev_t = $1
          busy = ($6 + 0 >= busy_util)
          if (busy) { nb++; busy_s += dt; clk_sum += $3; if (min_clk == "" || $3 < min_clk) min_clk = $3 }
          if ($2 > max_t) { max_t = $2; max_t_at = $1 }
          if ($2 >= 80) t80 += dt; if ($2 >= 83) t83 += dt; if ($2 >= 87) t87 += dt
          if ($8 == 1) { th_s += dt; if (!in_th) { in_th = 1; th_start = $1; th_max = $2; th_n++ } else if ($2 > th_max) th_max = $2 }
          else if (in_th) { in_th = 0; ep = ep sprintf("    thermal  %s  %4d s  max %d C\n", strftime("%H:%M:%S", th_start), $1 - th_start, th_max) }
          if ($9 == 1) hw_s += dt
          if ($10 == 1) cap_s += dt
        }
        END {
          if (in_th) ep = ep sprintf("    thermal  %s  %4d s  max %d C (still on at end of data)\n", strftime("%H:%M:%S", th_start), prev_t - th_start, th_max)
          printf "v100-throttle report for %s: %d samples\n", day, n
          printf "  busy (util >= %d%%): %d min; SM clock while busy avg %d MHz, min %s MHz\n", busy_util, busy_s / 60, (nb ? clk_sum / nb : 0), (min_clk == "" ? "-" : min_clk)
          printf "  max temperature %d C at %s; time >= 80 C: %d s, >= 83 C (max operating): %d s, >= 87 C (slowdown): %d s\n", max_t, strftime("%H:%M:%S", max_t_at), t80, t83, t87
          printf "  thermal throttling: %d s in %d episodes; HW slowdown / power brake: %d s; at the power cap: %d s\n", th_s, th_n, hw_s, cap_s
          if (ep != "") printf "%s", ep
        }' "$f"
}

# ---------------------------------------------------------------- sampler
sample() {
    local line
    line=$("$NVIDIA_SMI" -i "$GPU_INDEX" --query-gpu="$FIELDS" --format=csv,noheader,nounits 2>/dev/null) || return 1
    [ -n "$line" ] || return 1
    IFS=',' read -r t sm mem pw util used hwt swt hws brake cap idle <<< "${line// /}"
    [[ "$t" =~ ^[0-9]+$ ]] || return 1
    TEMP=$t; SM=$sm; MEM=$mem; PW=${pw%%.*}; UTIL=${util%%.*}; USED=$used
    THERMAL=0; [ "$hwt" = Active ] || [ "$swt" = Active ] && THERMAL=1
    HWSLOW=0;  [ "$hws" = Active ] || [ "$brake" = Active ] && HWSLOW=1
    POWERCAP=0; [ "$cap" = Active ] && POWERCAP=1
    IDLE=0; [ "$idle" = Active ] && IDLE=1
    return 0
}

prune() {
    find "$STATE_DIR" -maxdepth 1 -name 'samples-*.csv' -mtime +"$KEEP_DAYS" -delete 2>/dev/null || true
}

run() {
    mkdir -p "$STATE_DIR"
    log "v100-throttle: every ${INTERVAL_S}s, summary every ${SUMMARY_S}s while busy (util >= ${BUSY_UTIL}%), warn at ${WARN_TEMP_C} C, csv in ${STATE_DIR}"
    local gpu_up=-1 in_thermal=0 in_hw=0 th_start=0 hw_start=0 th_max=0
    local day="" csv=""
    local w_t0=$SECONDS w_n=0 w_busy=0 w_clk=0 w_minclk=99999 w_maxt=0 w_th=0 w_hw=0 w_cap=0 w_warned=0
    while :; do
        if sample; then
            if [ "$gpu_up" -ne 1 ]; then gpu_up=1; log "gpu: visible (${TEMP} C, ${SM} MHz)"; fi
            local today; today=$(date +%F)
            if [ "$today" != "$day" ]; then
                day=$today; csv=$(csv_path "$day")
                [ -s "$csv" ] || printf '%s\n' "$HEADER" > "$csv"
                prune
            fi
            printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date +%s)" "$TEMP" "$SM" "$MEM" "$PW" "$UTIL" "$USED" "$THERMAL" "$HWSLOW" "$POWERCAP" "$IDLE" >> "$csv"

            # episodes
            if [ "$THERMAL" -eq 1 ] && [ "$in_thermal" -eq 0 ]; then
                in_thermal=1; th_start=$SECONDS; th_max=$TEMP
                warn "THERMAL THROTTLING began: ${TEMP} C, SM ${SM} MHz, ${PW} W, util ${UTIL}%"
            elif [ "$THERMAL" -eq 1 ]; then
                [ "$TEMP" -gt "$th_max" ] && th_max=$TEMP
            elif [ "$in_thermal" -eq 1 ]; then
                in_thermal=0
                warn "thermal throttling ended after $((SECONDS - th_start)) s (max ${th_max} C); now ${TEMP} C, SM ${SM} MHz"
            fi
            if [ "$HWSLOW" -eq 1 ] && [ "$in_hw" -eq 0 ]; then
                in_hw=1; hw_start=$SECONDS
                warn "HW SLOWDOWN / power brake began: ${TEMP} C, SM ${SM} MHz, ${PW} W"
            elif [ "$HWSLOW" -eq 0 ] && [ "$in_hw" -eq 1 ]; then
                in_hw=0; warn "HW slowdown ended after $((SECONDS - hw_start)) s"
            fi
            if [ "$TEMP" -ge "$WARN_TEMP_C" ] && [ "$w_warned" -eq 0 ]; then
                w_warned=1; warn "temperature ${TEMP} C >= ${WARN_TEMP_C} C (SM ${SM} MHz, ${PW} W, util ${UTIL}%)"
            fi

            # window
            w_n=$((w_n + 1))
            if [ "$UTIL" -ge "$BUSY_UTIL" ]; then
                w_busy=$((w_busy + 1)); w_clk=$((w_clk + SM)); [ "$SM" -lt "$w_minclk" ] && w_minclk=$SM
            fi
            [ "$TEMP" -gt "$w_maxt" ] && w_maxt=$TEMP
            w_th=$((w_th + THERMAL)); w_hw=$((w_hw + HWSLOW)); w_cap=$((w_cap + POWERCAP))
        else
            if [ "$gpu_up" -ne 0 ]; then gpu_up=0; log "gpu: not visible (dock detached / driver down) -- waiting"; fi
        fi

        if [ $((SECONDS - w_t0)) -ge "$SUMMARY_S" ]; then
            if [ "$w_busy" -gt 0 ]; then
                local msg
                msg=$(printf 'summary %ds: busy %d%%, SM while busy avg %d MHz min %d MHz, max %d C, thermal %ds, hw %ds, power cap %ds' \
                      "$((SECONDS - w_t0))" "$((w_busy * 100 / w_n))" "$((w_clk / w_busy))" "$w_minclk" "$w_maxt" \
                      "$((w_th * INTERVAL_S))" "$((w_hw * INTERVAL_S))" "$((w_cap * INTERVAL_S))")
                if [ "$w_th" -gt 0 ] || [ "$w_hw" -gt 0 ] || [ "$w_maxt" -ge "$WARN_TEMP_C" ]; then warn "$msg"; else log "$msg"; fi
            fi
            w_t0=$SECONDS; w_n=0; w_busy=0; w_clk=0; w_minclk=99999; w_maxt=0; w_th=0; w_hw=0; w_cap=0; w_warned=0
        fi
        sleep "$INTERVAL_S" &
        wait $!
    done
}

case "${1:-run}" in
    run)    run ;;
    report) shift; report "$@" ;;
    *) echo "usage: $0 [run | report [today|yesterday|YYYY-MM-DD]]" >&2; exit 2 ;;
esac
