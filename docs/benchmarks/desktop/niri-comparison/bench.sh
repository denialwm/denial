#!/bin/bash
# bench.sh desktop|full|stop|measure SECONDS LABEL
# Same load for every compositor: every client on the AMD GPU.
B=~/.cache/bench
export XDG_RUNTIME_DIR=/run/user/$(id -u)
export WAYLAND_DISPLAY=$(cd $XDG_RUNTIME_DIR && ls wayland-* | grep -v lock | head -1)
# PIN=0 leaves clients on the GPU the compositor's dmabuf feedback names.
if [ "${PIN:-1}" = 1 ]; then
export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
export DRI_PRIME=pci-0000_65_00_0
export MESA_VK_DEVICE_SELECT=1002:150e!
fi
unset DISPLAY
run() { setsid "$@" >/dev/null 2>&1 < /dev/null & }
runlog() { setsid "$@" >/dev/null 2>$B/kiosk.log < /dev/null & }
case $1 in
desktop)
  run mpvpaper -o "no-audio loop hwdec=vaapi" '*' $B/wall.mp4
  sleep 1
  run chromium --class=bench-video --ozone-platform=wayland --user-data-dir=/tmp/bench-chromium --no-first-run \
      --no-default-browser-check --autoplay-policy=no-user-gesture-required \
      --new-window --window-size=1100,700 file://$B/video.html
  run kitty -o remember_window_size=no -o initial_window_width=700 -o initial_window_height=450 top -d 1
  ;;
full)
  runlog chromium --ozone-platform=wayland --user-data-dir=/tmp/bench-kiosk --no-first-run \
      --no-default-browser-check --enable-logging=stderr --kiosk file://$B/full.html
  ;;
stop)
  pkill -f 'user-data-dir=/tmp/bench-' ; pkill -x mpvpaper; pkill -f 'initial_window_width'
  ;;
measure)
  # measure SECONDS LABEL: CPU, GPU time, package power over the window, then memory.
  R=$B/results; mkdir -p $R
  e0=$(sudo -n cat /sys/class/powercap/intel-rapl:0/energy_uj); t0=$(date +%s.%N)
  nvidia-smi --query-gpu=power.draw,utilization.gpu,pstate --format=csv,noheader,nounits -lms 500 > $R/nvsmi-$3.txt 2>&1 &
  nv=$!
  python3 $B/compositor_load.py $2 --json $R/load-$3.json > $R/load-$3.txt
  kill $nv
  e1=$(sudo -n cat /sys/class/powercap/intel-rapl:0/energy_uj); t1=$(date +%s.%N)
  python3 -c "print(f'package power {($e1-$e0)/1e6/($t1-$t0):.2f} W')" | tee -a $R/load-$3.txt > $R/power-$3.txt
  python3 $B/compositor_memory.py --json $R/mem-$3.json > $R/mem-$3.txt
  nvidia-smi pmon -c 1 -s um > $R/nvidia-$3.txt 2>&1
  awk -F', ' '{p+=$1; u+=$2; n++} END {if(n) printf "NVIDIA board %.1f W, busy %.0f%%\n", p/n, u/n}' $R/nvsmi-$3.txt | tee -a $R/load-$3.txt > /dev/null
  cat $R/load-$3.txt; grep -E 'process|deniald|Xwayland|niri|noctalia|denial-' $R/mem-$3.txt
  ;;
esac
