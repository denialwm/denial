#!/bin/bash
# switch.sh amd|nvidia [audit]: new no-X11 Denial from bench-local on the chosen render GPU.
set -e
B=~/.cache/bench; L=~/.cache/denial/lab/bench-local
case $1 in amd) dev=pci-0000:65:00.0;; nvidia) dev=pci-0000:64:00.0;; *) exit 2;; esac
[ -f $B/deniald.r440 ] || cp /usr/bin/deniald $B/deniald.r440
sudo -n install -m755 $L/deniald.nox11 /usr/bin/.deniald.bench && sudo -n mv -f /usr/bin/.deniald.bench /usr/bin/deniald
sudo -n cp $B/session.conf.orig /etc/denial/session.conf
sudo -n sed -i "s#^export DENIAL_FLUTTER_BUNDLE=.*#export DENIAL_FLUTTER_BUNDLE=$L/shell#" /etc/denial/session.conf
# The display GPU (the 890M) renders unless nvidia is asked for.
if [ $1 = nvidia ]; then sudo -n sed -i "s|^#DENIAL_RENDER_DEVICE=.*|DENIAL_RENDER_DEVICE=/dev/dri/by-path/$dev-render|" /etc/denial/session.conf; fi
[ "$2" = audit ] || sudo -n sed -i 's/^export DENIAL_RENDER_AUDIT=1/#export DENIAL_RENDER_AUDIT=1/' /etc/denial/session.conf
sudo -n systemctl restart greetd.service
for i in $(seq 40); do pgrep -x 'deniald|niri' >/dev/null || break; sleep 0.5; done
sudo -n rm -f /run/greetd-denial-initial-session && sudo -n systemctl restart greetd.service
for i in $(seq 40); do pgrep -x deniald >/dev/null && break; sleep 0.5; done
sleep 8
P=$(pgrep -x deniald); echo "deniald $P $(sha256sum /proc/$P/exe | cut -c1-16)"
grep -oE '/[^ ]*libflutter_engine\.so' /proc/$P/maps | sort -u
pgrep -a Xwayland || echo "no Xwayland"
journalctl --user -b --since '-15s' --no-pager -o cat | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'Vulkan scene composer initialized|ERROR' | cut -c1-170
