#!/bin/bash
# runset.sh denial|niri amd|nvidia LABEL [firefox]: start that session on that render GPU (Denial: the build switch.sh installs), then phases.sh LABEL.
B=~/.cache/bench; L=~/.cache/denial/lab/bench-local
export XDG_RUNTIME_DIR=/run/user/$(id -u)
comp=$1 gpu=$2 label=$3; export BROWSER=$4
[ "$(cat /sys/class/power_supply/ACAD/online)" = 1 ] || { echo "on battery"; exit 1; }
$B/bench.sh stop >/dev/null 2>&1
restart() {
  systemctl --user stop niri.service 2>/dev/null
  sudo -n systemctl restart greetd.service
  for i in $(seq 40); do pgrep -x 'deniald|niri' >/dev/null || break; sleep 0.5; done
  systemctl --user reset-failed 2>/dev/null
  sudo -n rm -f /run/greetd-denial-initial-session && sudo -n systemctl restart greetd.service
  for i in $(seq 40); do pgrep -x "$1" >/dev/null && break; sleep 0.5; done
  sleep 10
}
if [ $comp = denial ]; then
  sudo -n cp $B/greetd-config.toml.orig /etc/greetd/config.toml
  bash $B/switch.sh $gpu | head -2
  pgrep -x deniald >/dev/null || restart deniald
else
  [ $gpu = amd ] && node=/dev/dri/renderD129 || node=/dev/dri/renderD128
  bash $B/niri-bench.sh $node
  sudo -n cp $B/greetd-config.toml.orig /etc/greetd/config.toml
  sudo -n sed -i 's#^command = "uwsm start -e -D Denial -- /usr/bin/denial-session"#command = "niri-session"#' /etc/greetd/config.toml
  restart niri
  pgrep -x noctalia >/dev/null || pgrep -f noctalia >/dev/null || echo "noctalia not seen"
fi
pgrep -x deniald >/dev/null || pgrep -x niri >/dev/null || { echo "$comp did not start"; exit 1; }
echo "== $label ($comp on $gpu, ${BROWSER:-chromium})"
[ $gpu = amd ] && pin=1 || pin=0
PIN=$pin bash $B/phases.sh $label 2>&1 | grep -E '^==|compositor|deniald|niri|noctalia|package power|NVIDIA board|page fps' | grep -v 'mem\b' | head -40
