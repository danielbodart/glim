# glim

> A *glim* is a light: old slang for a candle or a lamp. "Douse the glim" was
> to put it out, which is what your keyboard now does when the screen locks.

glim makes a Razer Blade's keyboard backlight a real LED on Linux, so the
desktop can drive it like any other laptop's:

- the **Keyboard Brightness** slider in GNOME's quick settings, and KDE's
- the backlight **off when the screen blanks or locks**, and back when it wakes
- **dimmed when idle**, with the display
- the **Fn brightness keys** and the slider kept in step, on GNOME

It is one static binary, about 100 KB, with no dependencies: no libc, no
Python, no DKMS, and no out-of-tree kernel module, so it keeps working under
Secure Boot and across kernel upgrades.

## How it works

A Blade's keyboard backlight lives in its embedded controller, which the
kernel has no driver for. Nothing appears in `/sys/class/leds`, so UPower --
and through it GNOME and KDE -- does not know there is a keyboard backlight to
control.

glim registers one through [uleds](https://docs.kernel.org/leds/uleds.html), a
module in the mainline kernel that lets a program provide an LED:

```
GNOME / KDE ──▶ UPower ──▶ /sys/class/leds/razer::kbd_backlight
                                         │ uleds
                                         ▼
                                       glim ──▶ /dev/hidrawN ──▶ Razer EC
```

Whatever sets the LED's brightness wakes glim with the new level, and glim
passes it to the EC as a 90-byte HID feature report. It sets brightness only,
so the effect and colour you chose -- in [rzrctrl](https://rzrctrl.com), say --
are left as they are.

glim is started by udev when a supported Blade appears, and never runs on any
other machine.

### The Fn keys

The Fn brightness keys never reach Linux as keys: the EC acts on them itself
and reports the new level on another of the Blade's HID interfaces -- every
level but 0, which it goes to without a word. glim listens there, and while Fn
is held asks the EC for its level every 100 ms, to catch that one.

Telling the desktop takes a second piece. GNOME ignores a brightness change it
hears of from UPower unless the kernel reported it, which an LED made through
uleds cannot. So `glim follow` runs in each desktop session, hears each Fn
change from glim over `/run/glim/fn.sock`, and sets it on GNOME's own
keyboard brightness. GNOME passes it back down through UPower, and glim
ignores that echo for 250 ms (`glim run --fn-hold-ms`) so it cannot undo a
press made since.

That interface is also a keyboard: every key press comes through it. hidraw
cannot hand over some reports and not others, so glim -- the root service,
and the only reader -- receives a copy of each, and drops it unread. `glim
follow` never opens the device.

## Install

### Any distribution with systemd

```bash
mkdir glim && cd glim
curl -fSL https://github.com/danielbodart/glim/releases/latest/download/glim-linux-x86_64.tar.gz | tar -xz
sudo ./install.sh
```

That puts `glim` in `/usr/local/bin`, its unit in `/etc/systemd/system`, its
udev rules in `/etc/udev/rules.d`, `uleds` in `/etc/modules-load.d`, and the
`glim-follow` user unit in `/etc/systemd/user`, enabled for every user from
their next login. Then it starts glim. `sudo ./install.sh --uninstall` takes
it all out again.

### NixOS

```nix
{
  inputs.glim = {
    url = "github:danielbodart/glim";
    inputs.nixpkgs.follows = "nixpkgs";
  };
}
```

```nix
{
  imports = [ inputs.glim.nixosModules.default ];
  services.glim.enable = true;
  # services.glim.follow = false;  # no glim-follow in desktop sessions
  # services.glim.fnHoldMs = 250;  # how long to ignore GNOME's echo of a Fn change
}
```

## Commands

```
glim probe        which Blade was found, and its brightness now
glim run          serve the LED (what glim.service runs)
glim follow       pass Fn changes on to GNOME (what glim-follow.service runs)
glim udev-rules   the rules that start glim.service on a Blade
glim version
```

`journalctl -u glim` shows what it found when it started, and any trouble
reaching the EC since; `journalctl --user -u glim-follow` the same for the
session side.

GNOME reads the keyboard's range once, when its power daemon starts, so a
first install needs a log out and in before the slider appears.

## Supported laptops

Every Blade that [OpenRazer](https://github.com/openrazer/openrazer) drives
with the same brightness command, from the 2016 Blade Stealth to the 2025
Blade 18 -- the full list is `models` in [src/razer.zig](src/razer.zig).

It has been tried on a **Blade 16 (2023)**. The rest are there on OpenRazer's
word; if yours works, or does not, please open an issue with the output of
`glim probe`.

## Building

Zig and Bun come from [mise](https://mise.jdx.dev), pinned in `.mise.toml`.
`./run test` runs the D-Bus client's test against a private bus it starts
with `dbus-run-session`, never the session it is run from.

```bash
./run          # lint, test, build
./run test     # unit tests
./run dist     # the release tarball
./run nix      # the flake's checks, including a NixOS VM test
```

## Thanks

- [OpenRazer](https://github.com/openrazer/openrazer), for the EC protocol and
  the list of models
- [rzrctrl](https://github.com/Razer-Linux/RazerControl), which showed the EC
  answers from userspace over hidraw
- [fw16-kbd-uleds](https://github.com/paco3346/fw16-kbd-uleds), which does the
  same for the Framework 16's keyboard

## Licence

MIT
