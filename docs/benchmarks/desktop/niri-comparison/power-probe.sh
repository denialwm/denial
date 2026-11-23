#!/bin/bash
# power-probe.sh LABEL [SECS]: 890M clocks, power rails and scanout planes while a phase runs.
# Writes results/probe-LABEL.txt: RAPL package and core power, amdgpu_pm_info and DPM levels each second,
# and the eDP CRTC's planes (framebuffer format, modifier, size) from DRM debugfs.
B=~/.cache/bench; S=${2:-10}; OUT=$B/results/probe-$1.txt
D=$(for n in $(sudo -n ls /sys/kernel/debug/dri); do sudo -n grep -qs 'unique=0000:65:00.0' /sys/kernel/debug/dri/$n/name && echo /sys/kernel/debug/dri/$n && break; done)
DEV=/sys/bus/pci/devices/0000:65:00.0
cur() { grep '\*' $DEV/$1 2>/dev/null | awk '{print $2}'; }
{
p0=$(sudo -n cat /sys/class/powercap/intel-rapl:0/energy_uj); c0=$(sudo -n cat /sys/class/powercap/intel-rapl:0:0/energy_uj); t0=$(date +%s.%N)
for i in $(seq $S); do
  echo "t=$i busy=$(cat $DEV/gpu_busy_percent)% sclk=$(cur pp_dpm_sclk) mclk=$(cur pp_dpm_mclk) fclk=$(cur pp_dpm_fclk) socclk=$(cur pp_dpm_socclk) | $(sudo -n cat $D/amdgpu_pm_info | grep -E '\((MCLK|SCLK|average SoC including CPU)\)|GPU Load|VCN Load' | tr -s ' ' | paste -sd'|')"
  sleep 1
done
p1=$(sudo -n cat /sys/class/powercap/intel-rapl:0/energy_uj); c1=$(sudo -n cat /sys/class/powercap/intel-rapl:0:0/energy_uj); t1=$(date +%s.%N)
python3 -c "dt=$t1-$t0; print(f'package {($p1-$p0)/dt/1e6:.2f} W, cores {($c1-$c0)/dt/1e6:.2f} W, rest {(($p1-$p0)-($c1-$c0))/dt/1e6:.2f} W')"
echo "== planes"
sudo -n cat $D/state | awk '/^plane\[/{p=$0} /crtc=crtc/{c=$0} /fb=[0-9]/{f=$0} /format=|modifier=|size=|src=|crtc-pos=/{print p" "$0}' | grep -v 'fb=0' | head -40
echo "== crtc"
sudo -n cat $D/state | grep -A6 '^crtc\[' | grep -E 'crtc\[|enable=1|active|mode:' | head -12
} > $OUT 2>&1
tail -25 $OUT
