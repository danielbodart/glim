#!/bin/sh
# Installs glim from an unpacked release tarball: the binary, its unit, the
# udev rules that start it, and the uleds module. Run as root from the
# directory it came in. `install.sh --uninstall` takes it all out again.
set -eu

here=$(cd "$(dirname "$0")" && pwd)

bin=/usr/local/bin/glim
unit=/etc/systemd/system/glim.service
rules=/etc/udev/rules.d/70-glim.rules
modules=/etc/modules-load.d/glim.conf

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: run as root (sudo $0)" >&2
    exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
    systemctl stop glim.service 2>/dev/null || true
    rm -f "$bin" "$unit" "$rules" "$modules"
    systemctl daemon-reload
    udevadm control --reload
    echo "glim removed. The keyboard stays at whatever brightness it was last set to."
    exit 0
fi

install -Dm755 "$here/glim" "$bin"
install -Dm644 "$here/glim.service" "$unit"
install -Dm644 "$here/glim.conf" "$modules"
"$bin" udev-rules > "$rules"
chmod 644 "$rules"

modprobe uleds
systemctl daemon-reload
udevadm control --reload
# The rules start glim when a Blade appears; this one already has, so start it
# by hand rather than waiting for the next boot.
systemctl restart glim.service
# UPower before 1.91 looks for keyboard backlights only when it starts.
systemctl try-restart upower.service

"$bin" probe
echo "glim installed and running: journalctl -u glim"
