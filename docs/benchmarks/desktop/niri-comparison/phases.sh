#!/bin/bash
# phases.sh LABEL [idle-only]: idle 20 s, desktop 30 s, fullscreen 30 s; PIN from the environment.
B=~/.cache/bench
fps() { grep -o 'bench-fps [0-9]*' $B/kiosk.log | tail -25 | awk '{s+=$2;n++} END {if(n) printf "page fps %.0f (%d samples)\n", s/n, n}'; }
geo() { if pgrep -x niri >/dev/null; then NIRI_SOCKET=$(ls $XDG_RUNTIME_DIR/niri.*.sock | head -1) niri msg --json windows > $B/results/windows-$1.json; fi; }
export XDG_RUNTIME_DIR=/run/user/$(id -u)
pgrep -f keepawake.py >/dev/null || { sudo -n setsid python3 $B/keepawake.py >/dev/null 2>&1 < /dev/null & }
$B/bench.sh stop >/dev/null 2>&1; sleep 2
echo "== idle"; $B/bench.sh measure 20 $1-idle
[ "$2" = idle-only ] && exit 0
$B/bench.sh desktop; sleep 12
geo $1-desktop; echo "== desktop"; $B/bench.sh measure 30 $1-desktop
$B/bench.sh full; sleep 10
geo $1-full; echo "== full"; $B/bench.sh measure 30 $1-full; fps | tee $B/results/fps-$1-full.txt
$B/bench.sh stop >/dev/null 2>&1
