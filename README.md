# v100-egpu-host

Host-side scripts for running a **passive Tesla V100 PCIe 32 GB** on a consumer **OcuLink eGPU dock**: bringing the
card up after a cold boot (the dock's power, the PCIe link, the driver), keeping it cool (a PWM fan driven from the
GPU's own temperature), and ordering the inference service after both. Two shell scripts and two systemd units, no
daemons beyond `nvidia-smi`.

This is the host that serves [llama-superfast-v100-q8-inscora](https://github.com/gabtremblay/llama-superfast-v100-q8-inscora),
a llama.cpp fork tuned for this card: Qwen3.8-27B with a 245,760-token context on the one V100.

## Why this exists

A datacenter V100 has no fan and no power switch of its own, and this host is a small Ryzen mini-PC whose firmware
was never meant to see one: **with the card powered at POST the machine does not boot at all** — the firmware trips
over the 32 GB BAR it is asked to map, and there is no hacked BIOS for this board that enables Resizable BAR or
above-4G decoding to make it fit. So the card must be dark while the host boots and powered only once Linux owns
the PCI bus, with `pci=nocrs` letting the kernel assign the window the firmware refused. That is what the USB relay
is for: the dock was physically modified for it — its power switch is wired out to the relay's normally-open
contacts, so the host itself decides when the card gets power (the relay closing is the button being pressed). An eGPU dock's PCIe
link, in turn, only trains if the card has power *before* the port is enumerated, so powering it late needs the link
retrained. Left alone, a boot ends with no POST, or with the card absent, or present without its 32 GB BAR, or present
and silently cooking at 85 °C. The scripts here make the sequence deterministic:

1. **Power.** The dock's power switch is bypassed by a USB relay; the host closes it, waits for the rails.
2. **Link.** The host suspends to S3 for a few seconds and resumes: the resume retrains the PCIe port with the card
   now powered, which a plain bus rescan does not do on this platform. Then a rescan, and a check that BAR1 (the 32 GB
   window) was assigned.
3. **Driver.** `nvidia` and `nvidia_uvm` are loaded, persistence mode is set, the power limit is capped at 200 W (the
   passive heatsink's sustained budget; the card would ask for 250).
4. **Cooling.** A fan daemon reads `nvidia-smi`'s temperature every 3 s and writes the duty of a PWM header on an
   Aquacomputer QUADRO through the kernel's `aquacomputer_d5next` hwmon driver: a floor below the threshold, 100%
   above it, never 0%, a spin-up kick on first write, the duty re-asserted every minute so the controller's stored
   curve cannot take the channel back, 100% if the card is there but its temperature cannot be read.
5. **Shutdown.** The attach unit's `ExecStop` opens the relay, so the dock is dark before the next POST sees a trained
   card (a warm reboot can otherwise keep the relay latched through USB VBUS). The fan unit keeps following the curve
   until the card is below the threshold, then parks the fan at the floor.

## Bill of materials

What this host is built from. Equivalent parts work if the software can see them the same way (a serial relay with
an AT-style protocol, a fan controller with a kernel hwmon driver).

| Part | Used here | Role |
|---|---|---|
| GPU | NVIDIA Tesla V100 PCIe 32 GB (passive, 250 W TDP, run at 200 W) | the card |
| eGPU dock | OcuLink (SFF-8612) eGPU dock with its own PSU and power switch | PCIe slot, 12 V for the card |
| Host link | OcuLink 4i cable, PCIe Gen3 x4 (~3.3 GB/s) | the only path between host and card |
| Host | AMD Ryzen 7 5700U mini-PC, 16 threads, 32 GB RAM, Arch Linux, kernel 7.2 | runs the services and the containers |
| USB relay | DSD TECH SH-UR01A (Silicon Labs CP2102N, 9600 8N1, `AT+CH1=1/0`) | lets the host power the dock |
| Dock modification | the dock's power switch leads are brought out and wired across the relay's NO contacts (switch kept in parallel for manual use) | makes the dock switchable by the host |
| Fan controller | Aquacomputer QUADRO (USB, hwmon `quadro`, driver `aquacomputer_d5next`) | PWM output the daemon owns |
| Fan | one 4-pin PWM fan on QUADRO header 1, ducted onto the V100's heatsink | the cooling the card lacks |
| Kernel cmdline | `pci=nocrs iommu=pt pcie_aspm=off modprobe.blacklist=nouveau nouveau.modeset=0` | `pci=nocrs` so the kernel, not the firmware, assigns the 32 GB BAR (the firmware cannot: no Resizable BAR / above-4G option on this board); ASPM off keeps the eGPU link from dropping |

Not in the box: a GPU with its own fan needs only `boot-v100.sh`; a host whose firmware POSTs with the card present
(Resizable BAR / above-4G decoding available) can leave the dock powered and skip the relay (`boot-v100.sh` then only
does the S3 dance and the driver).

## Layout

```
bin/boot-v100.sh            attach sequence: relay -> S3 -> rescan -> BAR check -> driver -> persistence -> power cap
bin/v100-fan.sh             fan daemon: nvidia-smi temperature -> QUADRO pwm; power cap re-applied when the GPU (re)appears
systemd/v100-attach.service oneshot at boot (RemainAfterExit), ExecStop opens the relay at shutdown
systemd/v100-fan.service    the daemon, ordered after the attach unit
examples/llama-superfast.service  how an inference service chains after both (Requires= and After= on them)
```

## Install

```bash
sudo install -m 755 bin/boot-v100.sh /usr/local/sbin/boot-v100.sh
sudo install -m 755 bin/v100-fan.sh  /usr/local/bin/v100-fan.sh
sudo install -m 644 systemd/v100-attach.service systemd/v100-fan.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now v100-attach.service v100-fan.service
```

Then check:

```bash
journalctl -u v100-attach -b      # "GPU at 0000:04:00.0", "BAR1 @ 0x...", "V100 online."
journalctl -fu v100-fan           # one telemetry line a minute: power, temp, clock, util, memory, fan %/rpm
```

Settings live at the top of each script and in the units' `Environment=` line:

| Variable | Default | Meaning |
|---|---|---|
| `RELAY_DEV` | first `/dev/serial/by-id/usb-Silicon_Labs_CP2102N_*` | the relay's serial device |
| `SLEEP_SECS` | 8 | seconds in S3 while the link trains |
| `POWER_CAP_W` / `GPU_POWER_CAP_W` | 200 | `nvidia-smi -pl`, applied at attach and whenever the GPU reappears |
| `FAN_SLOT` | 1 | QUADRO header (`pwm1`..`pwm4`) |
| `FAN_ON_C`, `FAN_MAX_C` | 65, 65 | floor below `FAN_ON_C`, linear to 100% at `FAN_MAX_C`; equal values make a step |
| `FAN_MIN_PCT` | 40 | the floor; the fan never stops |
| `FAN_POLL_S` | 3 | temperature poll |

With this fan the V100 holds 65–70 °C at the 200 W cap under sustained decode, the fan at 100% above the threshold.

## Ordering an inference service after the card

`examples/llama-superfast.service` is the unit this host runs. The two lines that matter:

```ini
Requires=docker.service v100-attach.service v100-fan.service
After=docker.service v100-attach.service v100-fan.service network-online.target
```

`v100-attach.service` is `Type=oneshot` with `RemainAfterExit=yes`, so `After=` means "the card is up", not "the
script was launched". A Docker container must not be resurrected by `docker.service` before the card exists, so the
launcher runs it with `--restart no` and lets systemd (`Restart=always`) own restarts.

## Known behaviour

- The S3 dance means the host actually sleeps for `SLEEP_SECS` at every cold boot; a machine that cannot resume from
  S3 (some firmware with the relay's USB device waking it) needs `rtcwake` tested by hand first.
- A warm reboot with the relay left closed can POST with the card already trained and end up without BAR1; the
  attach unit's `ExecStop` exists for that. If it still happens, `boot-v100.sh off`, wait, `boot-v100.sh`.
- The fan daemon holds the QUADRO channel; the Aquacomputer software must not also drive it.
- `nvidia-smi -pl` below 250 W is accepted without root only with persistence mode on; the units run as root.

## License

MIT.
