#!/bin/sh
# Installs glim from an unpacked release tarball: the binary, its system unit
# and the udev rules that start it, the uleds module, and the user unit that
# keeps GNOME in step with the Fn keys. Run as root from the directory it came
# in. `install.sh --uninstall` takes it all out again.
set -eu

here=$(cd "$(dirname "$0")" && pwd)

bin=/usr/local/bin/glim
unit=/etc/systemd/system/glim.service
follow_unit=/etc/systemd/user/glim-follow.service
rules=/etc/udev/rules.d/70-glim.rules
modules=/etc/modules-load.d/glim.conf

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: run as root (sudo $0)" >&2
    exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
    systemctl stop glim.service 2>/dev/null || true
    systemctl --global disable glim-follow.service 2>/dev/null || true
    rm -f "$bin" "$unit" "$follow_unit" "$rules" "$modules"
    systemctl daemon-reload
    udevadm control --reload
    echo "glim removed. The keyboard stays at whatever brightness it was last set to."
    exit 0
fi

install -Dm755 "$here/glim" "$bin"
install -Dm644 "$here/glim.service" "$unit"
install -Dm644 "$here/glim-follow.service" "$follow_unit"
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
# For every user, from their next login.
systemctl --global enable glim-follow.service

"$bin" probe
echo "glim installed and running: journalctl -u glim"
echo "For the Fn keys to move GNOME's slider, log in again, or now:"
echo "  systemctl --user start glim-follow"
